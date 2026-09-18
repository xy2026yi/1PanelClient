//
//  TerminalHostsView.swift
//  1PanelClient
//
//  终端入口：本机终端 + SSH 连接已保存主机（主机增删改、连接测试）
//  基于 logs/SSH连接主机.md 抓包
//

import SwiftUI
import Combine

struct TerminalHostsView: View {
    @StateObject private var vm: SSHHostsViewModel

    /// 本机行显示名（当前服务器名称）
    private let localTitle: String?
    private let server: ServerConfig

    @State private var showAddHost = false
    @State private var editingHost: SSHHostInfo?
    @State private var connectedHost: SSHHostInfo?
    @State private var connectingHostID: Int?
    @State private var showQuickCommands = false
    @State private var showSettings = false
    @State private var showMenu = false
    // SSH 服务管理相关的三个入口（自 SSH 服务管理页移入）
    @State private var showCerts = false
    @State private var showSessions = false
    @State private var showPanelSessions = false
    @State private var showServiceManage = false

    init(server: ServerConfig, localTitle: String?) {
        self.server = server
        self.localTitle = localTitle
        _vm = StateObject(wrappedValue: SSHHostsViewModel(server: server))
    }

    var body: some View {
        List {
            localSection
            hostsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("SSH")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EllipsisMenuButton {
                    withAnimation(Motion.fast) { showMenu.toggle() }
                }
                .accessibilityLabel(L10n.t("更多"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddHost = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("添加主机"))
            }
        }
        .overlay(alignment: .topTrailing) {
            if showMenu {
                EllipsisMenuPopup(entries: [
                    .action(title: L10n.t("密钥"), icon: "key") { showCerts = true },
                    .action(title: L10n.t("会话"), icon: "person.2") { showSessions = true },
                    .action(title: L10n.t("面板会话"), icon: "rectangle.on.rectangle") { showPanelSessions = true },
                    .action(title: L10n.t("服务管理"), icon: "gearshape.2") { showServiceManage = true },
                    .action(title: L10n.t("快速命令"), icon: "apple.terminal.on.rectangle") { showQuickCommands = true },
                    .action(title: L10n.t("设置"), icon: "gear") { showSettings = true },
                ]) {
                    withAnimation(Motion.fast) { showMenu = false }
                }
            }
        }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
        Text(vm.alertMessage)
        }
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("删除主机"), isPresented: Binding(
            get: { vm.pendingDeleteHost != nil },
            set: { if !$0 { vm.pendingDeleteHost = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { vm.pendingDeleteHost = nil }
            Button(L10n.t("删除"), role: .destructive) {
                Haptic.warning()
                if let host = vm.pendingDeleteHost {
                    Task { await vm.delete(host) }
                }
            }
        } message: {
            Text(L10n.f("确定删除主机「%@」吗？", vm.pendingDeleteHost?.displayName ?? ""))
        }
        .navigationDestination(isPresented: $showAddHost) {
            SSHHostEditView(vm: vm, editing: nil)
        }
        .navigationDestination(isPresented: $showQuickCommands) {
            QuickCommandsView(server: server)
        }
        .navigationDestination(isPresented: $showSettings) {
            TerminalSettingsView(server: server)
        }
        .navigationDestination(isPresented: $showCerts) {
            SSHCertsView(server: server)
        }
        .navigationDestination(isPresented: $showPanelSessions) {
            PanelTerminalSessionsView(server: server)
        }
        .navigationDestination(isPresented: $showSessions) {
            SSHSessionsView(server: server)
        }
        .navigationDestination(isPresented: $showServiceManage) {
            SSHView(server: server)
        }
        .navigationDestination(isPresented: Binding(
            get: { editingHost != nil },
            set: { if !$0 { editingHost = nil } }
        )) {
            if let host = editingHost {
                SSHHostEditView(vm: vm, editing: host)
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { connectedHost != nil },
            set: { if !$0 { connectedHost = nil } }
        )) {
            if let host = connectedHost {
                TerminalScreen(
                    server: server,
                    target: .sshHost(id: host.id, cols: 80, rows: 24),
                    title: host.displayName
        )
            }
        }
        .task { await vm.loadAll() }
        .refreshable { await vm.loadAll() }
    }

    // MARK: - 本机

    private var localSection: some View {
        Section {
            NavigationLink {
                TerminalScreen(
                    server: server,
                    target: .host(cols: 80, rows: 24),
                    title: localTitle ?? L10n.t("本机")
        )
            } label: {
                HStack(spacing: 12) {
                    IconBadge(systemName: "desktopcomputer", color: .blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(localTitle ?? L10n.t("本机"))
                            .font(.body.bold())
                        Text(L10n.t("面板所在服务器"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text(L10n.t("本机"))
        } footer: {
            Text(L10n.t("若本机终端无法连接，可将面板服务器地址添加为主机后经 SSH 连接"))
        }
    }

    // MARK: - 远程主机

    private var hostsSection: some View {
        Section {
            if vm.isLoading && vm.hosts.isEmpty {
                HStack {
                    Spacer()
                    LoadingStateView()
                    Spacer()
                }
            } else if let err = vm.errorMessage, !err.isEmpty, vm.hosts.isEmpty {
                LoadErrorStateView(message: err) {
                    Task { await vm.loadHosts() }
                }
                .listRowBackground(Color.clear)
            } else if vm.hosts.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无主机"),
                    systemImage: "rectangle.on.rectangle",
                    description: Text(L10n.t("点击右上角 + 添加"))
                )
            } else {
                ForEach(vm.hosts) { host in
                    Button {
                        Task { await connect(host) }
                    } label: {
                        SSHHostRow(
                            host: host,
                            isConnecting: connectingHostID == host.id
                        )
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            vm.pendingDeleteHost = host
                        } label: {
                            Label(L10n.t("删除"), systemImage: "trash")
                        }

                        Button {
                            editingHost = host
                        } label: {
                            Label(L10n.t("编辑"), systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            }
        } header: {
            Text(L10n.t("远程主机"))
        }
    }

    /// 连接主机：先按 id 测试连通，通过后进入 SSH 终端
    private func connect(_ host: SSHHostInfo) async {
        connectingHostID = host.id
        let ok = await vm.testByID(host)
        connectingHostID = nil
        if ok {
            connectedHost = host
        }
    }
}

// MARK: - 主机行

struct SSHHostRow: View {
    let host: SSHHostInfo
    var isConnecting = false

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(
                systemName: host.isKeyAuth ? "key.fill" : "terminal.fill",
                color: host.isKeyAuth ? .indigo : .teal
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(host.displayName)
                        .font(.body.bold())
                        .lineLimit(1)
                    if let group = host.groupBelong, !group.isEmpty, group != "Default" {
                        StatusBadge(text: group, color: .secondary)
                    }
                }
                Text("\(host.user ?? "—")@\(host.endpoint)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let desc = host.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isConnecting {
                ProgressView()
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - 主机编辑表单（添加 / 编辑，须先测试通过）

struct SSHHostEditView: View {
    @ObservedObject var vm: SSHHostsViewModel
    /// 编辑模式传入已有主机；添加模式传 nil
    let editing: SSHHostInfo?
    @Environment(\.dismiss) private var dismiss

    @State private var addr = ""
    @State private var portText = "22"
    @State private var user = ""
    @State private var authMode = "password"
    @State private var password = ""
    @State private var privateKey = ""
    @State private var passPhrase = ""
    @State private var rememberPassword = false
    @State private var groupID = 0
    @State private var name = ""
    @State private var desc = ""
    @State private var tested = false
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var didFill = false

    private var isEditing: Bool { editing != nil }
    private var isKeyAuth: Bool { authMode == "key" }
    private var port: Int? { Int(portText) }

    private var formValid: Bool {
        guard !addr.isEmpty, !user.isEmpty, let port, port > 0 else { return false }
        if isKeyAuth {
            return !privateKey.isEmpty || (isEditing && !(editing?.privateKey ?? "").isEmpty)
        }
        return !password.isEmpty || (isEditing && !(editing?.password ?? "").isEmpty)
    }

    private var canSave: Bool { formValid && tested && !isSaving }

    var body: some View {
        Form {
            basicSection
            authSection
            groupSection
            testSection
        }
        .navigationTitle(isEditing ? L10n.t("编辑主机") : L10n.t("添加主机"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if let req = buildRequest() {
                        Task {
                            isSaving = true
                            if await vm.upsert(req) { dismiss() }
                            isSaving = false
                        }
                    }
                } label: {
                    if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                }
                .disabled(!canSave)
            }
        }
        .onAppear {
            fillIfEditing()
            if groupID == 0 { groupID = vm.defaultGroupID }
        }
        .onChange(of: vm.groups) { _, _ in
            if groupID == 0 { groupID = vm.defaultGroupID }
        }
        .onChange(of: authMode) { _, _ in
            // 认证方式变更后原测试结果失效
            tested = false
        }
    }

    // MARK: - 基本信息

    private var basicSection: some View {
        Section {
            FormTextField(label: L10n.t("主机地址"), text: $addr, style: .stacked, keyboardType: .URL)
            OutlinedTextField(label: L10n.t("端口"), text: $portText, keyboardType: .numberPad)
            OutlinedTextField(label: L10n.t("用户名"), text: $user)
            OutlinedTextField(label: L10n.t("标题（可选）"), text: $name)
            OutlinedTextField(label: L10n.t("描述（可选）"), text: $desc, machineValue: false)
        } header: {
            Text(L10n.t("基本信息"))
        }
    }

    // MARK: - 认证

    private var authSection: some View {
        Section {
            OutlinedPicker(label: L10n.t("认证方式"), options: ["password", "key"],
                           selection: $authMode,
                           optionLabels: ["password": L10n.t("密码认证"),
                                          "key": L10n.t("私钥认证")])

            if isKeyAuth {
                TextEditor(text: $privateKey)
                    .font(.dataMonospacedFootnote)
                    .frame(minHeight: 100)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .overlay(alignment: .topLeading) {
                        if privateKey.isEmpty {
                            Text(isEditing ? L10n.t("私钥（不修改请留空）") : L10n.t("私钥（粘贴 OPENSSH PRIVATE KEY）"))
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                    }
                OutlinedTextField(label: L10n.t("私钥密码（可选）"), text: $passPhrase, isSecure: true)
            } else {
                SecureField(isEditing ? L10n.t("密码（不修改请留空）") : L10n.t("密码"), text: $password)
            }

            Toggle(L10n.t("记住认证信息"), isOn: $rememberPassword)
        } header: {
            Text(L10n.t("认证"))
        } footer: {
            Text(L10n.t("私钥支持粘贴 OPENSSH 格式内容；测试通过后才能保存"))
        }
    }

    // MARK: - 分组

    private var groupSection: some View {
        Section {
            if vm.groups.isEmpty {
                LabeledContent(L10n.t("分组"), value: "Default")
            } else {
                Picker(L10n.t("分组"), selection: $groupID) {
                    ForEach(vm.groups) { group in
                        Text(group.name ?? "Default").tag(group.id)
                    }
                }
            }
        }
    }

    // MARK: - 连接测试

    private var testSection: some View {
        Section {
            Button {
                Task {
                    guard let req = buildRequest() else { return }
                    isTesting = true
                    tested = await vm.testByInfo(req)
                    isTesting = false
                }
            } label: {
                HStack {
                    Label(L10n.t("连接测试"), systemImage: "dot.radiowaves.left.and.right")
                    if isTesting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isTesting || !formValid)

            if tested {
                Label(L10n.t("测试已通过"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } footer: {
            Text(L10n.t("保存前需连接测试通过"))
        }
    }

    // MARK: - 编辑预填

    private func fillIfEditing() {
        guard let host = editing, !didFill else { return }
        didFill = true
        addr = host.addr ?? ""
        portText = host.port.map { String($0) } ?? "22"
        user = host.user ?? ""
        authMode = host.authMode ?? "password"
        rememberPassword = host.rememberPassword ?? false
        groupID = host.groupID ?? vm.defaultGroupID
        name = host.name ?? ""
        desc = host.description ?? ""
    }

    // MARK: - 请求构造

    /// 凭据字段：有输入用明文 base64；编辑未修改时回传服务端加密原值
    private func buildRequest() -> SSHHostUpsertRequest? {
        guard let port, formValid else { return nil }
        var req = SSHHostUpsertRequest(
            id: editing?.id,
            createdAt: editing?.createdAt,
            groupID: groupID,
            name: name.isEmpty ? nil : name,
            addr: addr,
            port: port,
            user: user,
            authMode: authMode,
            password: nil,
            privateKey: nil,
            passPhrase: nil,
            rememberPassword: rememberPassword,
            description: desc.isEmpty ? nil : desc
        )
        if isKeyAuth {
            req.privateKey = privateKey.isEmpty
                ? (editing?.privateKey ?? "")
                : Data(privateKey.utf8).base64EncodedString()
            req.passPhrase = passPhrase.isEmpty
                ? (editing?.passPhrase ?? "")
                : Data(passPhrase.utf8).base64EncodedString()
            if isEditing {
                req.password = editing?.password ?? ""
            }
        } else {
            req.password = password.isEmpty
                ? (editing?.password ?? "")
                : Data(password.utf8).base64EncodedString()
            if isEditing {
                req.privateKey = editing?.privateKey ?? ""
                req.passPhrase = editing?.passPhrase ?? ""
            }
        }
        return req
    }
}

// MARK: - ViewModel

@MainActor
final class SSHHostsViewModel: ObservableObject {
    @Published var hosts: [SSHHostInfo] = []
    @Published var groups: [SSHHostGroup] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    @Published var showAlert = false
    @Published var alertMessage = ""

    /// 轻量提示（自动消失，无需确认）
    @Published var toastMessage: String?
    private var toastTask: Task<Void, Never>?

    /// 列表删除确认
    @Published var pendingDeleteHost: SSHHostInfo?

    private let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient.shared(for: server)
    }

    /// 默认分组 id（添加主机时预选）
    var defaultGroupID: Int {
        groups.first(where: { $0.isDefault == true })?.id ?? groups.first?.id ?? 0
    }

    func loadAll() async {
        async let hosts: Void = loadHosts()
        async let groups: Void = loadGroups()
        _ = await (hosts, groups)
    }

    func loadHosts() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let resp: PageResponse<SSHHostInfo> = try await client.send(
                path: APIEndpoint.hostsSearch.path,
                body: SSHHostListRequest(),
                as: PageResponse<SSHHostInfo>.self
            )
            hosts = resp.items ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadGroups() async {
        guard groups.isEmpty else { return }
        do {
            groups = try await client.send(
                path: APIEndpoint.hostGroupsSearch.path,
                body: SSHHostGroupRequest(),
                as: [SSHHostGroup].self
            )
        } catch {
            groups = []
        }
    }

    /// 连接前按已存 id 测试连通（未记住认证信息的主机同样适用）
    @discardableResult
    func testByID(_ host: SSHHostInfo) async -> Bool {
        do {
            let ok: Bool = try await client.send(
                path: APIEndpoint.hostsTestByID.path,
                body: SSHHostTestByIDRequest(id: host.id),
                as: Bool.self
            )
            if !ok {
                showAlert(message: L10n.f("无法连通「%@」，请检查主机状态与认证信息", host.displayName))
            }
            return ok
        } catch let err as APIError {
            showAlert(message: L10n.f("连接失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("连接失败：%@", error.localizedDescription))
            return false
        }
    }

    /// 添加 / 编辑时的连接测试（按表单信息）
    @discardableResult
    func testByInfo(_ req: SSHHostUpsertRequest) async -> Bool {
        do {
            let ok: Bool = try await client.send(
                path: APIEndpoint.hostsTestByInfo.path,
                body: req,
                as: Bool.self
            )
            if !ok {
                showAlert(message: L10n.t("连接测试未通过，请检查地址、端口与认证信息"))
            } else {
                showToast(L10n.t("连接测试通过"))
            }
            return ok
        } catch let err as APIError {
            showAlert(message: L10n.f("测试失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("测试失败：%@", error.localizedDescription))
            return false
        }
    }

    @discardableResult
    func upsert(_ req: SSHHostUpsertRequest) async -> Bool {
        let isCreate = req.id == nil
        do {
            let _: EmptyResponse = try await client.send(
                path: isCreate ? APIEndpoint.hostsCreate.path : APIEndpoint.hostsUpdate.path,
                body: req,
                as: EmptyResponse.self
            )
            showToast(isCreate ? L10n.t("主机已添加") : L10n.t("主机已更新"))
            await loadHosts()
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("保存失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("保存失败：%@", error.localizedDescription))
            return false
        }
    }

    func delete(_ host: SSHHostInfo) async {
        pendingDeleteHost = nil
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.hostsDelete.path,
                body: SSHHostDeleteRequest(ids: [host.id]),
                as: EmptyResponse.self
            )
            showToast(L10n.f("主机「%@」已删除", host.displayName))
            await loadHosts()
        } catch let err as APIError {
            showAlert(message: L10n.f("删除失败：%@", err.errorDescription ?? L10n.t("未知错误")))
        } catch {
            showAlert(message: L10n.f("删除失败：%@", error.localizedDescription))
        }
    }

    // MARK: 提示

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { self?.toastMessage = nil }
        }
    }
}


// MARK: - 面板保留终端会话（v2.3.0 会话保留：Web 终端创建、断线可恢复的会话）

struct PanelTerminalSessionsView: View {
    let server: ServerConfig

    @State private var sessions: [PanelTerminalSession] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var toastMessage: String?
    @State private var pendingCloseAll = false

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        List {
            if isLoading && sessions.isEmpty {
                Section { HStack { Spacer(); LoadingStateView(); Spacer() }.padding(.vertical, 24) }
                    .listRowBackground(Color.clear)
            } else if let err = errorMessage, sessions.isEmpty {
                Section {
                    LoadErrorStateView(message: err) { Task { await load() } }
                        .listRowBackground(Color.clear)
                }
            } else if sessions.isEmpty {
                Section {
                    ContentUnavailableView(
                        L10n.t("暂无面板会话"),
                        systemImage: "rectangle.on.rectangle",
                        description: Text(L10n.t("网页终端创建并保留的会话会显示在这里，可远程关闭。"))
                    )
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(sessions) { session in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Image(systemName: kindIcon(session.kind))
                                    .foregroundStyle(.tint)
                                Text(session.title ?? session.sessionID ?? "—")
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                                Spacer()
                                if session.attached == true {
                                    StatusBadge(text: L10n.t("在线"), color: .statusRunning)
                                } else {
                                    StatusBadge(text: L10n.t("已断开"), color: .statusStopped)
                                }
                            }
                            if let created = session.createdAt, !created.isEmpty {
                                Text(L10n.f("创建于 %@", String(created.prefix(19)).replacingOccurrences(of: "T", with: " ")))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Haptic.warning()
                                Task { await close(session) }
                            } label: {
                                Label(L10n.t("关闭"), systemImage: "xmark.circle")
                            }
                        }
                    }
                } header: {
                    Text(L10n.f("共 %ld 个", sessions.count))
                }
            }
        }
        .navigationTitle(L10n.t("面板会话"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !sessions.isEmpty {
                    Button(L10n.t("全部关闭")) { pendingCloseAll = true }
                        .foregroundStyle(.red)
                }
            }
        }
        .refreshable { await load() }
        .toastOverlay(message: $toastMessage)
        .alert(L10n.t("全部关闭"), isPresented: $pendingCloseAll) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("关闭"), role: .destructive) {
                Task { await closeAll() }
            }
        } message: {
            Text(L10n.t("将关闭全部面板保留的终端会话（含网页端正在使用的会话），是否继续？"))
        }
        .task { await load() }
    }

    private func kindIcon(_ kind: String?) -> String {
        switch kind {
        case "ssh": return "personalhotspot"
        case "container": return "shippingbox"
        default: return "terminal"
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            sessions = try await client.send(
                path: APIEndpoint.terminalSessionsSearch.path,
                body: EmptyRequest(),
                as: [PanelTerminalSession].self
            )
            errorMessage = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func close(_ session: PanelTerminalSession) async {
        guard let id = session.sessionID else { return }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.terminalSessionClose.path,
                body: PanelTerminalSessionCloseRequest(id: id),
                as: EmptyResponse.self
            )
            await load()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            toastMessage = error.localizedDescription
        }
    }

    private func closeAll() async {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.terminalSessionCloseAll.path,
                body: EmptyRequest(),
                as: EmptyResponse.self
            )
            toastMessage = L10n.t("已全部关闭")
            await load()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            toastMessage = error.localizedDescription
        }
    }
}
