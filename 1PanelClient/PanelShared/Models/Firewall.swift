//
//  Firewall.swift
//  1PanelClient
//
//  防火墙契约（v2.4.0 对齐，2026-10；v2.3.0 整体重构 API 的后继演进）
//  形状来源：1Panel v2.4.0 agent/app/dto/firewall.go + forwarding.go +
//  agent/utils/firewall/filter/{model,inventory}.go 的 json tag 全量映射。
//  v2.4.0 上游拆除「面板期望态 vs 外部规则」对账模型：清单不再有
//  state/match/desired，sync/adopt 端点与 DTO 全数移除；增删改的操作键从
//  uuid 换成 (scope, instanceKey, observed) 三元组（FirewallRuleOperationTarget）。
//  L1 标准：字段全可选、宽松解码，上游字段口径漂移不整页失败。
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
    /// v2.4.0：子系统 IPv6 族是否启用（新增）
    let ipv6Enabled: Bool?
    let ipv4: FirewallBackendFamilyStatus?
    let ipv6: FirewallBackendFamilyStatus?

    /// 当前是否禁 ping（toggle ON = 阻断 ping）
    var pingBlocked: Bool {
        guard let s = pingStatus?.lowercased() else { return false }
        return s != "disable" && s != "normaldisable"
    }
}

nonisolated struct FirewallBackendFamilyStatus: Decodable, Sendable {
    /// v2.4.0 新增：族状态部分可用（如 IPv6 半初始化）
    let partial: Bool?
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

/// 原生规则定位信息（observed.locator：链内位置与规范化文本；随 observed 回传）
nonisolated struct FirewallLocator: Codable, Sendable {
    var provider: String?
    var scopeKey: String?
    var nativeId: String?
    var canonical: String?
    var position: Int?

    init(provider: String? = nil, scopeKey: String? = nil, nativeId: String? = nil,
         canonical: String? = nil, position: Int? = nil) {
        self.provider = provider
        self.scopeKey = scopeKey
        self.nativeId = nativeId
        self.canonical = canonical
        self.position = position
    }
}

/// 观察到的原生规则（inventory item 的 observed 侧；v2.4.0 增删改请求会把它
/// 原样回传——服务端按它定位活规则，故 Codable 双向）
nonisolated struct FirewallObservedRule: Codable, Sendable {
    var rule: FirewallRule?
    var locator: FirewallLocator?
    var instanceKey: String?
    /// 1panel-rule:<uuid> 标记（面板管理标记）
    var marker: String?
    var parseStatus: String?
    var uncertainFields: [String]?
    var raw: String?
    var protected: Bool?
    var persistence: String?

    init(rule: FirewallRule? = nil, locator: FirewallLocator? = nil,
         instanceKey: String? = nil, marker: String? = nil,
         parseStatus: String? = nil, uncertainFields: [String]? = nil,
         raw: String? = nil, protected: Bool? = nil, persistence: String? = nil) {
        self.rule = rule
        self.locator = locator
        self.instanceKey = instanceKey
        self.marker = marker
        self.parseStatus = parseStatus
        self.uncertainFields = uncertainFields
        self.raw = raw
        self.protected = protected
        self.persistence = persistence
    }
}

/// 规则增删改的操作目标键（v2.4.0）：上游弃 uuid，改以 (scope, instanceKey)
/// 定位 + observed 原样回传（服务端按观察态匹配活规则，防并发漂移错删）
nonisolated struct FirewallRuleOperationTarget: Codable, Hashable, Sendable {
    var scope: FirewallScope
    var instanceKey: String

    init(scope: FirewallScope, instanceKey: String) {
        self.scope = scope
        self.instanceKey = instanceKey
    }
}

/// 清单条目（v2.4.0）：上游拆除 state/match/desired 对账模型，仅剩
/// rule + observed；白名单保护（原 protected 态）由 isWhitelist 表达
nonisolated struct FirewallInventoryItem: Decodable, Identifiable, Sendable {
    let rule: FirewallRule?
    let observed: FirewallObservedRule?
    /// 面板端口白名单规则（原 state=protected 语义的承接字段）
    let isWhitelist: Bool?
    let descriptionID: String?

    /// 稳定行键：instanceKey 是活规则的稳定身份；缺失时回落规则内容组合
    /// （避免每次解码随机重建导致列表闪动）
    var id: String {
        if let u = rule?.uuid, !u.isEmpty { return u }
        if let k = observed?.instanceKey, !k.isEmpty { return k }
        let r = rule
        return "ext|\(r?.scope?.chain ?? "")|\(r?.protocolField ?? "")|\(r?.sourceAddress ?? "")|\(r?.destinationPort ?? "")|\(r?.action ?? "")"
    }
    /// 操作目标（有 instanceKey 才能编辑/删除/排序；scope 取 rule.scope）
    var operationTarget: FirewallRuleOperationTarget? {
        guard let key = observed?.instanceKey, !key.isEmpty,
              let scope = rule?.scope ?? observed?.rule?.scope else { return nil }
        return FirewallRuleOperationTarget(scope: scope, instanceKey: key)
    }
    /// 系统保护规则（端口白名单条目）：不可编辑/删除
    var isProtected: Bool { isWhitelist == true }
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
    /// 管理作用域集合（iptables/nftables 六链、ufw 单链 inet/incoming；
    /// 由 FirewallViewModel.scopeForSearch 按后端构造）
    var scopes: [FirewallScope]?
    /// 空串 = 全部作用域
    var info: String = ""
    var families: [String]?
    var actions: [String]?
    /// iptables/nftables 排除守护链本身（BEFORE/AFTER 只作定位不作展示）
    var excludeChains: [String]?
    var all: Bool?
}

nonisolated struct FirewallRuleInventoryResponse: Decodable, Sendable {
    let ipv4Range: FirewallPositionRange?
    let ipv6Range: FirewallPositionRange?
    let total: Int?
    let allTotal: Int?
    let items: [FirewallInventoryItem]?
    let notices: [FirewallScopeNotice]?
}

// MARK: - 规则增删改

nonisolated struct FirewallRuleCreateItem: Encodable, Sendable {
    var rule: FirewallRule
    var sourceKind: String?
}

nonisolated struct FirewallRuleCreateRequest: Encodable, Sendable {
    var items: [FirewallRuleCreateItem]
    /// 「初始化并恢复规则」流程（抓包 2026-10-21）：true = 先建基础链再恢复
    /// backupFile 内的规则，items 传空数组
    var initialize: Bool? = nil
    /// 恢复使用的备份文件名（rules/backups 返回的 name；仅 initialize=true 时携带）
    var backupFile: String? = nil
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

// MARK: - 规则删除（v2.4.0：targets[{scope,instanceKey,observed}]，弃 uuids）

nonisolated struct FirewallRuleDeleteItem: Encodable, Sendable {
    var scope: FirewallScope
    var instanceKey: String
    /// 观察态原样回传：服务端按它匹配活规则（防并发漂移错删）
    var observed: FirewallObservedRule
}

nonisolated struct FirewallRuleDeleteRequest: Encodable, Sendable {
    var targets: [FirewallRuleDeleteItem]
}

// MARK: - 规则重置（rules/reset；v2.4.0 响应含备份路径，需输入后端名确认）

/// 抓包 2026-10-21：{"backup":true,"provider":"iptables","withDockerRestart":false}；
/// backup=true 时响应带 backupFile 保存路径（弹窗提醒）
nonisolated struct FirewallRuleResetRequest: Encodable, Sendable {
    var backup: Bool = true
    var provider: String?
    var withDockerRestart: Bool
}

nonisolated struct FirewallRuleResetResponse: Decodable, Sendable {
    let backupPath: String?
    let removed: Int?
    let disabled: Bool?
}

// MARK: - 规则备份（GET rules/backups?subsystem=system；v2.4.0 新增，抓包 2026-10-21）

nonisolated struct FirewallRuleBackupFile: Decodable, Identifiable, Sendable {
    let name: String?
    let provider: String?
    let ruleCount: Int?
    /// 毫秒级修改时间（如 1792584345384）
    let modifiedAt: Int64?
    /// 行键：name 缺失时回落时间戳（避免随机重建导致列表闪动）
    var id: String { name ?? "backup-\(modifiedAt ?? 0)" }
}

nonisolated struct FirewallRuleBackupsResponse: Decodable, Sendable {
    /// 备份目录（服务器路径，如 /opt/1panel/backup/firewall/host）
    let directory: String?
    let files: [FirewallRuleBackupFile]?
}

// MARK: - 排序 / 原文查看（规则清单低频操作）

/// POST /firewall/rules/reorder：调整链内位置（v2.4.0 操作键 =
/// scope+instanceKey；Web 端排序走 update.orderIndex，本端点为上游保留能力）
nonisolated struct FirewallRuleReorderRequest: Encodable, Sendable {
    var scope: FirewallScope
    var instanceKey: String
    var targetPosition: Int64?
    var priority: Int?
}

/// POST /firewall/rules/native/detail：查看原生对象配置原文
/// （firewalld zone_service / ufw ufw_application；普通 iptables 规则用 observed.raw）
nonisolated struct FirewallNativeDetailRequest: Encodable, Sendable {
    var provider: String
    var nativeKind: String
    var name: String
    var permanent: Bool = true
}

nonisolated struct FirewallRuleDeleteFailure: Decodable, Sendable {
    let index: Int?
    let instanceKey: String?
    let error: String?
}

nonisolated struct FirewallRuleDeleteResponse: Decodable, Sendable {
    let taskID: String?
    let queued: Bool?
    let succeeded: Int?
    let failed: Int?
    let errors: [FirewallRuleDeleteFailure]?
}

/// 部分更新：rule（整规则替换）/ description / orderIndex（仅改优先级）互斥。
/// v2.4.0 操作键 = scope+instanceKey（弃 uuid）；整规则替换时 rule 内也带 orderIndex
nonisolated struct FirewallRuleUpdateRequest: Encodable, Sendable {
    var scope: FirewallScope
    var instanceKey: String
    var rule: FirewallRule?
    var descriptionText: String?
    var orderIndex: Int64?

    enum CodingKeys: String, CodingKey {
        case scope, instanceKey, rule, orderIndex
        case descriptionText = "description"
    }
}

// MARK: - 转发域（/firewall/forward/*）

/// 转发规则行（forward/search 返回 items；dto.PageResult 信封 → PageEnvelope）。
/// v2.4.0 上游删除 isDesired/isRuntime/syncStatus（同步时代字段）
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

    enum CodingKeys: String, CodingKey {
        case id, chain, family, address, port, strategy, num
        case targetIP, targetPort, interface, usedStatus
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

/// 转发操作条目：编辑/删除时回显**整行原始字段** + operation
///（remove 匹配依赖 num 等运行时字段，Web 端做法是把行对象原样回传再叠加操作）
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

    enum CodingKeys: String, CodingKey {
        case operation, id, chain, family, address, port, strategy, num
        case targetIP, targetPort, interface, usedStatus
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
            descriptionText: rule.descriptionText
        )
    }
}

/// v2.4.0：forceDelete 被 import 取代（true = 导入语义，服务端按导入口径
/// 处理重复/校验）；Swift 关键字经 CodingKeys 映射
nonisolated struct FirewallForwardOperateRequest: Encodable, Sendable {
    var isImport: Bool
    var rules: [FirewallForwardOperation]

    enum CodingKeys: String, CodingKey {
        case isImport = "import"
        case rules
    }
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

    /// 当前后端（current/selected 对应的 option）是否仍含 1Panel 运行时规则：
    /// 切换预检用——true 时须先重置才能换后端（否则服务端 409 CLEANUP_REQUIRED）
    var currentInitialized: Bool {
        let name = current ?? selected
        guard let name, !name.isEmpty else { return false }
        return (options ?? []).first { $0.name == name }?.initialized == true
    }
}

nonisolated struct FirewallSettings: Decodable, Sendable {
    let system: FirewallBackendGroup?
    let forwarding: FirewallBackendGroup?
    let docker: FirewallBackendGroup?
    let pingStatus: String?
    /// v2.3.1 上游为对象数组（[]filter.PortWhitelist）；曾误建为 String 触发解码回退
    let portWhiteList: [FirewallPortWhitelistEntry]?
    let panelPort: String?
    let sshPort: String?

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

// MARK: - 端口白名单条目（v2.3.1 上游 filter.PortWhitelist）

/// 白名单条目：上游 {port, protocol, type, sources}；无地址族维度
/// （sources 内 0.0.0.0/0 与 ::/0 已同时覆盖 v4/v6，App 不再分组展示）。
/// 旧版本误按「逗号串 / JSON 数组字符串」建 String 模型，与线上数组类型
/// 不匹配导致信封解码失败→裸解码回退→全字段 nil 的空对象（白名单恒 0）
nonisolated struct FirewallPortWhitelistEntry: Codable, Equatable, Identifiable, Sendable {
    var protocolField: String
    var port: String
    /// 条目类型：ssh / panel；其他（用户自建）不序列化
    var type: String?
    var sources: [String]?

    init(protocolField: String = "tcp", port: String,
         type: String? = nil, sources: [String]? = nil) {
        self.protocolField = protocolField
        self.port = port
        self.type = type
        self.sources = sources
    }

    enum CodingKeys: String, CodingKey {
        case port
        case protocolField = "protocol"
        case type, sources
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolField = try c.decodeIfPresent(String.self, forKey: .protocolField) ?? "tcp"
        port = try c.decodeIfPresent(String.self, forKey: .port) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type)
        sources = try c.decodeIfPresent([String].self, forKey: .sources)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(port, forKey: .port)
        try c.encode(protocolField, forKey: .protocolField)
        try c.encodeIfPresent(type, forKey: .type)
        try c.encodeIfPresent(sources, forKey: .sources)
    }

    /// 列表行唯一键：上游匹配键含 sources——同端口同协议不同来源是合法数据
    /// （如 80/tcp 分别放行两个 IP），不并入则 ForEach 重号（串显/编辑错行/
    /// 删一条实际删两条/Dictionary 建索引静默丢一条，与 WAF 重名 id 同型问题）
    var id: String {
        "\(type ?? "")|\(protocolField)|\(port)|\((sources ?? []).joined(separator: ","))"
    }

    /// 展示文本（80/tcp，不带地址族后缀）
    var display: String {
        let proto = protocolField.isEmpty ? "" : "/\(protocolField)"
        return "\(port)\(proto)"
    }

    /// 类型徽标（ssh / panel；其他为 nil）
    var typeLabel: String? {
        switch type {
        case "ssh": return "SSH"
        case "panel": return "1Panel"
        default: return nil
        }
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

/// v2.3.1 白名单逐条写接口：POST /settings/whitelist {rule} 与
/// /settings/whitelist/delete {rule}
nonisolated struct FirewallWhitelistRuleRequest: Encodable, Sendable {
    let rule: FirewallPortWhitelistEntry
}

/// v2.3.1 白名单更新：POST /settings/whitelist/update {oldRule, rule}
nonisolated struct FirewallWhitelistRuleUpdateRequest: Encodable, Sendable {
    let oldRule: FirewallPortWhitelistEntry
    let rule: FirewallPortWhitelistEntry
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
nonisolated struct DockerGuardEndpoint: Decodable, Identifiable, Hashable, Sendable {
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
    /// deny_sources / allow_sources / deny_all（v2.4.0 上游另有
    /// accept_sources / accept_all，App 表单暂未提供）
    let mode: String?
    let sources: [String]?
    let effective: Bool?
    let trafficPath: String?
    let managementTarget: String?
    let managementReason: String?

    enum CodingKeys: String, CodingKey {
        case family, hostIP, hostPort, containerID, containerName, containerState
        case containerPort, compose, application, policyUUID, mode, sources
        case effective, trafficPath
        case managementTarget, managementReason
        case protocolField = "protocol"
    }

    var id: String { policyUUID ?? "\(family ?? "")|\(hostIP ?? "")|\(hostPort ?? 0)|\(protocolField ?? "")|\(containerID ?? "")" }
}

nonisolated struct DockerGuardPortGroup: Decodable, Identifiable, Hashable, Sendable {
    let key: String?
    let label: String?
    let endpoint: DockerGuardEndpoint?
    let endpoints: [DockerGuardEndpoint]?

    var id: String { key ?? endpoint?.id ?? UUID().uuidString }
}

nonisolated struct DockerGuardContainer: Decodable, Identifiable, Hashable, Sendable {
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

/// Docker 守护策略（v2.4.0 上游移除 description 字段；mode 另有
/// accept_sources / accept_all，App 表单暂未提供）
nonisolated struct DockerGuardPolicy: Codable, Sendable {
    var family: String
    var hostIP: String
    var hostPort: Int
    var protocolField: String
    var mode: String
    var sources: [String]

    enum CodingKeys: String, CodingKey {
        case family, hostIP, hostPort, mode, sources
        case protocolField = "protocol"
    }
}

nonisolated struct DockerGuardPolicyBatchRequest: Encodable, Sendable {
    var policies: [DockerGuardPolicy]
}

nonisolated struct DockerGuardPolicyDeleteRequest: Encodable, Sendable {
    var uuids: [String]
}
