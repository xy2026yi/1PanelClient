//
//  FtpView.swift
//  1PanelClient
//
//  FTP 工具箱：安装状态（未安装跳脚本库）/ 服务启停 / 账号列表（添加/编辑/删除）/ 用户日志
//  接口见 logs/FTP.md 抓包（/api/v2/toolbox/ftp/*）
//

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class FTPViewModel: ObservableObject {
    @Published var base: FTPBase?
    @Published var isLoading = true
    @Published var isOperating = false
    @Published var isSyncing = false
    @Published var errorMessage: String?
    /// 账号列表加载失败（与空列表区分，避免错误被空态掩盖）
    @Published var listErrorMessage: String?

    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var toastMessage: String?
    private var toastTask: Task<Void, Never>?

    // 账号列表（服务端分页）
    @Published var accounts: [FTPItem] = []
    @Published private(set) var total = 0
    @Published private(set) var isLoadingAccounts = false
    @Published private(set) var isLoadingMore = false
    private var page = 1
    private var loadGeneration = 0
    private static let pageSize = 20

    /// 删除确认
    @Published var pendingDeleteAccount: FTPItem?

    private(set) var client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient.shared(for: server)
    }

    var isInstalled: Bool { base?.isExist ?? false }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        await loadBase()
        await loadAccounts()
    }

    func loadBase() async {
        do {
            base = try await client.send(path: APIEndpoint.ftpBase.path, method: "GET", as: FTPBase.self)
            errorMessage = nil
        } catch {
            // 页面退出取消不是失败：保留原状态
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadAccounts() async {
        isLoadingAccounts = true
        listErrorMessage = nil
        defer { isLoadingAccounts = false }
        page = 1
        loadGeneration += 1
        let req = FTPSearchRequest(page: 1, pageSize: Self.pageSize)
        do {
            let resp: PageResponse<FTPItem> = try await client.send(
                path: APIEndpoint.ftpSearch.path, body: req, as: PageResponse<FTPItem>.self)
            accounts = resp.items ?? []
            total = resp.total ?? 0
        } catch {
            guard !APIError.isCancellation(error) else { return }
            // 基础状态已可展示：列表失败单独提示，可重试
            accounts = []
            total = 0
            listErrorMessage = error.localizedDescription
        }
    }

    func loadMoreAccounts() async {
        guard accounts.count < total, !isLoadingMore, !isLoadingAccounts else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let next = page + 1
        let generation = loadGeneration
        let req = FTPSearchRequest(page: next, pageSize: Self.pageSize)
        do {
            let resp: PageResponse<FTPItem> = try await client.send(
                path: APIEndpoint.ftpSearch.path, body: req, as: PageResponse<FTPItem>.self)
            // 期间重载过：丢弃过期追加
            guard generation == loadGeneration else { return }
            let existing = Set(accounts.map(\.id))
            let newItems = (resp.items ?? []).filter { !existing.contains($0.id) }
            if newItems.isEmpty {
                total = accounts.count
                return
            }
            accounts += newItems
            total = resp.total ?? total
            page = next
        } catch {
            // 追加失败不打断列表，下拉刷新可重试
        }
    }

    func operate(_ operation: String) async {
        isOperating = true
        errorMessage = nil
        defer { isOperating = false }
        let req = FTPOperateRequest(operation: operation)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.ftpOperate.path, body: req, as: EmptyResponse.self)
            showToast(L10n.t("操作成功"))
            await loadBase()
        } catch {
            showAlert(message: L10n.f("操作失败：%@", error.localizedDescription))
        }
    }

    @discardableResult
    func create(req: FTPCreateRequest) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.ftpCreate.path, body: req, as: EmptyResponse.self)
            showToast(L10n.f("账号「%@」已创建", req.user))
            await loadAccounts()
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("创建失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("创建失败：%@", error.localizedDescription))
            return false
        }
    }

    @discardableResult
    func update(req: FTPUpdateRequest) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.ftpUpdate.path, body: req, as: EmptyResponse.self)
            showToast(L10n.f("账号「%@」已更新", req.user))
            await loadAccounts()
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("更新失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("更新失败：%@", error.localizedDescription))
            return false
        }
    }

    func delete(account: FTPItem) async {
        pendingDeleteAccount = nil
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.ftpDelete.path,
                body: FTPDeleteRequest(ids: [account.id]),
                as: EmptyResponse.self)
            showToast(L10n.f("账号「%@」已删除", account.user))
            await loadAccounts()
        } catch let err as APIError {
            showAlert(message: L10n.f("删除失败：%@", err.errorDescription ?? L10n.t("未知错误")))
        } catch {
            showAlert(message: L10n.f("删除失败：%@", error.localizedDescription))
        }
    }

    /// 同步服务器上的 FTP 账号（调用方先确认）
    @discardableResult
    func syncAccounts() async -> Bool {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.ftpSync.path, as: EmptyResponse.self)
            showToast(L10n.t("同步完成"))
            await loadAccounts()
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("同步失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("同步失败：%@", error.localizedDescription))
            return false
        }
    }

    // MARK: 提示

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { self?.toastMessage = nil }
        }
    }
}

// MARK: - FTP 主视图

struct FTPView: View {
    @StateObject private var vm: FTPViewModel

    private let server: ServerConfig

    @State private var isServiceExpanded = false
    @State private var pendingAction: String?
    @State private var showCreate = false
    @State private var showMenu = false
    @State private var confirmSync = false
    /// 长按弹出的操作菜单目标（编辑 / 日志 / 删除）
    @State private var actionAccount: FTPItem?
    /// 行「编辑」推入的表单目标
    @State private var editingAccount: FTPItem?
    /// 行「日志」推入的用户日志页目标
    @State private var logAccount: FTPItem?

    init(server: ServerConfig) {
        self.server = server
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(key: ManageItem.ftp.storeKey(server: server)) {
            FTPViewModel(server: server)
        })
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.base == nil {
                LoadingStateView()
            } else if let base = vm.base {
                if base.isExist {
                    content(base: base)
                } else {
                    notInstalledView
                }
            } else if let err = vm.errorMessage {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button(L10n.t("重试")) { Task { await vm.load() } }
                }
            }
        }
        .navigationTitle("FTP")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 未安装时不显示同步/添加入口
            if vm.isInstalled {
                ToolbarItem(placement: .topBarTrailing) {
                    EllipsisMenuButton(isLoading: vm.isSyncing) {
                        withAnimation(Motion.fast) { showMenu.toggle() }
                    }
                    .accessibilityLabel(L10n.t("更多操作"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L10n.t("添加账号"))
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if showMenu {
                EllipsisMenuPopup(entries: [
                    .action(title: L10n.t("同步"), icon: "arrow.trianglehead.2.clockwise.rotate.90", isDisabled: vm.isSyncing) {
                        confirmSync = true
                    },
                ]) {
                    withAnimation(Motion.fast) { showMenu = false }
                }
            }
        }
        .refreshable { await vm.load() }
        .task { await PageVMStore.shared.autoRefresh(vm: vm) { await vm.load() } }
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .alert(
            pendingAction.map { ftpActionDisplayName($0) } ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            )
        ) {
            Button(L10n.t("取消"), role: .cancel) { pendingAction = nil }
            Button(L10n.t("确认"), role: .destructive) {
                Haptic.warning()
                let op = pendingAction
                pendingAction = nil
                if let op { Task { await vm.operate(op) } }
            }
        } message: {
            if let action = pendingAction {
                Text(L10n.f("将对 FTP 进行 %@ 操作，是否继续？", ftpActionDisplayName(action)))
            }
        }
        .alert(L10n.t("删除账号"), isPresented: Binding(
            get: { vm.pendingDeleteAccount != nil },
            set: { if !$0 { vm.pendingDeleteAccount = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { vm.pendingDeleteAccount = nil }
            Button(L10n.t("删除"), role: .destructive) {
                Haptic.warning()
                if let account = vm.pendingDeleteAccount {
                    Task { await vm.delete(account: account) }
                }
            }
        } message: {
            Text(L10n.f("确定删除账号「%@」吗？此操作不可恢复。", vm.pendingDeleteAccount?.user ?? ""))
        }
        .alert(L10n.t("同步"), isPresented: $confirmSync) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("确认")) {
                Task { await vm.syncAccounts() }
            }
        } message: {
            Text(L10n.t("将同步服务器上的 FTP 账号列表，是否继续？"))
        }
        .navigationDestination(isPresented: $showCreate) {
            FTPAccountFormView(server: server, editing: nil, vm: vm)
        }
        .navigationDestination(isPresented: Binding(
            get: { editingAccount != nil },
            set: { if !$0 { editingAccount = nil } }
        )) {
            if let account = editingAccount {
                FTPAccountFormView(server: server, editing: account, vm: vm)
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { logAccount != nil },
            set: { if !$0 { logAccount = nil } }
        )) {
            if let account = logAccount {
                FTPLogView(server: server, user: account.user)
            }
        }
    }

    private func ftpActionDisplayName(_ action: String) -> String {
        switch action {
        case "stop":    return L10n.t("停止")
        case "start":   return L10n.t("启动")
        case "restart": return L10n.t("重启")
        default:        return action
        }
    }

    // MARK: - 未安装

    /// 未安装：与数据库未安装页同款样式，安装入口跳转脚本库（FTP 由脚本安装）
    private var notInstalledView: some View {
        VStack(spacing: 20) {
            Spacer()

            IconBadge(systemName: "arrow.up.arrow.down", color: .teal, size: 72, cornerRadius: 16)
                .opacity(0.5)

            VStack(spacing: 8) {
                Text(L10n.f("%@未安装", "FTP"))
                    .font(.headline)
                Text(L10n.f("请先安装 %@ 后再使用此功能", "FTP"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            NavigationLink {
                ScriptLibraryView(server: server)
            } label: {
                Label(L10n.f("安装 %@", "Pure-FTPd"), systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)

            Spacer()
        }
        .padding()
    }

    // MARK: - 已安装

    @ViewBuilder
    private func content(base: FTPBase) -> some View {
        List {
            ServiceStatusCard(
                title: "FTP",
                statusText: base.isActive ? L10n.t("运行中") : L10n.t("已停止"),
                statusColor: base.isActive ? .statusRunning : .statusStopped,
                isOperating: vm.isOperating,
                isExpanded: $isServiceExpanded,
                actions: [
                    ServiceAction(
                        title: base.isActive ? L10n.t("停止") : L10n.t("启动"),
                        icon: base.isActive ? "stop.fill" : "play.fill",
                        color: base.isActive ? .orange : .green
                    ) { pendingAction = base.isActive ? "stop" : "start" },
                    ServiceAction(title: L10n.t("重启"), icon: "arrow.triangle.2.circlepath", color: .blue) {
                        pendingAction = "restart"
                    },
                ]
            ) {
                IconBadge(systemName: "arrow.up.arrow.down", color: .teal, size: 44)
            }

            accountSection
        }
        .listStyle(.insetGrouped)
        .sheet(item: $actionAccount) { account in
            ActionBottomSheet(
                title: account.user,
                items: [
                    ActionMenuItem(title: L10n.t("编辑"), icon: "pencil") {
                        editingAccount = account
                    },
                    ActionMenuItem(title: L10n.t("日志"), icon: "doc.text.magnifyingglass") {
                        logAccount = account
                    },
                    ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red, role: .destructive) {
                        vm.pendingDeleteAccount = account
                    },
                ],
                onDismiss: { actionAccount = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: 3))])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if vm.accounts.isEmpty {
                if vm.isLoadingAccounts || vm.isLoading {
                    HStack {
                        Spacer()
                        LoadingStateView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else if let listErr = vm.listErrorMessage {
                    LoadErrorStateView(message: listErr) {
                        Task { await vm.loadAccounts() }
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ContentUnavailableView(
                        L10n.t("暂无账号"),
                        systemImage: "person.crop.circle",
                        description: Text(L10n.t("点击右上角 + 添加账号"))
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(vm.accounts) { account in
                    Button {
                        editingAccount = account
                    } label: {
                        FTPAccountRow(account: account)
                    }
                    .buttonStyle(.plain)
                    // 行级操作收进长按菜单（编辑 / 日志 / 删除），不再用滑动操作；
                    // 用 simultaneousGesture 与点击进入共存——onLongPressGesture
                    // 会独占手势导致点击无法进编辑
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                            Haptic.selection()
                            actionAccount = account
                        }
                    )
                    .onAppear {
                        if account.id == vm.accounts.last?.id {
                            Task { await vm.loadMoreAccounts() }
                        }
                    }
                }

                if vm.accounts.count < vm.total || vm.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .onAppear { Task { await vm.loadMoreAccounts() } }
                }
            }
        } header: {
            SectionLabel(title: L10n.t("账号"), systemImage: "person.2")
        }
    }
}

// MARK: - 账号列表行

struct FTPAccountRow: View {
    let account: FTPItem

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "person.fill", color: .teal)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(account.user)
                        .font(.body.bold())
                        .lineLimit(1)
                    if !account.isEnabled {
                        StatusBadge(text: L10n.t("已停用"), color: .secondary)
                    }
                }
                Text(account.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let desc = account.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - 添加 / 编辑表单

struct FTPAccountFormView: View {
    let server: ServerConfig
    /// 编辑模式传入已有账号；添加模式传 nil
    let editing: FTPItem?
    @ObservedObject var vm: FTPViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var user = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var path = ""
    @State private var desc = ""
    @State private var showDirPicker = false
    /// 目录权限变更确认（创建必弹；编辑仅路径变化时弹）
    @State private var showPermConfirm = false
    @State private var isSaving = false
    @State private var didFill = false

    private var isEditing: Bool { editing != nil }

    private var canSubmit: Bool {
        !user.isEmpty && !password.isEmpty && path.hasPrefix("/") && !isSaving
    }

    var body: some View {
        Form {
            Section {
                TextField(L10n.t("用户名"), text: $user)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(isEditing)
                PasswordInputRow(password: $password, showPassword: $showPassword)
            } header: {
                SectionLabel(title: L10n.t("账号"), systemImage: "person.crop.circle")
            } footer: {
                if isEditing {
                    Text(L10n.t("用户名不可修改"))
                }
            }

            Section {
                HStack {
                    TextField(L10n.t("根目录"), text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        showDirPicker = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.t("浏览目录"))
                }
            } header: {
                SectionLabel(title: L10n.t("根目录"), systemImage: "folder")
            } footer: {
                Text(L10n.t("开启 FTP 将修改整个根目录的权限"))
            }

            Section {
                TextField(L10n.t("可选描述"), text: $desc, axis: .vertical)
                    .lineLimit(1...3)
            } header: {
                SectionLabel(title: L10n.t("描述"), systemImage: "text.alignleft")
            }
        }
        .navigationTitle(isEditing ? L10n.t("编辑账号") : L10n.t("添加账号"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    submit()
                } label: {
                    if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                }
                .disabled(!canSubmit)
            }
        }
        .task {
            guard !didFill else { return }
            didFill = true
            if let account = editing {
                user = account.user
                password = account.password
                path = account.path
                desc = account.description ?? ""
                // 回填密码默认遮蔽（与网页端一致），需要核对时再点眼睛展开
                showPassword = false
            } else if password.isEmpty {
                password = PasswordInputRow.randomPassword()
                showPassword = true
            }
        }
        .sheet(isPresented: $showDirPicker) {
            // 用宿主 VM 的 client：避免多机切换瞬间读到别的服务器的目录
            DirectoryPickerSheet(client: vm.client) { picked in
                path = picked
            }
        }
        .alert("FTP", isPresented: $showPermConfirm) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("确认"), role: .destructive) {
                Task { await save() }
            }
        } message: {
            Text(L10n.f("开启 FTP 将修改整个 %@ 目录权限，是否继续？", path))
        }
    }

    private func submit() {
        if !isEditing || path != editing?.path {
            showPermConfirm = true
        } else {
            Task { await save() }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        // 密码按接口要求 base64 编码传输
        let encoded = Data(password.utf8).base64EncodedString()
        let optionalDesc = desc.isEmpty ? nil : desc
        let ok: Bool
        if let account = editing {
            ok = await vm.update(req: FTPUpdateRequest(
                id: account.id,
                createdAt: account.createdAt,
                user: user,
                password: encoded,
                path: path,
                status: account.status,
                description: optionalDesc
            ))
        } else {
            ok = await vm.create(req: FTPCreateRequest(
                user: user,
                password: encoded,
                path: path,
                description: optionalDesc
            ))
        }
        if ok { dismiss() }
    }
}

// MARK: - 用户日志页

/// 单个 FTP 账号的上传/下载日志（POST /toolbox/ftp/log/search）
struct FTPLogView: View {
    let server: ServerConfig
    let user: String

    @State private var logs: [FTPLogItem] = []
    @State private var total = 0
    @State private var page = 1
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var loadGeneration = 0
    /// "" 全部 / "PUT" 上传 / "GET" 下载
    @State private var operation = ""

    private let client: APIClient
    private static let pageSize = 20

    init(server: ServerConfig, user: String) {
        self.server = server
        self.user = user
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        List {
            Section {
                Picker(L10n.t("操作"), selection: $operation) {
                    Text(L10n.t("全部")).tag("")
                    Text(L10n.t("上传")).tag("PUT")
                    Text(L10n.t("下载")).tag("GET")
                }
                .pickerStyle(.segmented)
                .onChange(of: operation) { _, _ in
                    Task { await load() }
                }
            }

            Section {
                if isLoading && logs.isEmpty {
                    HStack {
                        Spacer()
                        LoadingStateView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else if let err = errorMessage, !err.isEmpty, logs.isEmpty {
                    LoadErrorStateView(message: err) {
                        Task { await load() }
                    }
                    .listRowBackground(Color.clear)
                } else if logs.isEmpty {
                    ContentUnavailableView(
                        L10n.t("暂无日志"),
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(L10n.f("账号「%@」暂无传输记录", user))
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(Array(logs.enumerated()), id: \.offset) { _, log in
                        FTPLogRow(log: log)
                            .onAppear {
                                if log == logs.last {
                                    Task { await loadMore() }
                                }
                            }
                    }

                    if logs.count < total || isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .onAppear { Task { await loadMore() } }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("日志"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        page = 1
        loadGeneration += 1
        let req = FTPLogSearchRequest(user: user, operation: operation, page: 1, pageSize: Self.pageSize)
        do {
            let resp: PageResponse<FTPLogItem> = try await client.send(
                path: APIEndpoint.ftpLogSearch.path, body: req, as: PageResponse<FTPLogItem>.self)
            logs = resp.items ?? []
            total = resp.total ?? 0
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard logs.count < total, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let next = page + 1
        let generation = loadGeneration
        let req = FTPLogSearchRequest(user: user, operation: operation, page: next, pageSize: Self.pageSize)
        do {
            let resp: PageResponse<FTPLogItem> = try await client.send(
                path: APIEndpoint.ftpLogSearch.path, body: req, as: PageResponse<FTPLogItem>.self)
            guard generation == loadGeneration else { return }
            logs += resp.items ?? []
            total = resp.total ?? total
            page = next
        } catch {
            // 追加失败不打断列表，下拉刷新可重试
        }
    }
}

// MARK: - 日志行

struct FTPLogRow: View {
    let log: FTPLogItem

    /// 服务端操作串形如 "\"GET/tmp/test1/README.md\""：去掉包裹引号展示
    private var operationText: String {
        (log.operation ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private var isUpload: Bool { operationText.hasPrefix("PUT") }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(
                systemName: isUpload ? "arrow.up.circle.fill" : "arrow.down.circle.fill",
                color: isUpload ? .orange : .blue,
                size: 36,
                cornerRadius: 8
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(operationText)
                    .font(.caption.monospaced())
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if let time = log.time, !time.isEmpty {
                        Text(time)
                    }
                    if let ip = log.ip, !ip.isEmpty {
                        Text(ip)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if let status = log.status, !status.isEmpty {
                    StatusBadge(text: status, color: status == "200" ? .statusRunning : .semanticWarning, monospaced: true)
                }
                if let size = log.size, !size.isEmpty {
                    Text(size)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
