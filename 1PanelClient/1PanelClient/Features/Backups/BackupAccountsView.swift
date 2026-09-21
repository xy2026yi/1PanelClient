//
//  BackupAccountsView.swift
//  1PanelClient
//
//  备份账号管理：MINIO / 阿里云OSS / WebDAV / SFTP 账号 列表 / 新增 / 编辑 / 删除。
//  新增与编辑需先「连接测试」通过才能保存（与网页端一致）；
//  accessKey / credential 以 base64 提交（后端解码），凭证仅在勾选
//  「记住认证信息」后才会回显。接口字段通过 logs/备份账号.md、logs/0818-新增备份.md 抓包验证。
//

import SwiftUI
import Combine

// MARK: - 模型

/// 备份账号（POST /backups/search 返回的 items 元素）
nonisolated struct BackupAccount: Decodable, Identifiable {
    let id: Int
    let name: String?
    let type: String?
    let isPublic: Bool?
    let bucket: String?
    let accessKey: String?
    let credential: String?
    let backupPath: String?
    let vars: String?
    let createdAt: String?
    let rememberAuth: Bool?

    var isLocal: Bool { type == "LOCAL" }
    /// 本机账号（localhost/LOCAL）不可删除
    var isProtected: Bool { isLocal || name == "localhost" }
    /// 当前客户端支持编辑表单的类型
    var isEditable: Bool { BackupAccountType(rawValue: type ?? "") != nil || isLocal }

    var displayType: String { type ?? "—" }
    var displayCreatedAt: String {
        guard let t = createdAt, t.count >= 10 else { return "—" }
        return String(t.prefix(10))
    }
}

/// 客户端支持创建/编辑的备份账号类型（LOCAL 仅可编辑）
enum BackupAccountType: String, CaseIterable, Identifiable {
    case minio = "MINIO"
    case oss = "OSS"
    case webdav = "WebDAV"
    case sftp = "SFTP"
    case cos = "COS"
    case s3 = "S3"
    case kodo = "KODO"
    case upyun = "UPYUN"
    case aliyun = "ALIYUN"
    case oneDrive = "OneDrive"
    case googleDrive = "GoogleDrive"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .minio:  return "MINIO"
        case .oss:    return L10n.t("阿里云OSS")
        case .webdav: return "WebDAV"
        case .sftp:   return "SFTP"
        case .cos:    return L10n.t("腾讯云COS")
        case .s3:     return L10n.t("亚马逊S3云存储")
        case .kodo:   return L10n.t("七牛云Kodo")
        case .upyun:  return L10n.t("又拍云")
        case .aliyun: return L10n.t("阿里云盘")
        case .oneDrive: return L10n.t("微软 OneDrive")
        case .googleDrive: return L10n.t("谷歌云盘")
        }
    }

    // MARK: 表单形态分组（对齐官方 hasAccessKey/hasPassword/isUPYUN/hasClient 等谓词）

    /// AK/SK + Endpoint + 桶（KODO 的 Endpoint 键名为 domain）
    var hasAccessKey: Bool {
        switch self {
        case .minio, .oss, .cos, .s3, .kodo: return true
        default: return false
        }
    }
    var hasPasswordAuth: Bool { self == .webdav || self == .sftp }
    var isUpyun: Bool { self == .upyun }
    var isAliyun: Bool { self == .aliyun }
    /// OAuth 客户端类型（client_id/secret/redirect_uri + 授权码换 token）
    var isOAuthClient: Bool { self == .oneDrive || self == .googleDrive }

    /// 桶选择页（自动获取）；UPYUN 服务名手动输入、ALIYUN/OAuth 无桶概念
    var supportsBucketListing: Bool { hasAccessKey }

    /// 「记住认证信息」：OAuth/阿里云盘不存凭证（对齐官方 hasRemember）
    var showsRememberAuth: Bool { !isOAuthClient && !isAliyun }

    /// 三页向导（连接页凭证+Endpoint，存储页桶+类型设置）
    var isThreePageWizard: Bool { hasAccessKey }
}

/// 阿里云OSS 存储类型（vars.scType）
enum OSSStorageType: String, CaseIterable, Identifiable {
    case standard = "Standard"
    case ia = "IA"
    case archive = "Archive"
    case coldArchive = "ColdArchive"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .standard:    return L10n.t("标准存储")
        case .ia:          return L10n.t("低频存储")
        case .archive:     return L10n.t("归档存储")
        case .coldArchive: return L10n.t("深度归档存储")
        }
    }

    var remark: String {
        switch self {
        case .standard:
            return L10n.t("适用于实时访问的大量热点文件、频繁的数据交互等业务场景")
        case .ia:
            return L10n.t("适用于较低访问频率（例如平均每月访问频率1到2次）的业务场景，最少存储30天")
        case .archive:
            return L10n.t("适用于极低访问频率（例如半年访问1次）的业务场景")
        case .coldArchive:
            return L10n.t("适用于极低访问频率（例如1年访问1～2次）的业务场景")
        }
    }
}

/// SFTP 认证方式
enum SFTPAuthMode: String, CaseIterable, Identifiable {
    case password
    case key
    var id: String { rawValue }
    var displayName: String { self == .password ? L10n.t("密码认证") : L10n.t("私钥认证") }
}

/// 备份账号分页查询请求
nonisolated struct BackupAccountSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let type: String
    let name: String
}

nonisolated struct BackupAccountListResponse: Decodable {
    let total: Int
    let items: [BackupAccount]?
}

/// varsJson 动态值（字符串 / 整数 / 布尔）
nonisolated enum BackupVarsValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let i = try? container.decode(Int.self) { self = .int(i) }
        else { self = .string(try container.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i):    try container.encode(i)
        case .bool(let b):   try container.encode(b)
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }
}

/// varsJson / vars：同一份键值对象，提交时 vars 为其 JSON 字符串形式
nonisolated struct BackupVarsJSON: Encodable, Equatable {
    var values: [String: BackupVarsValue]

    init(_ values: [String: BackupVarsValue] = [:]) { self.values = values }

    subscript(key: String) -> BackupVarsValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    /// 直接编码为 JSON 对象（不包 values 外层键）
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    /// 紧凑 JSON 字符串（键排序，保证同一表单状态产出稳定）
    var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(values), let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    /// 从服务端 vars 字符串解析（编辑回显用）
    static func parse(_ json: String?) -> BackupVarsJSON {
        guard let json, let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: BackupVarsValue].self, from: data) else {
            return BackupVarsJSON()
        }
        return BackupVarsJSON(dict)
    }
}

/// 创建 / 更新 / 连接测试 共用的请求体（dto.BackupOperate + varsJson）
nonisolated struct BackupAccountOperate: Encodable {
    var id: Int = 0
    var name: String
    var type: String
    var isPublic: Bool = false
    var bucket: String = ""
    /// base64 编码后的凭证（后端 StdEncoding 解码）
    var accessKey: String
    var credential: String
    var backupPath: String
    /// varsJson 的 JSON 字符串形式（后端实际使用此字段）
    var vars: String
    var varsJson: BackupVarsJSON
    var rememberAuth: Bool = false
    /// 编辑时原样回传（后端会以库中值为准）
    var createdAt: String?
}

/// 获取存储桶请求（MINIO）
nonisolated struct BackupBucketsRequest: Encodable {
    let isPublic: Bool
    let type: String
    let vars: String
    let accessKey: String
    let credential: String
}

/// 连接测试响应
nonisolated struct BackupCheckResult: Decodable {
    let isOk: Bool
    let msg: String?
    let token: String?
}

nonisolated struct BackupAccountDeleteRequest: Encodable {
    let id: Int
}

// MARK: - ViewModel

@MainActor
final class BackupAccountsViewModel: ObservableObject {
    /// 列表数据放 VM（PageVMStore 常驻）：重访页面直接渲染上次数据
    @Published var accounts: [BackupAccount] = []
    @Published var isLoading = false
    /// 首屏加载失败（空态展示重试按钮）；已有数据时刷新失败仅弹提示、保留旧列表
    @Published var loadFailed = false
    @Published var showAlert = false
    @Published var alertMessage = ""

    private let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient.shared(for: server)
    }

    /// 列表加载（进页 / 下拉 / 增删后）：失败保留旧数据。
    /// 首屏尚无内容时不短路：秒退秒进场景下在途刷新被取消、页面为空，
    /// 短路不仅让快照卡空态，还会让 autoRefresh 误记 5 秒节流窗口
    func refresh() async {
        guard !isLoading || accounts.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        if let list = await loadAccounts() {
            accounts = list
            loadFailed = false
        } else if Task.isCancelled {
            // 页面退出取消不是失败：不标加载失败
            return
        } else if accounts.isEmpty {
            loadFailed = true
        }
    }

    /// 加载全部账号（按 total 分页拉全）；失败返回 nil（调用方保留旧数据）
    func loadAccounts() async -> [BackupAccount]? {
        let pageSize = 100
        var all: [BackupAccount] = []
        do {
            var page = 1
            var total = Int.max
            while all.count < total && page <= 20 {
                let req = BackupAccountSearchRequest(page: page, pageSize: pageSize, type: "", name: "")
                let resp: BackupAccountListResponse = try await client.send(
                    path: APIEndpoint.backupAccountsSearch.path, body: req,
                    as: BackupAccountListResponse.self
                )
                let items = resp.items ?? []
                all.append(contentsOf: items)
                total = resp.total
                if items.count < pageSize { break }
                page += 1
            }
            return all
        } catch {
            // 页面退出取消不是失败：不弹窗
            guard !APIError.isCancellation(error) else { return nil }
            showAlert(message: L10n.f("加载备份账号失败：%@", error.localizedDescription))
            return nil
        }
    }

    /// 获取存储桶列表（MINIO / 阿里云OSS）；MINIO 仅含 endpoint，OSS 另带 scType
    /// alertOnError=false 时失败不弹 VM 级 alert（桶选择页自行提示）
    /// 拉取桶列表；出错返回 nil（与「成功且为空列表」区分，调用方按需弹窗/空态）
    func fetchBuckets(type: String, vars: BackupVarsJSON, accessKey: String, credential: String,
                      alertOnError: Bool = true) async -> [String]? {
        let req = BackupBucketsRequest(
            isPublic: false, type: type, vars: vars.jsonString,
            accessKey: accessKey, credential: credential
        )
        do {
            let buckets: [String] = try await client.send(
                path: APIEndpoint.backupAccountsBuckets.path, body: req, as: [String].self
            )
            return buckets
        } catch {
            if alertOnError {
                showAlert(message: L10n.f("获取桶失败：%@", error.localizedDescription))
            }
            return nil
        }
    }

    /// 凭据 Base64（表单提交与桶拉取共用）
    static func encodeBase64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    /// 连接测试；返回失败原因（成功返回 nil）
    /// 连接测试；成功时 OAuth 类型（OneDrive/GoogleDrive）响应携带 token
    ///（Base64 的 refresh_token，由调用方解码存入 vars）
    func checkConnection(_ op: BackupAccountOperate) async -> (reason: String?, token: String?) {
        do {
            let res: BackupCheckResult = try await client.send(
                path: APIEndpoint.backupAccountsCheck.path, body: op, as: BackupCheckResult.self
            )
            if res.isOk { return (nil, res.token) }
            let msg = res.msg ?? ""
            return (msg.isEmpty ? L10n.t("连接失败") : msg, nil)
        } catch {
            return (error.localizedDescription, nil)
        }
    }

    /// OAuth 默认客户端信息（GET /backups/client/:type，OneDrive/GoogleDrive 创建时预填）
    func loadOAuthClientInfo(type: String) async -> BackupClientInfo? {
        do {
            return try await client.send(
                path: APIEndpoint.backupAccountsClientInfo.path
                    .replacingOccurrences(of: ":type", with: type),
                method: "GET", as: BackupClientInfo.self)
        } catch {
            return nil
        }
    }

    /// 创建 / 更新
    func submitAccount(_ op: BackupAccountOperate, isCreate: Bool) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: isCreate ? APIEndpoint.backupAccountsCreate.path : APIEndpoint.backupAccountsUpdate.path,
                body: op,
                as: EmptyResponse.self
            )
            return true
        } catch {
            showAlert(message: L10n.f("%@失败：%@", isCreate ? L10n.t("创建") : L10n.t("保存"), error.localizedDescription))
            return false
        }
    }

    func deleteAccount(id: Int) async -> Bool {
        let req = BackupAccountDeleteRequest(id: id)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.backupAccountsDelete.path, body: req, as: EmptyResponse.self
            )
            return true
        } catch {
            showAlert(message: L10n.f("删除失败：%@", error.localizedDescription))
            return false
        }
    }

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }
}

// MARK: - 连接测试状态

enum ConnectionCheckState: Equatable {
    case none
    case ok
    case failed(String)
}

// MARK: - 账号列表页

struct BackupAccountsView: View {
    @StateObject private var vm: BackupAccountsViewModel
    @State private var showCreate = false
    @State private var pendingDelete: BackupAccount?

    init(server: ServerConfig) {
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(key: ManageItem.backupAccount.storeKey(server: server)) {
            BackupAccountsViewModel(server: server)
        })
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.accounts.isEmpty {
                LoadingStateView()
            } else if vm.accounts.isEmpty && vm.loadFailed {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(L10n.t("无法连接服务器，请检查网络后重试"))
                } actions: {
                    Button(L10n.t("重试")) {
                        Task { await vm.refresh() }
                    }
                }
            } else if vm.accounts.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无备份账号"),
                    systemImage: "externaldrive.badge.icloud",
                    description: Text(L10n.t("点击右上角 + 添加 MINIO / 阿里云OSS / WebDAV / SFTP 备份账号"))
                )
            } else {
                accountList
            }
        }
        .navigationTitle(L10n.t("备份账号"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("添加备份账号"))
            }
        }
        .navigationDestination(isPresented: $showCreate) {
            BackupAccountEditView(vm: vm, existing: nil) {
                Task { await vm.refresh() }
            }
        }
        .task { await PageVMStore.shared.autoRefresh(vm: vm) { await vm.refresh() } }
        .refreshable { await vm.refresh() }
        .alert(L10n.t("删除备份账号"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingDelete = nil }
            Button(L10n.t("删除"), role: .destructive) {
                Haptic.warning()
                if let account = pendingDelete {
                    Task {
                        if await vm.deleteAccount(id: account.id) {
                            await vm.refresh()
                        }
                    }
                }
                pendingDelete = nil
            }
        } message: {
            if let account = pendingDelete {
                Text(L10n.f("确定删除账号「%@」吗？使用该账号的计划任务备份将失败。", account.name ?? "—"))
            }
        }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
    }

    private var accountList: some View {
        List {
            Section {
                ForEach(vm.accounts) { account in
                    if account.isEditable {
                        NavigationLink {
                            BackupAccountEditView(vm: vm, existing: account) {
                                Task { await vm.refresh() }
                            }
                        } label: {
                            BackupAccountRow(account: account)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !account.isProtected {
                                Button(role: .destructive) {
                                    pendingDelete = account
                                } label: {
                                    Label(L10n.t("删除"), systemImage: "trash")
                                }
                            }
                        }
                    } else {
                        BackupAccountRow(account: account)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if !account.isProtected {
                                    Button(role: .destructive) {
                                        pendingDelete = account
                                    } label: {
                                        Label(L10n.t("删除"), systemImage: "trash")
                                    }
                                }
                            }
                    }
                }
            } footer: {
                Text(L10n.t("本机账号（LOCAL）为面板内置账号，不可删除；点击账号可编辑"))
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - 账号行

struct BackupAccountRow: View {
    let account: BackupAccount

    private var typeIcon: (name: String, color: Color) {
        switch account.type {
        case "LOCAL":  return ("internaldrive", .gray)
        case "MINIO":  return ("externaldrive.badge.icloud", .orange)
        case "OSS":    return ("externaldrive.badge.icloud", .indigo)
        case "WebDAV": return ("externaldrive.connected.to.line.below", .blue)
        case "SFTP":   return ("externaldrive.badge.timemachine", .green)
        case "COS":    return ("externaldrive.badge.icloud", .teal)
        case "S3":     return ("externaldrive.badge.icloud", .yellow)
        case "KODO":   return ("externaldrive.badge.icloud", .mint)
        case "UPYUN":  return ("externaldrive.connected.to.line.below", .cyan)
        case "ALIYUN": return ("externaldrive.badge.person.cloud", .blue)
        case "OneDrive": return ("externaldrive.badge.icloud", .blue)
        case "GoogleDrive": return ("externaldrive.badge.icloud", .red)
        default:       return ("externaldrive", .purple)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: typeIcon.name, color: typeIcon.color, cornerRadius: Radius.medium)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(account.name ?? "—")
                        .font(.body.bold())
                        .lineLimit(1)
                    if account.isProtected {
                        StatusBadge(text: L10n.t("内置"), color: .secondary)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(account.displayType)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(account.displayCreatedAt)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let bucket = account.bucket, !bucket.isEmpty {
            parts.append(L10n.f("桶: %@", bucket))
        }
        if let path = account.backupPath, !path.isEmpty {
            parts.append(path)
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

// MARK: - 新增 / 编辑表单

struct BackupAccountEditView: View {
    @ObservedObject var vm: BackupAccountsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// 传入则进入「编辑」模式，为 nil 则为「创建」
    let existing: BackupAccount?
    /// 保存成功回调（用于刷新列表）
    var onComplete: (() -> Void)? = nil

    // MARK: 表单状态
    /// WebDAV 端口 String ↔ 提交值（空=不带 port）
    private var webdavPortText: Binding<String> {
        Binding<String>(get: { webdavPort },
                        set: { webdavPort = $0.filter(\.isNumber) })
    }

    /// SFTP 端口 Int ↔ String（描边框用）
    private var sftpPortText: Binding<String> {
        Binding<String>(get: { String(sftpPort) },
                        set: { sftpPort = Int($0) ?? sftpPort })
    }

    @State private var name = ""
    @State private var type: BackupAccountType = .minio
    @State private var rememberAuth = false
    @State private var backupPath = ""

    // MINIO / 阿里云OSS（共用 Endpoint 与桶表单）
    @State private var accessKeyID = ""
    @State private var secretKey = ""
    @State private var endpointProto = "https"
    @State private var endpointHost = ""
    /// 桶录入方式：manual = 页内输入框；auto = 入口行 → 桶选择页自动获取回填
    @State private var bucketMode = "auto"
    @State private var bucket = ""
    @State private var showBucketPicker = false

    // 阿里云OSS
    @State private var ossScType: OSSStorageType = .standard

    // 腾讯云COS
    @State private var cosRegion = ""
    /// COS 地域录入：select = 常用地域菜单；manual = 手动输入（其他地域）
    @State private var cosRegionMode = "select"
    @State private var cosScType: COSScType = .standard

    // 亚马逊S3
    @State private var s3Region = ""
    @State private var s3ScType: S3ScType = .standard
    @State private var s3Mode: S3EndpointMode = .virtualHost

    // 七牛云Kodo（Endpoint 键名 domain；timeout 单位小时）
    @State private var kodoTimeout = 1

    // 阿里云盘（粘贴 token JSON 解析出 drive_id / refresh_token）
    @State private var aliyunToken = ""
    @State private var aliyunDriveID = ""
    @State private var aliyunRefreshToken = ""

    // OneDrive / GoogleDrive（授权码粘贴流）
    @State private var oauthClientID = ""
    @State private var oauthClientSecret = ""
    @State private var oauthRedirectURI = ""
    @State private var oauthCode = ""
    @State private var oneDriveIsCN = false
    /// 服务端默认客户端信息（OneDrive 创建态预填，切回国际版时恢复）
    @State private var defaultClientInfo: BackupClientInfo?
    /// 阿里云盘 token 解析结果提示
    @State private var aliyunParseHint: String?
    @State private var aliyunParseOK = false

    // WebDAV
    @State private var webdavAddress = ""
    /// WebDAV 端口（vars.port；留空不提交，地址可带 :port）
    @State private var webdavPort = ""
    @State private var webdavUsername = ""
    @State private var webdavPassword = ""

    // SFTP
    @State private var sftpAddress = ""
    @State private var sftpPort = 22
    @State private var sftpUsername = ""
    @State private var sftpAuthMode: SFTPAuthMode = .password
    @State private var sftpPassword = ""
    @State private var sftpPrivateKey = ""
    @State private var sftpPassPhrase = ""
    /// 编辑时保留原 vars 中的其他键（如 timeout）
    @State private var extraVars: [String: BackupVarsValue] = [:]

    // 状态
    @State private var checkState: ConnectionCheckState = .none
    @State private var isChecking = false
    @State private var isSubmitting = false
    @State private var showValidationAlert = false
    @State private var validationMessage = ""

    // 向导分页：MINIO/OSS 三页（基本信息 → 连接信息 → 存储桶），
    // WebDAV/SFTP 两页（基本信息 → 连接信息）；LOCAL 保持单页（工具栏保存）
    @State private var wizardPage = 0
    private var isThreePage: Bool { type.isThreePageWizard }
    private var wizardPageNames: [String] {
        isThreePage
            ? [L10n.t("基本信息"), L10n.t("连接信息"), L10n.t("存储桶")]
            : [L10n.t("基本信息"), L10n.t("连接信息")]
    }

    private var isEdit: Bool { existing != nil }
    private var isLocal: Bool { existing?.isLocal ?? false }

    /// 当前页必填是否满足（控制「下一步」；末页主操作用「连接测试通过」整表校验）
    private var pageReady: Bool {
        switch wizardPage {
        case 0:
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case 1:
            switch type {
            case .minio, .oss, .kodo:
                return !accessKeyID.isEmpty && !secretKey.isEmpty
                    && !endpointHost.trimmingCharacters(in: .whitespaces).isEmpty
            case .cos:
                return !accessKeyID.isEmpty && !secretKey.isEmpty
                    && !endpointHost.trimmingCharacters(in: .whitespaces).isEmpty
                    && !cosRegion.trimmingCharacters(in: .whitespaces).isEmpty
            case .s3:
                return !accessKeyID.isEmpty && !secretKey.isEmpty
                    && !endpointHost.trimmingCharacters(in: .whitespaces).isEmpty
                    && !s3Region.trimmingCharacters(in: .whitespaces).isEmpty
            case .upyun:
                return !accessKeyID.isEmpty && !secretKey.isEmpty
                    && !bucket.trimmingCharacters(in: .whitespaces).isEmpty
            case .aliyun:
                return !aliyunDriveID.isEmpty && !aliyunRefreshToken.isEmpty
            case .oneDrive, .googleDrive:
                return !oauthClientID.isEmpty && !oauthClientSecret.isEmpty
                    && !oauthRedirectURI.isEmpty
            default:
                return true
            }
        default:
            return true
        }
    }

    var body: some View {
        Group {
            if isLocal {
                localBody
            } else {
                wizardBody
            }
        }
        .navigationTitle(isEdit ? L10n.t("编辑备份账号") : L10n.t("添加备份账号"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(L10n.t("提示"), isPresented: $showValidationAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
        Text(validationMessage)
        }
        // 保存/获取桶等失败提示：本页被 push 展示，需自带 alert（父页面的会被遮挡）
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .task {
            if let account = existing { prefill(from: account) }
        }
        // 表单内容变化后需重新测试连接（与网页端一致：改动即失效）
        .onChange(of: formFingerprint) { _, _ in
            if checkState != .none { checkState = .none }
        }
    }

    /// LOCAL 内置账号：单页（基本信息 + 备份目录），右上角保存
    private var localBody: some View {
        Form {
            basicSection
            localPathSection
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text(isEdit ? L10n.t("保存") : L10n.t("确认")).bold()
                    }
                }
                .disabled(isSubmitting)
            }
        }
    }

    /// MINIO/OSS/WebDAV/SFTP：分页向导（底部导航；末页主操作 = 保存，需连接测试通过）
    private var wizardBody: some View {
        VStack(spacing: 0) {
            WizardStepsBar(pageNames: wizardPageNames, current: wizardPage)
            Form {
                Group {
                    switch wizardPage {
                    case 0:
                        basicSection
                    case 1:
                        connectionPage
                        if !isThreePage {
                            dirSection
                            checkSection
                        }
                    default:
                        storageExtrasSection
                        if type.supportsBucketListing {
                            bucketSection
                        }
                        dirSection
                        checkSection
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WizardBottomBar(
                page: wizardPage,
                totalPages: wizardPageNames.count,
                primaryTitle: isEdit ? L10n.t("保存") : L10n.t("确认"),
                isBusy: isSubmitting,
                primaryDisabled: wizardPage < wizardPageNames.count - 1
                    ? !pageReady : checkState != .ok,
                onBack: { withAnimation { wizardPage -= 1 } },
                onNext: { withAnimation { wizardPage += 1 } },
                onPrimary: { Task { await submit() } }
            )
        }
        .animation(.easeInOut(duration: 0.22), value: wizardPage)
        .modifier(WizardDiscardGuard(page: wizardPage))
        // 类型切换：OneDrive 创建态拉取服务端默认客户端信息预填
        .onChange(of: type) { _, newType in
            if newType == .oneDrive, !isEdit, defaultClientInfo == nil {
                Task {
                    defaultClientInfo = await vm.loadOAuthClientInfo(type: "Onedrive")
                    if !oneDriveIsCN, let info = defaultClientInfo,
                       oauthClientID.isEmpty {
                        oauthClientID = info.client_id ?? ""
                        oauthClientSecret = info.client_secret ?? ""
                        oauthRedirectURI = info.redirect_uri ?? ""
                    }
                }
            }
        }
        // 桶选择页（自动获取模式入口行进入；vars 由表单按类型预构建）
        .navigationDestination(isPresented: $showBucketPicker) {
            BackupBucketPickerView(
                vm: vm, type: type.rawValue,
                vars: varsForBuckets,
                accessKeyID: accessKeyID, secretKey: secretKey,
                bucket: $bucket)
        }
    }

    // MARK: 表单区块

    private var basicSection: some View {
        Section {
            OutlinedTextField(label: L10n.t("名称"), text: $name)
            if isEdit {
                // 类型不可改：描边只读框 + 锁标识
                OutlinedShape(label: L10n.t("类型"), isFocused: false,
                              hasValue: true,
                              trailing: {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }) {
                    Text(isLocal ? "LOCAL" : type.displayName)
                        .lineLimit(1)
                }
            } else {
                OutlinedPicker(label: L10n.t("类型"), options: BackupAccountType.allCases,
                               selection: $type) { $0.displayName }
            }
        } header: {
            Text(L10n.t("基本信息"))
        } footer: {
            if isEdit && !isLocal && (existing?.rememberAuth != true) {
                Text(L10n.t("该账号未记住认证信息，凭证需重新填写"))
            }
        }
    }

    /// 连接页内容：MINIO/OSS = 连接信息（凭证）+ Endpoint；WebDAV = 连接信息；SFTP = 连接信息 + 认证方式
    @ViewBuilder
    private var connectionPage: some View {
        switch type {
        case .minio, .oss:
            credentialsSection
            endpointSection()
        case .cos:
            credentialsSection
            cosRegionSection
            endpointSection()
        case .s3:
            credentialsSection
            s3RegionSection
            endpointSection()
        case .kodo:
            credentialsSection
            endpointSection(kodo: true)
        case .upyun:
            upyunSection
        case .aliyun:
            aliyunSection
        case .oneDrive, .googleDrive:
            oauthSection
        case .webdav:
            webdavSection
        case .sftp:
            sftpConnectionSection
            sftpAuthSection
        }
    }

    /// MINIO / 阿里云OSS 共用：Access Key 凭证（记住认证信息置于分组末尾）
    private var credentialsSection: some View {
        Section {
            OutlinedTextField(label: "Access Key ID", text: $accessKeyID)
            OutlinedPasswordField(label: "Secret Key", text: $secretKey)
            Toggle(L10n.t("记住认证信息"), isOn: $rememberAuth)
        } header: {
            Text(L10n.t("连接信息"))
        } footer: {
            Text(L10n.t("开启「记住认证信息」后凭证加密存储在服务器，编辑时可直接回显"))
        }
    }

    /// MINIO / OSS / COS / S3 / Kodo 共用：协议 + Endpoint 地址
    ///（KODO 的 Endpoint 是下载域名，vars 键名为 domain）
    private func endpointSection(kodo: Bool = false) -> some View {
        Section {
            OutlinedPicker(label: L10n.t("协议"), options: ["http", "https"],
                           selection: $endpointProto)
            OutlinedTextField(label: kodo ? L10n.t("域名") : L10n.t("Endpoint 地址"),
                              text: $endpointHost, keyboardType: .URL)
        } header: {
            Text(kodo ? L10n.t("域名") : "Endpoint")
        }
    }

    /// COS 地域：常用地域菜单 / 手动输入（其他地域）
    private var cosRegionSection: some View {
        Section {
            OutlinedPicker(label: L10n.t("地域"), options: ["select", "manual"],
                           selection: $cosRegionMode,
                           optionLabels: ["select": L10n.t("常用地域"),
                                          "manual": L10n.t("手动输入")])
            if cosRegionMode == "manual" {
                OutlinedTextField(label: L10n.t("地域"), prompt: "ap-guangzhou",
                                  text: $cosRegion, keyboardType: .URL)
            } else {
                OutlinedPicker(label: L10n.t("地域"), options: COSRegions.all,
                               selection: $cosRegion)
            }
        } header: {
            Text(L10n.t("地域"))
        }
    }

    /// S3 地域（自由输入，如 us-east-1）
    private var s3RegionSection: some View {
        Section {
            OutlinedTextField(label: L10n.t("地域"), prompt: "us-east-1",
                              text: $s3Region, keyboardType: .URL)
        } header: {
            Text(L10n.t("地域"))
        }
    }

    /// UPYUN：操作员 / 密码 / 服务名称（无 vars、无桶列表）
    private var upyunSection: some View {
        Section {
            OutlinedTextField(label: L10n.t("操作员"), text: $accessKeyID)
            OutlinedPasswordField(label: L10n.t("密码"), text: $secretKey)
            OutlinedTextField(label: L10n.t("服务名称"), text: $bucket)
            Toggle(L10n.t("记住认证信息"), isOn: $rememberAuth)
        } header: {
            Text(L10n.t("连接信息"))
        } footer: {
            Text(L10n.t("开启「记住认证信息」后凭证加密存储在服务器，编辑时可直接回显"))
        }
    }

    /// 阿里云盘：粘贴 token JSON 一键解析（drive_id / refresh_token）
    private var aliyunSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Token")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        parseAliyunToken()
                    } label: {
                        Label(L10n.t("解析"), systemImage: "wand.and.stars")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(aliyunToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                TextEditor(text: $aliyunToken)
                    .font(.caption.monospaced())
                    .frame(minHeight: 88)
                    .overlay(alignment: .topLeading) {
                        if aliyunToken.isEmpty {
                            Text("{ \"default_drive_id\": …, \"refresh_token\": … }")
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                    }
            }
            OutlinedTextField(label: "Drive ID", text: $aliyunDriveID,
                              keyboardType: .URL)
            OutlinedTextField(label: "Refresh Token", text: $aliyunRefreshToken,
                              keyboardType: .URL)
            if let hint = aliyunParseHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(aliyunParseOK ? .green : .red)
            }
        } header: {
            Text(L10n.t("连接信息"))
        } footer: {
            Text(L10n.t("粘贴整个 token 内容自动解析；阿里云盘非客户端下载单文件限 100 MB"))
        }
    }

    /// OneDrive / GoogleDrive：客户端信息 + 授权码粘贴流
    private var oauthSection: some View {
        Section {
            if type == .oneDrive {
                OutlinedPicker(label: L10n.t("版本"), options: ["global", "cn"],
                               selection: oneDriveEditionText,
                               optionLabels: ["global": L10n.t("国际版"),
                                              "cn": L10n.t("世纪互联")])
                    .onChange(of: oneDriveIsCN) { _, cn in
                        // 世纪互联需自填自有应用信息；切回国际版恢复服务端默认值
                        if cn {
                            oauthClientID = ""
                            oauthClientSecret = ""
                            oauthRedirectURI = ""
                        } else if let info = defaultClientInfo {
                            oauthClientID = info.client_id ?? ""
                            oauthClientSecret = info.client_secret ?? ""
                            oauthRedirectURI = info.redirect_uri ?? ""
                        }
                    }
            }
            OutlinedTextField(label: L10n.t("客户端 ID"), text: $oauthClientID,
                              keyboardType: .URL)
            OutlinedTextField(label: L10n.t("客户端密钥"), text: $oauthClientSecret,
                              keyboardType: .URL)
            OutlinedTextField(label: L10n.t("重定向 Url"), text: $oauthRedirectURI,
                              keyboardType: .URL)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L10n.t("授权码"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        openAuthorizePage()
                    } label: {
                        Label(L10n.t("打开授权页"), systemImage: "safari")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(oauthClientID.isEmpty || oauthRedirectURI.isEmpty)
                }
                TextEditor(text: $oauthCode)
                    .font(.caption.monospaced())
                    .frame(minHeight: 72)
                    .overlay(alignment: .topLeading) {
                        if oauthCode.isEmpty {
                            Text(L10n.t("在授权页完成登录后，从跳转地址中复制 code 参数粘贴至此"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                    }
            }
        } header: {
            Text(L10n.t("连接信息"))
        } footer: {
            Text(L10n.t("测试通过后服务端将以授权码换取令牌；编辑已有账号且令牌仍有效时可留空授权码"))
        }
    }

    /// 存储页的类型设置（OSS/COS/S3 存储类型、S3 寻址模式、Kodo 过期时间）
    @ViewBuilder
    private var storageExtrasSection: some View {
        switch type {
        case .oss:
            ossStorageSection
        case .cos:
            cosStorageSection
        case .s3:
            s3StorageSection
        case .kodo:
            kodoTimeoutSection
        default:
            EmptyView()
        }
    }

    /// COS 存储类型
    private var cosStorageSection: some View {
        Section {
            OutlinedPicker(label: L10n.t("存储类型"), options: COSScType.allCases,
                           selection: $cosScType) { $0.displayName }
        } header: {
            Text(L10n.t("存储类型"))
        } footer: {
            if cosScType.isArchive {
                Text(L10n.t("归档存储的文件无法直接下载，需先在云服务商网站恢复，请谨慎使用"))
            }
        }
    }

    /// S3 寻址模式 + 存储类型
    private var s3StorageSection: some View {
        Section {
            OutlinedPicker(label: L10n.t("寻址模式"), options: S3EndpointMode.allCases,
                           selection: $s3Mode) { $0.displayName }
            OutlinedPicker(label: L10n.t("存储类型"), options: S3ScType.allCases,
                           selection: $s3ScType) { $0.displayName }
        } header: {
            Text(L10n.t("存储类型"))
        } footer: {
            if s3ScType.isArchive {
                Text(L10n.t("归档存储的文件无法直接下载，需先在云服务商网站恢复，请谨慎使用"))
            }
        }
    }

    /// Kodo 上传请求过期时间（小时）
    private var kodoTimeoutSection: some View {
        Section {
            OutlinedUnitField(label: L10n.t("上传请求过期时间"), unit: L10n.t("小时"),
                              text: kodoTimeoutText, range: 1...720)
        } header: {
            Text(L10n.t("上传请求过期时间"))
        }
    }

    /// Kodo 过期时间 Int ↔ String
    private var kodoTimeoutText: Binding<String> {
        Binding<String>(get: { String(kodoTimeout) },
                        set: { kodoTimeout = Int($0) ?? kodoTimeout })
    }

    /// OneDrive 版本 String 键 ↔ isCN
    private var oneDriveEditionText: Binding<String> {
        Binding<String>(get: { oneDriveIsCN ? "cn" : "global" },
                        set: { oneDriveIsCN = $0 == "cn" })
    }

    /// 阿里云盘 token 解析（官方 loadFromTokenForAliyun：default_drive_id / refresh_token）
    private func parseAliyunToken() {
        guard let parsed = BackupOAuth.parseAliyunToken(
            aliyunToken.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            aliyunParseOK = false
            aliyunParseHint = L10n.t("Token 解析失败：需包含 default_drive_id 与 refresh_token")
            return
        }
        aliyunDriveID = parsed.driveID
        aliyunRefreshToken = parsed.refreshToken
        aliyunParseOK = true
        aliyunParseHint = L10n.t("解析成功：已填入 Drive ID 与 Refresh Token")
    }

    /// 打开 OAuth 授权页（Safari；用户复制跳转地址中的 code 回填）
    private func openAuthorizePage() {
        let url: URL?
        if type == .oneDrive {
            url = BackupOAuth.oneDriveAuthorizeURL(
                clientID: oauthClientID, redirectURI: oauthRedirectURI,
                isCN: oneDriveIsCN)
        } else {
            url = BackupOAuth.googleDriveAuthorizeURL(
                clientID: oauthClientID, redirectURI: oauthRedirectURI)
        }
        if let url { openURL(url) }
    }

    /// MINIO / 阿里云OSS 共用：桶录入（选择方式 + 手动输入 / 自动获取入口行）。
    /// 入口行用 Button 呈现（无 NavigationLink 系统尖角），点击进桶选择页
    private var bucketSection: some View {
        Section {
            OutlinedPicker(label: L10n.t("选择"), options: ["manual", "auto"],
                           selection: $bucketMode,
                           optionLabels: ["manual": L10n.t("手动输入"),
                                          "auto": L10n.t("自动获取")])
            if bucketMode == "manual" {
                OutlinedTextField(label: L10n.t("桶名"), text: $bucket)
            } else {
                Button {
                    showBucketPicker = true
                } label: {
                    // hasValue 恒真：空态标签浮到框线、内容显示「未获取」，
                    // 避免占位标签与内容文字同位重叠（与许可证空态同款处理）
                    OutlinedShape(label: L10n.t("桶"), isFocused: false,
                                  hasValue: true,
                                  trailing: {
                        Image(systemName: "externaldrive")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }) {
                        Text(bucket.isEmpty ? L10n.t("未获取") : bucket)
                            .foregroundStyle(bucket.isEmpty ? Color.secondary : Color.primary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text(L10n.t("存储桶"))
        } footer: {
            Text(L10n.t("自动获取时点击进入桶选择页获取列表，选中后自动回填"))
        }
    }

    /// OSS 存储类型（存储页，桶列表之上）
    private var ossStorageSection: some View {
        Section {
            OutlinedPicker(label: L10n.t("存储类型"), options: OSSStorageType.allCases,
                           selection: $ossScType) { $0.displayName }
        } header: {
            Text(L10n.t("存储类型"))
        } footer: {
            Text(ossScType.remark)
        }
    }

    private var webdavSection: some View {
        Section {
            OutlinedTextField(label: L10n.t("地址"), prompt: "https://example.com:5006",
                          text: $webdavAddress, keyboardType: .URL)
            OutlinedUnitField(label: L10n.t("端口"), unit: "", text: webdavPortText)
            OutlinedTextField(label: L10n.t("用户名"), text: $webdavUsername)
            OutlinedPasswordField(label: L10n.t("密码"), text: $webdavPassword)
            Toggle(L10n.t("记住认证信息"), isOn: $rememberAuth)
        } header: {
            Text(L10n.t("连接信息"))
        } footer: {
            Text(L10n.t("开启「记住认证信息」后凭证加密存储在服务器，编辑时可直接回显"))
        }
    }

    /// SFTP 连接信息（记住认证信息置于分组末尾）
    private var sftpConnectionSection: some View {
        Section {
            OutlinedTextField(label: L10n.t("地址"), text: $sftpAddress,
                          keyboardType: .URL)
            OutlinedUnitField(label: L10n.t("端口"), unit: "", prompt: "22",
                              text: sftpPortText)
            OutlinedTextField(label: L10n.t("用户名"), text: $sftpUsername)
            Toggle(L10n.t("记住认证信息"), isOn: $rememberAuth)
        } header: {
            Text(L10n.t("连接信息"))
        } footer: {
            Text(L10n.t("开启「记住认证信息」后凭证加密存储在服务器，编辑时可直接回显"))
        }
    }

    /// SFTP 认证方式（密码 / 私钥）
    private var sftpAuthSection: some View {
        Section {
            OutlinedPicker(label: L10n.t("认证方式"), options: SFTPAuthMode.allCases,
                           selection: $sftpAuthMode) { $0.displayName }

            if sftpAuthMode == .password {
                OutlinedPasswordField(label: L10n.t("密码"), text: $sftpPassword)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("私钥"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $sftpPrivateKey)
                        .font(.caption.monospaced())
                        .frame(minHeight: 110)
                        .overlay(alignment: .topLeading) {
                            if sftpPrivateKey.isEmpty {
                                Text("-----BEGIN OPENSSH PRIVATE KEY-----")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                OutlinedPasswordField(label: L10n.t("私钥密码"), prompt: L10n.t("可选"),
                              text: $sftpPassPhrase)
            }
        } header: {
            Text(L10n.t("认证方式"))
        }
    }

    /// LOCAL 内置账号：仅可改名称与备份目录（保存后服务器会移动现有备份）
    private var localPathSection: some View {
        Section {
            OutlinedTextField(label: L10n.t("备份目录"), prompt: "/opt/1panel/backup",
                          text: $backupPath)
        } header: {
            Text(L10n.t("备份目录"))
        } footer: {
            Text(L10n.t("修改后服务器会将现有备份文件移动到新目录"))
        }
    }

    /// 备份目录（MINIO/OSS 在存储页；WebDAV/SFTP 在连接页末尾）
    private var dirSection: some View {
        Section {
            OutlinedTextField(label: L10n.t("备份目录"), prompt: "/",
                          text: $backupPath, keyboardType: .URL)
        } header: {
            Text(L10n.t("备份目录"))
        } footer: {
            Text(L10n.t("备份目录为该账号下的备份存放路径，需手动填写（如 /backup）"))
        }
    }

    private var checkSection: some View {
        Section {
            Button {
                Task { await runCheck() }
            } label: {
                HStack {
                    Text(L10n.t("连接测试"))
                    Spacer()
                    switch checkState {
                    case .ok:
                        Label(L10n.t("通过"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .labelStyle(.titleAndIcon)
                    case .failed(let msg):
                        Text(msg)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    case .none:
                        if isChecking { ProgressView() }
                    }
                }
            }
            .disabled(isChecking)
        } header: {
            Text(L10n.t("连接测试"))
        } footer: {
            Text(L10n.t("测试通过后才能保存"))
        }
    }

    // MARK: 逻辑

    /// 表单指纹：任一输入变化都会改变，用于重置连接测试状态
    ///（不含 bucketMode——仅切换「手动输入/自动获取」不改实际提交值，
    ///  不应使已通过的连接测试失效）
    private var formFingerprint: String {
        [
            name, type.rawValue, String(rememberAuth), backupPath,
            accessKeyID, secretKey, endpointProto, endpointHost, bucket,
            ossScType.rawValue,
            cosRegion, cosScType.rawValue,
            s3Region, s3ScType.rawValue, s3Mode.rawValue,
            String(kodoTimeout),
            aliyunDriveID, aliyunRefreshToken,
            oauthClientID, oauthClientSecret, oauthRedirectURI, oauthCode,
            String(oneDriveIsCN),
            webdavAddress, webdavUsername, webdavPassword,
            sftpAddress, String(sftpPort), sftpUsername, sftpAuthMode.rawValue,
            sftpPassword, sftpPrivateKey, sftpPassPhrase,
        ].joined(separator: "¦")
    }

    private func prefill(from account: BackupAccount) {
        name = account.name ?? ""
        backupPath = account.backupPath ?? ""
        rememberAuth = account.rememberAuth ?? false
        type = BackupAccountType(rawValue: account.type ?? "") ?? .minio
        let vars = BackupVarsJSON.parse(account.vars)

        switch type {
        case .minio:
            let endpoint = Self.splitProto(vars["endpoint"]?.stringValue ?? "")
            if let proto = endpoint.proto { endpointProto = proto }
            endpointHost = endpoint.host
            bucket = account.bucket ?? ""
            // 已有桶名回显为手动输入（可直接改），空桶默认自动获取
            bucketMode = (account.bucket ?? "").isEmpty ? "auto" : "manual"
            // 保留 timeout 等其他键（与 OSS 一致）
            extraVars = vars.values.filter { !["endpointItem", "endpoint"].contains($0.key) }
        case .oss:
            let endpoint = Self.splitProto(vars["endpoint"]?.stringValue ?? "")
            if let proto = endpoint.proto { endpointProto = proto }
            endpointHost = endpoint.host
            bucket = account.bucket ?? ""
            // 已有桶名回显为手动输入（可直接改），空桶默认自动获取
            bucketMode = (account.bucket ?? "").isEmpty ? "auto" : "manual"
            if let sc = vars["scType"]?.stringValue, let t = OSSStorageType(rawValue: sc) {
                ossScType = t
            }
            // 保留 timeout 等其他键
            extraVars = vars.values.filter { !["scType", "endpointItem", "endpoint"].contains($0.key) }
        case .cos:
            let endpoint = Self.splitProto(vars["endpoint"]?.stringValue ?? "")
            if let proto = endpoint.proto { endpointProto = proto }
            endpointHost = endpoint.host
            bucket = account.bucket ?? ""
            bucketMode = (account.bucket ?? "").isEmpty ? "auto" : "manual"
            cosRegion = vars["region"]?.stringValue ?? ""
            // 非常用地域回落手动输入
            cosRegionMode = COSRegions.all.contains(cosRegion) ? "select" : "manual"
            if let sc = vars["scType"]?.stringValue, let t = COSScType(rawValue: sc) {
                cosScType = t
            }
            extraVars = vars.values.filter {
                !["region", "scType", "endpointItem", "endpoint"].contains($0.key)
            }
        case .s3:
            let endpoint = Self.splitProto(vars["endpoint"]?.stringValue ?? "")
            if let proto = endpoint.proto { endpointProto = proto }
            endpointHost = endpoint.host
            bucket = account.bucket ?? ""
            bucketMode = (account.bucket ?? "").isEmpty ? "auto" : "manual"
            s3Region = vars["region"]?.stringValue ?? ""
            if let sc = vars["scType"]?.stringValue, let t = S3ScType(rawValue: sc) {
                s3ScType = t
            }
            if let m = vars["mode"]?.stringValue, let t = S3EndpointMode(rawValue: m) {
                s3Mode = t
            }
            extraVars = vars.values.filter {
                !["region", "scType", "mode", "endpointItem", "endpoint"].contains($0.key)
            }
        case .kodo:
            // KODO 的 Endpoint 存于 domain 键
            let endpoint = Self.splitProto(vars["domain"]?.stringValue ?? "")
            if let proto = endpoint.proto { endpointProto = proto }
            endpointHost = endpoint.host
            bucket = account.bucket ?? ""
            bucketMode = (account.bucket ?? "").isEmpty ? "auto" : "manual"
            kodoTimeout = vars["timeout"]?.intValue ?? 1
            extraVars = vars.values.filter {
                !["domain", "timeout", "endpointItem"].contains($0.key)
            }
        case .upyun:
            bucket = account.bucket ?? ""
            extraVars = [:]
        case .aliyun:
            aliyunDriveID = vars["drive_id"]?.stringValue ?? ""
            aliyunRefreshToken = vars["refresh_token"]?.stringValue ?? ""
            // 保留 refresh_status / refresh_time 等键；token 仅是输入辅助不回填
            extraVars = vars.values.filter {
                !["drive_id", "refresh_token", "token"].contains($0.key)
            }
        case .oneDrive, .googleDrive:
            oauthClientID = vars["client_id"]?.stringValue ?? ""
            oauthClientSecret = vars["client_secret"]?.stringValue ?? ""
            oauthRedirectURI = vars["redirect_uri"]?.stringValue ?? ""
            if case .oneDrive = type, let cn = vars["isCN"]?.boolValue {
                oneDriveIsCN = cn
            }
            // 保留 refresh_token / refresh_status / refresh_time；code 不回填
            extraVars = vars.values.filter {
                !["client_id", "client_secret", "redirect_uri", "isCN", "code"].contains($0.key)
            }
        case .webdav:
            webdavAddress = vars["address"]?.stringValue ?? ""
            if let p = vars["port"]?.intValue { webdavPort = String(p) }
        case .sftp:
            sftpAddress = vars["address"]?.stringValue ?? ""
            if let p = vars["port"]?.intValue { sftpPort = p }
            if let mode = vars["authMode"]?.stringValue, let m = SFTPAuthMode(rawValue: mode) {
                sftpAuthMode = m
            }
            sftpPassPhrase = vars["passPhrase"]?.stringValue ?? ""
            // 保留 timeout 等其他键
            extraVars = vars.values.filter { !["address", "port", "authMode", "passPhrase"].contains($0.key) }
        }

        // 凭证仅记住认证时回显（服务端返回 base64，解码展示），且只填入当前类型对应的字段
        if rememberAuth {
            switch type {
            case .minio, .oss, .cos, .s3, .kodo, .upyun:
                accessKeyID = Self.decodeBase64(account.accessKey)
                secretKey = Self.decodeBase64(account.credential)
            case .aliyun, .oneDrive, .googleDrive:
                // 无 AK/SK 凭证概念（token 走 vars），且这两类不提供「记住认证信息」
                break
            case .webdav:
                webdavUsername = Self.decodeBase64(account.accessKey)
                webdavPassword = Self.decodeBase64(account.credential)
            case .sftp:
                sftpUsername = Self.decodeBase64(account.accessKey)
                let credential = Self.decodeBase64(account.credential)
                // 密码认证只回显密码，私钥认证只回显私钥，避免明文密码落入私钥输入框
                if sftpAuthMode == .password {
                    sftpPassword = credential
                } else {
                    sftpPrivateKey = credential
                }
            }
        }
    }

    private static func decodeBase64(_ text: String?) -> String {
        guard let text, !text.isEmpty, let data = Data(base64Encoded: text) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 拆分 "https://host" → (proto, host)；无协议时 proto 为 nil
    private static func splitProto(_ endpoint: String) -> (proto: String?, host: String) {
        if endpoint.hasPrefix("https://") {
            return ("https", String(endpoint.dropFirst("https://".count)))
        }
        if endpoint.hasPrefix("http://") {
            return ("http", String(endpoint.dropFirst("http://".count)))
        }
        return (nil, endpoint)
    }

    /// 校验必填项，返回错误信息（通过返回 nil）
    private func validationError() -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.t("请填写名称")
        }
        guard !isLocal else { return nil }
        switch type {
        case .minio, .oss, .kodo:
            if accessKeyID.isEmpty { return L10n.t("请填写 Access Key ID") }
            if secretKey.isEmpty { return L10n.t("请填写 Secret Key") }
            if endpointHost.isEmpty {
                return L10n.t(type == .kodo ? "请填写域名" : "请填写 Endpoint 地址")
            }
            if bucket.trimmingCharacters(in: .whitespaces).isEmpty { return L10n.t("请选择或填写桶") }
        case .cos:
            if accessKeyID.isEmpty { return L10n.t("请填写 Access Key ID") }
            if secretKey.isEmpty { return L10n.t("请填写 Secret Key") }
            if endpointHost.isEmpty { return L10n.t("请填写 Endpoint 地址") }
            if cosRegion.trimmingCharacters(in: .whitespaces).isEmpty { return L10n.t("请填写地域") }
            if bucket.trimmingCharacters(in: .whitespaces).isEmpty { return L10n.t("请选择或填写桶") }
        case .s3:
            if accessKeyID.isEmpty { return L10n.t("请填写 Access Key ID") }
            if secretKey.isEmpty { return L10n.t("请填写 Secret Key") }
            if endpointHost.isEmpty { return L10n.t("请填写 Endpoint 地址") }
            if s3Region.trimmingCharacters(in: .whitespaces).isEmpty { return L10n.t("请填写地域") }
            if bucket.trimmingCharacters(in: .whitespaces).isEmpty { return L10n.t("请选择或填写桶") }
        case .upyun:
            if accessKeyID.isEmpty { return L10n.t("请填写操作员") }
            if secretKey.isEmpty { return L10n.t("请填写密码") }
            if bucket.trimmingCharacters(in: .whitespaces).isEmpty { return L10n.t("请填写服务名称") }
        case .aliyun:
            if aliyunDriveID.isEmpty { return L10n.t("请填写 Drive ID") }
            if aliyunRefreshToken.isEmpty { return L10n.t("请填写 Refresh Token") }
        case .oneDrive, .googleDrive:
            if oauthClientID.isEmpty { return L10n.t("请填写客户端 ID") }
            if oauthClientSecret.isEmpty { return L10n.t("请填写客户端密钥") }
            if oauthRedirectURI.isEmpty { return L10n.t("请填写重定向 Url") }
            // 首次绑定需授权码；已有 refresh_token（编辑）且未改动客户端信息时可免
            if oauthCode.isEmpty, extraVars["refresh_token"] == nil {
                return L10n.t("请填写授权码")
            }
        case .webdav:
            if webdavAddress.isEmpty { return L10n.t("请填写地址") }
            if webdavUsername.isEmpty { return L10n.t("请填写用户名") }
            if webdavPassword.isEmpty { return L10n.t("请填写密码") }
        case .sftp:
            if sftpAddress.isEmpty { return L10n.t("请填写地址") }
            if sftpUsername.isEmpty { return L10n.t("请填写用户名") }
            if sftpAuthMode == .password && sftpPassword.isEmpty { return L10n.t("请填写密码") }
            if sftpAuthMode == .key && sftpPrivateKey.isEmpty { return L10n.t("请填写私钥") }
        }
        return nil
    }

    /// 构造 vars / varsJson（按类型，键形状经 BackupAccountVarsBuilder 与官方前端对齐）
    private func buildVars(includeOAuthCode: Bool = true) -> BackupVarsJSON {
        let host = endpointHost.trimmingCharacters(in: .whitespaces)
        var vars: BackupVarsJSON
        switch type {
        case .minio:
            vars = BackupAccountVarsBuilder.minio(proto: endpointProto, host: host)
        case .oss:
            vars = BackupAccountVarsBuilder.oss(proto: endpointProto, host: host,
                                                scType: ossScType.rawValue)
        case .cos:
            vars = BackupAccountVarsBuilder.cos(proto: endpointProto, host: host,
                                                region: cosRegion.trimmingCharacters(in: .whitespaces),
                                                scType: cosScType.rawValue)
        case .s3:
            vars = BackupAccountVarsBuilder.s3(proto: endpointProto, host: host,
                                               region: s3Region.trimmingCharacters(in: .whitespaces),
                                               scType: s3ScType.rawValue,
                                               mode: s3Mode.rawValue)
        case .kodo:
            vars = BackupAccountVarsBuilder.kodo(proto: endpointProto, host: host,
                                                 timeoutHours: kodoTimeout)
        case .upyun:
            vars = BackupAccountVarsBuilder.upyun()
        case .aliyun:
            vars = BackupAccountVarsBuilder.aliyun(
                driveID: aliyunDriveID.trimmingCharacters(in: .whitespaces),
                refreshToken: aliyunRefreshToken.trimmingCharacters(in: .whitespaces))
        case .oneDrive, .googleDrive:
            // isCN 仅 OneDrive 携带；code 仅测试时携带（保存走 extraVars 里的 refresh_token）
            vars = BackupAccountVarsBuilder.oauthClient(
                clientID: oauthClientID.trimmingCharacters(in: .whitespaces),
                clientSecret: oauthClientSecret.trimmingCharacters(in: .whitespaces),
                redirectURI: oauthRedirectURI.trimmingCharacters(in: .whitespaces),
                isCN: type == .oneDrive ? oneDriveIsCN : nil,
                code: includeOAuthCode
                    ? oauthCode.trimmingCharacters(in: .whitespaces).removingPercentEncoding
                    : nil)
        case .webdav:
            vars = BackupVarsJSON()
            vars["address"] = .string(webdavAddress.trimmingCharacters(in: .whitespaces))
            if let p = Int(webdavPort), p > 0 {
                vars["port"] = .int(p)
            }
        case .sftp:
            vars = BackupVarsJSON()
            vars["address"] = .string(sftpAddress.trimmingCharacters(in: .whitespaces))
            vars["port"] = .int(sftpPort)
            vars["authMode"] = .string(sftpAuthMode.rawValue)
            if sftpAuthMode == .key, !sftpPassPhrase.isEmpty {
                vars["passPhrase"] = .string(sftpPassPhrase)
            }
        }
        for (k, v) in extraVars where vars[k] == nil {
            vars[k] = v
        }
        return vars
    }

    /// 拉桶用的 vars：与提交同形，但剥离 endpointItem（对齐官方 getBuckets 的 undefined 处理）
    private var varsForBuckets: BackupVarsJSON {
        let vars = buildVars()
        var copy = vars
        copy["endpointItem"] = nil
        return copy
    }

    /// 构造提交/测试共用请求体（凭证 base64）
    private func buildOperate() -> BackupAccountOperate {
        // LOCAL 内置账号没有 MINIO/OSS/WebDAV/SFTP 表单，vars 沿用服务端原值，
        // 避免把其他类型形状的空表单数据覆写进记录
        let vars: BackupVarsJSON = isLocal ? BackupVarsJSON.parse(existing?.vars) : buildVars()
        let userKey: String
        let secret: String
        switch type {
        case .minio, .oss, .cos, .s3, .kodo, .upyun:
            userKey = BackupAccountsViewModel.encodeBase64(accessKeyID)
            secret = BackupAccountsViewModel.encodeBase64(secretKey)
        case .aliyun, .oneDrive, .googleDrive:
            // 无 AK/SK 概念（token 走 vars），凭证为空串
            userKey = ""
            secret = ""
        case .webdav:
            userKey = BackupAccountsViewModel.encodeBase64(webdavUsername)
            secret = BackupAccountsViewModel.encodeBase64(webdavPassword)
        case .sftp:
            userKey = BackupAccountsViewModel.encodeBase64(sftpUsername)
            secret = sftpAuthMode == .password
                ? BackupAccountsViewModel.encodeBase64(sftpPassword)
                : BackupAccountsViewModel.encodeBase64(sftpPrivateKey)
        }
        return BackupAccountOperate(
            id: existing?.id ?? 0,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            type: isLocal ? "LOCAL" : type.rawValue,
            isPublic: false,
            bucket: isLocal ? "" : bucket.trimmingCharacters(in: .whitespaces),
            accessKey: isLocal ? "" : userKey,
            credential: isLocal ? "" : secret,
            backupPath: backupPath.isEmpty ? "/" : backupPath,
            vars: vars.jsonString,
            varsJson: vars,
            rememberAuth: rememberAuth,
            createdAt: existing?.createdAt
        )
    }

    private func runCheck() async {
        if let error = validationError() {
            validationMessage = error
            showValidationAlert = true
            return
        }
        isChecking = true
        defer { isChecking = false }
        // 记录发起测试时的表单指纹：测试期间表单被改动则结果作废，
        // 防止基于旧凭证的结果放行新表单保存
        let fingerprintAtStart = formFingerprint
        let result = await vm.checkConnection(buildOperate())
        guard formFingerprint == fingerprintAtStart else {
            checkState = .none
            return
        }
        guard let reason = result.reason else {
            checkState = .ok
            handleCheckToken(result.token)
            return
        }
        checkState = .failed(reason)
    }

    /// 测试通过后的令牌回写（对齐官方 onCheck 成功分支）：
    /// OAuth 类型用响应 token（Base64 refresh_token）落 extraVars；
    /// OAuth / 阿里云盘补 refresh_status / refresh_time（extraVars 变化不触发重测，
    /// 与表单指纹不含 extraVars 的既有语义一致）
    private func handleCheckToken(_ token: String?) {
        let now = Self.refreshTimeFormatter.string(from: Date())
        if type.isOAuthClient, let token, !token.isEmpty {
            let decoded = BackupOAuth.decodeRefreshToken(token)
            if !decoded.isEmpty {
                extraVars["refresh_token"] = .string(decoded)
            }
        }
        if type.isOAuthClient || type.isAliyun {
            extraVars["refresh_status"] = .string("Success")
            extraVars["refresh_time"] = .string(now)
        }
    }

    /// refresh_time 格式（官方 dateFormat 的 YYYY-MM-DD HH:mm:ss）
    private static let refreshTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private func submit() async {
        if let error = validationError() {
            validationMessage = error
            showValidationAlert = true
            return
        }
        // 与网页端一致：连接测试通过后才允许保存（本机账号除外）
        guard isLocal || checkState == .ok else {
            validationMessage = L10n.t("请先通过连接测试")
            showValidationAlert = true
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        if await vm.submitAccount(buildOperate(), isCreate: !isEdit) {
            onComplete?()
            dismiss()
        }
    }
}

// MARK: - 桶选择页（存储页入口行进入）

/// 桶选择页：进入自动获取桶列表，选中行自动返回回填；获取失败可重试或手动输入。
/// vars 由表单按类型预构建（endpoint/domain/region/scType 等，endpointItem 已剥离）
private struct BackupBucketPickerView: View {
    @ObservedObject var vm: BackupAccountsViewModel
    let type: String
    let vars: BackupVarsJSON
    let accessKeyID: String
    let secretKey: String
    @Binding var bucket: String

    @Environment(\.dismiss) private var dismiss
    @State private var buckets: [String] = []
    @State private var isLoading = false
    /// 获取失败弹窗提示（不再渲染页内错误态；可在弹窗中重试）
    @State private var showFetchFailAlert = false
    /// 失败原因（缺失凭证项给具体文案，请求失败为通用文案）
    @State private var fetchFailMessage = ""

    var body: some View {
        List {
            if isLoading && buckets.isEmpty {
                HStack { Spacer(); LoadingStateView(); Spacer() }
                    .listRowBackground(Color.clear)
            } else if buckets.isEmpty {
                Section {
                    Text(L10n.t("未获取到桶列表"))
                        .foregroundStyle(.secondary)
                } footer: {
                    Text(L10n.t("获取失败或列表中没有目标桶时可手动填写"))
                }
            } else {
                Section {
                    ForEach(buckets, id: \.self) { name in
                        Button {
                            bucket = name
                            dismiss()
                        } label: {
                            HStack {
                                Text(name).font(.dataMonospacedBody)
                                Spacer()
                                if name == bucket {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(L10n.f("共 %ld 个桶", buckets.count))
                }
            }

            // 获取失败或列表中没有目标桶时的兜底
            Section {
                OutlinedTextField(label: L10n.t("桶名"), text: $bucket)
            } header: {
                Text(L10n.t("手动输入"))
            } footer: {
                Text(L10n.t("获取失败或列表中没有目标桶时可手动填写"))
            }
        }
        .navigationTitle(L10n.t("选择桶"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await fetch() }
        .alert(L10n.t("提示"), isPresented: $showFetchFailAlert) {
            Button(L10n.t("重试")) { Task { await fetch() } }
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(fetchFailMessage.isEmpty ? L10n.t("获取桶失败") : fetchFailMessage)
        }
    }

    private func fetch() async {
        // 凭证缺失给出具体缺失项（Endpoint/地域等由表单页门控保证非空）
        if accessKeyID.isEmpty {
            fetchFailMessage = L10n.t("请填写 Access Key ID")
            showFetchFailAlert = true
            return
        }
        if secretKey.isEmpty {
            fetchFailMessage = L10n.t("请填写 Secret Key")
            showFetchFailAlert = true
            return
        }
        isLoading = true
        defer { isLoading = false }
        // 静默拉取：失败由本页弹窗提示（VM 级 alert 会在返回后才弹出）
        let list = await vm.fetchBuckets(
            type: type, vars: vars,
            accessKey: BackupAccountsViewModel.encodeBase64(accessKeyID),
            credential: BackupAccountsViewModel.encodeBase64(secretKey),
            alertOnError: false)
        // nil=请求失败（弹窗可重试）；成功但空列表走页内「未获取到桶列表」空态 + 手动输入兜底
        if let list {
            buckets = list
        } else {
            fetchFailMessage = L10n.t("获取桶失败")
            showFetchFailAlert = true
        }
    }
}
