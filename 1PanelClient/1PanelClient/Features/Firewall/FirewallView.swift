//
//  FirewallView.swift
//  1PanelClient
//
//  防火墙 v2.3.0（上游 2026-09 整体重构后的 API，docs/v2.3.0-upstream-diff.md）：
//  状态卡（系统子系统生命周期 + 基础链初始化/绑定）+ 四段内容——
//  规则（统一规则清单）/ 转发（forward 子域）/ Docker 端口守护 / 设置（三组后端）。
//  旧 v2.2.5 端口/IP/链规则三段模型已被上游「rules 统一命名空间 + states 五态」取代。
//

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class FirewallViewModel: ObservableObject {
    // MARK: 状态卡
    @Published var systemStatus: FirewallSubsystemStatus?
    @Published var forwardStatus: FirewallSubsystemStatus?
    /// L2 版本门禁：新端点 404 → 旧面板（< v2.3.0）
    @Published var unsupportedPanel = false

    // MARK: 规则段
    @Published var inventory: [FirewallInventoryItem] = []
    @Published private(set) var rulesAllTotal = 0
    @Published private(set) var rulesManagedTotal = 0
    @Published private(set) var isRulesLoadingMore = false
    @Published var ruleStateFilter: String?      // nil = 全部状态
    @Published var ruleFamilyFilter: String?     // nil = 全部族
    @Published var ruleSearchText = ""
    private var rulesPage = 1
    private var rulesGeneration = 0
    private static let rulesPageSize = 100

    // MARK: 转发段
    @Published var forwards: [FirewallForwardRule] = []
    @Published private(set) var forwardsTotal = 0
    @Published private(set) var isForwardsLoadingMore = false
    private var forwardsPage = 1
    private var forwardsGeneration = 0
    private static let forwardsPageSize = 100

    // MARK: Docker 守护段
    @Published var dockerGuard: DockerGuardList?

    // MARK: 设置段
    @Published var settings: FirewallSettings?

    // MARK: 通用
    @Published var isLoading = false
    @Published var isOperating = false
    @Published var errorMessage: String?
    @Published var toastMessage: String?
    /// 任务式操作的进度页目标（init-base / forward enable / 白名单 / Docker 初始化）
    @Published var activeTask: FirewallTaskTarget?
    /// 端口号 → 监听进程名（规则行补全；process/listening 端点 v2.3.0 未变）
    @Published var portProcessNames: [String: String] = [:]
    /// 网卡列表（转发表单网口选择）
    @Published var netOptions: [String] = []

    private let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient.shared(for: server)
    }

    // MARK: - 加载

    func refresh() async {
        guard !isLoading
            || (systemStatus == nil && inventory.isEmpty && forwards.isEmpty && dockerGuard == nil)
        else { return }
        isLoading = true
        defer { isLoading = false }
        await loadSystemStatus()
        guard !unsupportedPanel else { return }
        async let rules: () = loadRules(replacing: true)
        async let forward: () = loadForwardStatus()
        async let forwards: () = loadForwards(replacing: true)
        async let docker: () = loadDockerGuard()
        async let settings: () = loadSettings()
        _ = await (rules, forward, forwards, docker, settings)
        // 辅助数据静默补齐（失败无感）
        async let listening: () = loadListening()
        async let nets: () = loadNetOptions()
        _ = await (listening, nets)
    }

    func loadSystemStatus() async {
        struct BaseReq: Encodable { let name: String }
        do {
            systemStatus = try await client.send(
                path: APIEndpoint.firewallBase.path,
                body: BaseReq(name: "base"),
                as: FirewallSubsystemStatus.self
            )
            errorMessage = nil
            unsupportedPanel = false
        } catch {
            guard !APIError.isCancellation(error) else { return }
            if let apiErr = error as? APIError, apiErr.isEndpointMissing {
                // L2 门禁：旧面板没有 v2.3.0 的防火墙 API（含 /rules 命名空间）
                unsupportedPanel = true
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    func loadForwardStatus() async {
        guard !unsupportedPanel else { return }
        do {
            forwardStatus = try await client.send(
                path: APIEndpoint.firewallForwardBase.path,
                body: EmptyRequest(),
                as: FirewallSubsystemStatus.self
            )
        } catch {
            guard !APIError.isCancellation(error) else { return }
            // 转发子系统状态失败不阻塞页面（部分后端无转发概念）
        }
    }

    // MARK: 规则段

    func loadRules(replacing: Bool) async {
        if replacing {
            rulesGeneration += 1
            rulesPage = 1
        } else {
            guard !isRulesLoadingMore, inventory.count < rulesAllTotal else { return }
            isRulesLoadingMore = true
        }
        let generation = rulesGeneration
        var req = FirewallRuleSearchRequest(page: replacing ? 1 : rulesPage + 1,
                                            pageSize: Self.rulesPageSize)
        req.scopes = Self.scopeForSearch(backend: systemStatus?.backend)
        req.excludeChains = Self.excludeChainsForSearch(backend: systemStatus?.backend)
        req.info = ruleSearchText
        req.states = ruleStateFilter.map { [$0] }
        req.families = ruleFamilyFilter.map { [$0] }
        do {
            let resp: FirewallRuleInventoryResponse = try await client.send(
                path: APIEndpoint.firewallRulesSearch.path, body: req,
                as: FirewallRuleInventoryResponse.self
            )
            guard generation == rulesGeneration else { return }
            if replacing {
                inventory = resp.items ?? []
            } else {
                inventory += resp.items ?? []
            }
            rulesPage = req.page
            rulesAllTotal = resp.allTotal ?? resp.total ?? inventory.count
            rulesManagedTotal = resp.managedTotal ?? 0
            errorMessage = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            guard generation == rulesGeneration else { return }
            errorMessage = error.localizedDescription
        }
        if !replacing { isRulesLoadingMore = false }
    }

    /// 建规则（v2.3.0 统一模型：端口/IP 规则都是 FirewallRule）
    func createRule(_ rule: FirewallRule) async -> Bool {
        await submitRules(FirewallRuleCreateRequest(
            items: [FirewallRuleCreateItem(rule: rule, sourceKind: "user", sourceID: nil)]))
    }

    func updateRule(uuid: String, rule: FirewallRule) async -> Bool {
        isOperating = true
        defer { isOperating = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.firewallRulesUpdate.path,
                body: FirewallRuleUpdateRequest(uuid: uuid, rule: rule, descriptionText: nil,
                                                orderIndex: rule.orderIndex),
                as: EmptyResponse.self
            )
            await loadRules(replacing: true)
            return true
        } catch {
            guard !APIError.isCancellation(error) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func submitRules(_ request: FirewallRuleCreateRequest) async -> Bool {
        isOperating = true
        defer { isOperating = false }
        do {
            let resp: FirewallRuleCreateResponse = try await client.send(
                path: APIEndpoint.firewallRulesCreate.path, body: request,
                as: FirewallRuleCreateResponse.self
            )
            if let taskID = resp.taskID, !taskID.isEmpty {
                activeTask = FirewallTaskTarget(taskID: taskID, title: L10n.t("创建规则"))
            } else if (resp.failed ?? 0) > 0, let first = resp.errors?.first {
                errorMessage = first.error ?? L10n.t("部分规则创建失败")
            } else {
                toastMessage = L10n.t("规则已提交")
            }
            await loadRules(replacing: true)
            return true
        } catch {
            guard !APIError.isCancellation(error) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteRule(_ item: FirewallInventoryItem) async {
        guard let uuid = item.manageableUUID else { return }
        isOperating = true
        defer { isOperating = false }
        do {
            let _: FirewallRuleDeleteResponse = try await client.send(
                path: APIEndpoint.firewallRulesDelete.path,
                body: FirewallRuleDeleteRequest(uuids: [uuid]),
                as: FirewallRuleDeleteResponse.self
            )
            await loadRules(replacing: true)
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    // MARK: 转发段

    func loadForwards(replacing: Bool) async {
        if replacing {
            forwardsGeneration += 1
            forwardsPage = 1
        } else {
            guard !isForwardsLoadingMore, forwards.count < forwardsTotal else { return }
            isForwardsLoadingMore = true
        }
        let generation = forwardsGeneration
        var req = FirewallForwardSearchRequest(
            page: replacing ? 1 : forwardsPage + 1,
            pageSize: Self.forwardsPageSize
        )
        req.info = ""
        do {
            let resp: PageEnvelope<FirewallForwardRule> = try await client.send(
                path: APIEndpoint.firewallForwardSearch.path, body: req,
                as: PageEnvelope<FirewallForwardRule>.self
            )
            guard generation == forwardsGeneration else { return }
            if replacing {
                forwards = resp.items ?? []
            } else {
                forwards += resp.items ?? []
            }
            forwardsPage = req.page
            forwardsTotal = resp.total
        } catch {
            guard !APIError.isCancellation(error), generation == forwardsGeneration else { return }
        }
        if !replacing { isForwardsLoadingMore = false }
    }

    /// 编辑 = 同请求内先 remove 后 add（上游 forward/operate 仅支持 add/remove）。
    /// 响应为任务式 {taskID, queued}（抓包 2026-09-17），进进度页
    func submitForward(_ operations: [FirewallForwardOperation], forceDelete: Bool = false) async -> Bool {
        isOperating = true
        defer { isOperating = false }
        do {
            let resp: FirewallTaskResponse = try await client.send(
                path: APIEndpoint.firewallForwardOperate.path,
                body: FirewallForwardOperateRequest(forceDelete: forceDelete, rules: operations),
                as: FirewallTaskResponse.self
            )
            if let taskID = resp.taskID, !taskID.isEmpty {
                activeTask = FirewallTaskTarget(taskID: taskID, title: L10n.t("更新转发规则"))
            }
            await loadForwards(replacing: true)
            await loadForwardStatus()
            return true
        } catch {
            guard !APIError.isCancellation(error) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// 启用转发子系统（forward/enable，任务式）
    func enableForwarding() async {
        isOperating = true
        defer { isOperating = false }
        do {
            let resp: FirewallTaskResponse = try await client.send(
                path: APIEndpoint.firewallForwardEnable.path,
                body: EmptyRequest(),
                as: FirewallTaskResponse.self
            )
            if let taskID = resp.taskID, !taskID.isEmpty {
                activeTask = FirewallTaskTarget(taskID: taskID, title: L10n.t("启用端口转发"))
            }
            await loadForwardStatus()
            await loadForwards(replacing: true)
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    // MARK: 生命周期 / 基础链

    /// start / stop / restart / disableBanPing / enableBanPing
    func operateFirewall(_ operation: String) async {
        isOperating = true
        defer { isOperating = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.firewallOperate.path,
                body: FirewallOperateRequest(operation: operation, withDockerRestart: false),
                as: EmptyResponse.self
            )
            toastMessage = L10n.t("操作已提交")
            await loadSystemStatus()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// 基础链：init-base / bind-base / unbind-base（iptables/nftables）
    func operateFilterChain(_ operate: String) async {
        isOperating = true
        defer { isOperating = false }
        do {
            let resp: FirewallTaskResponse = try await client.send(
                path: APIEndpoint.firewallFilterOperate.path,
                body: FirewallFilterOperateRequest(name: "1PANEL_BASIC", operate: operate, taskID: nil),
                as: FirewallTaskResponse.self
            )
            if let taskID = resp.taskID, !taskID.isEmpty {
                activeTask = FirewallTaskTarget(taskID: taskID, title: L10n.t("防火墙初始化"))
            }
            await loadSystemStatus()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Docker 守护

    func loadDockerGuard() async {
        guard !unsupportedPanel else { return }
        do {
            dockerGuard = try await client.send(
                path: APIEndpoint.firewallDockerPorts.path, method: "GET",
                as: DockerGuardList.self
            )
        } catch {
            guard !APIError.isCancellation(error) else { return }
            // Docker 未安装/守护不可用时该段显示空态，不阻塞页面
        }
    }

    func dockerOperate(_ operation: String) async {
        isOperating = true
        defer { isOperating = false }
        do {
            // 抓包 2026-09-17：initialize 返回 {taskID,queued}，bind/unbind 返回 null
            if operation == "initialize" {
                let resp: FirewallTaskResponse = try await client.send(
                    path: APIEndpoint.firewallDockerOperate.path,
                    body: DockerGuardOperateRequest(operation: operation, taskID: nil),
                    as: FirewallTaskResponse.self
                )
                if let taskID = resp.taskID, !taskID.isEmpty {
                    activeTask = FirewallTaskTarget(taskID: taskID, title: L10n.t("Docker 端口守护"))
                }
            } else {
                let _: EmptyResponse = try await client.send(
                    path: APIEndpoint.firewallDockerOperate.path,
                    body: DockerGuardOperateRequest(operation: operation, taskID: nil),
                    as: EmptyResponse.self
                )
                toastMessage = L10n.t("操作已提交")
            }
            await loadDockerGuard()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func dockerSync() async {
        isOperating = true
        defer { isOperating = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.firewallDockerSync.path,
                body: EmptyRequest(),
                as: EmptyResponse.self
            )
            toastMessage = L10n.t("同步已提交")
            await loadDockerGuard()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func deleteDockerPolicy(_ endpoint: DockerGuardEndpoint) async {
        guard let uuid = endpoint.policyUUID, !uuid.isEmpty else { return }
        isOperating = true
        defer { isOperating = false }
        do {
            let _: FirewallTaskResponse = try await client.send(
                path: APIEndpoint.firewallDockerPolicyDelete.path,
                body: DockerGuardPolicyDeleteRequest(uuids: [uuid]),
                as: FirewallTaskResponse.self
            )
            await loadDockerGuard()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    // MARK: 设置段

    func loadSettings() async {
        guard !unsupportedPanel else { return }
        do {
            settings = try await client.send(
                path: APIEndpoint.firewallSettings.path, method: "GET",
                as: FirewallSettings.self
            )
        } catch {
            guard !APIError.isCancellation(error) else { return }
        }
    }

    /// subsystem = system/forwarding/docker；operation = select/initialize/cleanup
    func operateBackend(subsystem: String, backend: String, operation: String) async {
        isOperating = true
        defer { isOperating = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.firewallSettingsOperate.path,
                body: FirewallBackendOperationRequest(subsystem: subsystem, backend: backend, operation: operation),
                as: EmptyResponse.self
            )
            toastMessage = L10n.t("操作已提交")
            // 后端切换影响全部子系统状态，整页重拉
            await loadSystemStatus()
            await loadForwardStatus()
            await loadSettings()
            await loadRules(replacing: true)
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// 面板端口白名单（任务式）
    func updatePortWhitelist(_ value: String) async -> Bool {
        isOperating = true
        defer { isOperating = false }
        do {
            let resp: FirewallTaskResponse = try await client.send(
                path: APIEndpoint.firewallSettingsWhitelist.path,
                body: FirewallPortWhitelistRequest(value: value),
                as: FirewallTaskResponse.self
            )
            await loadSettings()
            if let taskID = resp.taskID, !taskID.isEmpty {
                activeTask = FirewallTaskTarget(taskID: taskID, title: L10n.t("更新端口白名单"))
            } else {
                toastMessage = L10n.t("白名单已提交")
            }
            return true
        } catch {
            guard !APIError.isCancellation(error) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: 辅助

    private func loadListening() async {
        struct ListeningReq: Encodable { let info: String; let page: Int; let pageSize: Int }
        struct ListeningResp: Decodable { let items: [ListeningItem]? }
        struct ListeningItem: Decodable {
            let port: String?
            let processNames: String?
        }
        do {
            let resp: ListeningResp = try await client.send(
                path: APIEndpoint.processListening.path,
                body: ListeningReq(info: "", page: 1, pageSize: 200),
                as: ListeningResp.self
            )
            var map: [String: String] = [:]
            for item in resp.items ?? [] {
                guard let port = item.port, !port.isEmpty else { continue }
                map[port] = item.processNames
            }
            portProcessNames = map
        } catch { /* 静默：行内进程名缺失不影响功能 */ }
    }

    private func loadNetOptions() async {
        do {
            let resp: [String] = try await client.send(
                path: APIEndpoint.monitorNetOptions.path, method: "GET",
                as: [String].self
            )
            netOptions = resp
        } catch { /* 静默 */ }
    }

    /// 规则清单搜索的管理作用域（抓包 2026-09-17：iptables/nftables 六链；ufw 单链 inet/incoming；
    /// firewalld inet/public——后者按上游 ManagedInputScopes 源码，抓包未覆盖）
    nonisolated static func scopeForSearch(backend: String?) -> [FirewallScope]? {
        switch backend {
        case "iptables", "nftables":
            var result: [FirewallScope] = []
            for family in ["ipv4", "ipv6"] {
                for chain in ["1PANEL_BASIC_BEFORE", "1PANEL_BASIC", "1PANEL_BASIC_AFTER"] {
                    result.append(FirewallScope(provider: backend, family: family,
                                                 table: "filter", chain: chain, direction: "input"))
                }
            }
            return result
        case "ufw":
            return [FirewallScope(provider: "ufw", family: "inet", chain: "incoming", direction: "input")]
        case "firewalld":
            return [FirewallScope(provider: "firewalld", family: "inet", zone: "public", direction: "input")]
        default:
            return nil
        }
    }

    /// iptables/nftables 排除守护定位链（只展示 1PANEL_BASIC 主链规则）
    nonisolated static func excludeChainsForSearch(backend: String?) -> [String]? {
        switch backend {
        case "iptables", "nftables":
            return ["1PANEL_BASIC_BEFORE", "1PANEL_BASIC_AFTER"]
        default:
            return []
        }
    }

    /// 规则表单的 scope 构造（对齐 Web 端 buildRule：按后端补 table/zone/chain）
    static func scopeForCreate(backend: String?, family: String) -> FirewallScope {
        switch backend {
        case "iptables", "nftables":
            return FirewallScope(provider: backend, family: family, table: "filter",
                                 chain: "1PANEL_BASIC", direction: "input")
        case "firewalld":
            return FirewallScope(provider: backend, family: "inet", zone: "public", direction: "input")
        default: // ufw
            return FirewallScope(provider: backend ?? "ufw", family: family, chain: "incoming", direction: "input")
        }
    }
}

/// 任务进度页目标
struct FirewallTaskTarget: Identifiable, Hashable {
    let taskID: String
    let title: String
    var id: String { taskID }
}

// MARK: - 主视图

struct FirewallView: View {
    @StateObject private var vm: FirewallViewModel
    let server: ServerConfig

    @State private var statusExpanded = false
    /// 内容段：0=规则 1=转发 2=Docker 守护 3=设置
    @State private var segment = 0
    // 规则段交互
    @State private var showAddRule = false
    @State private var editingRule: FirewallRule?
    @State private var editingRuleUUID: String?
    @State private var pendingDeleteItem: FirewallInventoryItem?
    @State private var pendingLifeOp: String?
    // 转发段交互
    @State private var showAddForward = false
    @State private var editingForward: FirewallForwardRule?
    @State private var pendingDeleteForward: FirewallForwardRule?
    @State private var pendingDeleteForwardForce = false
    // WAF 入口（与防火墙同属主机安全防护，管理列表不单列）
    @State private var showWAF = false

    init(server: ServerConfig) {
        self.server = server
        _vm = StateObject(wrappedValue: FirewallViewModel(server: server))
    }

    var body: some View {
        List {
            if vm.unsupportedPanel {
                unsupportedSection
            } else {
                statusSection
                Picker("", selection: $segment) {
                    Text(L10n.t("规则")).tag(0)
                    Text(L10n.t("转发")).tag(1)
                    Text("Docker").tag(2)
                    Text(L10n.t("设置")).tag(3)
                }
                .pickerStyle(.segmented)
                .segmentedPickerRow()
                .listRowBackground(Color.clear)

                switch segment {
                case 0: rulesSection
                case 1: forwardSection
                case 2: dockerSection
                default: settingsSection
                }
            }
        }
        .navigationTitle(L10n.t("防火墙"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !vm.unsupportedPanel {
                    Menu {
                        if segment == 0 {
                            Button { showAddRule = true } label: {
                                Label(L10n.t("创建规则"), systemImage: "plus")
                            }
                        } else if segment == 1 {
                            Button { showAddForward = true } label: {
                                Label(L10n.t("创建转发"), systemImage: "plus")
                            }
                        }
                        Button { showWAF = true } label: {
                            Label("WAF", systemImage: "shield.lefthalf.filled")
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .accessibilityLabel(L10n.t("添加"))
                }
            }
        }
        .refreshable { await vm.refresh() }
        .overlay {
            if vm.isLoading && vm.systemStatus == nil && !vm.unsupportedPanel {
                LoadingStateView()
            } else if let err = vm.errorMessage, vm.systemStatus == nil, !vm.unsupportedPanel {
                // 整页加载失败：统一 LoadErrorStateView（ErrorBanner 仅限首页概览降级场景）
                LoadErrorStateView(message: err) {
                    Task { await vm.refresh() }
                }
            }
        }
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { vm.errorMessage != nil && vm.systemStatus != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .task { await vm.refresh() }
        // 规则：创建 / 编辑
        .navigationDestination(isPresented: $showAddRule) {
            FirewallRuleFormView(vm: vm, editing: nil, editingUUID: nil)
        }
        .navigationDestination(isPresented: Binding(
            get: { editingRule != nil },
            set: { if !$0 { editingRule = nil; editingRuleUUID = nil } }
        )) {
            if let rule = editingRule {
                FirewallRuleFormView(vm: vm, editing: rule, editingUUID: editingRuleUUID)
            }
        }
        .alert(L10n.t("删除规则"), isPresented: Binding(
            get: { pendingDeleteItem != nil },
            set: { if !$0 { pendingDeleteItem = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingDeleteItem = nil }
            Button(L10n.t("删除"), role: .destructive) {
                Haptic.warning()
                if let item = pendingDeleteItem {
                    pendingDeleteItem = nil
                    Task { await vm.deleteRule(item) }
                }
            }
        } message: {
            if let item = pendingDeleteItem {
                Text(L10n.f("确定删除规则「%@」吗？删除后不可恢复。", item.rule?.destinationPort ?? item.rule?.sourceAddress ?? ""))
            }
        }
        // 转发：创建 / 编辑 / 删除
        .navigationDestination(isPresented: $showAddForward) {
            FirewallForwardFormView(vm: vm, editing: nil)
        }
        .navigationDestination(isPresented: Binding(
            get: { editingForward != nil },
            set: { if !$0 { editingForward = nil } }
        )) {
            if let rule = editingForward {
                FirewallForwardFormView(vm: vm, editing: rule)
            }
        }
        .alert(L10n.t("删除端口转发"), isPresented: Binding(
            get: { pendingDeleteForward != nil && !pendingDeleteForwardForce },
            set: { if !$0 { pendingDeleteForward = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingDeleteForward = nil }
            Button(L10n.t("删除"), role: .destructive) {
                Haptic.warning()
                deleteForward(force: false)
            }
            Button(L10n.t("强制删除"), role: .destructive) {
                Haptic.warning()
                deleteForward(force: true)
            }
        } message: {
            if let rule = pendingDeleteForward {
                Text(L10n.f("确定删除端口转发「%@」吗？若端口被占用可选择强制删除。", rule.port ?? ""))
            }
        }
        // 生命周期确认（start/stop/restart 大操作保留确认；ping 开关直接执行）
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { pendingLifeOp != nil },
            set: { if !$0 { pendingLifeOp = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingLifeOp = nil }
            Button(L10n.t("确认"), role: .destructive) {
                guard let op = pendingLifeOp else { return }
                pendingLifeOp = nil
                Task { await vm.operateFirewall(op) }
            }
        } message: {
            Text(L10n.f("将对防火墙执行「%@」，操作期间服务可能短暂中断，是否继续？",
                        pendingLifeOp.flatMap(Self.lifeOpName) ?? ""))
        }
        // WAF 与防火墙同属主机安全防护，入口收进本页右上角（管理列表不单列）
        .navigationDestination(isPresented: $showWAF) {
            WAFView(server: server)
        }
        // 任务式操作进度页（初始化/启用转发/白名单/Docker 操作）
        .navigationDestination(item: $vm.activeTask) { target in
            TaskProgressView(taskID: target.taskID, title: target.title) { _ in false }
        }
    }

    private func deleteForward(force: Bool) {
        guard let rule = pendingDeleteForward else { return }
        pendingDeleteForward = nil
        Task {
            _ = await vm.submitForward([.remove(rule)], forceDelete: force)
        }
    }

    private static func lifeOpName(_ op: String) -> String {
        switch op {
        case "start": return L10n.t("启动")
        case "stop": return L10n.t("停止")
        case "restart": return L10n.t("重启")
        default: return op
        }
    }

    // MARK: 旧面板门禁（L2）

    private var unsupportedSection: some View {
        Section {
            ContentUnavailableView {
                Label(L10n.t("面板版本过低"), systemImage: "exclamationmark.arrow.triangle.2.circlepath")
            } description: {
                Text(L10n.t("防火墙新管理界面需要 1Panel v2.3.0 及以上版本。请升级面板后使用；旧版端口/转发管理已随 v2.3.0 重构下线。"))
            }
        }
    }

    // MARK: 状态卡

    private var statusSection: some View {
        Section {
            Button {
                withAnimation(Motion.standard) { statusExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    IconBadge(systemName: "flame.fill",
                              color: (vm.systemStatus?.isActive == true) ? .orange : .gray)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(vm.systemStatus?.backend?.uppercased() ?? "—")
                                .font(.subheadline.bold())
                            if let v = vm.systemStatus?.version, !v.isEmpty {
                                Text("v\(v)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(vm.systemStatus?.isActive == true ? L10n.t("运行中") : L10n.t("已停止"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let conflict = vm.systemStatus?.conflictBackend, !conflict.isEmpty {
                        StatusBadge(text: L10n.t("后端冲突"), color: .semanticWarning)
                    }
                    Image(systemName: statusExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if statusExpanded {
                if let conflict = vm.systemStatus?.conflictBackend, !conflict.isEmpty {
                    Label(L10n.f("检测到冲突后端 %@，可能互相干扰规则，建议在设置段清理未用后端。", conflict),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.semanticWarning)
                }
                badgesRow
                operationsRow
                    .padding(.top, 4)
            }
        }
    }

    private var badgesRow: some View {
        HStack(spacing: 6) {
            if vm.systemStatus?.isInit == true {
                StatusBadge(text: L10n.t("已初始化"), color: .statusRunning)
            } else if vm.systemStatus?.backend == "iptables" || vm.systemStatus?.backend == "nftables" {
                StatusBadge(text: L10n.t("未初始化"), color: .semanticWarning)
            }
            if vm.systemStatus?.isBind == true {
                StatusBadge(text: L10n.t("已绑定"), color: .blue)
            }
            familyBadge("IPv4", vm.systemStatus?.ipv4)
            familyBadge("IPv6", vm.systemStatus?.ipv6)
        }
    }

    private func familyBadge(_ title: String, _ family: FirewallBackendFamilyStatus?) -> some View {
        Group {
            if let family {
                StatusBadge(
                    text: title,
                    color: (family.available == true) ? .statusRunning : .secondary
                )
            }
        }
    }

    private var operationsRow: some View {
        HStack(spacing: 8) {
            CardActionButton(
                title: vm.systemStatus?.isActive == true ? L10n.t("停止") : L10n.t("启动"),
                icon: vm.systemStatus?.isActive == true ? "stop.fill" : "play.fill",
                color: .blue,
                busy: vm.isOperating
            ) {
                pendingLifeOp = (vm.systemStatus?.isActive == true) ? "stop" : "start"
            }
            CardActionButton(title: L10n.t("重启"), icon: "arrow.triangle.2.circlepath",
                             color: .orange, busy: vm.isOperating) {
                pendingLifeOp = "restart"
            }
            CardActionButton(
                title: vm.systemStatus?.pingBlocked == true ? L10n.t("允许 Ping") : L10n.t("禁 Ping"),
                icon: "waveform.path.ecg",
                color: .purple,
                busy: vm.isOperating
            ) {
                Task {
                    await vm.operateFirewall(vm.systemStatus?.pingBlocked == true ? "enableBanPing" : "disableBanPing")
                }
            }
            // iptables/nftables：基础链初始化 / 绑定 / 解绑
            if vm.systemStatus?.backend == "iptables" || vm.systemStatus?.backend == "nftables" {
                if vm.systemStatus?.isInit != true {
                    CardActionButton(title: L10n.t("初始化"), icon: "wand.and.stars",
                                     color: .green, busy: vm.isOperating) {
                        Task { await vm.operateFilterChain("init-base") }
                    }
                } else if vm.systemStatus?.isBind == true {
                    CardActionButton(title: L10n.t("解绑"), icon: "link.badge.plus",
                                     color: .secondary, busy: vm.isOperating) {
                        Task { await vm.operateFilterChain("unbind-base") }
                    }
                } else {
                    CardActionButton(title: L10n.t("绑定"), icon: "link",
                                     color: .green, busy: vm.isOperating) {
                        Task { await vm.operateFilterChain("bind-base") }
                    }
                }
            }
        }
    }

    // MARK: 规则段

    private var rulesSection: some View {
        Group {
            Section {
                filterBar
            }
            if vm.inventory.isEmpty && !vm.isRulesLoadingMore {
                Section {
                    ContentUnavailableView(L10n.t("暂无规则"), systemImage: "shield")
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(vm.inventory) { item in
                        FirewallRuleRowView(item: item, processName: processName(for: item))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard item.manageableUUID != nil else { return }
                                if let uuid = item.manageableUUID, let rule = item.rule {
                                    editingRuleUUID = uuid
                                    editingRule = rule
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if item.manageableUUID != nil {
                                    Button(role: .destructive) {
                                        Haptic.warning()
                                        pendingDeleteItem = item
                                    } label: {
                                        Label(L10n.t("删除"), systemImage: "trash")
                                    }
                                }
                            }
                            .onAppear {
                                if item.id == vm.inventory.last?.id,
                                   vm.inventory.count < vm.rulesAllTotal {
                                    Task { await vm.loadRules(replacing: false) }
                                }
                            }
                    }
                    if vm.isRulesLoadingMore {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                } header: {
                    Text(L10n.f("共 %ld 条（面板管理 %ld 条）", vm.rulesAllTotal, vm.rulesManagedTotal))
                }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            Menu {
                Button(L10n.t("全部状态")) { vm.ruleStateFilter = nil; reloadRules() }
                ForEach(Self.ruleStates, id: \.0) { state, label in
                    Button(label) { vm.ruleStateFilter = state; reloadRules() }
                }
            } label: {
                StatusBadge(
                    text: vm.ruleStateFilter.flatMap { state in
                        Self.ruleStates.first { $0.0 == state }?.1
                    } ?? L10n.t("全部状态"),
                    color: .secondary
                )
            }
            .buttonStyle(.plain)
            Menu {
                Button(L10n.t("全部族")) { vm.ruleFamilyFilter = nil; reloadRules() }
                Button("IPv4") { vm.ruleFamilyFilter = "ipv4"; reloadRules() }
                Button("IPv6") { vm.ruleFamilyFilter = "ipv6"; reloadRules() }
            } label: {
                StatusBadge(text: vm.ruleFamilyFilter?.uppercased() ?? L10n.t("全部族"),
                            color: .secondary)
            }
            .buttonStyle(.plain)
            Spacer()
            TextField(L10n.t("搜索端口 / 地址"), text: $vm.ruleSearchText)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { reloadRules() }
            Button {
                reloadRules()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
        }
    }

    private func reloadRules() {
        Task { await vm.loadRules(replacing: true) }
    }

    private func processName(for item: FirewallInventoryItem) -> String? {
        guard let port = item.rule?.destinationPort, !port.isEmpty else { return nil }
        return vm.portProcessNames[port]
    }

    private static let ruleStates: [(String, String)] = [
        ("managed", L10n.t("面板管理")),
        ("adopted", L10n.t("已纳管")),
        ("external", L10n.t("外部规则")),
        ("drifted", L10n.t("已漂移")),
        ("protected", L10n.t("受保护")),
    ]

    // MARK: 转发段

    private var forwardSection: some View {
        Group {
            if let fs = vm.forwardStatus {
                Section {
                    HStack(spacing: 10) {
                        // 抓包 2026-09-17：转发子系统 isActive 恒 false（iptables-forward），
                        // 启用判据用 isInit
                        StatusDot(color: (fs.isInit == true) ? .statusRunning : .statusStopped,
                                  diameter: 8)
                        Text(fs.backend?.uppercased() ?? "—")
                            .font(.subheadline.bold())
                        if let v = fs.version, !v.isEmpty {
                            Text("v\(v)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if fs.isInit != true {
                            Button(L10n.t("启用转发")) {
                                Task { await vm.enableForwarding() }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(vm.isOperating)
                        } else if let err = fs.syncError, !err.isEmpty {
                            StatusBadge(text: L10n.t("同步异常"), color: .semanticWarning)
                        }
                    }
                } header: {
                    SectionLabel(title: L10n.t("转发子系统"), systemImage: "arrow.triangle.branch")
                }
            }
            if vm.forwards.isEmpty {
                Section {
                    ContentUnavailableView(L10n.t("暂无转发规则"), systemImage: "arrow.triangle.branch")
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(vm.forwards) { rule in
                        FirewallForwardRowView(rule: rule)
                            .contentShape(Rectangle())
                            .onTapGesture { editingForward = rule }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Haptic.warning()
                                    pendingDeleteForward = rule
                                } label: {
                                    Label(L10n.t("删除"), systemImage: "trash")
                                }
                            }
                            .onAppear {
                                if rule.id == vm.forwards.last?.id,
                                   vm.forwards.count < vm.forwardsTotal {
                                    Task { await vm.loadForwards(replacing: false) }
                                }
                            }
                    }
                    if vm.isForwardsLoadingMore {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                } header: {
                    Text(L10n.f("共 %ld 条", vm.forwardsTotal))
                }
            }
        }
    }

    // MARK: Docker 守护段

    private var dockerSection: some View {
        Group {
            if let guard_ = vm.dockerGuard, let base = guard_.base, base.isExist == true {
                Section {
                    HStack(spacing: 10) {
                        IconBadge(systemName: "shippingbox.fill", color: .blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(base.name?.uppercased() ?? "DOCKER")
                                .font(.subheadline.bold())
                            if let backend = base.backend, !backend.isEmpty {
                                Text(backend.uppercased())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if base.initialized != true {
                            StatusBadge(text: L10n.t("未初始化"), color: .semanticWarning)
                        } else if base.bound == true {
                            StatusBadge(text: L10n.t("已绑定"), color: .blue)
                        }
                    }
                    if base.initialized != true {
                        CardActionButton(title: L10n.t("初始化守护"), icon: "wand.and.stars",
                                         color: .green, busy: vm.isOperating) {
                            Task { await vm.dockerOperate("initialize") }
                        }
                    } else {
                        HStack(spacing: 8) {
                            CardActionButton(
                                title: base.bound == true ? L10n.t("解绑") : L10n.t("绑定"),
                                icon: base.bound == true ? "link.badge.plus" : "link",
                                color: base.bound == true ? .secondary : .green,
                                busy: vm.isOperating
                            ) {
                                Task { await vm.dockerOperate(base.bound == true ? "unbind" : "bind") }
                            }
                            CardActionButton(title: L10n.t("同步规则"), icon: "arrow.triangle.2.circlepath",
                                             color: .blue, busy: vm.isOperating) {
                                Task { await vm.dockerSync() }
                            }
                        }
                    }
                    if let msg = base.message, !msg.isEmpty {
                        Text(msg).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    SectionLabel(title: L10n.t("Docker 端口守护"), systemImage: "shippingbox")
                }

                ForEach(guard_.containers ?? []) { container in
                    DockerGuardContainerSection(
                        container: container,
                        onDeletePolicy: { endpoint in
                            Haptic.warning()
                            Task { await vm.deleteDockerPolicy(endpoint) }
                        },
                        isOperating: vm.isOperating
                    )
                }

                if let orphans = guard_.orphanPolicies, !orphans.isEmpty {
                    Section {
                        ForEach(orphans) { endpoint in
                            DockerGuardEndpointRow(endpoint: endpoint) {
                                Haptic.warning()
                                Task { await vm.deleteDockerPolicy(endpoint) }
                            }
                        }
                    } header: {
                        SectionLabel(title: L10n.t("孤立策略"), systemImage: "questionmark.circle")
                    }
                }
            } else {
                Section {
                    ContentUnavailableView(
                        L10n.t("Docker 守护不可用"),
                        systemImage: "shippingbox",
                        description: Text(L10n.t("未检测到 Docker 或守护链不可用；安装 Docker 后下拉刷新。"))
                    )
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .listRowBackground(Color.clear)
                }
            }
        }
    }

    // MARK: 设置段

    private var settingsSection: some View {
        Group {
            Section {
                Toggle(L10n.t("禁 Ping"), isOn: Binding(
                    get: { vm.settings?.pingBlocked ?? vm.systemStatus?.pingBlocked ?? false },
                    set: { on in
                        Task {
                            await vm.operateFirewall(on ? "disableBanPing" : "enableBanPing")
                        }
                    }
                ))
                .disabled(vm.isOperating)
                NavigationLink {
                    FirewallWhitelistView(vm: vm)
                } label: {
                    HStack {
                        Text(L10n.t("面板端口白名单"))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(parseFirewallWhitelistEntries(vm.settings?.portWhiteList).count)")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                SectionLabel(title: L10n.t("基础设置"), systemImage: "gearshape")
            } footer: {
                Text(L10n.t("禁 Ping 后服务器不再响应 ICMP 探测；端口白名单外的高校验规则见任务日志。"))
            }

            backendGroupSection(title: L10n.t("系统防火墙"), subsystem: "system",
                                group: vm.settings?.system)
            backendGroupSection(title: L10n.t("端口转发"), subsystem: "forwarding",
                                group: vm.settings?.forwarding)
            backendGroupSection(title: L10n.t("Docker 守护"), subsystem: "docker",
                                group: vm.settings?.docker)
        }
    }

    private func backendGroupSection(title: String, subsystem: String,
                                     group: FirewallBackendGroup?) -> some View {
        Section {
            if let group {
                ForEach(group.options ?? []) { option in
                    backendOptionRow(option: option, group: group, subsystem: subsystem)
                }
            }
        } header: {
            HStack {
                SectionLabel(title: title, systemImage: "server.rack")
                Spacer()
                if let selected = group?.selected, !selected.isEmpty {
                    Text(L10n.f("当前：%@", selected))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func backendOptionRow(option: FirewallBackendOption,
                                  group: FirewallBackendGroup,
                                  subsystem: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text((option.name ?? "—").uppercased())
                        .font(.subheadline.bold())
                    if option.name == group.selected {
                        StatusBadge(text: L10n.t("已选择"), color: .blue)
                    }
                }
                HStack(spacing: 6) {
                    if option.installed != true {
                        StatusBadge(text: L10n.t("未安装"), color: .secondary)
                    }
                    if option.installed == true, option.active == true {
                        StatusBadge(text: L10n.t("已激活"), color: .statusRunning)
                    }
                    if option.supported == false {
                        StatusBadge(text: L10n.t("不支持"), color: .semanticWarning)
                    }
                }
                if let reason = option.supportReason ?? option.message, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if option.supported != false, option.installed == true {
                Menu {
                    if option.name != group.selected {
                        Button(L10n.t("选择此后端")) {
                            Task { await vm.operateBackend(subsystem: subsystem, backend: option.name ?? "", operation: "select") }
                        }
                    }
                    if option.initialized != true, option.name != group.selected {
                        Button(L10n.t("初始化")) {
                            Task { await vm.operateBackend(subsystem: subsystem, backend: option.name ?? "", operation: "initialize") }
                        }
                    }
                    if option.bound == true {
                        Button(L10n.t("清理绑定"), role: .destructive) {
                            Task { await vm.operateBackend(subsystem: subsystem, backend: option.name ?? "", operation: "cleanup") }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .frame(width: 32, height: 32)
                }
            }
        }
    }
}

// pingBlocked 已上移至 Models/Firewall.swift 的 FirewallSettings（测试与视图共用）

// MARK: - 规则行

struct FirewallRuleRowView: View {
    let item: FirewallInventoryItem
    var processName: String?

    private var rule: FirewallRule? { item.rule ?? item.desired?.rule }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                // 端口（端口规则）或 源地址（IP 规则）为主标识
                Text(mainToken)
                    .font(.dataMonospacedBody.bold())
                    .lineLimit(1)
                if let proto = rule?.protocolField, !proto.isEmpty {
                    StatusBadge(text: proto.uppercased(), color: .blue)
                }
                Spacer()
                stateBadge
                actionBadge
            }
            if !secondaryLine.isEmpty {
                Text(secondaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var mainToken: String {
        if let port = rule?.destinationPort, !port.isEmpty { return port }
        if let addr = rule?.sourceAddress, !addr.isEmpty { return addr }
        return "—"
    }

    private var secondaryLine: String {
        var parts: [String] = []
        if let addr = rule?.sourceAddress, !addr.isEmpty,
           rule?.destinationPort?.isEmpty == false {
            parts.append(L10n.f("来源：%@", addr))
        }
        if let sport = rule?.sourcePort, !sport.isEmpty {
            parts.append(L10n.f("源端口：%@", sport))
        }
        if let dest = rule?.destinationAddress, !dest.isEmpty {
            parts.append(L10n.f("目标：%@", dest))
        }
        if let pn = processName, !pn.isEmpty {
            parts.append(pn)
        }
        if let desc = rule?.descriptionText, !desc.isEmpty {
            parts.append(desc)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var stateBadge: some View {
        let mapping: [(String, String, Color)] = [
            ("managed", L10n.t("面板管理"), .statusRunning),
            ("adopted", L10n.t("已纳管"), .blue),
            ("external", L10n.t("外部"), .secondary),
            ("drifted", L10n.t("漂移"), .semanticWarning),
            ("protected", L10n.t("受保护"), .purple),
        ]
        if let state = item.state,
           let entry = mapping.first(where: { $0.0 == state }) {
            StatusBadge(text: entry.1, color: entry.2)
        }
    }

    @ViewBuilder
    private var actionBadge: some View {
        if let action = rule?.action {
            StatusBadge(
                text: action == "accept" ? L10n.t("放行") : L10n.t("拒绝"),
                color: action == "accept" ? .statusRunning : .statusError
            )
        }
    }
}

// MARK: - 转发行

struct FirewallForwardRowView: View {
    let rule: FirewallForwardRule

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(rule.port ?? "-")
                    .font(.dataMonospacedBody.bold())
                if let proto = rule.protocolField, !proto.isEmpty {
                    StatusBadge(text: proto.uppercased(), color: .blue)
                }
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(target)
                    .font(.dataMonospaced)
                    .lineLimit(1)
                Spacer()
                if rule.strategy?.lowercased() == "accept" || rule.strategy == nil {
                    StatusBadge(text: L10n.t("放行"), color: .statusRunning)
                } else {
                    StatusBadge(text: L10n.t("拒绝"), color: .statusError)
                }
            }
            if !secondaryLine.isEmpty {
                Text(secondaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var target: String {
        let ip = rule.targetIP ?? ""
        let port = rule.targetPort ?? ""
        if ip.isEmpty { return port }
        return "\(ip):\(port)"
    }

    private var secondaryLine: String {
        var parts: [String] = []
        if let family = rule.family, !family.isEmpty { parts.append(family.uppercased()) }
        if let iface = rule.interface, !iface.isEmpty, iface != "*" {
            parts.append(L10n.f("网卡：%@", iface))
        }
        if let used = rule.usedStatus, !used.isEmpty { parts.append(used) }
        if let desc = rule.descriptionText, !desc.isEmpty { parts.append(desc) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Docker 守护子视图

private struct DockerGuardContainerSection: View {
    let container: DockerGuardContainer
    let onDeletePolicy: (DockerGuardEndpoint) -> Void
    let isOperating: Bool
    @State private var expanded = true

    var body: some View {
        Section {
            Button {
                withAnimation(Motion.standard) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox.fill")
                        .foregroundStyle(.blue)
                    Text(container.name ?? "—")
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    if let compose = container.compose, !compose.isEmpty {
                        StatusBadge(text: compose, color: .purple)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                // 抓包 2026-09-17：实际返回为容器下平铺 endpoints（ipv4/ipv6 各一条）；
                // portGroups 为 DTO 保留形态，两者并集渲染、按 id 去重
                let groupEndpoints = (container.portGroups ?? []).compactMap { $0.endpoint }
                var seen = Set<String>()
                let endpoints = ((container.endpoints ?? []) + groupEndpoints).filter { seen.insert($0.id).inserted }
                if endpoints.isEmpty {
                    Text(L10n.t("未发布端口"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(endpoints) { endpoint in
                        DockerGuardEndpointRow(endpoint: endpoint) {
                            if endpoint.readOnly != true, endpoint.policyUUID?.isEmpty == false {
                                onDeletePolicy(endpoint)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct DockerGuardEndpointRow: View {
    let endpoint: DockerGuardEndpoint
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(hostLabel)
                    .font(.dataMonospacedBody.bold())
                if let proto = endpoint.protocolField {
                    StatusBadge(text: proto.uppercased(), color: .blue)
                }
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(endpoint.containerName ?? "—")
                    .lineLimit(1)
                Spacer()
                modeBadge
            }
            if let sources = endpoint.sources, !sources.isEmpty {
                Text(L10n.f("来源：%@", sources.joined(separator: ", ")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if endpoint.readOnly != true, endpoint.policyUUID?.isEmpty == false {
                Button(role: .destructive, action: onDelete) {
                    Label(L10n.t("删除"), systemImage: "trash")
                }
            }
        }
    }

    private var hostLabel: String {
        let ip = endpoint.hostIP ?? ""
        let port = endpoint.hostPort.map(String.init) ?? ""
        return ip.isEmpty ? port : "\(ip):\(port)"
    }

    @ViewBuilder
    private var modeBadge: some View {
        switch endpoint.mode {
        case "deny_all":
            StatusBadge(text: L10n.t("全部拒绝"), color: .statusError)
        case "allow_sources":
            StatusBadge(text: L10n.t("白名单"), color: .statusRunning)
        case "deny_sources":
            StatusBadge(text: L10n.t("黑名单"), color: .semanticWarning)
        default:
            StatusBadge(text: L10n.t("未设置"), color: .secondary)
        }
    }
}

// 端口白名单解析已上移至 Models/Firewall.swift（PanelShared 自包含，Widget target 可见）
