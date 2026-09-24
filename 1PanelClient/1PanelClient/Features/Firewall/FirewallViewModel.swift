//
//  FirewallViewModel.swift
//  1PanelClient
//
//  防火墙 ViewModel + 任务跳转模型（自 FirewallView.swift 拆出，内容未改动）
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
    /// 全量规则总数（接口 allTotal，不随筛选/搜索变化；用于无筛选时的「共 N 条」）
    @Published private(set) var rulesAllTotal = 0
    /// 当前筛选+搜索的结果总数（接口 total；头部计数与分页停止条件都用它，
    /// 否则筛空后头部仍显示全量数、分页会多发空页请求）
    @Published private(set) var rulesResultTotal = 0
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
    /// 设置加载失败原因（设置段内展示 + 重试入口）
    @Published var settingsErrorMessage: String?

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
            guard !isRulesLoadingMore, inventory.count < rulesResultTotal else { return }
            isRulesLoadingMore = true
        }
        // 函数级 defer 复位（不能放在上面的 else 块尾——块尾 defer 在块结束时
        // 立即执行，标志等于没设）：generation 失配/取消的早退路径也必须清标志，
        // 否则懒加载永久失效（补页循环与下拉刷新并发时必现）
        defer { if !replacing { isRulesLoadingMore = false } }
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
            rulesResultTotal = resp.total ?? resp.allTotal ?? inventory.count
            rulesManagedTotal = resp.managedTotal ?? 0
            errorMessage = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            guard generation == rulesGeneration else { return }
            errorMessage = error.localizedDescription
        }
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

    // MARK: 规则同步 / 重置 / Docker 策略（抓包 2026-09-17）

    /// 同步预览：ready>0 才值得执行（existing=已一致，blocked=受阻）
    func syncPreview(subsystem: String) async -> FirewallRuleSyncPreview? {
        do {
            let target = subsystem == "forwarding"
                ? (forwardStatus?.backend ?? systemStatus?.backend ?? "iptables")
                : (systemStatus?.backend ?? "iptables")
            return try await client.send(
                path: APIEndpoint.firewallRulesSyncPreview.path,
                body: FirewallRuleSyncRequest(subsystem: subsystem, targetProvider: target,
                                              resetSource: false, taskID: nil),
                as: FirewallRuleSyncPreview.self
            )
        } catch {
            guard !APIError.isCancellation(error) else { return nil }
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// 执行同步（任务式结果 → 进度页）
    func executeSync(subsystem: String) async {
        isOperating = true
        defer { isOperating = false }
        do {
            let target = subsystem == "forwarding"
                ? (forwardStatus?.backend ?? systemStatus?.backend ?? "iptables")
                : (systemStatus?.backend ?? "iptables")
            let resp: FirewallRuleSyncResult = try await client.send(
                path: APIEndpoint.firewallRulesSync.path,
                body: FirewallRuleSyncRequest(subsystem: subsystem, targetProvider: target,
                                              resetSource: false, taskID: nil),
                as: FirewallRuleSyncResult.self
            )
            if let taskID = resp.taskID, !taskID.isEmpty {
                activeTask = FirewallTaskTarget(taskID: taskID, title: L10n.t("同步防火墙规则"))
            }
            if subsystem == "forwarding" {
                await loadForwards(replacing: true)
            } else {
                await loadRules(replacing: true)
            }
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// 重置运行时规则（R1：调用方需先经输入后端名确认）
    func resetRules() async {
        isOperating = true
        defer { isOperating = false }
        do {
            let resp: FirewallRuleResetResponse = try await client.send(
                path: APIEndpoint.firewallRulesReset.path,
                body: FirewallRuleResetRequest(provider: systemStatus?.backend,
                                               withDockerRestart: false),
                as: FirewallRuleResetResponse.self
            )
            toastMessage = L10n.f("已重置：移除 %ld 条规则", resp.removed ?? 0)
            await loadSystemStatus()
            await loadRules(replacing: true)
            // 重置会改变 settings 各组当前后端的 initialized，同步刷新供切换预检
            await loadSettings()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Docker 端口守护重置（settings/operate cleanup；R1：调用方需先经输入后端名确认）
    func resetDockerGuard() async {
        isOperating = true
        defer { isOperating = false }
        await operateBackend(subsystem: "docker",
                             backend: dockerGuard?.base?.backend ?? systemStatus?.backend ?? "iptables",
                             operation: "cleanup")
        await loadDockerGuard()
        await loadSettings()
    }

    /// 转发运行时规则重置（settings/operate cleanup，抓包 2026-09-19 logs/iptables.md；
    /// R1：调用方需先经输入后端名确认）
    func resetForwarding() async {
        isOperating = true
        defer { isOperating = false }
        await operateBackend(subsystem: "forwarding",
                             backend: forwardStatus?.backend ?? systemStatus?.backend ?? "iptables",
                             operation: "cleanup")
        await loadForwards(replacing: true)
        await loadSettings()
    }

    /// 设置 Docker 端点防护策略（任务式）
    func upsertDockerPolicy(_ policy: DockerGuardPolicy) async -> Bool {
        isOperating = true
        defer { isOperating = false }
        do {
            let resp: FirewallTaskResponse = try await client.send(
                path: APIEndpoint.firewallDockerPolicyBatch.path,
                body: DockerGuardPolicyBatchRequest(policies: [policy]),
                as: FirewallTaskResponse.self
            )
            if let taskID = resp.taskID, !taskID.isEmpty {
                activeTask = FirewallTaskTarget(taskID: taskID, title: L10n.t("设置端口防护"))
            }
            await loadDockerGuard()
            return true
        } catch {
            guard !APIError.isCancellation(error) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: 纳管 / 排序 / 原文 / 导入导出（低频操作）

    /// 纳管 external/drifted 规则（进入面板管理，可编辑删除）
    func adoptRule(_ item: FirewallInventoryItem) async {
        guard let key = item.observed?.instanceKey ?? item.rule?.id,
              let scope = item.rule?.scope else {
            errorMessage = L10n.t("该规则缺少纳管所需的定位信息")
            return
        }
        isOperating = true
        defer { isOperating = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.firewallRulesAdopt.path,
                body: FirewallRuleAdoptRequest(scope: scope, instanceKey: key),
                as: EmptyResponse.self
            )
            toastMessage = L10n.t("已纳管")
            await loadRules(replacing: true)
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// 链内位置调整（上移/下移一位）
    func reorderRule(uuid: String, to position: Int64) async {
        isOperating = true
        defer { isOperating = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.firewallRulesReorder.path,
                body: FirewallRuleReorderRequest(uuid: uuid, targetPosition: position, priority: nil),
                as: EmptyResponse.self
            )
            await loadRules(replacing: true)
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// 原生对象配置原文（zone_service / ufw_application）；普通规则用 observed.raw
    func loadNativeDetail(for item: FirewallInventoryItem) async -> String {
        if let raw = item.observed?.raw, !raw.isEmpty { return raw }
        guard let rule = item.rule, let name = rule.uuid ?? item.observed?.instanceKey else {
            return item.observed?.raw ?? ""
        }
        do {
            return try await client.send(
                path: APIEndpoint.firewallNativeDetail.path,
                body: FirewallNativeDetailRequest(
                    provider: rule.scope?.provider ?? systemStatus?.backend ?? "iptables",
                    nativeKind: rule.nativeKind ?? "rule",
                    name: name),
                as: String.self
            )
        } catch {
            return item.observed?.raw ?? (error.localizedDescription)
        }
    }

    /// 导入规则（文件解析后的选中项，sourceKind: imported，任务式）
    func importRules(_ rules: [FirewallRule]) async -> Bool {
        isOperating = true
        defer { isOperating = false }
        do {
            let resp: FirewallRuleCreateResponse = try await client.send(
                path: APIEndpoint.firewallRulesCreate.path,
                body: FirewallRuleCreateRequest(
                    items: rules.map { FirewallRuleCreateItem(rule: $0, sourceKind: "imported", sourceID: nil) }),
                as: FirewallRuleCreateResponse.self
            )
            if let taskID = resp.taskID, !taskID.isEmpty {
                activeTask = FirewallTaskTarget(taskID: taskID, title: L10n.t("导入规则"))
            }
            await loadRules(replacing: true)
            return true
        } catch {
            guard !APIError.isCancellation(error) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// 导出：对齐 Web 端——面板管理且可删除的规则，去除 uuid 后本地组 JSON
    /// （无服务端端点），写入临时文件供 ShareLink 分享
    func exportRulesURL(for items: [FirewallInventoryItem]? = nil) -> URL? {
        let exportable = items ?? inventory.filter { item in
            guard item.manageableUUID != nil, item.state != "protected" else { return false }
            return true
        }
        guard !exportable.isEmpty else { return nil }
        let rules = exportable.compactMap { item -> FirewallRule? in
            guard var rule = item.rule ?? item.desired?.rule else { return nil }
            rule.uuid = nil
            return rule
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(rules) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("1panel-firewall-rules-\(formatter.string(from: Date())).json")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// 导出转发规则（本地组 JSON，无服务端端点；清 id/num 等运行时字段；
    /// 传入子集时长按菜单多选导出，nil = 全量）
    func exportForwardsURL(for rules: [FirewallForwardRule]? = nil) -> URL? {
        let list = rules ?? forwards
        guard !list.isEmpty else { return nil }
        let cleaned = list.map { rule -> FirewallForwardRule in
            var r = rule
            r.id = nil
            r.num = nil
            return r
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(cleaned) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("1panel-firewall-forwards-\(formatter.string(from: Date())).json")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// 导入转发（forward/operate 批量 add；抓包 2026-09-19 logs/iptables.md）
    func importForwards(_ rules: [FirewallForwardRule]) async -> Bool {
        guard !rules.isEmpty else { return false }
        isOperating = true
        defer { isOperating = false }
        let ops = rules.map { rule in
            FirewallForwardOperation(
                operation: "add", id: nil, chain: rule.chain, family: rule.family,
                address: rule.address, port: rule.port,
                protocolField: rule.protocolField, strategy: rule.strategy,
                num: nil, targetIP: rule.targetIP, targetPort: rule.targetPort,
                interface: rule.interface, usedStatus: nil,
                descriptionText: rule.descriptionText, isDesired: nil,
                isRuntime: nil, syncStatus: nil)
        }
        do {
            let resp: FirewallTaskResponse = try await client.send(
                path: APIEndpoint.firewallForwardOperate.path,
                body: FirewallForwardOperateRequest(forceDelete: false, rules: ops),
                as: FirewallTaskResponse.self)
            if let taskID = resp.taskID, !taskID.isEmpty {
                activeTask = FirewallTaskTarget(taskID: taskID, title: L10n.t("导入转发规则"))
            }
            await loadForwards(replacing: true)
            return true
        } catch {
            guard !APIError.isCancellation(error) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// 导出 Docker 端口防护策略（本地组 JSON；含容器端点策略与孤儿策略，
    /// 不含 host_firewall 托管的端点——那类须在规则段调整；
    /// 传入子集时长按菜单多选导出，nil = 全量）
    func exportDockerPoliciesURL(for policies: [DockerGuardPolicy]? = nil) -> URL? {
        let list = policies ?? allExportableDockerPolicies()
        guard !list.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(list) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("1panel-firewall-docker-\(formatter.string(from: Date())).json")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// 全部可导出策略（容器端点 + 孤儿策略）
    private func allExportableDockerPolicies() -> [DockerGuardPolicy] {
        guard let guard_ = dockerGuard else { return [] }
        var policies: [DockerGuardPolicy] = []
        for container in guard_.containers ?? [] {
            policies += Self.exportablePolicies(endpoints: container.endpoints)
        }
        policies += Self.exportablePolicies(endpoints: guard_.orphanPolicies)
        return policies
    }

    /// 可导出策略（视图层多选页读取）
    var dockerExportablePolicies: [DockerGuardPolicy] {
        allExportableDockerPolicies()
    }

    /// 指定容器在 dockerExportablePolicies 中的下标集合（容器行长按「导出规则」预选用；
    /// 顺序与 allExportableDockerPolicies 完全一致：容器顺序 + 末尾孤儿策略）
    func dockerExportableIndices(containerID: String) -> Set<Int> {
        guard let guard_ = dockerGuard else { return [] }
        var result: Set<Int> = []
        var idx = 0
        for container in guard_.containers ?? [] {
            let count = Self.exportablePolicies(endpoints: container.endpoints).count
            if container.id == containerID {
                result.formUnion(idx..<idx + count)
            }
            idx += count
        }
        return result
    }

    /// 端点 → 可导出策略（缺关键字段或 host_firewall 托管的跳过）
    private static func exportablePolicies(endpoints: [DockerGuardEndpoint]?) -> [DockerGuardPolicy] {
        (endpoints ?? []).compactMap { ep in
            guard ep.managementTarget != "host_firewall",
                  let family = ep.family, let hostIP = ep.hostIP,
                  let hostPort = ep.hostPort, let proto = ep.protocolField else { return nil }
            return DockerGuardPolicy(
                family: family, hostIP: hostIP, hostPort: hostPort,
                protocolField: proto,
                mode: ep.mode ?? "deny_all",
                sources: ep.sources ?? [],
                descriptionText: ep.descriptionText ?? "")
        }
    }

    /// 导入 Docker 端口防护策略（docker/policies/batch；抓包 2026-09-19 logs/iptables.md）
    func importDockerPolicies(_ policies: [DockerGuardPolicy]) async -> Bool {
        guard !policies.isEmpty else { return false }
        isOperating = true
        defer { isOperating = false }
        do {
            let resp: FirewallTaskResponse = try await client.send(
                path: APIEndpoint.firewallDockerPolicyBatch.path,
                body: DockerGuardPolicyBatchRequest(policies: policies),
                as: FirewallTaskResponse.self)
            if let taskID = resp.taskID, !taskID.isEmpty {
                activeTask = FirewallTaskTarget(taskID: taskID, title: L10n.t("导入防护策略"))
            }
            await loadDockerGuard()
            return true
        } catch {
            guard !APIError.isCancellation(error) else { return false }
            errorMessage = error.localizedDescription
            return false
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
            settingsErrorMessage = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            // 不再静默吞错：失败原因暴露到设置段（白名单 0/后端不可选这类症状
            // 的唯一线索），否则真机上无从排查
            settingsErrorMessage = "\(APIEndpoint.firewallSettings.path)：\(error.localizedDescription)"
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

    /// 面板端口白名单（v2.3.1 逐条写）：按 id 对比编辑前后差异——
    /// 删除→/delete、新增→/whitelist、同 id 变更→/whitelist/update
    func savePortWhitelist(
        original: [FirewallPortWhitelistEntry],
        entries: [FirewallPortWhitelistEntry]
    ) async -> Bool {
        isOperating = true
        defer { isOperating = false }
        do {
            let origByID = Dictionary(original.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let newIDs = Set(entries.map(\.id))
            for old in original where !newIDs.contains(old.id) {
                let _: EmptyResponse = try await client.send(
                    path: APIEndpoint.firewallSettingsWhitelistDelete.path,
                    body: FirewallWhitelistRuleRequest(rule: old),
                    as: EmptyResponse.self
                )
            }
            for entry in entries {
                if let old = origByID[entry.id] {
                    guard old != entry else { continue }
                    let _: EmptyResponse = try await client.send(
                        path: APIEndpoint.firewallSettingsWhitelistUpdate.path,
                        body: FirewallWhitelistRuleUpdateRequest(oldRule: old, rule: entry),
                        as: EmptyResponse.self
                    )
                } else {
                    let _: EmptyResponse = try await client.send(
                        path: APIEndpoint.firewallSettingsWhitelist.path,
                        body: FirewallWhitelistRuleRequest(rule: entry),
                        as: EmptyResponse.self
                    )
                }
            }
            await loadSettings()
            toastMessage = L10n.t("白名单已提交")
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
