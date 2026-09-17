//
//  Firewall.swift
//  1PanelClient
//
//  防火墙 v2.3.0 契约（2026-09 上游整体重构后的 API）
//  形状来源：1Panel v2.3.0 agent/app/dto/firewall.go + forwarding.go +
//  agent/utils/firewall/filter/{model,inventory}.go 的 json tag 全量映射
//  （docs/v2.3.0-upstream-diff.md §2）。L1 标准：字段全可选、宽松解码，
//  上游字段口径漂移不整页失败。抓包验证待做（M1 收尾项）。
//

import Foundation

// MARK: - 子系统状态（POST /firewall/base {name} / POST /firewall/forward/base）

/// 防火墙子系统状态：name=base（系统）/docker 走 /firewall/base，
/// 转发子系统走 /firewall/forward/base（无请求体）
nonisolated struct FirewallSubsystemStatus: Decodable, Sendable {
    let name: String?
    /// 当前后端：firewalld / ufw / iptables / nftables
    let backend: String?
    /// 冲突后端（如 firewalld 与 ufw 同时在场）
    let conflictBackend: String?
    let isExist: Bool?
    let isActive: Bool?
    let isInit: Bool?
    let isBind: Bool?
    let version: String?
    /// 禁 ping 状态；"Disable"/"NormalDisable" 表示未禁 ping
    let pingStatus: String?
    let message: String?
    let reason: String?
    let syncError: String?
    let ipv4: FirewallBackendFamilyStatus?
    let ipv6: FirewallBackendFamilyStatus?

    /// 当前是否禁 ping（toggle ON = 阻断 ping）
    var pingBlocked: Bool {
        guard let s = pingStatus?.lowercased() else { return false }
        return s != "disable" && s != "normaldisable"
    }
}

nonisolated struct FirewallBackendFamilyStatus: Decodable, Sendable {
    let available: Bool?
    let initialized: Bool?
    let bound: Bool?
    let reason: String?
}

// MARK: - 生命周期操作（POST /firewall/operate）

nonisolated struct FirewallOperateRequest: Encodable, Sendable {
    /// start / stop / restart / disableBanPing / enableBanPing
    let operation: String
    let withDockerRestart: Bool
}

// MARK: - 基础链操作（POST /firewall/filter/operate，v2.3.0 幸存端点）

/// name 恒为 1PANEL_BASIC；operate = init-base / bind-base / unbind-base；
/// 转发链初始化改走 /firewall/forward/enable
nonisolated struct FirewallFilterOperateRequest: Encodable, Sendable {
    let name: String
    let operate: String
    var taskID: String?
}

/// 任务式响应（init-base / 转发启用 / 白名单更新 / Docker 操作等共用）
nonisolated struct FirewallTaskResponse: Decodable, Sendable {
    let taskID: String?
    let queued: Bool?
}

// MARK: - 规则域（filter 包）

/// 规则作用域：iptables/nftables 带 table+chain；firewalld 带 zone；ufw 带 chain(incoming)
nonisolated struct FirewallScope: Codable, Sendable, Hashable {
    var provider: String?
    var family: String?
    var table: String?
    var zone: String?
    var chain: String?
    var direction: String?

    init(provider: String? = nil, family: String? = nil, table: String? = nil,
         zone: String? = nil, chain: String? = nil, direction: String? = "input") {
        self.provider = provider
        self.family = family
        self.table = table
        self.zone = zone
        self.chain = chain
        self.direction = direction
    }
}

/// 统一规则模型（filter.FirewallRule）。nativeKind 建/改时恒 "rule"
nonisolated struct FirewallRule: Codable, Identifiable, Hashable, Sendable {
    var uuid: String?
    var scope: FirewallScope?
    var nativeKind: String?
    /// tcp / udp / tcp/udp（提交时 ufw 用 all）/ icmp / icmpv6
    var protocolField: String?
    var sourceAddress: String?
    var sourcePort: String?
    var destinationAddress: String?
    var destinationPort: String?
    var interface: String?
    var connectionStates: [String]?
    /// accept / drop / reject
    var action: String?
    var priority: Int?
    var orderIndex: Int64?
    var orderBucket: String?
    var descriptionText: String?

    enum CodingKeys: String, CodingKey {
        case uuid, scope, nativeKind
        case protocolField = "protocol"
        case sourceAddress, sourcePort, destinationAddress, destinationPort
        case interface, connectionStates, action, priority
        case orderIndex, orderBucket
        case descriptionText = "description"
    }

    /// 列表行唯一键（uuid 可能缺失——external 规则只有 observed）
    var id: String {
        uuid ?? "\(scope?.provider ?? "")|\(protocolField ?? "")|\(sourceAddress ?? "")|\(destinationPort ?? "")-\(action ?? "")"
    }
}

/// 原生规则定位信息（observed.locator：链内位置与规范化文本）
nonisolated struct FirewallLocator: Decodable, Sendable {
    let provider: String?
    let scopeKey: String?
    let nativeId: String?
    let canonical: String?
    let position: Int?
}

/// 观察到的原生规则（inventory item 的 observed 侧）
nonisolated struct FirewallObservedRule: Decodable, Sendable {
    let rule: FirewallRule?
    let locator: FirewallLocator?
    let instanceKey: String?
    /// 1panel-rule:<uuid> 标记（面板纳管标记）
    let marker: String?
    let parseStatus: String?
    let uncertainFields: [String]?
    let raw: String?
    let protected: Bool?
}

/// 面板期望态规则（desired 侧；uuid 是增删改的操作键）
nonisolated struct FirewallDesiredRule: Decodable, Sendable {
    let uuid: String?
    let rule: FirewallRule?
    let origin: String?
    let protected: Bool?
}

/// 清单条目：state = managed/adopted/external/drifted/protected，
/// match = none/exact/changed/missing/ambiguous/opaque
nonisolated struct FirewallInventoryItem: Decodable, Identifiable, Sendable {
    let incompatible: Bool?
    let error: String?
    let rule: FirewallRule?
    let observed: FirewallObservedRule?
    let desired: FirewallDesiredRule?
    let state: String?
    let match: String?

    /// 稳定行键：managed/adopted 用 desired.uuid；external 无 uuid，
    /// 用 observed.instanceKey 或规则内容组合（避免每次解码随机重建导致列表闪动）
    var id: String {
        if let u = desired?.uuid ?? rule?.uuid { return u }
        if let k = observed?.instanceKey, !k.isEmpty { return k }
        let r = rule
        return "ext|\(r?.scope?.chain ?? "")|\(r?.protocolField ?? "")|\(r?.sourceAddress ?? "")|\(r?.destinationPort ?? "")|\(r?.action ?? "")"
    }
    /// 可管理的（有 desired.uuid 才能编辑/删除）
    var manageableUUID: String? {
        guard let u = desired?.uuid ?? rule?.uuid, !u.isEmpty else { return nil }
        return u
    }
}

nonisolated struct FirewallPositionRange: Decodable, Sendable {
    let min: Int?
    let max: Int?
}

nonisolated struct FirewallScopeNotice: Decodable, Sendable {
    let code: String?
    let values: [String]?
}

// MARK: - 规则查询（POST /firewall/rules/search）

nonisolated struct FirewallRuleSearchRequest: Encodable, Sendable {
    var page: Int
    var pageSize: Int
    /// 管理作用域集合（抓包 2026-09-17：iptables/nftables 六链、ufw 单链 inet/incoming；
    /// 由 FirewallViewModel.scopeForSearch 按后端构造）
    var scopes: [FirewallScope]?
    /// 空串 = 全部作用域
    var info: String = ""
    var families: [String]?
    var actions: [String]?
    /// managed / adopted / external / drifted / protected
    var states: [String]?
    /// iptables/nftables 排除守护链本身（BEFORE/AFTER 只作定位不作展示）
    var excludeChains: [String]?
    var all: Bool?
}

nonisolated struct FirewallRuleInventoryResponse: Decodable, Sendable {
    let ipv4Range: FirewallPositionRange?
    let ipv6Range: FirewallPositionRange?
    let total: Int?
    let allTotal: Int?
    let managedTotal: Int?
    let items: [FirewallInventoryItem]?
    let notices: [FirewallScopeNotice]?
}

// MARK: - 规则增删改

nonisolated struct FirewallRuleCreateItem: Encodable, Sendable {
    var rule: FirewallRule
    var sourceKind: String?
    var sourceID: String?
}

nonisolated struct FirewallRuleCreateRequest: Encodable, Sendable {
    var items: [FirewallRuleCreateItem]
}

nonisolated struct FirewallRuleCreateFailure: Decodable, Sendable {
    let index: Int?
    let status: String?
    let rule: FirewallRule?
    let error: String?
}

nonisolated struct FirewallRuleCreateResponse: Decodable, Sendable {
    let taskID: String?
    let queued: Bool?
    let succeeded: Int?
    let failed: Int?
    let skipped: Int?
    let errors: [FirewallRuleCreateFailure]?
}

nonisolated struct FirewallRuleDeleteRequest: Encodable, Sendable {
    var uuids: [String]
}

// MARK: - 规则同步（rules/sync/preview → rules/sync；抓包 2026-09-17）

nonisolated struct FirewallRuleSyncRequest: Encodable, Sendable {
    /// system / forwarding / docker
    var subsystem: String
    var targetProvider: String
    var resetSource: Bool
    var taskID: String?
}

nonisolated struct FirewallRuleSyncItem: Decodable, Sendable {
    let sourceUUID: String?
    let rule: FirewallRule?
    let forwardRule: FirewallForwardRule?
    let dockerRule: DockerGuardEndpoint?
    /// ready（可同步）/ existing（已一致）/ remove（将被移除）/ blocked（受阻）
    let status: String?
    let reasonCode: String?
    let reason: String?

    /// 条目展示名（按子系统取对应规则的主标识）
    var displayToken: String {
        if let p = rule?.destinationPort, !p.isEmpty { return p }
        if let a = rule?.sourceAddress, !a.isEmpty { return a }
        if let fp = forwardRule?.port, !fp.isEmpty { return fp }
        if let hp = dockerRule?.hostPort { return String(hp) }
        return sourceUUID?.prefix(8).description ?? "—"
    }
}

nonisolated struct FirewallRuleSyncPreview: Decodable, Sendable {
    let subsystem: String?
    let sourceProvider: String?
    let targetProvider: String?
    let total: Int?
    let ready: Int?
    let existing: Int?
    let removed: Int?
    let blocked: Int?
    let items: [FirewallRuleSyncItem]?
}

nonisolated struct FirewallRuleSyncResult: Decodable, Sendable {
    let subsystem: String?
    let targetProvider: String?
    let total: Int?
    let succeeded: Int?
    let skipped: Int?
    let removed: Int?
    let failed: Int?
    let taskID: String?
    let queued: Bool?
}

// MARK: - 规则重置（rules/reset；抓包 2026-09-17：{removed, disabled}，需输入后端名确认）

nonisolated struct FirewallRuleResetRequest: Encodable, Sendable {
    var provider: String?
    var withDockerRestart: Bool
}

nonisolated struct FirewallRuleResetResponse: Decodable, Sendable {
    let removed: Int?
    let disabled: Bool?
}

nonisolated struct FirewallRuleDeleteFailure: Decodable, Sendable {
    let index: Int?
    let uuid: String?
    let error: String?
}

nonisolated struct FirewallRuleDeleteResponse: Decodable, Sendable {
    let succeeded: Int?
    let failed: Int?
    let errors: [FirewallRuleDeleteFailure]?
}

/// 部分更新：rule（整规则替换）/ description / orderIndex（仅改优先级）互斥。
/// 抓包 2026-09-17：优先级单改走 {"uuid","orderIndex"}，整规则替换时 rule 内也带 orderIndex
nonisolated struct FirewallRuleUpdateRequest: Encodable, Sendable {
    var uuid: String
    var rule: FirewallRule?
    var descriptionText: String?
    var orderIndex: Int64?

    enum CodingKeys: String, CodingKey {
        case uuid, rule, orderIndex
        case descriptionText = "description"
    }
}

// MARK: - 转发域（/firewall/forward/*）

/// 转发规则行（forward/search 返回 items；dto.PageResult 信封 → PageEnvelope）
nonisolated struct FirewallForwardRule: Codable, Identifiable, Hashable, Sendable {
    var id: Int?
    var chain: String?
    var family: String?
    var address: String?
    var port: String?
    var protocolField: String?
    var strategy: String?
    /// iptables 规则序号（remove 时回传）
    var num: String?
    var targetIP: String?
    var targetPort: String?
    var interface: String?
    var usedStatus: String?
    var descriptionText: String?
    var isDesired: Bool?
    var isRuntime: Bool?
    var syncStatus: String?

    enum CodingKeys: String, CodingKey {
        case id, chain, family, address, port, strategy, num
        case targetIP, targetPort, interface, usedStatus
        case isDesired, isRuntime, syncStatus
        case protocolField = "protocol"
        case descriptionText = "description"
    }
}

nonisolated struct FirewallForwardSearchRequest: Encodable, Sendable {
    var page: Int
    var pageSize: Int
    var all: Bool?
    var info: String = ""
    var status: String = ""
    var strategy: String = ""
}

/// 转发操作条目：编辑/删除时回显**整行原始字段** + operation（抓包 2026-09-17：
/// remove 匹配依赖 num 等运行时字段，Web 端做法是把行对象原样回传再叠加操作）
nonisolated struct FirewallForwardOperation: Encodable, Sendable {
    var operation: String
    var id: Int?
    var chain: String?
    var family: String?
    var address: String?
    var port: String?
    var protocolField: String?
    var strategy: String?
    var num: String?
    var targetIP: String?
    var targetPort: String?
    var interface: String?
    var usedStatus: String?
    var descriptionText: String?
    var isDesired: Bool?
    var isRuntime: Bool?
    var syncStatus: String?

    enum CodingKeys: String, CodingKey {
        case operation, id, chain, family, address, port, strategy, num
        case targetIP, targetPort, interface, usedStatus
        case isDesired, isRuntime, syncStatus
        case protocolField = "protocol"
        case descriptionText = "description"
    }

    /// 由列表行构造 remove 操作（整行回显，运行时字段保真）
    static func remove(_ rule: FirewallForwardRule) -> FirewallForwardOperation {
        FirewallForwardOperation(
            operation: "remove",
            id: rule.id, chain: rule.chain, family: rule.family, address: rule.address,
            port: rule.port, protocolField: rule.protocolField, strategy: rule.strategy,
            num: rule.num, targetIP: rule.targetIP, targetPort: rule.targetPort,
            interface: rule.interface, usedStatus: rule.usedStatus,
            descriptionText: rule.descriptionText,
            isDesired: rule.isDesired, isRuntime: rule.isRuntime, syncStatus: rule.syncStatus
        )
    }
}

nonisolated struct FirewallForwardOperateRequest: Encodable, Sendable {
    var forceDelete: Bool
    var rules: [FirewallForwardOperation]
}

// MARK: - 设置域（GET /firewall/settings + /settings/operate + /settings/whitelist）

nonisolated struct FirewallBackendOption: Decodable, Identifiable, Sendable {
    let name: String?
    let installed: Bool?
    let active: Bool?
    let initialized: Bool?
    let bound: Bool?
    let supported: Bool?
    let supportReason: String?
    let implementation: String?
    let message: String?
    let ipv4: FirewallBackendFamilyStatus?
    let ipv6: FirewallBackendFamilyStatus?

    var id: String { name ?? UUID().uuidString }
}

nonisolated struct FirewallBackendGroup: Decodable, Sendable {
    let selected: String?
    let current: String?
    let options: [FirewallBackendOption]?
}

nonisolated struct FirewallSettings: Decodable, Sendable {
    let system: FirewallBackendGroup?
    let forwarding: FirewallBackendGroup?
    let docker: FirewallBackendGroup?
    let pingStatus: String?
    let portWhiteList: String?

    /// 当前是否禁 ping（与 FirewallSubsystemStatus.pingBlocked 同一口径）
    var pingBlocked: Bool {
        guard let s = pingStatus?.lowercased() else { return false }
        return s != "disable" && s != "normaldisable"
    }
}

/// POST /firewall/settings/operate：subsystem = system/forwarding/docker，
/// backend = firewalld/ufw/iptables/nftables，operation = select/initialize/cleanup
nonisolated struct FirewallBackendOperationRequest: Encodable, Sendable {
    let subsystem: String
    let backend: String
    let operation: String
}

nonisolated struct FirewallPortWhitelistRequest: Encodable, Sendable {
    let value: String
}

// MARK: - 端口白名单条目（双格式，抓包 2026-09-17）

/// 白名单条目：{family, protocol, port}。
/// 面板存在两种存储形态：初始为逗号串（"80/tcp,443/tcp"），
/// 编辑保存后为 JSON 数组字符串（"[{\"family\":…,\"port\":…,\"protocol\":…}]"）。
/// 读取兼容两种；提交统一用 JSON 数组字符串（Web 端形态）
nonisolated struct FirewallPortWhitelistEntry: Codable, Equatable, Identifiable, Sendable {
    var family: String
    var protocolField: String
    var port: String

    enum CodingKeys: String, CodingKey {
        case family, port
        case protocolField = "protocol"
    }

    var id: String { "\(family)|\(protocolField)|\(port)" }

    /// 展示文本（80/tcp）
    var display: String {
        let proto = protocolField.isEmpty ? "" : "/\(protocolField)"
        return "\(port)\(proto) (\(family.uppercased()))"
    }
}

/// 解析白名单原始串：JSON 数组格式优先，回落逗号/换行分隔（family/protocol 缺省 ipv4/tcp）
nonisolated func parseFirewallWhitelistEntries(_ raw: String?) -> [FirewallPortWhitelistEntry] {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
        return []
    }
    if raw.hasPrefix("["),
       let data = raw.data(using: .utf8),
       let entries = try? JSONDecoder().decode([FirewallPortWhitelistEntry].self, from: data) {
        return entries
    }
    // 旧格式："80/tcp,443/tcp,443/udp"
    return parseFirewallPortWhitelist(raw).map { item in
        let parts = item.split(separator: "/", maxSplits: 1).map(String.init)
        let port = parts.first ?? item
        let proto = parts.count > 1 ? parts[1] : "tcp"
        return FirewallPortWhitelistEntry(family: "ipv4", protocolField: proto, port: port)
    }
}

/// 旧逗号/换行格式拆行（ isNewline 而非 == "\n"：CRLF 在 Swift 里是单个
/// Character 字素簇，单独比较 \n 或 \r 都匹配不上 CRLF 整体）
nonisolated func parseFirewallPortWhitelist(_ raw: String?) -> [String] {
    guard let raw, !raw.isEmpty else { return [] }
    return raw
        .split(whereSeparator: { $0 == "," || $0.isNewline })
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

/// 白名单条目数组 → 提交串（JSON 数组字符串，Web 端形态）
nonisolated func encodeFirewallWhitelistEntries(_ entries: [FirewallPortWhitelistEntry]) -> String {
    guard let data = try? JSONEncoder().encode(entries) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Docker 端口守护（/firewall/docker/*）

nonisolated struct DockerGuardFamilyStatus: Decodable, Sendable {
    let state: String?
    let reason: String?
    let initialized: Bool?
    let bound: Bool?
    let effective: Bool?
}

nonisolated struct DockerGuardBase: Decodable, Sendable {
    let name: String?
    let version: String?
    let isExist: Bool?
    let initialized: Bool?
    let bound: Bool?
    let ipv4: DockerGuardFamilyStatus?
    let ipv6: DockerGuardFamilyStatus?
    let backend: String?
    let message: String?
}

/// Docker 发布端口的一个守护点（hostIP:hostPort/protocol → container）
nonisolated struct DockerGuardEndpoint: Decodable, Identifiable, Sendable {
    let family: String?
    let hostIP: String?
    let hostPort: Int?
    let protocolField: String?
    let containerID: String?
    let containerName: String?
    let containerState: String?
    let containerPort: Int?
    let compose: String?
    let application: String?
    let policyUUID: String?
    /// deny_sources / allow_sources / deny_all
    let mode: String?
    let nativeAction: String?
    let readOnly: Bool?
    let sources: [String]?
    let effective: Bool?
    let descriptionText: String?
    let trafficPath: String?
    let managementTarget: String?
    let managementReason: String?

    enum CodingKeys: String, CodingKey {
        case family, hostIP, hostPort, containerID, containerName, containerState
        case containerPort, compose, application, policyUUID, mode, nativeAction
        case readOnly, sources, effective, trafficPath
        case managementTarget, managementReason
        case protocolField = "protocol"
        case descriptionText = "description"
    }

    var id: String { policyUUID ?? "\(family ?? "")|\(hostIP ?? "")|\(hostPort ?? 0)|\(protocolField ?? "")|\(containerID ?? "")" }
}

nonisolated struct DockerGuardPortGroup: Decodable, Identifiable, Sendable {
    let key: String?
    let label: String?
    let endpoint: DockerGuardEndpoint?
    let endpoints: [DockerGuardEndpoint]?

    var id: String { key ?? endpoint?.id ?? UUID().uuidString }
}

nonisolated struct DockerGuardContainer: Decodable, Identifiable, Sendable {
    let key: String?
    let name: String?
    let compose: String?
    let application: String?
    let endpoints: [DockerGuardEndpoint]?
    let portGroups: [DockerGuardPortGroup]?

    var id: String { key ?? name ?? UUID().uuidString }
}

nonisolated struct DockerGuardList: Decodable, Sendable {
    let base: DockerGuardBase?
    let containers: [DockerGuardContainer]?
    let orphanPolicies: [DockerGuardEndpoint]?
}

/// POST /firewall/docker/operate：operation = initialize / bind / unbind
nonisolated struct DockerGuardOperateRequest: Encodable, Sendable {
    let operation: String
    var taskID: String?
}

nonisolated struct DockerGuardPolicy: Encodable, Sendable {
    var family: String
    var hostIP: String
    var hostPort: Int
    var protocolField: String
    var mode: String
    var sources: [String]
    var descriptionText: String

    enum CodingKeys: String, CodingKey {
        case family, hostIP, hostPort, mode, sources
        case protocolField = "protocol"
        case descriptionText = "description"
    }
}

nonisolated struct DockerGuardPolicyBatchRequest: Encodable, Sendable {
    var policies: [DockerGuardPolicy]
}

nonisolated struct DockerGuardPolicyDeleteRequest: Encodable, Sendable {
    var uuids: [String]
}
