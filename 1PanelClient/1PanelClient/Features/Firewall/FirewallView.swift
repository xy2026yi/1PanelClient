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
    /// 内容段：0=规则 1=转发 2=容器端口防护（设置经状态抽屉按钮进入独立页）
    @State private var segment = 0
    @State private var showSettings = false
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
    // 同步 / 重置 / Docker 策略（抓包 2026-09-17 补齐）
    @State private var showSyncPreview = false
    @State private var syncSubsystem = "system"
    @State private var showRulesReset = false
    @State private var showDockerReset = false
    @State private var showForwardReset = false
    @State private var editingPolicy: DockerGuardEndpoint?
    // 规则低频操作
    @State private var showImport = false
    @State private var rawDetail: RawDetailPayload?
    @State private var showForwardImport = false
    @State private var showDockerImport = false
    /// 长按弹出的规则操作目标
    @State private var actionItem: FirewallInventoryItem?
    /// 长按弹出的转发操作目标
    @State private var actionForward: FirewallForwardRule?
    /// 规则导出多选页
    @State private var showExportPicker = false
    /// 转发导出多选页
    @State private var showForwardExportPicker = false
    /// Docker 导出多选页
    @State private var showDockerExportPicker = false
    /// 长按「导出规则」的预选（与计划任务语义一致：仅预选长按对象，nil = 默认全选）
    @State private var ruleExportPreselect: Set<String>? = nil
    @State private var forwardExportPreselect: Int? = nil
    @State private var dockerExportPreselect: Set<Int>? = nil
    struct RawDetailPayload: Identifiable {
        let title: String
        let text: String
        var id: String { title }
    }

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
                }
                .pickerStyle(.segmented)
                .segmentedPickerRow()
                .listRowBackground(Color.clear)

                switch segment {
                case 0: rulesSection
                case 1: forwardSection
                default: dockerSection
                }
            }
        }
        .navigationTitle(L10n.t("防火墙"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !vm.unsupportedPanel {
                    // WAF 与防火墙同属主机安全防护，入口收进本页右上角（管理列表不单列），
                    // 与「添加」菜单并排独立成按钮
                    Button { showWAF = true } label: {
                        Image(systemName: "shield.lefthalf.filled")
                    }
                    .accessibilityLabel("WAF")
                    // + 按段条件渲染（未初始化段不显示；导入/导出/同步/重置均已收进
                    // 状态抽屉，规则与转发都只剩创建，直接点击不经菜单）
                    if segment == 0 && !needsRulesInit {
                        Button { showAddRule = true } label: {
                            Image(systemName: "plus.circle")
                        }
                        .accessibilityLabel(L10n.t("创建规则"))
                        .id(segment)
                    } else if segment == 1 && !needsForwardInit {
                        Button { showAddForward = true } label: {
                            Image(systemName: "plus.circle")
                        }
                        .accessibilityLabel(L10n.t("创建转发"))
                        .id(segment)
                    }
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
        // 设置页（状态抽屉按钮进入）：禁 Ping / 白名单 / 三组防护后端下拉切换
        .navigationDestination(isPresented: $showSettings) {
            FirewallSettingsPageView(vm: vm)
        }
        // 同步预览（规则段 / 转发段共用）
        .sheet(isPresented: $showSyncPreview) {
            FirewallSyncPreviewView(vm: vm, subsystem: syncSubsystem)
                .bottomSheetDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        // Docker 端点防护策略表单
        .sheet(item: $editingPolicy) { endpoint in
            DockerPolicyFormView(vm: vm, endpoint: endpoint)
                .bottomSheetDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        // 规则导入（文件解析 + 勾选 + sourceKind imported）
        .sheet(isPresented: $showImport) {
            FirewallImportView(vm: vm)
        }
        // 转发导入（文件解析 + 勾选 + forward/operate 批量 add）
        .sheet(isPresented: $showForwardImport) {
            FirewallForwardImportView(vm: vm)
        }
        // Docker 防护策略导入（文件解析 + 勾选 + docker/policies/batch）
        .sheet(isPresented: $showDockerImport) {
            FirewallDockerImportView(vm: vm)
        }
        // 原文查看（observed.raw 或 native/detail）
        .sheet(item: $rawDetail) { payload in
            FirewallRawDetailView(title: payload.title, text: payload.text)
                .bottomSheetDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        // 长按规则：半屏操作弹窗（编辑/删除/上移下移/导出规则/查看原文，或纳管）
        .sheet(isPresented: Binding(
            get: { actionItem != nil },
            set: { if !$0 { actionItem = nil } }
        )) {
            ActionBottomSheet(
                title: actionItem?.rule?.destinationPort ?? actionItem?.rule?.sourceAddress ?? L10n.t("规则"),
                items: ruleActionItems,
                onDismiss: { actionItem = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: ruleActionItems.count))])
            .presentationDragIndicator(.visible)
        }
        // 规则导出多选（长按菜单「导出规则」进入：仅预选长按的这条）
        .sheet(isPresented: $showExportPicker) {
            FirewallExportPickerView(vm: vm, preselectedIDs: ruleExportPreselect)
        }
        // 长按转发：半屏操作弹窗（编辑/删除/导出规则）
        .sheet(isPresented: Binding(
            get: { actionForward != nil },
            set: { if !$0 { actionForward = nil } }
        )) {
            ActionBottomSheet(
                title: actionForward?.port ?? L10n.t("转发"),
                items: [
                    ActionMenuItem(title: L10n.t("编辑"), icon: "pencil", color: .blue) {
                        let rule = actionForward
                        actionForward = nil
                        if let rule { editingForward = rule }
                    },
                    ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red,
                                   role: .destructive) {
                        Haptic.warning()
                        let rule = actionForward
                        actionForward = nil
                        if let rule { pendingDeleteForward = rule }
                    },
                    ActionMenuItem(title: L10n.t("导出规则"), icon: "square.and.arrow.up",
                                   color: .teal) {
                        let rule = actionForward
                        actionForward = nil
                        // 仅预选长按的这条转发（与计划任务「导出任务」语义一致）
                        if let rule {
                            forwardExportPreselect = vm.forwards.firstIndex {
                                $0.port == rule.port && $0.protocolField == rule.protocolField
                                    && $0.family == rule.family && $0.targetIP == rule.targetIP
                                    && $0.targetPort == rule.targetPort && $0.interface == rule.interface
                            }
                        }
                        showForwardExportPicker = true
                    },
                ],
                onDismiss: { actionForward = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: 3))])
            .presentationDragIndicator(.visible)
        }
        // 转发导出多选（长按菜单「导出规则」进入）
        .sheet(isPresented: $showForwardExportPicker) {
            FirewallForwardExportPickerView(vm: vm, preselectedIndex: forwardExportPreselect)
        }
        // Docker 导出多选（容器行长按「导出规则」进入：仅预选该容器的策略）
        .sheet(isPresented: $showDockerExportPicker) {
            FirewallDockerExportPickerView(vm: vm, preselectedIndices: dockerExportPreselect)
        }
        // 规则重置（R1：输入后端名确认，对齐 Web 端「请手动输入 iptables」）
        .sheet(isPresented: $showRulesReset) {
            TextInputConfirmSheet(
                title: L10n.t("重置防火墙规则"),
                message: L10n.f("将删除 %@ 中的全部 1Panel 运行时规则及规则链，仅保留数据库策略；重置后需重新初始化或同步。请输入后端名「%@」以确认。", vm.systemStatus?.backend ?? "", vm.systemStatus?.backend ?? ""),
                expectedText: vm.systemStatus?.backend ?? "",
                fieldLabel: L10n.t("确认输入"),
                fieldPlaceholder: vm.systemStatus?.backend
            ) {
                Task { await vm.resetRules() }
            }
        }
        // Docker 守护重置（R1：同款输入后端名确认；settings/operate cleanup）
        .sheet(isPresented: $showDockerReset) {
            TextInputConfirmSheet(
                title: L10n.t("重置 Docker 端口防护"),
                message: L10n.f("将删除 %@ 中的 1Panel Docker 端口防护运行时规则：删除全部相关规则及规则链，仅保留数据库数据。请输入后端名「%@」以确认。", vm.dockerGuard?.base?.backend ?? "", vm.dockerGuard?.base?.backend ?? ""),
                expectedText: vm.dockerGuard?.base?.backend ?? "",
                fieldLabel: L10n.t("确认输入"),
                fieldPlaceholder: vm.dockerGuard?.base?.backend
            ) {
                Task { await vm.resetDockerGuard() }
            }
        }
        // 转发运行时规则重置（R1：同款输入后端名确认；settings/operate cleanup）
        .sheet(isPresented: $showForwardReset) {
            TextInputConfirmSheet(
                title: L10n.t("重置端口转发规则"),
                message: L10n.f("将删除 %@ 中的 1Panel 端口转发运行时规则：删除全部相关规则及规则链，仅保留数据库数据。请输入后端名「%@」以确认。", vm.forwardStatus?.backend ?? vm.systemStatus?.backend ?? "", vm.forwardStatus?.backend ?? vm.systemStatus?.backend ?? ""),
                expectedText: vm.forwardStatus?.backend ?? vm.systemStatus?.backend ?? "",
                fieldLabel: L10n.t("确认输入"),
                fieldPlaceholder: vm.forwardStatus?.backend ?? vm.systemStatus?.backend
            ) {
                Task { await vm.resetForwarding() }
            }
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

    // MARK: 段初始化判定（未初始化：隐藏 + / 列表 / 筛选，仅显示初始化入口）

    /// iptables/nftables 有基础链初始化概念；ufw/firewalld 与状态未加载完成按已初始化处理（防闪烁）
    private var needsRulesInit: Bool {
        guard let s = vm.systemStatus else { return false }
        return (s.backend == "iptables" || s.backend == "nftables") && s.isInit != true
    }

    private var needsForwardInit: Bool {
        vm.forwardStatus?.isInit != true && vm.forwardStatus != nil
    }

    private var needsDockerInit: Bool {
        guard let base = vm.dockerGuard?.base else { return false }
        return base.isExist == true && base.initialized != true
    }

    /// 段未初始化时的占位：说明 + 初始化按钮（隐藏 +、列表与筛选）
    private func uninitializedPlaceholder(message: String, buttonTitle: String,
                                          action: @escaping () -> Void) -> some View {
        Section {
            VStack(spacing: 14) {
                Image(systemName: "wand.and.stars")
                    .font(.title)
                    .foregroundStyle(.tint)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(action: action) {
                    // 图标/文字显式白色：主题 tint 下 Label 内容可能与按钮底色
                    // 同色导致图标不可见（borderedProminent 不保证内容对比度）
                    Label(buttonTitle, systemImage: "wand.and.stars")
                        .foregroundStyle(.white)
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .disabled(vm.isOperating)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
            .listRowBackground(Color.clear)
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
                        Text(lifeStatusText)
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

    /// 生命周期状态文案：停止（不论是否初始化）→ 已停止；
    /// 运行中未初始化（iptables/nftables）→ 未初始化；运行中已初始化 → 运行中。
    /// 转发/Docker 段按各自子系统状态显示（转发 isActive 恒 false 用 isInit 判据）
    private var lifeStatusText: String {
        switch segment {
        case 1:
            guard let fs = vm.forwardStatus else { return "—" }
            return fs.isInit == true ? L10n.t("运行中") : L10n.t("未初始化")
        case 2:
            guard let base = vm.dockerGuard?.base, base.isExist == true else { return "—" }
            return base.initialized == true ? L10n.t("运行中") : L10n.t("未初始化")
        default:
            guard let s = vm.systemStatus else { return "—" }
            if s.isActive != true { return L10n.t("已停止") }
            if s.isInit != true, s.backend == "iptables" || s.backend == "nftables" {
                return L10n.t("未初始化")
            }
            return L10n.t("运行中")
        }
    }

    /// 已绑定随段取值：规则=系统基础链；转发无绑定概念；Docker=端口守护
    private var isBoundCurrent: Bool? {
        switch segment {
        case 1: return nil
        case 2: return vm.dockerGuard?.base?.bound
        default: return vm.systemStatus?.isBind
        }
    }

    private var badgesRow: some View {
        HStack(spacing: 6) {
            // 初始化状态并入头部运行状态文案，徽标行不再重复
            if isBoundCurrent == true {
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
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // iptables/nftables 无服务生命周期概念，不提供停止/重启
                if vm.systemStatus?.backend != "iptables", vm.systemStatus?.backend != "nftables" {
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
                }
                // 禁 Ping 开关移入设置页；设置入口以按钮形式收进状态抽屉
                CardActionButton(title: L10n.t("设置"), icon: "gearshape",
                                 color: .purple, busy: false) {
                    showSettings = true
                }
            }
            // 随段变化的上下文操作：同名按钮（解绑/绑定、同步规则、重置）按段传对应参数
            contextOperationsRow
        }
    }

    @ViewBuilder
    private var contextOperationsRow: some View {
        switch segment {
        case 0:
            // 规则段：基础链解绑/绑定 + 同步 + 重置 + 导入/导出（未初始化段不提供）
            if !needsRulesInit {
                HStack(spacing: 8) {
                    filterChainBindButton
                    CardActionButton(title: L10n.t("同步规则"),
                                     icon: "arrow.triangle.2.circlepath",
                                     color: .blue, busy: vm.isOperating) {
                        syncSubsystem = "system"
                        showSyncPreview = true
                    }
                    CardActionButton(title: L10n.t("重置"), icon: "trash",
                                     color: .statusError, busy: vm.isOperating) {
                        showRulesReset = true
                    }
                    CardActionButton(title: L10n.t("导入"), icon: "square.and.arrow.down",
                                     color: .teal, busy: false) {
                        showImport = true
                    }
                }
            }
        case 1:
            // 转发段：同步 + 重置 + 导入（导出走长按菜单，子系统无绑定概念）
            if !needsForwardInit {
                HStack(spacing: 8) {
                    CardActionButton(title: L10n.t("同步规则"),
                                     icon: "arrow.triangle.2.circlepath",
                                     color: .blue, busy: vm.isOperating) {
                        syncSubsystem = "forwarding"
                        showSyncPreview = true
                    }
                    CardActionButton(title: L10n.t("重置"), icon: "trash",
                                     color: .statusError, busy: vm.isOperating) {
                        showForwardReset = true
                    }
                    CardActionButton(title: L10n.t("导入"), icon: "square.and.arrow.down",
                                     color: .teal, busy: false) {
                        showForwardImport = true
                    }
                }
            }
        default:
            // Docker 段：端口守护解绑/绑定 + 同步 + 重置 + 导入/导出（未初始化/不可用不提供）
            if let base = vm.dockerGuard?.base,
               base.isExist == true, base.initialized == true {
                HStack(spacing: 8) {
                    CardActionButton(
                        title: base.bound == true ? L10n.t("解绑") : L10n.t("绑定"),
                        icon: base.bound == true ? "link.badge.plus" : "link",
                        color: base.bound == true ? .secondary : .green,
                        busy: vm.isOperating
                    ) {
                        Task { await vm.dockerOperate(base.bound == true ? "unbind" : "bind") }
                    }
                    CardActionButton(title: L10n.t("同步规则"),
                                     icon: "arrow.triangle.2.circlepath",
                                     color: .blue, busy: vm.isOperating) {
                        Task { await vm.dockerSync() }
                    }
                    CardActionButton(title: L10n.t("重置"), icon: "trash",
                                     color: .statusError, busy: vm.isOperating) {
                        showDockerReset = true
                    }
                    CardActionButton(title: L10n.t("导入"), icon: "square.and.arrow.down",
                                     color: .teal, busy: false) {
                        showDockerImport = true
                    }
                }
            }
        }
    }

    /// 规则段基础链解绑/绑定（iptables/nftables；未初始化时不提供绑定）
    @ViewBuilder
    private var filterChainBindButton: some View {
        if vm.systemStatus?.backend == "iptables" || vm.systemStatus?.backend == "nftables" {
            if vm.systemStatus?.isBind == true {
                CardActionButton(title: L10n.t("解绑"), icon: "link.badge.plus",
                                 color: .secondary, busy: vm.isOperating) {
                    Task { await vm.operateFilterChain("unbind-base") }
                }
            } else if vm.systemStatus?.isInit == true {
                CardActionButton(title: L10n.t("绑定"), icon: "link",
                                 color: .green, busy: vm.isOperating) {
                    Task { await vm.operateFilterChain("bind-base") }
                }
            }
        }
    }

    // MARK: 规则段

    private var rulesSection: some View {
        Group {
            if needsRulesInit {
                uninitializedPlaceholder(
                    message: L10n.t("初始化后将创建 1Panel 基础链并接管规则管理；完成前不可创建规则。"),
                    buttonTitle: L10n.t("初始化")
                ) {
                    Task { await vm.operateFilterChain("init-base") }
                }
            } else {
                rulesListContent
            }
        }
    }

    /// 长按规则弹窗（半屏）菜单项：可管理 → 编辑/删除/上移下移；
    /// external/drifted → 纳管；末尾固定 导出规则 + 查看原文
    private var ruleActionItems: [ActionMenuItem] {
        guard let item = actionItem else { return [] }
        var items: [ActionMenuItem] = []
        if let uuid = item.manageableUUID, let rule = item.rule {
            items.append(ActionMenuItem(title: L10n.t("编辑"), icon: "pencil", color: .blue) {
                editingRuleUUID = uuid
                editingRule = rule
            })
            items.append(ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red,
                                        role: .destructive) {
                Haptic.warning()
                pendingDeleteItem = item
            })
            if let position = item.observed?.locator?.position {
                items.append(ActionMenuItem(title: L10n.t("上移"), icon: "arrow.up", color: .orange) {
                    Task { await vm.reorderRule(uuid: uuid, to: Int64(max(1, position - 1))) }
                })
                items.append(ActionMenuItem(title: L10n.t("下移"), icon: "arrow.down", color: .orange) {
                    Task { await vm.reorderRule(uuid: uuid, to: Int64(position + 1)) }
                })
            }
        } else if item.state == "external" || item.state == "drifted" {
            items.append(ActionMenuItem(title: L10n.t("纳管"),
                                        icon: "square.and.arrow.down.on.square", color: .blue) {
                Task { await vm.adoptRule(item) }
            })
        }
        items.append(ActionMenuItem(title: L10n.t("导出规则"),
                                    icon: "square.and.arrow.up", color: .teal) {
            // 仅预选长按的这条规则（与计划任务「导出任务」语义一致）
            ruleExportPreselect = [item.id]
            showExportPicker = true
        })
        items.append(ActionMenuItem(title: L10n.t("查看原文"),
                                    icon: "doc.text.magnifyingglass", color: .gray) {
            Task {
                let text = await vm.loadNativeDetail(for: item)
                rawDetail = RawDetailPayload(
                    title: item.rule?.destinationPort ?? item.rule?.sourceAddress ?? "",
                    text: text)
            }
        })
        return items
    }

    private var rulesListContent: some View {
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
                            // 长按弹半屏操作菜单（编辑/删除/上移下移/导出规则/查看原文，或纳管）
                            .onLongPressGesture {
                                actionItem = item
                            }
                            // VoiceOver 无长按手势：以自定义操作暴露同一菜单
                            .accessibilityAction(named: L10n.t("更多操作")) {
                                actionItem = item
                            }
                            .onAppear {
                                if item.id == vm.inventory.last?.id,
                                   vm.inventory.count < vm.rulesAllTotal {
                                    Task { await vm.loadRules(replacing: false) }
                                }
                            }
                    }
                    // 加载指示行仅在仍有更多页时出现（已加载全量时不再多占一行）
                    if vm.isRulesLoadingMore && vm.inventory.count < vm.rulesAllTotal {
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
            if needsForwardInit {
                uninitializedPlaceholder(
                    message: L10n.t("启用端口转发子系统后将创建转发规则链；完成前不可创建转发。"),
                    buttonTitle: L10n.t("初始化")
                ) {
                    Task { await vm.enableForwarding() }
                }
            } else {
                forwardListContent
            }
        }
    }

    private var forwardListContent: some View {
        Group {
            // 转发子系统状态分组已移除（初始化状态并入头部，操作收进右上角菜单）
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
                            // 长按弹半屏操作菜单（编辑/删除/导出规则）
                            .onLongPressGesture { actionForward = rule }
                            // VoiceOver 无长按手势：以自定义操作暴露同一菜单
                            .accessibilityAction(named: L10n.t("更多操作")) { actionForward = rule }
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
                if needsDockerInit {
                    uninitializedPlaceholder(
                        message: L10n.t("初始化容器端口防护后将接管已发布端口的访问控制；完成前不可配置策略。"),
                        buttonTitle: L10n.t("初始化")
                    ) {
                        Task { await vm.dockerOperate("initialize") }
                    }
                } else {
                    dockerListContent(guard_, base)
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

    /// Docker 段主内容（已初始化）：容器入口行 + 孤立策略
    private func dockerListContent(_ guard_: DockerGuardList, _ base: DockerGuardBase) -> some View {
        Group {
                ForEach(guard_.containers ?? []) { container in
                    DockerGuardContainerSection(
                        container: container,
                        onEditPolicy: { endpoint in
                            if endpoint.managementTarget == "host_firewall" {
                                vm.toastMessage = L10n.t("该端点由主机防火墙规则管理，请在规则段调整")
                            } else {
                                editingPolicy = endpoint
                            }
                        },
                        onExport: {
                            // 仅预选该容器的策略（与计划任务「导出任务」语义一致）
                            dockerExportPreselect = vm.dockerExportableIndices(containerID: container.id)
                            showDockerExportPicker = true
                        }
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
        }
    }
}

// MARK: - 设置页（状态抽屉按钮进入）

/// 防火墙设置：禁 Ping / 面板端口白名单 / 三组防护后端。
/// 后端（系统防火墙 / 端口转发 / 容器端口防护）用下拉选择，切换需弹窗确认
private struct FirewallSettingsPageView: View {
    @ObservedObject var vm: FirewallViewModel

    /// 待确认的后端切换（弹窗确认后才下发 select）
    @State private var pendingSwitch: BackendSwitch?
    /// 被拦截的切换（当前后端仍含运行时规则，仅提示不发请求）
    @State private var blockedSwitch: (current: String, target: String)?

    struct BackendSwitch: Identifiable {
        let subsystem: String
        let backend: String
        var id: String { "\(subsystem)/\(backend)" }
    }

    var body: some View {
        Form {
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

            backendPickerSection(title: L10n.t("系统防火墙"), subsystem: "system",
                                 group: vm.settings?.system)
            backendPickerSection(title: L10n.t("端口转发"), subsystem: "forwarding",
                                 group: vm.settings?.forwarding)
            backendPickerSection(title: L10n.t("容器端口防护"), subsystem: "docker",
                                 group: vm.settings?.docker)
        }
        .navigationTitle(L10n.t("设置"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        // 下拉切换后端：弹窗确认（确认后 select，取消回弹为当前后端）
        .alert(L10n.t("确认"), isPresented: Binding(
            get: { pendingSwitch != nil },
            set: { if !$0 { pendingSwitch = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingSwitch = nil }
            Button(L10n.t("确认"), role: .destructive) {
                Haptic.warning()
                guard let sw = pendingSwitch else { return }
                pendingSwitch = nil
                Task {
                    await vm.operateBackend(subsystem: sw.subsystem, backend: sw.backend,
                                            operation: "select")
                }
            }
        } message: {
            Text(L10n.f("确认切换为 %@？", pendingSwitch?.backend ?? ""))
        }
        // 切换被拦：当前后端仍含 1Panel 运行时规则，须先重置（仅提示，不发请求）
        .alert(L10n.t("重置"), isPresented: Binding(
            get: { blockedSwitch != nil },
            set: { if !$0 { blockedSwitch = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) { blockedSwitch = nil }
        } message: {
            Text(L10n.f("当前后端 %@ 仍存在 1Panel 运行时规则，请先重置该后端，再切换到 %@。重置仅清理运行时规则，数据库策略会保留，切换后可以重新初始化或同步。", blockedSwitch?.current ?? "", blockedSwitch?.target ?? ""))
        }
    }

    /// 单组防护后端：形态 3 描边菜单（未安装 / 不支持的选项不展示，
    /// 当前选中不在可选列表时兜底保留，避免无效 selection）
    private func backendPickerSection(title: String, subsystem: String,
                                      group: FirewallBackendGroup?) -> some View {
        Section {
            OutlinedPicker(label: title,
                           options: backendOptionKeys(group: group),
                           selection: backendBinding(subsystem: subsystem, group: group),
                           optionLabels: backendOptionLabels(group: group))
                .disabled(vm.isOperating)
        } header: {
            SectionLabel(title: title, systemImage: "server.rack")
        } footer: {
            if let reason = unusableReason(group: group) {
                Text(reason)
            } else {
                Text(L10n.t("切换防护后端将重建对应规则链，期间服务可能短暂中断"))
            }
        }
    }

    /// 可选后端键：可用选项 + 当前选中兜底（去重）
    private func backendOptionKeys(group: FirewallBackendGroup?) -> [String] {
        var keys = (group?.options ?? [])
            .filter { $0.installed == true && $0.supported != false }
            .compactMap { $0.name }
        if let selected = group?.selected, !selected.isEmpty,
           !(group?.options ?? []).contains(where: { $0.name == selected && $0.installed == true && $0.supported != false }) {
            keys.insert(selected, at: 0)
        }
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    private func backendOptionLabels(group: FirewallBackendGroup?) -> [String: String] {
        var labels: [String: String] = [:]
        for option in group?.options ?? [] {
            if let name = option.name { labels[name] = name.uppercased() }
        }
        if let selected = group?.selected { labels[selected] = selected.uppercased() }
        return labels
    }

    /// 选择值真源是服务端的 group.selected；用户改选仅触发确认弹窗，不直接落状态。
    /// 当前后端仍含运行时规则（settings options 中当前 name 的 initialized=true）
    /// 时不发请求，改弹「请先重置」提示（服务端此时返回 409 FW_BACKEND_CLEANUP_REQUIRED）
    private func backendBinding(subsystem: String, group: FirewallBackendGroup?) -> Binding<String> {
        Binding<String>(
            get: { group?.selected ?? "" },
            set: { chosen in
                guard let group, !chosen.isEmpty, chosen != group.selected else { return }
                if group.currentInitialized {
                    blockedSwitch = (current: group.current ?? group.selected ?? "", target: chosen)
                    return
                }
                pendingSwitch = BackendSwitch(subsystem: subsystem, backend: chosen)
            }
        )
    }

    /// 当前选中项不可用时给出原因（如「未安装 / 由发行版管控」）
    private func unusableReason(group: FirewallBackendGroup?) -> String? {
        guard let group, let selected = group.selected else { return nil }
        guard let option = (group.options ?? []).first(where: { $0.name == selected }) else {
            return nil
        }
        let reason = option.supportReason ?? option.message ?? ""
        return reason.isEmpty ? nil : L10n.f("%@：%@", selected.uppercased(), reason)
    }
}

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
    var onEditPolicy: (DockerGuardEndpoint) -> Void = { _ in }
    /// 长按「导出规则」入口
    var onExport: () -> Void = {}

    /// 容器下平铺 endpoints（ipv4/ipv6 各一条）；portGroups 为 DTO 保留形态，
    /// 两者并集、按 id 去重（抓包 2026-09-17）
    private var endpoints: [DockerGuardEndpoint] {
        let groupEndpoints = (container.portGroups ?? []).compactMap { $0.endpoint }
        var seen = Set<String>()
        return ((container.endpoints ?? []) + groupEndpoints).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        Section {
            NavigationLink {
                DockerGuardEndpointsView(container: container, onEditPolicy: onEditPolicy)
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "shippingbox.fill")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(container.name ?? "—")
                            .font(.subheadline.bold())
                        // 第二行：应用名（缺省回落 compose）
                        Text(container.application?.isEmpty == false
                             ? container.application! : (container.compose ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if endpoints.isEmpty {
                        Text(L10n.t("未发布端口"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L10n.f("%ld 条", endpoints.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // 长按弹半屏菜单（导出规则）
            .onLongPressGesture { onExport() }
            // VoiceOver 无长按手势：以自定义操作暴露同一菜单
            .accessibilityAction(named: L10n.t("更多操作")) { onExport() }
        }
    }
}

// MARK: - 容器端口规则展示页（入口行进入）

/// 容器端口规则只读展示（形态 8「行即 Section」对应式，不提供添加/删除）：
/// 每条规则 = 来源（形态 1）+ 目标（形态 1）+ 防护模式（标签为模式名，内容为
/// sources，形态 7.1）；点击规则进入防护策略编辑
struct DockerGuardEndpointsView: View {
    let container: DockerGuardContainer
    var onEditPolicy: (DockerGuardEndpoint) -> Void = { _ in }

    private let modeLabels = [
        "deny_sources": L10n.t("禁止指定来源"),
        "allow_sources": L10n.t("仅允许指定来源"),
        "deny_all": L10n.t("禁止所有访问"),
    ]

    private var endpoints: [DockerGuardEndpoint] {
        let groupEndpoints = (container.portGroups ?? []).compactMap { $0.endpoint }
        var seen = Set<String>()
        return ((container.endpoints ?? []) + groupEndpoints).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        Form {
            if endpoints.isEmpty {
                Section {
                    ContentUnavailableView(L10n.t("未发布端口"), systemImage: "shippingbox")
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .listRowBackground(Color.clear)
                }
            } else {
                ForEach(endpoints) { endpoint in
                    endpointSection(endpoint)
                }
            }
        }
        .navigationTitle(container.name ?? "—")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func endpointSection(_ endpoint: DockerGuardEndpoint) -> some View {
        Section {
            OutlinedShape(label: L10n.t("来源"), isFocused: false,
                          hasValue: sourceText(endpoint) != L10n.t("未设置"),
                          trailing: { EmptyView() }) {
                Text(sourceText(endpoint))
                    .font(.dataMonospacedBody)
                    .lineLimit(1)
            }
            OutlinedShape(label: L10n.t("目标"), isFocused: false,
                          hasValue: targetText(endpoint) != L10n.t("未设置"),
                          trailing: { EmptyView() }) {
                Text(targetText(endpoint))
                    .font(.dataMonospacedBody)
                    .lineLimit(1)
            }
            OutlinedMultiLineField(
                label: endpoint.mode.flatMap { modeLabels[$0] } ?? L10n.t("防护模式"),
                text: .constant(sourcesText(endpoint)))
                .disabled(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { onEditPolicy(endpoint) }
    }

    /// 来源 = 主机 IP + 端口；缺任一显示未设置
    private func sourceText(_ endpoint: DockerGuardEndpoint) -> String {
        if let ip = endpoint.hostIP, let port = endpoint.hostPort {
            return "\(ip):\(port)"
        }
        return L10n.t("未设置")
    }

    /// 目标 = 容器端口 + 协议；缺任一显示未设置
    private func targetText(_ endpoint: DockerGuardEndpoint) -> String {
        if let port = endpoint.containerPort, let proto = endpoint.protocolField {
            return "\(port)/\(proto.uppercased())"
        }
        return L10n.t("未设置")
    }

    /// 防护模式内容 = sources（每行一条）；空（deny_all 或未配置）显示未设置
    private func sourcesText(_ endpoint: DockerGuardEndpoint) -> String {
        let list = (endpoint.sources ?? []).filter { !$0.isEmpty }
        return list.isEmpty ? L10n.t("未设置") : list.joined(separator: "\n")
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
