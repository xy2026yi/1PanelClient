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
    /// 链内优先级可设范围（搜索响应 ipv4Range/ipv6Range；编辑表单提示用）
    @Published var rulesIPv4Range: FirewallPositionRange?
    @Published var rulesIPv6Range: FirewallPositionRange?
    @Published private(set) var isRulesLoadingMore = false
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
    /// 任务式操作的进度页目标（init-base / 初始化恢复 / forward enable / 白名单 / Docker 初始化）
    @Published var activeTask: FirewallTaskTarget?
    /// 规则备份列表（rules/backups；「初始化并恢复规则」流程按需加载，
    /// 三段共享一份缓存——换段立即作废，防闪显他段备份文件）
    @Published var ruleBackups: FirewallRuleBackupsResponse?
    @Published var isLoadingBackups = false
    /// 备份列表加载失败（恢复 sheet 内展示 + 重试；不占用整页 errorMessage）
    @Published var ruleBackupsError: String?
    /// 缓存/在途加载所属段（system / docker / forwarding）
    private var ruleBackupsSubsystem: String?
    /// 备份加载代际（丢弃换段后乱序到达的过期响应）
    private var backupsGeneration = 0
    /// 备份后重置的结果（含服务器保存路径；弹窗提醒后清除）
    @Published var lastResetResult: FirewallRuleResetResponse?
    /// 端口+协议 → 监听进程名（键 "端口|tcp" / "端口|udp"；process/listening 裸数组）
    @Published var portProcessNames: [String: String] = [:]
    /// 端口 → 监听进程名（无协议维度兜底；协议未命中时使用）
    @Published var portAnyProcessNames: [String: String] = [:]
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
        req.info = ruleSearchText
        req.families = ruleFamilyFilter.map { [$0] }
        do {
            let resp: FirewallRuleInventoryResponse = try await client.send(
                path: APIEndpoint.firewallRulesSearch.path, body: req,
                as: FirewallRuleInventoryResponse.self
            )
            guard generation == rulesGeneration else { return }
            // 刚删除的规则在服务端运行时摘除完成前会短暂回显（残影），
            // 窗口期内本地过滤（见 deleteRule）
            pruneExpiredDeletedRuleKeys()
            let filtered = (resp.items ?? []).filter { item in
                guard let key = item.operationTarget?.instanceKey else { return true }
                return recentlyDeletedRuleKeys[key] == nil
            }
            if replacing {
                inventory = filtered
            } else {
                inventory += filtered
            }
            rulesPage = req.page
            rulesAllTotal = resp.allTotal ?? resp.total ?? inventory.count
            rulesResultTotal = resp.total ?? resp.allTotal ?? inventory.count
            rulesIPv4Range = resp.ipv4Range
            rulesIPv6Range = resp.ipv6Range
            errorMessage = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            guard generation == rulesGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// 建规则（统一模型：端口/IP 规则都是 FirewallRule）
    func createRule(_ rule: FirewallRule) async -> Bool {
        await submitRules(FirewallRuleCreateRequest(
            items: [FirewallRuleCreateItem(rule: rule, sourceKind: "user")]))
    }

    /// 编辑规则：整规则替换（rule 内携带 orderIndex）与仅改优先级（顶层 orderIndex、
    /// rule 为 nil）互斥——同传会被面板 excluded_with 校验拒绝。
    /// v2.4.0 操作键 = (scope, instanceKey)
    func updateRule(target: FirewallRuleOperationTarget, rule: FirewallRule?,
                    orderIndex: Int64?) async -> Bool {
        isOperating = true
        defer { isOperating = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.firewallRulesUpdate.path,
                body: FirewallRuleUpdateRequest(
                    scope: target.scope, instanceKey: target.instanceKey,
                    rule: rule, descriptionText: nil,
                    orderIndex: rule == nil ? orderIndex : nil),
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

    /// 删除规则（v2.4.0：targets[{scope,instanceKey,observed}]，observed 原样回传
    /// 供服务端匹配活规则）
    func deleteRule(_ item: FirewallInventoryItem) async {
        guard let target = item.operationTarget, let observed = item.observed else { return }
        isOperating = true
        defer { isOperating = false }
        do {
            let _: FirewallRuleDeleteResponse = try await client.send(
                path: APIEndpoint.firewallRulesDelete.path,
                body: FirewallRuleDeleteRequest(targets: [FirewallRuleDeleteItem(
                    scope: target.scope, instanceKey: target.instanceKey, observed: observed)]),
                as: FirewallRuleDeleteResponse.self
            )
            // rules/delete 的运行时摘除是异步任务：立即重拉会短暂回显残影
            //（下拉刷新才消失）。先本地移除整行，再在窗口期内把该 instanceKey
            // 从后续搜索结果中滤掉，直到服务端状态收敛
            recentlyDeletedRuleKeys[target.instanceKey] =
                Date().addingTimeInterval(Self.deletedRuleFilterWindow)
            inventory.removeAll { $0.operationTarget?.instanceKey == target.instanceKey }
            await loadRules(replacing: true)
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// 刚删除规则的 instanceKey → 过滤截止时间
    private var recentlyDeletedRuleKeys: [String: Date] = [:]
    private static let deletedRuleFilterWindow: TimeInterval = 60

    private func pruneExpiredDeletedRuleKeys() {
        let now = Date()
        recentlyDeletedRuleKeys = recentlyDeletedRuleKeys.filter { $0.value > now }
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
    /// 转发批量操作（v2.4.0：forceDelete 已被 import 取代，普通删除不设标志）
    func submitForward(_ operations: [FirewallForwardOperation], isImport: Bool = false) async -> Bool {
        isOperating = true
        defer { isOperating = false }
        do {
            let resp: FirewallTaskResponse = try await client.send(
                path: APIEndpoint.firewallForwardOperate.path,
                body: FirewallForwardOperateRequest(isImport: isImport, rules: operations),
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

    /// 启用转发子系统（forward/enable，任务式；抓包 2026-10-22：仅初始化由客户端
    /// 生成 taskID 携带，初始化并恢复规则携带 backupFile 不带 taskID）。
    /// 返回是否成功（恢复选择的 sheet 据此 dismiss）
    @discardableResult
    func enableForwarding(backupFile: String? = nil) async -> Bool {
        isOperating = true
        defer { isOperating = false }
        do {
            let resp: FirewallTaskResponse = try await client.send(
                path: APIEndpoint.firewallForwardEnable.path,
                body: FirewallForwardEnableRequest(
                    taskID: backupFile == nil ? UUID().uuidString.lowercased() : nil,
                    backupFile: backupFile),
                as: FirewallTaskResponse.self
            )
            if let taskID = resp.taskID, !taskID.isEmpty {
                // 启用/恢复任务在服务端异步建链，完成返回时整页刷新校准
                activeTask = FirewallTaskTarget(taskID: taskID, title: L10n.t("启用端口转发"),
                                                refreshAfterDone: true)
            }
            await loadForwardStatus()
            await loadForwards(replacing: true)
            return true
        } catch {
            guard !APIError.isCancellation(error) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: 规则重置 / 备份 / Docker 策略（v2.4.0：上游移除 rules/sync 全家，不再提供同步）

    /// 重置运行时规则（rules/reset，三段统一；R1：调用方需先经输入后端名确认）。
    /// backup=true 时服务端先落备份文件，成功后经 lastResetResult 弹窗展示保存路径。
    /// 抓包 2026-10-21（system）+ 2026-10-22（docker/forwarding 显式携带 subsystem，
    /// 响应 {backupPath, removed, disabled}，重置后子系统回到未初始化态）
    func resetRules(subsystem: String = "system", backup: Bool) async {
        isOperating = true
        defer { isOperating = false }
        let provider: String?
        switch subsystem {
        case "docker": provider = dockerGuard?.base?.backend
        case "forwarding": provider = forwardStatus?.backend ?? systemStatus?.backend
        default: provider = systemStatus?.backend
        }
        do {
            let resp: FirewallRuleResetResponse = try await client.send(
                path: APIEndpoint.firewallRulesReset.path,
                body: FirewallRuleResetRequest(
                    subsystem: subsystem == "system" ? nil : subsystem,
                    backup: backup, provider: provider,
                    withDockerRestart: subsystem == "system" ? false : nil),
                as: FirewallRuleResetResponse.self
            )
            if backup, let path = resp.backupPath, !path.isEmpty {
                lastResetResult = resp
            } else {
                toastMessage = L10n.f("已重置：移除 %ld 条规则", resp.removed ?? 0)
            }
            switch subsystem {
            case "docker":
                await loadDockerGuard()
            case "forwarding":
                await loadForwardStatus()
                await loadForwards(replacing: true)
            default:
                await loadSystemStatus()
                await loadRules(replacing: true)
            }
            // 重置会改变 settings 各组当前后端的 initialized，同步刷新供切换预检
            await loadSettings()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// 规则备份列表（rules/backups?subsystem=…；各段「初始化并恢复规则」的选择来源。
    /// 抓包 2026-10-22：docker/forwarding 各自目录独立，subsystem 取
    /// system/docker/forwarding）。
    /// 三段共用一份缓存：换段立即作废旧缓存并作废在途响应（代际）——否则
    /// 他段旧文件会闪显甚至长期滞留（在途加载互相挡掉时不被替换）
    func loadRuleBackups(subsystem: String = "system") async {
        if ruleBackupsSubsystem != subsystem {
            ruleBackupsSubsystem = subsystem
            ruleBackups = nil
            ruleBackupsError = nil
        }
        backupsGeneration += 1
        let generation = backupsGeneration
        isLoadingBackups = true
        defer { isLoadingBackups = false }
        do {
            let resp: FirewallRuleBackupsResponse = try await client.send(
                path: APIEndpoint.firewallRulesBackups.path, method: "GET",
                queryItems: [URLQueryItem(name: "subsystem", value: subsystem)],
                as: FirewallRuleBackupsResponse.self
            )
            guard generation == backupsGeneration else { return }
            ruleBackups = resp
        } catch {
            guard !APIError.isCancellation(error) else { return }
            guard generation == backupsGeneration else { return }
            ruleBackupsError = error.localizedDescription
        }
    }

    /// 初始化并恢复规则（抓包 2026-10-21：POST rules
    /// {"initialize":true,"backupFile":…,"items":[]}，任务式）
    func initializeWithRestore(backupFile: String) async -> Bool {
        isOperating = true
        defer { isOperating = false }
        do {
            let resp: FirewallRuleCreateResponse = try await client.send(
                path: APIEndpoint.firewallRulesCreate.path,
                body: FirewallRuleCreateRequest(items: [], initialize: true,
                                                backupFile: backupFile),
                as: FirewallRuleCreateResponse.self
            )
            if let taskID = resp.taskID, !taskID.isEmpty {
                activeTask = FirewallTaskTarget(taskID: taskID,
                                                title: L10n.t("初始化并恢复规则"),
                                                refreshAfterDone: true)
            }
            await loadSystemStatus()
            return true
        } catch {
            guard !APIError.isCancellation(error) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Docker 端口守护重置（settings/operate cleanup；R1：调用方需先经输入后端名确认）
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

    // MARK: 排序 / 原文 / 导入导出（低频操作；v2.4.0 上游移除纳管端点）

    /// 链内位置调整（上移/下移一位；v2.4.0 操作键 = scope+instanceKey）
    func reorderRule(target: FirewallRuleOperationTarget, to position: Int64) async {
        isOperating = true
        defer { isOperating = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.firewallRulesReorder.path,
                body: FirewallRuleReorderRequest(scope: target.scope,
                                                 instanceKey: target.instanceKey,
                                                 targetPosition: position, priority: nil),
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
                    items: rules.map { FirewallRuleCreateItem(rule: $0, sourceKind: "imported") }),
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
    /// （无服务端端点），落盘 Documents/Exports
    func exportRules(for items: [FirewallInventoryItem]? = nil) -> LocalDownloads.Saved? {
        let exportable = items ?? inventory.filter { item in
            guard item.operationTarget != nil, !item.isProtected else { return false }
            return true
        }
        guard !exportable.isEmpty else { return nil }
        let rules = exportable.compactMap { item -> FirewallRule? in
            guard var rule = item.rule else { return nil }
            rule.uuid = nil
            return rule
        }
        return Self.saveExport(rules, prefix: "1panel-firewall-rules")
    }

    /// 导出转发规则（本地组 JSON，无服务端端点；清 id/num 等运行时字段；
    /// 传入子集时长按菜单多选导出，nil = 全量）
    func exportForwards(for rules: [FirewallForwardRule]? = nil) -> LocalDownloads.Saved? {
        let list = rules ?? forwards
        guard !list.isEmpty else { return nil }
        let cleaned = list.map { rule -> FirewallForwardRule in
            var r = rule
            r.id = nil
            r.num = nil
            return r
        }
        return Self.saveExport(cleaned, prefix: "1panel-firewall-forwards")
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
                descriptionText: rule.descriptionText)
        }
        do {
            let resp: FirewallTaskResponse = try await client.send(
                path: APIEndpoint.firewallForwardOperate.path,
                body: FirewallForwardOperateRequest(isImport: true, rules: ops),
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
    func exportDockerPolicies(for policies: [DockerGuardPolicy]? = nil) -> LocalDownloads.Saved? {
        let list = policies ?? allExportableDockerPolicies()
        guard !list.isEmpty else { return nil }
        return Self.saveExport(list, prefix: "1panel-firewall-docker")
    }

    /// 本地组 JSON 落盘 Documents/Exports/<prefix>-yyyyMMddHHmmss.json；编码或写入失败返回 nil
    private static func saveExport<T: Encodable>(_ value: T, prefix: String) -> LocalDownloads.Saved? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        return try? LocalDownloads.save(
            data: data,
            fileName: "\(prefix)-\(formatter.string(from: Date())).json",
            category: .exports)
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
                sources: ep.sources ?? [])
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
            // 禁 Ping 开关读的是 settings.pingStatus：不重拉设置段，
            // 开关会被旧值弹回（systemStatus 与 settings 各有一份 pingStatus）
            if operation == "enableBanPing" || operation == "disableBanPing" {
                await loadSettings()
            }
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// 基础链：init-base / bind-base / unbind-base（iptables/nftables）。
    /// taskID 与 Web 端一致由客户端生成（抓包 2026-10-21：请求即携带 UUID，
    /// 响应原样回显；服务端对缺省也会生成，这里显式带上保证一致）
    func operateFilterChain(_ operate: String) async {
        isOperating = true
        defer { isOperating = false }
        let clientTaskID = UUID().uuidString.lowercased()
        do {
            let resp: FirewallTaskResponse = try await client.send(
                path: APIEndpoint.firewallFilterOperate.path,
                body: FirewallFilterOperateRequest(name: "1PANEL_BASIC", operate: operate,
                                                   taskID: clientTaskID),
                as: FirewallTaskResponse.self
            )
            if let taskID = resp.taskID, !taskID.isEmpty {
                // 初始化/绑定/解绑的任务效应落在规则清单上，完成返回时整页刷新校准
                activeTask = FirewallTaskTarget(taskID: taskID, title: L10n.t("防火墙初始化"),
                                                refreshAfterDone: true)
            }
            await loadSystemStatus()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// 单地址族操作（family/operate，任务式；抓包 2026-10-21：
    /// {"subsystem":"system","backend":"iptables","family":"ipv6",
    ///  "operation":"initialize"|"bind"}，进度走通用任务页。
    ///  抓包 2026-10-22：Docker 段 {"subsystem":"docker",…,"operation":"bind"}
    ///  （任务日志「容器端口防护」）与转发段 {"subsystem":"forwarding",…,
    ///  "operation":"initialize"}（Web 端「IPv6 转发尚未启用」入口））
    func operateFamily(_ family: String, operation: String, subsystem: String = "system") async {
        let backend: String?
        switch subsystem {
        case "docker": backend = dockerGuard?.base?.backend
        case "forwarding": backend = forwardStatus?.backend ?? systemStatus?.backend
        default: backend = systemStatus?.backend
        }
        guard let backend else { return }
        isOperating = true
        defer { isOperating = false }
        do {
            let resp: FirewallTaskResponse = try await client.send(
                path: APIEndpoint.firewallFamilyOperate.path,
                body: FirewallFamilyOperateRequest(subsystem: subsystem, backend: backend,
                                                   family: family, operation: operation),
                as: FirewallTaskResponse.self
            )
            if let taskID = resp.taskID, !taskID.isEmpty {
                let prefix: String
                switch subsystem {
                case "docker": prefix = L10n.t("容器端口防护")
                case "forwarding": prefix = L10n.t("端口转发")
                default: prefix = L10n.t("1PANEL_BASIC 链")
                }
                activeTask = FirewallTaskTarget(
                    taskID: taskID,
                    title: "\(family.uppercased()) · \(prefix) · \(Self.familyActionName(operation))",
                    refreshAfterDone: true)
            }
            switch subsystem {
            case "docker":
                await loadDockerGuard()
            case "forwarding":
                await loadForwardStatus()
            default:
                await loadSystemStatus()
            }
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// family/operate 动作名（任务标题/按钮共用）
    nonisolated static func familyActionName(_ operation: String) -> String {
        switch operation {
        case "initialize": return L10n.t("初始化")
        case "repair": return L10n.t("修复")
        case "bind": return L10n.t("绑定")
        default: return operation
        }
    }

    /// 规则段的地址族待办派生（Web 端在规则列表区暴露「IPv6 · 1PANEL_BASIC 链 ·
    /// 未初始化」同款入口，仅规则段展示；抓包 2026-10-21）：available 且 partial →
    /// repair；available 未初始化 → initialize；已初始化未绑定 → bind；
    /// 健康/不可用不展示。仅 iptables/nftables、整体已初始化
    /// （整体未初始化走全局初始化流程）、IPv6 支持开启（ipv6Enabled）时才有族级行
    nonisolated static func familyAttention(
        _ status: FirewallSubsystemStatus?
    ) -> [FirewallFamilyAttention] {
        guard let s = status,
              s.backend == "iptables" || s.backend == "nftables",
              s.isInit == true else { return [] }
        var result: [FirewallFamilyAttention] = []
        for family in ["ipv4", "ipv6"] {
            guard let fs = family == "ipv4" ? s.ipv4 : s.ipv6 else { continue }
            if family == "ipv6", s.ipv6Enabled == false { continue }
            guard fs.available == true else { continue }
            if fs.partial == true {
                result.append(FirewallFamilyAttention(family: family, operation: "repair"))
            } else if fs.initialized != true {
                result.append(FirewallFamilyAttention(family: family, operation: "initialize"))
            } else if fs.bound != true {
                result.append(FirewallFamilyAttention(family: family, operation: "bind"))
            }
        }
        return result
    }

    /// Docker 段的地址族待办派生（Web 端 Docker 页「IPv6 容器端口防护尚未绑定，
    /// 因此当前不生效，请重新绑定」同款入口，仅 Docker 段展示；抓包 2026-10-22）：
    /// 派生顺序与 system 一致（partial → repair / 未初始化 → initialize /
    /// 已初始化未绑定 → bind，健康不展示）。门禁：守护存在且整体已初始化
    /// （未初始化走段内全局初始化流程）、iptables/nftables、IPv6 支持开启；
    /// Docker 族状态无 available 字段（有 state/reason/effective），不作该项门禁
    nonisolated static func dockerFamilyAttention(
        _ base: DockerGuardBase?
    ) -> [FirewallFamilyAttention] {
        guard let b = base,
              b.isExist == true, b.initialized == true,
              b.backend == "iptables" || b.backend == "nftables" else { return [] }
        var result: [FirewallFamilyAttention] = []
        for family in ["ipv4", "ipv6"] {
            if family == "ipv6", b.ipv6Enabled == false { continue }
            guard let fs = family == "ipv4" ? b.ipv4 : b.ipv6 else { continue }
            if fs.partial == true {
                result.append(FirewallFamilyAttention(family: family, operation: "repair"))
            } else if fs.initialized != true {
                result.append(FirewallFamilyAttention(family: family, operation: "initialize"))
            } else if fs.bound != true {
                result.append(FirewallFamilyAttention(family: family, operation: "bind"))
            }
        }
        return result
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

    /// Docker 守护操作。initialize 两种形态（抓包 2026-10-22）：仅初始化由客户端
    /// 生成 taskID 随请求携带（对齐 Web 行为），初始化并恢复规则携带 backupFile
    /// 而不带 taskID；bind/unbind 返回 null（抓包 2026-09-17）。
    /// 返回是否成功（恢复选择的 sheet 据此 dismiss）
    @discardableResult
    func dockerOperate(_ operation: String, backupFile: String? = nil) async -> Bool {
        isOperating = true
        defer { isOperating = false }
        do {
            if operation == "initialize" {
                let resp: FirewallTaskResponse = try await client.send(
                    path: APIEndpoint.firewallDockerOperate.path,
                    body: DockerGuardOperateRequest(
                        operation: operation,
                        taskID: backupFile == nil ? UUID().uuidString.lowercased() : nil,
                        backupFile: backupFile),
                    as: FirewallTaskResponse.self
                )
                if let taskID = resp.taskID, !taskID.isEmpty {
                    // 初始化/恢复任务在服务端异步接管端口，完成返回时整页刷新校准
                    activeTask = FirewallTaskTarget(taskID: taskID, title: L10n.t("容器端口防护"),
                                                    refreshAfterDone: true)
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
            return true
        } catch {
            guard !APIError.isCancellation(error) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteDockerPolicy(_ endpoint: DockerGuardEndpoint) async {
        guard let uuid = endpoint.policyUUID, !uuid.isEmpty else { return }
        isOperating = true
        defer { isOperating = false }
        do {
            // 抓包 2026-10-22：{"uuids":[…]} → {taskID,queued}；删除在服务端
            // 异步生效，进进度页、完成返回整页刷新校准（防立即重拉的残影）
            let resp: FirewallTaskResponse = try await client.send(
                path: APIEndpoint.firewallDockerPolicyDelete.path,
                body: DockerGuardPolicyDeleteRequest(uuids: [uuid]),
                as: FirewallTaskResponse.self
            )
            if let taskID = resp.taskID, !taskID.isEmpty {
                activeTask = FirewallTaskTarget(taskID: taskID,
                                                title: L10n.t("删除防护策略"),
                                                refreshAfterDone: true)
            }
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
            let loaded = try await client.send(
                path: APIEndpoint.firewallSettings.path, method: "GET",
                as: FirewallSettings.self
            )
            // 健全性校验：信封解码失败会静默回落裸 JSON 解码，全字段可选的
            // 模型解出全 nil 也算「成功」（「防火墙设置全空」事故的完整症状
            // 链）。关键字段全空视为失败报错，宁可暴露问题也不展示假数据
            if loaded.system == nil, loaded.forwarding == nil, loaded.docker == nil,
               loaded.pingStatus == nil, loaded.panelPort == nil, loaded.sshPort == nil,
               loaded.portWhiteList == nil {
                throw APIError.decodingError(L10n.t("响应缺少防火墙设置字段"))
            }
            settings = loaded
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

    /// IPv6 支持开关（settings/ipv6，v2.4.0；抓包 2026-10-21：{status:Enable|Disable}
    /// 任务式——后台逐子系统解绑/重建 IPv6 族）。乐观更新本地态防开关回弹，
    /// 完成返回时经 refreshAfterDone 整页校准（规则/白名单/容器 IPv6 端口都会变）
    func setIPv6Enabled(_ enabled: Bool) async {
        isOperating = true
        defer { isOperating = false }
        do {
            let resp: FirewallTaskResponse = try await client.send(
                path: APIEndpoint.firewallSettingsIPv6.path,
                body: FirewallIPv6StatusRequest(status: enabled ? "Enable" : "Disable"),
                as: FirewallTaskResponse.self
            )
            settings?.ipv6Enabled = enabled
            if let taskID = resp.taskID, !taskID.isEmpty {
                activeTask = FirewallTaskTarget(taskID: taskID,
                                                title: L10n.t("设置 IPv6 支持"),
                                                refreshAfterDone: true)
            }
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// 面板端口白名单（v2.3.1 逐条写）。差异配对不按含 sources 的行 id：
    /// id 含 sources 后「仅改来源」会退化成删+建，对 ssh/panel 条目
    /// （服务端按 type 键控）有风险。改为：全等条目跳过；剩余按
    /// type|协议|端口 配对走 /update（改来源/改端口均覆盖）；配不上
    /// 的旧条目 /delete、新条目 /whitelist
    func savePortWhitelist(
        original: [FirewallPortWhitelistEntry],
        entries: [FirewallPortWhitelistEntry]
    ) async -> Bool {
        isOperating = true
        defer { isOperating = false }
        do {
            var pendingOld = original
            var updates: [(old: FirewallPortWhitelistEntry, new: FirewallPortWhitelistEntry)] = []
            var creates: [FirewallPortWhitelistEntry] = []
            for entry in entries {
                if let idx = pendingOld.firstIndex(of: entry) {
                    pendingOld.remove(at: idx)
                    continue
                }
                if let idx = pendingOld.firstIndex(where: {
                    $0.type == entry.type && $0.protocolField == entry.protocolField && $0.port == entry.port
                }) {
                    updates.append((pendingOld[idx], entry))
                    pendingOld.remove(at: idx)
                } else {
                    creates.append(entry)
                }
            }
            for old in pendingOld {
                let _: EmptyResponse = try await client.send(
                    path: APIEndpoint.firewallSettingsWhitelistDelete.path,
                    body: FirewallWhitelistRuleRequest(rule: old),
                    as: EmptyResponse.self
                )
            }
            for update in updates {
                let _: EmptyResponse = try await client.send(
                    path: APIEndpoint.firewallSettingsWhitelistUpdate.path,
                    body: FirewallWhitelistRuleUpdateRequest(oldRule: update.old, rule: update.new),
                    as: EmptyResponse.self
                )
            }
            for entry in creates {
                let _: EmptyResponse = try await client.send(
                    path: APIEndpoint.firewallSettingsWhitelist.path,
                    body: FirewallWhitelistRuleRequest(rule: entry),
                    as: EmptyResponse.self
                )
            }
            await loadSettings()
            toastMessage = L10n.t("白名单已提交")
            return true
        } catch {
            guard !APIError.isCancellation(error) else { return false }
            errorMessage = error.localizedDescription
            // 先删后写中途失败：本地与服务器已分叉，重拉对齐（调用方以重拉
            // 结果重建基线），否则下次保存会重放已生效的 delete 永远失败
            await loadSettings()
            return false
        }
    }

    // MARK: 辅助

    /// /process/listening 响应元素：data 为裸数组（无分页信封），
    /// Port 是「端口号 → 空对象」映射，Protocol 1=tcp 2=udp（3/4 为 v6 同义）
    private struct ListeningProcessItem: Decodable {
        struct EmptyObject: Decodable {}
        let pid: Int?
        let port: [String: EmptyObject]?
        let protocolField: Int?
        let name: String?

        enum CodingKeys: String, CodingKey {
            case pid = "PID"
            case port = "Port"
            case protocolField = "Protocol"
            case name = "Name"
        }
    }

    private func loadListening() async {
        do {
            let resp: [ListeningProcessItem] = try await client.send(
                path: APIEndpoint.processListening.path,
                body: EmptyRequest(),
                as: [ListeningProcessItem].self
            )
            var keyed: [String: String] = [:]
            var anyByPort: [String: String] = [:]
            for process in resp {
                guard let name = process.name, !name.isEmpty else { continue }
                let proto = process.protocolField == 2 ? "udp" : "tcp"
                let ports: [String] = process.port.map { Array($0.keys) } ?? []
                for port in ports where !port.isEmpty {
                    keyed["\(port)|\(proto)"] = name
                    if anyByPort[port] == nil { anyByPort[port] = name }
                }
            }
            portProcessNames = keyed
            portAnyProcessNames = anyByPort
        } catch { /* 静默：行内进程名缺失不影响功能 */ }
    }

    /// 规则行使用方：按端口+协议精确命中，协议缺失/未命中时回落任意协议
    func processName(port: String?, proto: String?) -> String? {
        guard let port, !port.isEmpty else { return nil }
        let p = (proto ?? "").lowercased()
        if p.isEmpty || p == "tcp" || p == "tcp/udp" || p == "all" {
            if let n = portProcessNames["\(port)|tcp"] { return n }
        }
        if p.isEmpty || p == "udp" || p == "tcp/udp" || p == "all" {
            if let n = portProcessNames["\(port)|udp"] { return n }
        }
        return portAnyProcessNames[port]
    }

    /// 编辑表单的优先级可设范围（按地址族取 ipv4Range / ipv6Range）
    func positionRange(family: String?) -> FirewallPositionRange? {
        family == "ipv6" ? rulesIPv6Range : rulesIPv4Range
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

    /// v2.4.0 起不再发送 excludeChains（抓包 2026-10-22）：BEFORE/AFTER 守护链的
    /// 白名单规则已并入统一清单展示（Web 端同口径），排除会漏行且与 allTotal 计数不一致

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
    /// 完成返回时是否整页刷新（IPv6 开关：任务后台改写全部子系统的族状态/
    /// 规则/白名单/容器 IPv6 端口，返回时需重拉校准）
    var refreshAfterDone: Bool = false
    var id: String { taskID }
}

/// 规则段的地址族待办（VM.familyAttention 派生结果；family = ipv4/ipv6，
/// operation = initialize/repair/bind）
struct FirewallFamilyAttention: Equatable {
    let family: String
    let operation: String
}
