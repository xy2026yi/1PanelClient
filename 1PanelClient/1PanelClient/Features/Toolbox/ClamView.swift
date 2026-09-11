//
//  ClamView.swift
//  1PanelClient
//
//  ClamAV 病毒扫描：双服务管理（ClamAV / FreshClam 病毒库，可隐藏）/
//  扫描规则列表（创建/编辑/执行/报告/删除）/ 右上角设置入口
//  接口见 logs/ClamAV.md 抓包（/api/v2/toolbox/clam/*）
//

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class ClamViewModel: ObservableObject {
    @Published var base: ClamBase?
    @Published var isLoading = true
    @Published var isOperating = false
    @Published var errorMessage: String?

    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var toastMessage: String?
    private var toastTask: Task<Void, Never>?

    // 规则列表（服务端分页）
    @Published var rules: [ClamItem] = []
    @Published private(set) var total = 0
    @Published private(set) var isLoadingRules = false
    @Published private(set) var isLoadingMore = false
    private var page = 1
    private var loadGeneration = 0
    private static let pageSize = 20

    /// 删除确认（输入规则名称 + 可勾选同时删除病毒文件）
    @Published var pendingDeleteRule: ClamItem?
    @Published var deleteInfectedFiles = false

    private(set) var client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient.shared(for: server)
    }

    var isInstalled: Bool { base?.isExist ?? false }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        await loadBase()
        await loadRules()
    }

    func loadBase() async {
        do {
            base = try await client.send(
                path: APIEndpoint.clamBase.path,
                body: EmptyRequest(),
                as: ClamBase.self)
            errorMessage = nil
        } catch {
            // 页面退出取消不是失败：保留原状态
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadRules() async {
        isLoadingRules = true
        defer { isLoadingRules = false }
        page = 1
        loadGeneration += 1
        let req = ClamSearchRequest(page: 1, pageSize: Self.pageSize, orderBy: "createdAt", order: "null")
        do {
            let resp: PageResponse<ClamItem> = try await client.send(
                path: APIEndpoint.clamSearch.path, body: req, as: PageResponse<ClamItem>.self)
            rules = resp.items ?? []
            total = resp.total ?? 0
        } catch {
            guard !APIError.isCancellation(error) else { return }
            // 基础状态已可展示：列表失败降级为空列表 + 提示，不整页转错误态
            rules = []
            total = 0
            errorMessage = error.localizedDescription
        }
    }

    func loadMoreRules() async {
        guard rules.count < total, !isLoadingMore, !isLoadingRules else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let next = page + 1
        let generation = loadGeneration
        let req = ClamSearchRequest(page: next, pageSize: Self.pageSize, orderBy: "createdAt", order: "null")
        do {
            let resp: PageResponse<ClamItem> = try await client.send(
                path: APIEndpoint.clamSearch.path, body: req, as: PageResponse<ClamItem>.self)
            // 期间重载过：丢弃过期追加
            guard generation == loadGeneration else { return }
            let existing = Set(rules.map(\.id))
            let newItems = (resp.items ?? []).filter { !existing.contains($0.id) }
            if newItems.isEmpty {
                total = rules.count
                return
            }
            rules += newItems
            total = resp.total ?? total
            page = next
        } catch {
            // 追加失败不打断列表，下拉刷新可重试
        }
    }

    /// 服务操作：ClamAV 用 start/stop/restart，病毒库服务用 fresh- 前缀
    func operate(_ operation: String) async {
        isOperating = true
        errorMessage = nil
        defer { isOperating = false }
        let req = ClamOperateRequest(operation: operation)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.clamOperate.path, body: req, as: EmptyResponse.self)
            showToast(L10n.t("操作成功"))
            await loadBase()
        } catch {
            showAlert(message: L10n.f("操作失败：%@", error.localizedDescription))
        }
    }

    /// 立即执行扫描（异步任务，进度在报告页查看）
    func handle(rule: ClamItem) async {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.clamHandle.path,
                body: ClamHandleRequest(id: rule.id),
                as: EmptyResponse.self)
            showToast(L10n.f("扫描任务「%@」已开始", rule.name))
            await loadRules()
        } catch let err as APIError {
            showAlert(message: L10n.f("执行失败：%@", err.errorDescription ?? L10n.t("未知错误")))
        } catch {
            showAlert(message: L10n.f("执行失败：%@", error.localizedDescription))
        }
    }

    @discardableResult
    func createRule(req: ClamUpsertRequest) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.clamCreate.path, body: req, as: EmptyResponse.self)
            showToast(L10n.f("规则「%@」已创建", req.name))
            await loadRules()
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
    func updateRule(req: ClamUpsertRequest) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.clamUpdate.path, body: req, as: EmptyResponse.self)
            showToast(L10n.f("规则「%@」已更新", req.name))
            await loadRules()
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("更新失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("更新失败：%@", error.localizedDescription))
            return false
        }
    }

    func delete(rule: ClamItem) async {
        pendingDeleteRule = nil
        // 就地取走勾选值并复位（失败重试/下次删除从「未勾选」开始）
        let removeFiles = deleteInfectedFiles
        deleteInfectedFiles = false
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.clamDelete.path,
                body: ClamDeleteRequest(ids: [rule.id], isDeleteFile: removeFiles ? true : nil),
                as: EmptyResponse.self)
            showToast(L10n.f("规则「%@」已删除", rule.name))
            await loadRules()
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

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { self?.toastMessage = nil }
        }
    }
}

// MARK: - 主视图

struct ClamView: View {
    @StateObject private var vm: ClamViewModel

    private let server: ServerConfig

    @State private var isClamExpanded = false
    @State private var isFreshExpanded = false
    /// 病毒库服务（FreshClam）卡显隐
    @State private var showFreshClam = true
    @State private var pendingAction: String?
    @State private var showCreate = false
    @State private var showMenu = false
    /// 长按弹出的操作菜单目标（执行 / 报告 / 编辑 / 删除）
    @State private var actionRule: ClamItem?
    /// 行「编辑」推入的表单目标
    @State private var editingRule: ClamItem?
    /// 行「报告」推入的报告页目标
    @State private var recordRule: ClamItem?
    @State private var showSettings = false

    init(server: ServerConfig) {
        self.server = server
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(key: ManageItem.clam.storeKey(server: server)) {
            ClamViewModel(server: server)
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
        .navigationTitle(L10n.t("病毒扫描"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 未安装时不显示设置/添加入口
            if vm.isInstalled {
                ToolbarItem(placement: .topBarTrailing) {
                    EllipsisMenuButton {
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
                    .accessibilityLabel(L10n.t("添加规则"))
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if showMenu {
                EllipsisMenuPopup(entries: [
                    .action(title: L10n.t("ClamAV 设置"), icon: "gearshape") {
                        showSettings = true
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
            pendingAction.map { clamActionDisplayName($0) } ?? "",
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
                Text(L10n.f(
                    "将对 %@ 进行 %@ 操作，是否继续？",
                    isFreshAction(action) ? L10n.t("病毒库服务") : "ClamAV",
                    clamActionDisplayName(action)))
            }
        }
        .navigationDestination(isPresented: $showCreate) {
            ClamRuleFormView(server: server, editing: nil, vm: vm)
        }
        .navigationDestination(isPresented: $showSettings) {
            ClamSettingsView(server: server)
        }
        .navigationDestination(isPresented: Binding(
            get: { editingRule != nil },
            set: { if !$0 { editingRule = nil } }
        )) {
            if let rule = editingRule {
                ClamRuleFormView(server: server, editing: rule, vm: vm)
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { recordRule != nil },
            set: { if !$0 { recordRule = nil } }
        )) {
            if let rule = recordRule {
                ClamRecordView(server: server, clamID: rule.id, ruleName: rule.name)
            }
        }
    }

    private func isFreshAction(_ action: String) -> Bool {
        action.hasPrefix("fresh-")
    }

    private func clamActionDisplayName(_ action: String) -> String {
        switch action {
        case "stop", "fresh-stop":          return L10n.t("停止")
        case "start", "fresh-start":        return L10n.t("启动")
        case "restart", "fresh-restart":    return L10n.t("重启")
        default:                            return action
        }
    }

    // MARK: - 未安装

    /// 未安装：与 FTP 未安装页同款样式，安装入口跳脚本库
    private var notInstalledView: some View {
        VStack(spacing: 20) {
            Spacer()

            IconBadge(systemName: "cross.case.fill", color: .green, size: 72, cornerRadius: 16)
                .opacity(0.5)

            VStack(spacing: 8) {
                Text(L10n.f("%@未安装", "ClamAV"))
                    .font(.headline)
                Text(L10n.f("请先安装 %@ 后再使用此功能", "ClamAV"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            minimumRequirementsCard

            NavigationLink {
                ScriptLibraryView(server: server)
            } label: {
                Label(L10n.f("安装 %@", "ClamAV"), systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)

            Spacer()
        }
        .padding()
    }

    // MARK: - 最低配置要求

    /// ClamAV 资源占用较高，安装前展示官方最低配置要求
    private var minimumRequirementsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.t("最低配置要求"))
                .font(.subheadline.bold())
                .padding(.bottom, 8)

            Divider()

            requirementRow(L10n.t("CPU 要求"), L10n.t("1 CPU，2.0 Ghz+"))
            Divider()
            requirementRow(L10n.t("内存要求"), L10n.t("3 GiB+"))
            Divider()
            requirementRow(L10n.t("服务器架构"), L10n.t("至少 5GiB 可用磁盘空间"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 24)
    }

    private func requirementRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.footnote.monospacedDigit())
        }
        .padding(.vertical, 7)
    }

    // MARK: - 已安装

    @ViewBuilder
    private func content(base: ClamBase) -> some View {
        List {
            clamSection(base: base)
            if showFreshClam && (base.freshIsExist ?? false) {
                freshSection(base: base)
            }
            ruleSection
        }
        .listStyle(.insetGrouped)
        .sheet(item: $actionRule) { rule in
            ActionBottomSheet(
                title: rule.name,
                items: [
                    ActionMenuItem(title: L10n.t("立即扫描"), icon: "play.fill", color: .green) {
                        Task { await vm.handle(rule: rule) }
                    },
                    ActionMenuItem(title: L10n.t("报告"), icon: "doc.text.magnifyingglass") {
                        recordRule = rule
                    },
                    ActionMenuItem(title: L10n.t("编辑"), icon: "pencil") {
                        editingRule = rule
                    },
                    ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red, role: .destructive) {
                        vm.deleteInfectedFiles = false
                        vm.pendingDeleteRule = rule
                    },
                ],
                onDismiss: { actionRule = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: 4))])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $vm.pendingDeleteRule) { rule in
            TextInputConfirmSheet(
                title: L10n.t("删除规则"),
                message: L10n.f("删除任务检测到的病毒文件，以确保服务器的安全和正常运行。此操作不可恢复，请输入规则名称「%@」以确认删除。", rule.name),
                expectedText: rule.name,
                fieldLabel: L10n.t("确认名称"),
                fieldPlaceholder: L10n.t("规则名称")
            ) {
                Task { await vm.delete(rule: rule) }
            } options: {
                Section(L10n.t("选项")) {
                    Toggle(L10n.t("删除病毒文件"), isOn: $vm.deleteInfectedFiles)
                }
            }
        }
    }

    private func clamSection(base: ClamBase) -> some View {
        ServiceStatusCard(
            title: "ClamAV",
            subtitle: base.version.flatMap { $0.isEmpty || $0 == "-" ? nil : "v\($0)" },
            statusText: base.isActive ? L10n.t("运行中") : L10n.t("已停止"),
            statusColor: base.isActive ? .statusRunning : .statusStopped,
            isOperating: vm.isOperating,
            isExpanded: $isClamExpanded,
            actions: [
                ServiceAction(
                    title: base.isActive ? L10n.t("停止") : L10n.t("启动"),
                    icon: base.isActive ? "stop.fill" : "play.fill",
                    color: base.isActive ? .orange : .green
                ) { pendingAction = base.isActive ? "stop" : "start" },
                ServiceAction(title: L10n.t("重启"), icon: "arrow.triangle.2.circlepath", color: .blue) {
                    pendingAction = "restart"
                },
                ServiceAction(
                    title: L10n.t("病毒库服务"),
                    icon: showFreshClam ? "eye.slash" : "eye",
                    color: .indigo
                ) {
                    withAnimation(Motion.fast) { showFreshClam.toggle() }
                },
            ]
        ) {
            IconBadge(systemName: "cross.case.fill", color: .green, size: 44)
        }
    }

    private func freshSection(base: ClamBase) -> some View {
        ServiceStatusCard(
            title: L10n.t("病毒库服务"),
            subtitle: base.freshVersion.flatMap { $0.isEmpty || $0 == "-" ? nil : "v\($0)" },
            statusText: (base.freshIsActive ?? false) ? L10n.t("运行中") : L10n.t("已停止"),
            statusColor: (base.freshIsActive ?? false) ? .statusRunning : .statusStopped,
            isOperating: vm.isOperating,
            isExpanded: $isFreshExpanded,
            actions: [
                ServiceAction(
                    title: (base.freshIsActive ?? false) ? L10n.t("停止") : L10n.t("启动"),
                    icon: (base.freshIsActive ?? false) ? "stop.fill" : "play.fill",
                    color: (base.freshIsActive ?? false) ? .orange : .green
                ) { pendingAction = (base.freshIsActive ?? false) ? "fresh-stop" : "fresh-start" },
                ServiceAction(title: L10n.t("重启"), icon: "arrow.triangle.2.circlepath", color: .blue) {
                    pendingAction = "fresh-restart"
                },
            ]
        ) {
            IconBadge(systemName: "arrow.trianglehead.2.clockwise.rotate.90", color: .indigo, size: 44)
        }
    }

    @ViewBuilder
    private var ruleSection: some View {
        Section {
            if vm.rules.isEmpty {
                if vm.isLoadingRules || vm.isLoading {
                    HStack {
                        Spacer()
                        LoadingStateView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ContentUnavailableView(
                        L10n.t("暂无规则"),
                        systemImage: "magnifyingglass",
                        description: Text(L10n.t("点击右上角 + 添加规则"))
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(vm.rules) { rule in
                    Button {
                        editingRule = rule
                    } label: {
                        ClamRuleRow(rule: rule)
                    }
                    .buttonStyle(.plain)
                    // 行级操作收进长按菜单（执行 / 报告 / 编辑 / 删除）；
                    // 用 simultaneousGesture 与点击进入共存
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                            Haptic.selection()
                            actionRule = rule
                        }
                    )
                    .onAppear {
                        if rule.id == vm.rules.last?.id {
                            Task { await vm.loadMoreRules() }
                        }
                    }
                }

                if vm.rules.count < vm.total || vm.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .onAppear { Task { await vm.loadMoreRules() } }
                }
            }
        } header: {
            SectionLabel(title: L10n.t("扫描规则"), systemImage: "doc.text.magnifyingglass")
        }
    }
}

// MARK: - 规则行

struct ClamRuleRow: View {
    let rule: ClamItem

    private var isScheduled: Bool {
        guard let spec = rule.spec, !spec.isEmpty else { return false }
        return true
    }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "magnifyingglass", color: .green)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(rule.name)
                        .font(.body.bold())
                        .lineLimit(1)
                    if rule.status == "Disable" {
                        StatusBadge(text: L10n.t("已停用"), color: .secondary)
                    }
                }
                Text(rule.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if isScheduled, let spec = rule.spec {
                        StatusBadge(text: spec, color: .blue, monospaced: true)
                    } else {
                        Text(L10n.t("手动执行"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let time = rule.lastRecordTime, !time.isEmpty, time != "-" {
                        Text(time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
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
