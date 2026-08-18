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

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .minio:  return "MINIO"
        case .oss:    return "阿里云OSS"
        case .webdav: return "WebDAV"
        case .sftp:   return "SFTP"
        }
    }
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
        case .standard:    return "标准存储"
        case .ia:          return "低频存储"
        case .archive:     return "归档存储"
        case .coldArchive: return "深度归档存储"
        }
    }

    var remark: String {
        switch self {
        case .standard:
            return "适用于实时访问的大量热点文件、频繁的数据交互等业务场景"
        case .ia:
            return "适用于较低访问频率（例如平均每月访问频率1到2次）的业务场景，最少存储30天"
        case .archive:
            return "适用于极低访问频率（例如半年访问1次）的业务场景"
        case .coldArchive:
            return "适用于极低访问频率（例如1年访问1～2次）的业务场景"
        }
    }
}

/// SFTP 认证方式
enum SFTPAuthMode: String, CaseIterable, Identifiable {
    case password
    case key
    var id: String { rawValue }
    var displayName: String { self == .password ? "密码认证" : "私钥认证" }
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
    @Published var showAlert = false
    @Published var alertMessage = ""

    private let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
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
            showAlert(message: "加载备份账号失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 获取存储桶列表（MINIO / 阿里云OSS）；MINIO 仅含 endpoint，OSS 另带 scType
    func fetchBuckets(type: String, vars: BackupVarsJSON, accessKey: String, credential: String) async -> [String] {
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
            showAlert(message: "获取桶失败：\(error.localizedDescription)")
            return []
        }
    }

    /// 连接测试；返回失败原因（成功返回 nil）
    func checkConnection(_ op: BackupAccountOperate) async -> String? {
        do {
            let res: BackupCheckResult = try await client.send(
                path: APIEndpoint.backupAccountsCheck.path, body: op, as: BackupCheckResult.self
            )
            if res.isOk { return nil }
            let msg = res.msg ?? ""
            return msg.isEmpty ? "连接失败" : msg
        } catch {
            return error.localizedDescription
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
            showAlert(message: "\(isCreate ? "创建" : "保存")失败：\(error.localizedDescription)")
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
            showAlert(message: "删除失败：\(error.localizedDescription)")
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
    @State private var accounts: [BackupAccount] = []
    @State private var isLoading = false
    /// 首屏加载失败（空态展示重试按钮）；已有数据时刷新失败仅弹提示、保留旧列表
    @State private var loadFailed = false
    @State private var showCreate = false
    @State private var pendingDelete: BackupAccount?

    init(server: ServerConfig) {
        _vm = StateObject(wrappedValue: BackupAccountsViewModel(server: server))
    }

    var body: some View {
        Group {
            if isLoading && accounts.isEmpty {
                ProgressView("加载中…")
            } else if accounts.isEmpty && loadFailed {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("无法连接服务器，请检查网络后重试")
                } actions: {
                    Button("重试") {
                        Task { await load() }
                    }
                }
            } else if accounts.isEmpty {
                ContentUnavailableView(
                    "暂无备份账号",
                    systemImage: "externaldrive.badge.icloud",
                    description: Text("点击右下角 + 添加 MINIO / 阿里云OSS / WebDAV / SFTP 备份账号")
                )
            } else {
                accountList
            }
        }
        .navigationTitle("备份账号")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottomTrailing) {
            FloatingActionButton(action: {
                showCreate = true
            })
            .accessibilityLabel("添加备份账号")
        }
        .navigationDestination(isPresented: $showCreate) {
            BackupAccountEditView(vm: vm, existing: nil) {
                Task { await load() }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .alert("删除备份账号", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let account = pendingDelete {
                    Task {
                        if await vm.deleteAccount(id: account.id) {
                            await load()
                        }
                    }
                }
                pendingDelete = nil
            }
        } message: {
            if let account = pendingDelete {
                Text("确定删除账号「\(account.name ?? "—")」吗？使用该账号的计划任务备份将失败。")
            }
        }
        .alert("提示", isPresented: $vm.showAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
    }

    private var accountList: some View {
        List {
            Section {
                ForEach(accounts) { account in
                    if account.isEditable {
                        NavigationLink {
                            BackupAccountEditView(vm: vm, existing: account) {
                                Task { await load() }
                            }
                        } label: {
                            BackupAccountRow(account: account)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !account.isProtected {
                                Button(role: .destructive) {
                                    pendingDelete = account
                                } label: {
                                    Label("删除", systemImage: "trash")
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
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                    }
                }
            } footer: {
                Text("本机账号（LOCAL）为面板内置账号，不可删除；点击账号可编辑")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        // 加载失败保留旧列表（loadAccounts 失败返回 nil 并已弹提示）
        if let list = await vm.loadAccounts() {
            accounts = list
            loadFailed = false
        } else if accounts.isEmpty {
            loadFailed = true
        }
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
        default:       return ("externaldrive", .purple)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: typeIcon.name, color: typeIcon.color, cornerRadius: 12)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(account.name ?? "—")
                        .font(.body.bold())
                        .lineLimit(1)
                    if account.isProtected {
                        StatusBadge(text: "内置", color: .secondary)
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
            parts.append("桶: \(bucket)")
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
    /// 传入则进入「编辑」模式，为 nil 则为「创建」
    let existing: BackupAccount?
    /// 保存成功回调（用于刷新列表）
    var onComplete: (() -> Void)? = nil

    // MARK: 表单状态
    @State private var name = ""
    @State private var type: BackupAccountType = .minio
    @State private var rememberAuth = false
    @State private var backupPath = ""

    // MINIO / 阿里云OSS（共用 Endpoint 与桶表单）
    @State private var accessKeyID = ""
    @State private var secretKey = ""
    @State private var endpointProto = "https"
    @State private var endpointHost = ""
    @State private var bucketManual = false
    @State private var bucket = ""
    @State private var buckets: [String] = []
    @State private var isLoadingBuckets = false

    // 阿里云OSS
    @State private var ossScType: OSSStorageType = .standard

    // WebDAV
    @State private var webdavAddress = ""
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

    private var isEdit: Bool { existing != nil }
    private var isLocal: Bool { isEdit && existing!.isLocal }

    var body: some View {
        Form {
            basicSection

            if isLocal {
                localPathSection
            } else {
                switch type {
                case .minio:  minioSections
                case .oss:    ossSections
                case .webdav: webdavSection
                case .sftp:   sftpSections
                }
                otherSection
                checkSection
            }
        }
        .navigationTitle(isEdit ? "编辑备份账号" : "添加备份账号")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text(isEdit ? "保存" : "确认").bold()
                    }
                }
                .disabled(isSubmitting || (isLocal ? false : checkState != .ok))
            }
        }
        .alert(validationMessage, isPresented: $showValidationAlert) {
            Button("好的", role: .cancel) {}
        }
        // 保存/获取桶等失败提示：本页被 push 展示，需自带 alert（父页面的会被遮挡）
        .alert("提示", isPresented: $vm.showAlert) {
            Button("好的", role: .cancel) {}
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

    // MARK: 表单区块

    private var basicSection: some View {
        Section {
            TextField("名称", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if isEdit {
                LabeledContent("类型", value: isLocal ? "LOCAL" : type.displayName)
            } else {
                Picker("类型", selection: $type) {
                    ForEach(BackupAccountType.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .pickerStyle(.menu)
            }
        } header: {
            Text("基本信息")
        } footer: {
            if isEdit && !isLocal && (existing?.rememberAuth != true) {
                Text("该账号未记住认证信息，凭证需重新填写")
            }
        }
    }

    /// MINIO / 阿里云OSS 共用：Access Key 凭证
    private var credentialsSection: some View {
        Section {
            TextField("Access Key ID", text: $accessKeyID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Secret Key", text: $secretKey)
        } header: {
            Text("认证信息")
        }
    }

    /// MINIO / 阿里云OSS 共用：协议 + Endpoint 地址
    private var endpointSection: some View {
        Section {
            Picker("协议", selection: $endpointProto) {
                Text("http").tag("http")
                Text("https").tag("https")
            }
            .pickerStyle(.segmented)
            TextField("Endpoint 地址", text: $endpointHost)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Endpoint")
        }
    }

    /// MINIO / 阿里云OSS 共用：桶下拉（获取桶）/ 手动输入
    private var bucketSection: some View {
        Section {
            Toggle("手动输入桶名", isOn: $bucketManual)
            if bucketManual {
                TextField("桶名", text: $bucket)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                Picker("桶", selection: $bucket) {
                    Text(buckets.isEmpty ? "未获取" : "请选择").tag("")
                    ForEach(buckets, id: \.self) { b in
                        Text(b).tag(b)
                    }
                }
                .pickerStyle(.menu)
                Button {
                    Task { await loadBuckets() }
                } label: {
                    HStack {
                        Text("获取桶")
                        Spacer()
                        if isLoadingBuckets { ProgressView() }
                    }
                }
                .disabled(isLoadingBuckets)
            }
        } header: {
            Text("存储桶")
        } footer: {
            Text("默认从 Endpoint 拉取桶列表；开启手动输入可直接填写桶名")
        }
    }

    @ViewBuilder
    private var minioSections: some View {
        credentialsSection
        endpointSection
        bucketSection
    }

    @ViewBuilder
    private var ossSections: some View {
        credentialsSection
        endpointSection
        Section {
            Picker("存储类型", selection: $ossScType) {
                ForEach(OSSStorageType.allCases) { t in
                    Text(t.displayName).tag(t)
                }
            }
        } header: {
            Text("存储类型")
        } footer: {
            Text(ossScType.remark)
        }
        bucketSection
    }

    private var webdavSection: some View {
        Section {
            TextField("地址（含 http(s)://）", text: $webdavAddress)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("用户名", text: $webdavUsername)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("密码", text: $webdavPassword)
        } header: {
            Text("连接信息")
        }
    }

    @ViewBuilder
    private var sftpSections: some View {
        Section {
            TextField("地址", text: $sftpAddress)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Text("端口")
                Spacer()
                TextField("22", value: $sftpPort, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
            }
            TextField("用户名", text: $sftpUsername)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("连接信息")
        }

        Section {
            Picker("认证方式", selection: $sftpAuthMode) {
                ForEach(SFTPAuthMode.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.segmented)

            if sftpAuthMode == .password {
                SecureField("密码", text: $sftpPassword)
            } else {
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
                SecureField("私钥密码（可选）", text: $sftpPassPhrase)
            }
        } header: {
            Text("认证方式")
        }
    }

    /// LOCAL 内置账号：仅可改名称与备份目录（保存后服务器会移动现有备份）
    private var localPathSection: some View {
        Section {
            TextField("备份目录", text: $backupPath, prompt: Text("/opt/1panel/backup"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("备份目录")
        } footer: {
            Text("修改后服务器会将现有备份文件移动到新目录")
        }
    }

    private var otherSection: some View {
        Section {
            Toggle("记住认证信息", isOn: $rememberAuth)
            TextField("备份目录", text: $backupPath, prompt: Text("/"))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("认证与目录")
        } footer: {
            Text("开启「记住认证信息」后凭证加密存储在服务器，编辑时可直接回显；备份目录为该账号下的备份存放路径，需手动填写（如 /backup）")
        }
    }

    private var checkSection: some View {
        Section {
            Button {
                Task { await runCheck() }
            } label: {
                HStack {
                    Text("连接测试")
                    Spacer()
                    switch checkState {
                    case .ok:
                        Label("通过", systemImage: "checkmark.circle.fill")
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
            Text("连接测试")
        } footer: {
            Text("测试通过后才能保存")
        }
    }

    // MARK: 逻辑

    /// 表单指纹：任一输入变化都会改变，用于重置连接测试状态
    private var formFingerprint: String {
        [
            name, type.rawValue, String(rememberAuth), backupPath,
            accessKeyID, secretKey, endpointProto, endpointHost, String(bucketManual), bucket,
            ossScType.rawValue,
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
            bucketManual = !(account.bucket ?? "").isEmpty
            // 保留 timeout 等其他键（与 OSS 一致）
            extraVars = vars.values.filter { !["endpointItem", "endpoint"].contains($0.key) }
        case .oss:
            let endpoint = Self.splitProto(vars["endpoint"]?.stringValue ?? "")
            if let proto = endpoint.proto { endpointProto = proto }
            endpointHost = endpoint.host
            bucket = account.bucket ?? ""
            bucketManual = !(account.bucket ?? "").isEmpty
            if let sc = vars["scType"]?.stringValue, let t = OSSStorageType(rawValue: sc) {
                ossScType = t
            }
            // 保留 timeout 等其他键
            extraVars = vars.values.filter { !["scType", "endpointItem", "endpoint"].contains($0.key) }
        case .webdav:
            webdavAddress = vars["address"]?.stringValue ?? ""
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
            case .minio, .oss:
                accessKeyID = Self.decodeBase64(account.accessKey)
                secretKey = Self.decodeBase64(account.credential)
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

    private static func encodeBase64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
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
            return "请填写名称"
        }
        guard !isLocal else { return nil }
        switch type {
        case .minio, .oss:
            if accessKeyID.isEmpty { return "请填写 Access Key ID" }
            if secretKey.isEmpty { return "请填写 Secret Key" }
            if endpointHost.isEmpty { return "请填写 Endpoint 地址" }
            if bucket.trimmingCharacters(in: .whitespaces).isEmpty { return "请选择或填写桶" }
        case .webdav:
            if webdavAddress.isEmpty { return "请填写地址" }
            if webdavUsername.isEmpty { return "请填写用户名" }
            if webdavPassword.isEmpty { return "请填写密码" }
        case .sftp:
            if sftpAddress.isEmpty { return "请填写地址" }
            if sftpUsername.isEmpty { return "请填写用户名" }
            if sftpAuthMode == .password && sftpPassword.isEmpty { return "请填写密码" }
            if sftpAuthMode == .key && sftpPrivateKey.isEmpty { return "请填写私钥" }
        }
        return nil
    }

    /// 构造 vars / varsJson（按类型）
    private func buildVars() -> BackupVarsJSON {
        var vars = BackupVarsJSON()
        switch type {
        case .minio:
            let host = endpointHost.trimmingCharacters(in: .whitespaces)
            vars["endpointItem"] = .string(host)
            vars["endpoint"] = .string("\(endpointProto)://\(host)")
        case .oss:
            let host = endpointHost.trimmingCharacters(in: .whitespaces)
            vars["scType"] = .string(ossScType.rawValue)
            vars["endpointItem"] = .string(host)
            vars["endpoint"] = .string("\(endpointProto)://\(host)")
        case .webdav:
            vars["address"] = .string(webdavAddress.trimmingCharacters(in: .whitespaces))
        case .sftp:
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

    /// 构造提交/测试共用请求体（凭证 base64）
    private func buildOperate() -> BackupAccountOperate {
        // LOCAL 内置账号没有 MINIO/OSS/WebDAV/SFTP 表单，vars 沿用服务端原值，
        // 避免把其他类型形状的空表单数据覆写进记录
        let vars: BackupVarsJSON = isLocal ? BackupVarsJSON.parse(existing?.vars) : buildVars()
        let userKey: String
        let secret: String
        switch type {
        case .minio, .oss:
            userKey = Self.encodeBase64(accessKeyID)
            secret = Self.encodeBase64(secretKey)
        case .webdav:
            userKey = Self.encodeBase64(webdavUsername)
            secret = Self.encodeBase64(webdavPassword)
        case .sftp:
            userKey = Self.encodeBase64(sftpUsername)
            secret = sftpAuthMode == .password
                ? Self.encodeBase64(sftpPassword)
                : Self.encodeBase64(sftpPrivateKey)
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

    private func loadBuckets() async {
        // 拉桶只需 Endpoint 与凭证，不要求名称/桶已填
        let bucketFetchError: String?
        if accessKeyID.isEmpty { bucketFetchError = "请填写 Access Key ID" }
        else if secretKey.isEmpty { bucketFetchError = "请填写 Secret Key" }
        else if endpointHost.trimmingCharacters(in: .whitespaces).isEmpty { bucketFetchError = "请填写 Endpoint 地址" }
        else { bucketFetchError = nil }
        if let error = bucketFetchError {
            validationMessage = error
            showValidationAlert = true
            return
        }
        isLoadingBuckets = true
        defer { isLoadingBuckets = false }
        let host = endpointHost.trimmingCharacters(in: .whitespaces)
        // OSS 的拉桶 vars 需携带 scType，MINIO 仅 endpoint
        let vars: BackupVarsJSON
        switch type {
        case .minio:
            vars = BackupVarsJSON(["endpoint": .string("\(endpointProto)://\(host)")])
        case .oss:
            vars = BackupVarsJSON([
                "scType": .string(ossScType.rawValue),
                "endpoint": .string("\(endpointProto)://\(host)"),
            ])
        case .webdav, .sftp:
            return
        }
        let list = await vm.fetchBuckets(
            type: type.rawValue,
            vars: vars,
            accessKey: Self.encodeBase64(accessKeyID),
            credential: Self.encodeBase64(secretKey)
        )
        buckets = list
        // 获取失败（空列表）时保留已选/回显的桶，不强制清空
        if !list.isEmpty, !list.contains(bucket) {
            bucket = list.first ?? ""
        }
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
        let reason = await vm.checkConnection(buildOperate())
        guard formFingerprint == fingerprintAtStart else {
            checkState = .none
            return
        }
        checkState = reason.map { ConnectionCheckState.failed($0) } ?? .ok
    }

    private func submit() async {
        if let error = validationError() {
            validationMessage = error
            showValidationAlert = true
            return
        }
        // 与网页端一致：连接测试通过后才允许保存（本机账号除外）
        guard isLocal || checkState == .ok else {
            validationMessage = "请先通过连接测试"
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
