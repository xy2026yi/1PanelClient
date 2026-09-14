//
//  FilesOperations.swift
//  1PanelClient
//
//  文件操作扩展（logs/推荐实现-文件.md 抓包 2026-09-14）：
//  压缩/解压（taskID 任务进度）· 移动/剪切 · 权限修改（9 宫格 + 用户/组）·
//  远程下载 wget（WS 进度 /files/wget/process）
//

import SwiftUI
import Combine
import CryptoKit

// MARK: - 请求/响应模型

/// POST /files/compress {files,type,dst,name,replace,secret,taskID}
struct FileCompressRequest: Encodable {
    let files: [String]
    let type: String
    let dst: String
    let name: String
    let replace: Bool
    let secret: String
    let taskID: String
}

/// POST /files/decompress {type,dst,path,secret,taskID}
struct FileDecompressRequest: Encodable {
    let type: String
    let dst: String
    let path: String
    let secret: String
    let taskID: String
}

/// POST /files/move {oldPaths,newPath,type,...}（type=cut 剪切；
/// name/cover/coverPaths 为网页端覆盖交互字段，App 恒空/关闭；
/// allNames 按抓包携带全部所选名称——跳过冲突时 oldPaths 仅含未冲突项）
struct FileMoveRequest: Encodable {
    let oldPaths: [String]
    let newPath: String
    let type = "cut"
    let name = ""
    var allNames: [String] = []
    let isDir: Bool
    let cover = false
    let coverPaths: [String] = []
}

/// POST /files/batch/role {paths,mode,user,group,sub}
/// mode 为十进制数值（抓包：0777→511、0755→493、0444→292）
struct FileBatchRoleRequest: Encodable {
    let paths: [String]
    let mode: Int
    let user: String
    let group: String
    let sub: Bool
}

/// POST /files/wget {url,path,name,ignoreCertificate,useProxy} → {key}
struct FileWgetRequest: Encodable {
    let url: String
    let path: String
    let name: String
    let ignoreCertificate: Bool
    let useProxy: Bool
}

struct FileWgetKeyResponse: Decodable {
    let key: String?
}

/// GET /files/wget/process/keys → {keys}
struct FileWgetKeysResponse: Decodable {
    let keys: [String]?
}

/// WS /files/wget/process 收到的单条下载进度
struct FileWgetProgress: Decodable, Identifiable {
    let total: Double?
    let written: Double?
    let percent: Double?
    let name: String?
    var id: String { name ?? UUID().uuidString }
}

/// POST /files/user/group → {users,groups}（权限修改下拉数据）
struct FileUserGroupResponse: Decodable {
    let users: [FileUserGroupItem]?
    let groups: [String]?
}

struct FileUserGroupItem: Decodable, Hashable {
    let username: String?
    let group: String?
}

/// 压缩/解压任务（taskID → 任务进度页）
struct FileArchiveTask: Identifiable, Hashable {
    let taskID: String
    let title: String
    var id: String { taskID }
}

/// 进行中下载的展示目标（WS 进度 Sheet）
struct FileWgetProgressTarget: Identifiable {
    let keys: [String]
    var id: String { keys.joined(separator: ",") }
}

// MARK: - 权限换算（9 宫格 ↔ 八进制）

/// rwx 九位与 mode 数值的换算（所有者/用户组/公共 × 读/写/执行）
enum FileModeMath {
    struct Triple: Equatable {
        var read = false
        var write = false
        var execute = false

        init() {}

        var value: Int { (read ? 4 : 0) + (write ? 2 : 0) + (execute ? 1 : 0) }
        init(value: Int) {
            read = value & 4 != 0
            write = value & 2 != 0
            execute = value & 1 != 0
        }
    }

    /// 三组勾选 → 十进制（如 rwxr-xr-x → 493）
    static func mode(owner: Triple, group: Triple, other: Triple) -> Int {
        owner.value << 6 | group.value << 3 | other.value
    }

    /// 十进制 → 三组勾选
    static func triples(fromMode mode: Int) -> (owner: Triple, group: Triple, other: Triple) {
        (Triple(value: mode >> 6 & 7), Triple(value: mode >> 3 & 7), Triple(value: mode & 7))
    }

    /// "0755" 之类八进制字符串 → 十进制；解析失败返回 nil
    static func decimal(fromOctalString s: String?) -> Int? {
        guard let s, !s.isEmpty else { return nil }
        return Int(s, radix: 8)
    }

    /// 十进制 → "0755" 显示
    static func octalString(_ mode: Int) -> String {
        String(format: "0%o", mode)
    }
}

// MARK: - wget 下载进度 WebSocket

/// WS /api/v2/files/wget/process：每秒发送 {"type":"wget","keys":[...]}，
/// 收到进度数组或 null（全部完成）。认证头与终端 WS 相同（MD5 签名）。
@MainActor
final class FileWgetProcessSession: ObservableObject {
    @Published private(set) var items: [FileWgetProgress] = []
    @Published private(set) var isAllDone = false
    @Published private(set) var errorMessage: String?

    private let server: ServerConfig
    private let keys: [String]
    private var task: URLSessionWebSocketTask?
    private var pollTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    init(server: ServerConfig, keys: [String]) {
        self.server = server
        self.keys = keys
    }

    deinit {
        receiveTask?.cancel()
        pollTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
    }

    func start() {
        guard let url = makeURL() else {
            errorMessage = L10n.t("无法构造下载进度连接地址")
            return
        }
        var request = URLRequest(url: url)
        for (k, v) in authHeaders() {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let ws = URLSession.shared.webSocketTask(with: request)
        ws.resume()
        task = ws

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    func stop() {
        receiveTask?.cancel()
        pollTask?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    // MARK: URL 与认证（对齐 TerminalSession：MD5("1panel"+apiKey+ts)）

    private func makeURL() -> URL? {
        guard var comp = URLComponents(string: server.normalizedBaseURL) else { return nil }
        comp.scheme = comp.scheme == "https" ? "wss" : "ws"
        comp.path = "/api/v2/files/wget/process"
        let node = NodeScope.current(for: server.id) ?? "local"
        comp.queryItems = [URLQueryItem(name: "operateNode", value: node)]
        return comp.url
    }

    private func authHeaders() -> [String: String] {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let raw = "1panel" + server.apiKey + timestamp
        let digest = Insecure.MD5.hash(data: Data(raw.utf8))
        return [
            "1Panel-Token": digest.map { String(format: "%02x", $0) }.joined(),
            "1Panel-Timestamp": timestamp,
        ]
    }

    /// 每秒查询一次（抓包节奏：客户端周期重发 keys 查询）
    private func pollLoop() async {
        while !Task.isCancelled, let task {
            let payload: [String: Any] = ["type": "wget", "keys": keys]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let str = String(data: data, encoding: .utf8) {
                try? await task.send(.string(str))
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func receiveLoop() async {
        guard let task else { return }
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
                handle(msg)
            } catch {
                if !Task.isCancelled, !isAllDone {
                    errorMessage = error.localizedDescription
                }
                break
            }
        }
    }

    private func handle(_ msg: URLSessionWebSocketTask.Message) {
        let text: String
        switch msg {
        case .string(let s): text = s
        case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
        @unknown default: return
        }
        guard let data = text.data(using: .utf8) else { return }
        // 收到 null → 所有 key 已完成（抓包：进度 100% 后下一次查询返回 null）
        if let obj = try? JSONSerialization.jsonObject(with: data), obj is NSNull {
            isAllDone = true
            stop()
            return
        }
        if let list = try? JSONDecoder().decode([FileWgetProgress].self, from: data) {
            items = list
        }
    }
}

// MARK: - 压缩 Sheet

/// 网页端抓包的压缩格式全集（含 rar / 1z）
private let fileCompressFormats = [
    "zip", "gz", "bz2", "tar.bz2", "tar", "tgz", "tar.gz", "xz", "tar.xz", "rar", "1z",
]

struct FileCompressSheet: View {
    let server: ServerConfig
    let item: FileItem
    /// 默认压缩目标目录（当前目录）
    let defaultDst: String
    /// 提交成功（返回任务 taskID，调用方跳任务进度页）
    let onStarted: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var type = "zip"
    @State private var previousType = "zip"
    @State private var name = ""
    @State private var dst: String
    @State private var replace = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var appeared = false

    private let client: APIClient

    init(server: ServerConfig, item: FileItem, defaultDst: String, onStarted: @escaping (String) -> Void) {
        self.server = server
        self.item = item
        self.defaultDst = defaultDst
        self.onStarted = onStarted
        _dst = State(initialValue: defaultDst)
        self.client = APIClient.shared(for: server)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L10n.t("压缩格式"), selection: $type) {
                        ForEach(fileCompressFormats, id: \.self) { Text($0).tag($0) }
                    }
                    TextField(L10n.t("压缩名称"), text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    FilePathBrowseRow(title: L10n.t("压缩路径"), path: $dst, client: client)
                    Toggle(L10n.t("覆盖已存在的文件"), isOn: $replace)
                } header: {
                    SectionLabel(title: item.name, systemImage: "doc.zipper")
                }
            }
            .navigationTitle(L10n.t("压缩"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("压缩")) {
                        Task { await submit() }
                    }
                    .disabled(trimmedName.isEmpty || isSubmitting)
                }
            }
            .alert(L10n.t("提示"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(L10n.t("好的"), role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.medium])
        .onAppear {
            guard !appeared else { return }
            appeared = true
            name = item.name + "." + type
        }
        .onChange(of: type) { _, newType in
            // 切换格式时同步扩展名（名称仍是「基名.旧格式」形态才跟随）
            let oldSuffix = "." + previousType
            if trimmedName.hasSuffix(oldSuffix) {
                name = String(trimmedName.dropLast(oldSuffix.count)) + "." + newType
            }
            previousType = newType
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let req = FileCompressRequest(
            files: [item.path], type: type, dst: dst,
            name: trimmedName, replace: replace, secret: "", taskID: UUID().uuidString)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.filesCompress.path, body: req, as: EmptyResponse.self)
            onStarted(req.taskID)
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 解压 Sheet

struct FileDecompressSheet: View {
    let server: ServerConfig
    let item: FileItem
    let defaultDst: String
    let onStarted: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var dst: String
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig, item: FileItem, defaultDst: String, onStarted: @escaping (String) -> Void) {
        self.server = server
        self.item = item
        self.defaultDst = defaultDst
        self.onStarted = onStarted
        _dst = State(initialValue: defaultDst)
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    InfoRow(L10n.t("名称"), value: item.name)
                    FilePathBrowseRow(title: L10n.t("解压路径"), path: $dst, client: client)
                } header: {
                    SectionLabel(title: L10n.t("解压"), systemImage: "doc.badge.ellipsis")
                } footer: {
                    Text(L10n.t("解压任务提交后可在任务进度中查看"))
                }
            }
            .navigationTitle(L10n.t("解压"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("解压")) {
                        Task { await submit() }
                    }
                    .disabled(isSubmitting)
                }
            }
            .alert(L10n.t("提示"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(L10n.t("好的"), role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.medium])
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        // type 取压缩扩展名（抓包：ftp_test1.gz → type "gz"）
        let type = (item.name as NSString).pathExtension.lowercased()
        let req = FileDecompressRequest(
            type: type, dst: dst, path: item.path, secret: "", taskID: UUID().uuidString)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.filesDecompress.path, body: req, as: EmptyResponse.self)
            onStarted(req.taskID)
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 移动 Sheet

struct FileMoveSheet: View {
    let server: ServerConfig
    let item: FileItem
    let defaultDst: String
    let onMoved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var dst: String
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig, item: FileItem, defaultDst: String, onMoved: @escaping () -> Void) {
        self.server = server
        self.item = item
        self.defaultDst = defaultDst
        self.onMoved = onMoved
        _dst = State(initialValue: defaultDst)
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    InfoRow(L10n.t("名称"), value: item.name)
                    FilePathBrowseRow(title: L10n.t("目标路径"), path: $dst, client: client)
                } header: {
                    SectionLabel(title: L10n.t("移动"), systemImage: "arrow.right.square")
                }
            }
            .navigationTitle(L10n.t("移动"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("移动")) {
                        Task { await submit() }
                    }
                    .disabled(isSubmitting || dst == (item.path as NSString).deletingLastPathComponent)
                }
            }
            .alert(L10n.t("提示"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(L10n.t("好的"), role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.medium])
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let req = FileMoveRequest(oldPaths: [item.path], newPath: dst, isDir: item.isDir)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.filesMove.path, body: req, as: EmptyResponse.self)
            onMoved()
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 权限修改 Sheet

struct FilePermissionSheet: View {
    let server: ServerConfig
    /// 多选批量时传多项；勾选态/属主默认取首项
    let items: [FileItem]
    let onDone: () -> Void

    private var item: FileItem? { items.first }

    @Environment(\.dismiss) private var dismiss
    @State private var users: [FileUserGroupItem] = []
    @State private var groups: [String] = []
    @State private var user = ""
    @State private var group = ""
    @State private var owner = FileModeMath.Triple()
    @State private var groupPerm = FileModeMath.Triple()
    @State private var other = FileModeMath.Triple()
    @State private var sub = true
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig, items: [FileItem], onDone: @escaping () -> Void) {
        self.server = server
        self.items = items
        self.onDone = onDone
        self.client = APIClient.shared(for: server)
    }

    private var mode: Int { FileModeMath.mode(owner: owner, group: groupPerm, other: other) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    InfoRow(L10n.t("名称"), value: items.count == 1 ? (item?.name ?? "-") : L10n.f("%ld 项", items.count))
                    InfoRow(L10n.t("权限"), value: FileModeMath.octalString(mode))
                        .font(.system(.body, design: .monospaced))
                    permGrid
                    Picker(L10n.t("用户"), selection: $user) {
                        ForEach(users, id: \.username) { u in
                            Text(u.username ?? "-").tag(u.username ?? "-")
                        }
                    }
                    Picker(L10n.t("用户组"), selection: $group) {
                        ForEach(groups, id: \.self) { Text($0) }
                    }
                    Toggle(L10n.t("同时修改子文件属性"), isOn: $sub)
                } footer: {
                    Text(L10n.t("修改所有者/用户组/公共的读取、写入、可执行权限"))
                }
            }
            .navigationTitle(L10n.t("权限"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("保存")) {
                        Task { await submit() }
                    }
                    .disabled(isSubmitting || users.isEmpty)
                }
            }
            .alert(L10n.t("提示"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(L10n.t("好的"), role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.large])
        .task { await loadUsers() }
    }

    /// 三行（所有者/用户组/公共）× 三列（读/写/执行）勾选矩阵
    private var permGrid: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("")
                Text(L10n.t("读取")).font(.caption).foregroundStyle(.secondary)
                Text(L10n.t("写入")).font(.caption).foregroundStyle(.secondary)
                Text(L10n.t("可执行")).font(.caption).foregroundStyle(.secondary)
            }
            GridRow {
                Text(L10n.t("所有者"))
                Toggle("", isOn: $owner.read).labelsHidden()
                Toggle("", isOn: $owner.write).labelsHidden()
                Toggle("", isOn: $owner.execute).labelsHidden()
            }
            GridRow {
                Text(L10n.t("用户组"))
                Toggle("", isOn: $groupPerm.read).labelsHidden()
                Toggle("", isOn: $groupPerm.write).labelsHidden()
                Toggle("", isOn: $groupPerm.execute).labelsHidden()
            }
            GridRow {
                Text(L10n.t("公共"))
                Toggle("", isOn: $other.read).labelsHidden()
                Toggle("", isOn: $other.write).labelsHidden()
                Toggle("", isOn: $other.execute).labelsHidden()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadUsers() async {
        // 勾选态按当前 mode 预置（"0755" → rwxr-xr-x）
        if let m = FileModeMath.decimal(fromOctalString: item?.mode) {
            let t = FileModeMath.triples(fromMode: m)
            owner = t.owner
            groupPerm = t.group
            other = t.other
        }
        do {
            let resp: FileUserGroupResponse = try await client.send(
                path: APIEndpoint.filesUserGroup.path, body: nil, as: FileUserGroupResponse.self)
            users = resp.users ?? []
            groups = resp.groups ?? []
            // 默认选中文件当前属主/属组（不在候选列表时仍追加，避免 Picker 空 selection）
            if let current = item?.user, !current.isEmpty {
                if !users.contains(where: { $0.username == current }) {
                    users.insert(FileUserGroupItem(username: current, group: nil), at: 0)
                }
                user = current
            } else {
                user = users.first?.username ?? ""
            }
            if let currentGroup = item?.group, !currentGroup.isEmpty {
                if !groups.contains(currentGroup) { groups.insert(currentGroup, at: 0) }
                group = currentGroup
            } else {
                group = groups.first ?? ""
            }
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let req = FileBatchRoleRequest(
            paths: items.map(\.path), mode: mode, user: user, group: group, sub: sub)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.filesBatchRole.path, body: req, as: EmptyResponse.self)
            onDone()
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 远程下载 Sheet

struct FileWgetSheet: View {
    let server: ServerConfig
    let defaultPath: String
    /// 提交成功（返回下载 key，调用方打开 WS 进度）
    let onStarted: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var name = ""
    @State private var path: String
    @State private var useProxy = false
    @State private var ignoreCertificate = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var nameEdited = false
    @FocusState private var nameFocused: Bool

    private let client: APIClient

    init(server: ServerConfig, defaultPath: String, onStarted: @escaping (String) -> Void) {
        self.server = server
        self.defaultPath = defaultPath
        self.onStarted = onStarted
        _path = State(initialValue: defaultPath)
        self.client = APIClient.shared(for: server)
    }

    private var trimmedURL: String { urlText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.t("下载地址"), text: $urlText, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...3)
                    TextField(L10n.t("文件名"), text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($nameFocused)
                    FilePathBrowseRow(title: L10n.t("保存路径"), path: $path, client: client)
                } header: {
                    SectionLabel(title: L10n.t("远程下载"), systemImage: "arrow.down.circle")
                } footer: {
                    Text(L10n.t("文件名将由下载地址自动带入，可手动修改"))
                }
                Section {
                    Toggle(L10n.t("使用代理下载"), isOn: $useProxy)
                    Toggle(L10n.t("忽略不可信证书"), isOn: $ignoreCertificate)
                }
            }
            .navigationTitle(L10n.t("远程下载"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("下载")) {
                        Task { await submit() }
                    }
                    .disabled(trimmedURL.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
                }
            }
            .alert(L10n.t("提示"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(L10n.t("好的"), role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.large])
        .onChange(of: name) { _, _ in
            // 手动编辑后不再跟随 URL 自动带入（聚焦中的变更视为手动输入）
            if nameFocused { nameEdited = true }
        }
        .onChange(of: urlText) { _, new in
            // 名称未手动编辑时跟随 URL 最后一段（抓包：自动带入 ipa 文件名）
            guard !nameEdited else { return }
            if let last = URL(string: new)?.lastPathComponent, !last.isEmpty {
                name = last
            } else {
                name = ""
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let req = FileWgetRequest(
            url: trimmedURL, path: path,
            name: name.trimmingCharacters(in: .whitespaces),
            ignoreCertificate: ignoreCertificate, useProxy: useProxy)
        do {
            let resp: FileWgetKeyResponse = try await client.send(
                path: APIEndpoint.filesWget.path, body: req, as: FileWgetKeyResponse.self)
            if let key = resp.key, !key.isEmpty {
                onStarted(key)
                dismiss()
            } else {
                errorMessage = L10n.t("下载任务创建失败")
            }
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - wget 下载进度视图

struct FileWgetProgressView: View {
    let server: ServerConfig
    let target: FileWgetProgressTarget
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: FileWgetProcessSession

    init(server: ServerConfig, target: FileWgetProgressTarget, onFinished: @escaping () -> Void) {
        self.server = server
        self.target = target
        self.onFinished = onFinished
        _session = StateObject(wrappedValue: FileWgetProcessSession(server: server, keys: target.keys))
    }

    var body: some View {
        NavigationStack {
            Group {
                if session.errorMessage != nil && session.items.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.t("连接失败"), systemImage: "wifi.exclamationmark")
                    } actions: {
                        Button(L10n.t("关闭")) { dismiss() }
                    }
                } else if session.items.isEmpty && !session.isAllDone {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(L10n.t("正在获取下载进度…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(session.items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.name ?? "-")
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            ProgressView(value: max(0, min(100, item.percent ?? 0)) / 100)
                            HStack {
                                Text("\(Int(item.percent ?? 0))%")
                                if let written = item.written, let total = item.total, total > 0 {
                                    Text("\(fmt(Int64(written))) / \(fmt(Int64(total)))")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle(L10n.t("下载任务"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("关闭")) { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
        .task { session.start() }
        .onDisappear { session.stop() }
        .onChange(of: session.isAllDone) { _, done in
            if done {
                Haptic.success()
                onFinished()
            }
        }
    }

    private func fmt(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(bytes)
        var idx = 0
        while size >= 1024 && idx < units.count - 1 {
            size /= 1024
            idx += 1
        }
        return String(format: "%.1f %@", size, units[idx])
    }
}

// MARK: - 路径行（显示 + 浏览按钮）

/// 压缩/解压/移动/下载共用的目标路径行：等宽显示路径 + 文件夹按钮弹目录选择
/// （目录选择器由本行自行挂载，调用方只传路径 Binding）
struct FilePathBrowseRow: View {
    let title: String
    @Binding var path: String
    let client: APIClient

    @State private var showPicker = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(path)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Button {
                showPicker = true
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.t("选择目录"))
        }
        .sheet(isPresented: $showPicker) {
            DirectoryPickerSheet(client: client) { picked in path = picked }
        }
    }
}

// MARK: - FilesView 操作接线（ViewModifier）

/// 集中挂载文件操作 Sheet 与任务进度页，避免 FilesView body 继续膨胀
struct FilesOperationsModifier: ViewModifier {
    let server: ServerConfig
    let currentPath: String
    let reload: () -> Void

    @Binding var compressItem: FileItem?
    @Binding var decompressItem: FileItem?
    @Binding var moveItem: FileItem?
    @Binding var permItem: FileItem?
    @Binding var showWget: Bool
    @Binding var archiveTask: FileArchiveTask?
    @Binding var wgetProgress: FileWgetProgressTarget?

    func body(content: Content) -> some View {
        content
            .sheet(item: $compressItem) { item in
                FileCompressSheet(server: server, item: item, defaultDst: currentPath) { taskID in
                    archiveTask = FileArchiveTask(
                        taskID: taskID, title: L10n.f("压缩 %@", item.name))
                }
            }
            .sheet(item: $decompressItem) { item in
                FileDecompressSheet(server: server, item: item, defaultDst: currentPath) { taskID in
                    archiveTask = FileArchiveTask(
                        taskID: taskID, title: L10n.f("解压 %@", item.name))
                }
            }
            .sheet(item: $moveItem) { item in
                FileMoveSheet(server: server, item: item, defaultDst: currentPath) {
                    reload()
                }
            }
            .sheet(item: $permItem) { item in
                FilePermissionSheet(server: server, items: [item]) {
                    reload()
                }
            }
            .sheet(isPresented: $showWget) {
                FileWgetSheet(server: server, defaultPath: currentPath) { key in
                    wgetProgress = FileWgetProgressTarget(keys: [key])
                }
            }
            .sheet(item: $wgetProgress) { target in
                FileWgetProgressView(server: server, target: target) {
                    reload()
                }
            }
            .navigationDestination(item: $archiveTask) { task in
                TaskProgressView(taskID: task.taskID, title: task.title) { isDone in
                    if isDone { reload() }
                    return false
                }
            }
    }
}

// MARK: - 文件多选批量操作栏

struct FilesBatchBar: View {
    let selectedCount: Int
    let totalCount: Int
    let isOperating: Bool
    let onSelectAll: () -> Void
    let onDelete: () -> Void
    let onMove: () -> Void
    let onPerm: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelectAll) {
                Label(
                    selectedCount >= totalCount ? L10n.t("取消全选") : L10n.t("全选"),
                    systemImage: selectedCount >= totalCount ? "circle" : "checkmark.circle"
                )
                .font(.caption)
            }
            .buttonStyle(.bordered)
            barButton(L10n.t("删除"), icon: "trash", color: .red, action: onDelete)
            barButton(L10n.t("移动"), icon: "arrow.right.square", color: .orange, action: onMove)
            barButton(L10n.t("权限"), icon: "lock.shield", color: .teal, action: onPerm)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func barButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(color)
        }
        .buttonStyle(.bordered)
        .disabled(selectedCount == 0 || isOperating)
    }
}

// MARK: - 多选移动 Sheet（冲突检测 → 跳过/覆盖）

/// 多选移动（logs/文件多选抓包 2026-09-14）：
/// 1. batch/check 检查目标路径 → 返回同名冲突文件
/// 2. 无冲突直接 move；有冲突让用户选「跳过」（仅移动不冲突项）或「覆盖」（全部移动）
///    两个分支的 cover/coverPaths 均按抓包为 false/空
struct FileBatchMoveSheet: View {
    let server: ServerConfig
    let items: [FileItem]
    let defaultDst: String
    let onDone: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var dst: String
    @State private var conflicts: [FileItem]?
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showError = false

    private let client: APIClient

    init(server: ServerConfig, items: [FileItem], defaultDst: String, onDone: @escaping () async -> Void) {
        self.server = server
        self.items = items
        self.defaultDst = defaultDst
        _dst = State(initialValue: defaultDst)
        self.onDone = onDone
        self.client = APIClient.shared(for: server)
    }

    /// 目标目录拼接（"/tmp" + "a" → "/tmp/a"）
    private func join(_ dir: String, _ name: String) -> String {
        if dir == "/" { return "/" + name }
        return dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    /// 非冲突源路径（按目标路径排除冲突项）
    private var nonConflictPaths: [String] {
        let conflictTargets = Set((conflicts ?? []).map(\.path))
        return items.filter { !conflictTargets.contains(join(dst, $0.name)) }.map(\.path)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    InfoRow(L10n.t("已选"), value: L10n.f("%ld 项", items.count))
                    FilePathBrowseRow(title: L10n.t("目标路径"), path: $dst, client: client)
                } header: {
                    SectionLabel(title: L10n.t("移动"), systemImage: "arrow.right.square")
                }

                // 冲突确认：列出同名文件，跳过 / 覆盖
                if let conflicts, !conflicts.isEmpty {
                    Section {
                        ForEach(conflicts) { conflict in
                            Label(conflict.name, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        Button {
                            Task { await move(paths: nonConflictPaths) }
                        } label: {
                            Label(L10n.t("跳过同名文件"), systemImage: "arrow.uturn.right")
                        }
                        Button {
                            Task { await move(paths: items.map(\.path)) }
                        } label: {
                            Label(L10n.t("覆盖同名文件"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .tint(.red)
                    } header: {
                        SectionLabel(title: L10n.t("目标目录存在同名文件"), systemImage: "exclamationmark.triangle")
                    } footer: {
                        Text(L10n.t("跳过仅移动不冲突的文件；覆盖将替换目标目录中的同名文件"))
                    }
                }
            }
            .navigationTitle(L10n.t("移动"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                        .disabled(isSubmitting)
                }
                if conflicts == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.t("移动")) {
                            Task { await checkAndMove() }
                        }
                        .disabled(isSubmitting)
                    }
                }
            }
            .alert(L10n.t("提示"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(L10n.t("好的"), role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.medium])
        .interactiveDismissDisabled(isSubmitting)
    }

    /// 先查冲突：无冲突直接移动，有冲突展示跳过/覆盖选择
    private func checkAndMove() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let targets = items.map { join(dst, $0.name) }
            let resp: [FileItem] = try await client.send(
                path: APIEndpoint.filesBatchCheck.path,
                body: FileBatchCheckRequest(paths: targets),
                as: [FileItem].self)
            if resp.isEmpty {
                try await move(paths: items.map(\.path))
            } else {
                conflicts = resp
            }
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func move(paths: [String]) async {
        guard !paths.isEmpty else {
            errorMessage = L10n.t("没有可移动的文件")
            showError = true
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        var req = FileMoveRequest(oldPaths: paths, newPath: dst, isDir: items.first?.isDir ?? false)
        req.allNames = items.map(\.name)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.filesMove.path, body: req, as: EmptyResponse.self)
            await onDone()
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

/// 批量 Sheet 的条目包装（sheet(item:) 需 Identifiable；数组路径集合做身份）
struct FileItemList: Identifiable {
    let items: [FileItem]
    var id: String { items.map(\.path).joined(separator: "\n") }
}
