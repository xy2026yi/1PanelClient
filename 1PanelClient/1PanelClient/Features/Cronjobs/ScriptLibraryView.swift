//
//  ScriptLibraryView.swift
//  1PanelClient
//
//  脚本库：列表 / 搜索 / 查看脚本内容 / 执行脚本 / 选择脚本填充计划任务
//  POST /api/v2/core/script/search
//  执行：WS /api/v2/core/script/run?script_id=N
//

import SwiftUI
import Combine

@MainActor
final class ScriptLibraryViewModel: ObservableObject {
    @Published var scripts: [ScriptItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var toastMessage: String?
    /// 脚本库自动同步开关（settings.search → scriptSync）
    @Published var isAutoSyncEnabled = false
    /// 分组（列表筛选数据源）
    @Published var groups: [PanelGroup] = []
    /// 当前筛选分组（0 = 全部）
    @Published var selectedGroupID = 0

    private var client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient.shared(for: server)
    }

    func load(query: String = "") async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let req = ScriptSearchRequest(info: query, groupID: selectedGroupID, page: 1, pageSize: 100)
        do {
            let resp: PageResponse<ScriptItem> = try await client.send(
                path: APIEndpoint.scriptSearch.path, body: req,
                as: PageResponse<ScriptItem>.self
            )
            self.scripts = resp.items ?? []
        } catch {
            // 页面退出取消不是失败：保留原快照
            guard !APIError.isCancellation(error) else { return }
            self.errorMessage = error.localizedDescription
            self.scripts = []
        }
    }

    /// 加载脚本库分组（筛选条数据源；失败静默）
    /// - Parameter force: true 强制重查（分组管理页变更后）
    func loadGroups(force: Bool = false) async {
        guard force || groups.isEmpty else { return }
        do {
            let items: [PanelGroup] = try await client.send(
                path: GroupScope.script.searchPath,
                body: GroupSearchRequest(type: GroupScope.script.type),
                as: [PanelGroup].self
            )
            groups = items
            // 选中的分组已被删除：回落「全部」
            if selectedGroupID != 0, !items.contains(where: { $0.id == selectedGroupID }) {
                selectedGroupID = 0
            }
        } catch {
            guard !APIError.isCancellation(error) else { return }
            if force { groups = [] }
        }
    }

    // MARK: - 同步

    /// 读取自动同步开关（POST /core/settings/search → scriptSync）
    func loadAutoSync() async {
        do {
            let info: SettingInfo = try await client.send(
                path: APIEndpoint.settingsSearch.path,
                as: SettingInfo.self
            )
            isAutoSyncEnabled = (info.scriptSync ?? "Enable") == "Enable"
        } catch {
            // 页面退出取消不是失败：保留上次开关状态
            guard !APIError.isCancellation(error) else { return }
            isAutoSyncEnabled = true
        }
    }

    /// 立即同步系统脚本库：成功返回任务 ID（进度走任务日志）
    @discardableResult
    func syncNow() async -> String? {
        let taskID = UUID().uuidString
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.scriptSync.path,
                body: ScriptSyncRequest(taskID: taskID),
                as: EmptyResponse.self
            )
            return taskID
        } catch let err as APIError {
            showAlert(message: L10n.f("同步请求失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return nil
        } catch {
            showAlert(message: L10n.f("同步请求失败：%@", error.localizedDescription))
            return nil
        }
    }

    /// 自动同步开关：POST /core/settings/update {key: ScriptSync}
    @discardableResult
    func updateAutoSync(enabled: Bool) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.coreSettingsUpdate.path,
                body: CoreSettingUpdateRequest(key: "ScriptSync", value: enabled ? "Enable" : "Disable"),
                as: EmptyResponse.self
            )
            isAutoSyncEnabled = enabled
            showToast(enabled ? L10n.t("已开启自动同步") : L10n.t("已关闭自动同步"))
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("操作失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("操作失败：%@", error.localizedDescription))
            return false
        }
    }

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { self?.toastMessage = nil }
        }
    }
}

// MARK: - 脚本库列表

struct ScriptLibraryView: View {
    @StateObject private var vm: ScriptLibraryViewModel
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var showMenu = false
    /// 立即同步确认
    @State private var confirmSyncNow = false
    /// 关闭自动同步确认
    @State private var confirmDisableAutoSync = false
    /// 开启自动同步确认
    @State private var confirmEnableAutoSync = false
    /// 同步任务 ID（非 nil 时 push 任务进度页）
    @State private var syncTaskID: String?
    // 分组管理入口（三点菜单；选择脚本模式下不展示）
    @State private var showGroupManage = false

    private let server: ServerConfig

    /// 选择模式：非 nil 时，点击脚本行调用 onPick 并返回（用于创建计划任务填充脚本）
    var onPick: ((ScriptItem) -> Void)?

    init(server: ServerConfig, onPick: ((ScriptItem) -> Void)? = nil) {
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(key: ManageItem.scriptLibrary.storeKey(server: server)) {
            ScriptLibraryViewModel(server: server)
        })
        self.server = server
        self.onPick = onPick
    }

    var body: some View {
        VStack(spacing: 0) {
            // 分组筛选条放在分支外常驻（末尾「管理」入口推入分组管理页）：
            // 选中分组无脚本时仍能切回「全部」；选择脚本模式（创建计划任务选稿）
            // 下不显示管理入口
            if !vm.groups.isEmpty {
                GroupFilterBar(
                    groups: vm.groups,
                    selectedID: $vm.selectedGroupID,
                    onManage: onPick == nil ? { showGroupManage = true } : nil
                )
            }

            if vm.isLoading && vm.scripts.isEmpty {
                LoadingStateView()
            } else if let err = vm.errorMessage, !err.isEmpty, vm.scripts.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button(L10n.t("重试")) {
                        Task { await vm.load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if vm.scripts.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无脚本"),
                    systemImage: "doc.text",
                    description: Text(L10n.t("脚本库为空"))
                )
            } else {
                scriptList
            }
        }
        .searchIconMode(
            text: $searchText,
            isSearching: $isSearching,
            title: L10n.t("脚本库"),
            prompt: L10n.t("搜索脚本名")
        )
        // 右上角：搜索 + 三点菜单（立即同步 / 自动同步）
        .toolbar {
            if !isSearching {
                ToolbarItem(placement: .topBarTrailing) {
                    EllipsisMenuButton {
                        withAnimation(Motion.fast) { showMenu.toggle() }
                    }
                    .accessibilityLabel(L10n.t("更多"))
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if showMenu {
                EllipsisMenuPopup(entries: [
                    .action(title: L10n.t("立即同步"), icon: "arrow.trianglehead.2.clockwise.rotate.90") { confirmSyncNow = true },
                    .action(title: vm.isAutoSyncEnabled ? L10n.t("关闭自动同步") : L10n.t("开启自动同步"),
                            icon: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90") {
                        if vm.isAutoSyncEnabled {
                            confirmDisableAutoSync = true
                        } else {
                            confirmEnableAutoSync = true
                        }
                    },
                    // 分组管理入口已移至筛选条末尾「管理」chip（推页呈现）
                ]) {
                    withAnimation(Motion.fast) { showMenu = false }
                }
            }
        }
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .alert(L10n.t("立即同步"), isPresented: $confirmSyncNow) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("确认")) {
                Task {
                    if let taskID = await vm.syncNow() {
                        syncTaskID = taskID
                    }
                }
            }
        } message: {
            Text(L10n.t("即将同步系统脚本库，该操作仅针对系统脚本，是否继续？"))
        }
        .alert(L10n.t("关闭自动同步"), isPresented: $confirmDisableAutoSync) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("确认")) {
                Task { await vm.updateAutoSync(enabled: false) }
            }
        } message: {
            Text(L10n.t("关闭自动同步可能导致脚本同步不及时，是否确认？"))
        }
        .alert(L10n.t("开启自动同步"), isPresented: $confirmEnableAutoSync) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("确认")) {
                Task { await vm.updateAutoSync(enabled: true) }
            }
        } message: {
            Text(L10n.t("开启自动同步将在每天凌晨时段进行自动同步"))
        }
        .navigationDestination(isPresented: Binding(
            get: { syncTaskID != nil },
            set: { if !$0 { syncTaskID = nil } }
        )) {
            if let taskID = syncTaskID {
                TaskProgressView(taskID: taskID, title: L10n.t("同步脚本库")) { _ in
                    Task { await vm.load(query: searchText) }
                    return false
                }
            }
        }
        .task {
            // 分组筛选条数据源（首次进入加载一次，失败静默）
            await vm.loadGroups()
            // 重访（已有快照）时门控不转圈，这里静默刷新（5 秒内重访节流）
            await PageVMStore.shared.autoRefresh(vm: vm) {
                await vm.load()
                await vm.loadAutoSync()
            }
        }
        .onChange(of: searchText) { _, newValue in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { await vm.load(query: newValue) }
            }
        }
        .onChange(of: vm.selectedGroupID) { _, _ in
            // 切换分组：沿用当前搜索词重查（与搜索同款 300ms 防抖）
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { await vm.load(query: searchText) }
            }
        }
        .navigationDestination(isPresented: $showGroupManage) {
            GroupManageView(server: server, scope: .script) {
                Task {
                    await vm.loadGroups(force: true)
                    await vm.load(query: searchText)
                }
            }
        }
    }

    private var scriptList: some View {
        List {
            ForEach(vm.scripts) { script in
                if onPick != nil {
                    Button {
                        if let pick = onPick { pick(script) }
                    } label: {
                        ScriptRow(script: script)
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink {
                        ScriptDetailView(script: script, server: server)
                    } label: {
                        ScriptRow(script: script)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await vm.load(query: searchText) }
    }
}

// MARK: - 脚本列表项

struct ScriptRow: View {
    let script: ScriptItem

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "terminal", color: .purple, size: 34, cornerRadius: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(script.displayName)
                    .font(.body.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let desc = script.displayDescription, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if script.isSystem == true {
                        StatusBadge(text: L10n.t("系统"), color: .blue)
                    }
                    if script.isInteractive == true {
                        StatusBadge(text: L10n.t("需交互"), color: .orange)
                    }
                    StatusBadge(text: script.riskLevel.label, color: script.riskLevel.color)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 脚本详情

struct ScriptDetailView: View {
    let script: ScriptItem
    let server: ServerConfig
    @State private var showTerminal = false
    @State private var confirmHighRisk = false

    var body: some View {
        List {
            Section(L10n.t("基本信息")) {
                InfoRow(L10n.t("名称"), value: script.displayName)
                if let desc = script.displayDescription, !desc.isEmpty {
                    InfoRow(L10n.t("描述"), value: desc)
                }
                if script.isInteractive == true {
                    InfoRow(L10n.t("类型"), value: L10n.t("需要交互输入"))
                }
                InfoRow(L10n.t("风险等级"), value: script.riskLevel.label)
                if let t = script.createdAt, !t.isEmpty {
                    InfoRow(L10n.t("创建时间"), value: t.prefix(19).description)
                }
            }

            if let code = script.script, !code.isEmpty {
                Section(L10n.t("脚本内容")) {
                    Text(code)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle(script.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    // 高风险脚本执行前二次确认（Termius 风险标注模式）
                    if script.riskLevel == .high {
                        confirmHighRisk = true
                    } else {
                        showTerminal = true
                    }
                } label: {
                    Text(L10n.t("安装")).fontWeight(.medium)
                }
            }
        }
        .alert(L10n.t("高风险脚本"), isPresented: $confirmHighRisk) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("仍然执行"), role: .destructive) { Haptic.warning(); showTerminal = true }
        } message: {
            Text(L10n.t("该脚本包含删除、磁盘写入或重启类命令，执行后可能不可恢复。确定要运行吗？"))
        }
        .navigationDestination(isPresented: $showTerminal) {
            TerminalScreen(
                server: server,
                target: .scriptRun(scriptID: script.id, cols: 80, rows: 24),
                title: script.displayName
            )
        }
    }
}
