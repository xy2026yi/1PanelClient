//
//  Firewall.swift
//  1PanelClient
//
//  防火墙（ufw）状态 / 端口规则
//  POST /api/v2/hosts/firewall/base | operate | search | port | batch
//

import Foundation

/// 防火墙基础状态（POST /firewall/base，body {name:"base"}）
nonisolated struct FirewallBase: Decodable {
    let name: String?
    let isExist: Bool?
    let isActive: Bool?
    let isInit: Bool?
    let isBind: Bool?
    let version: String?
    /// 禁 ping 状态；"Disable" 表示未禁 ping（允许 ping）
    let pingStatus: String?

    /// 当前是否禁 ping（toggle ON = 阻断 ping）
    var pingBlocked: Bool {
        guard let s = pingStatus?.lowercased() else { return false }
        return s != "disable" && s != "normaldisable"
    }
}

/// 防火墙端口规则（/firewall/search 返回 items）
/// 注意：API 返回的 id 恒为 0，无法用于唯一标识，
/// 改用 port/protocol/address/strategy/family 组合做 Identifiable.id
nonisolated struct FirewallRule: Decodable, Identifiable, Hashable {
    let address: String?
    let port: String?
    let protocolField: String?
    let strategy: String?
    let usedStatus: String?
    let description: String?
    let family: String?
    let chain: String?

    enum CodingKeys: String, CodingKey {
        case address, port, strategy, usedStatus, description, family, chain
        case protocolField = "protocol"
    }

    /// 组合唯一键（API 的 id 全为 0 无意义）
    var id: String {
        "\(port ?? "")|\(protocolField ?? "")|\(address ?? "")|\(strategy ?? "")|\(family ?? "")"
    }
}

/// 操作请求（/firewall/operate）：start / stop / restart / enablePing / disablePing
nonisolated struct FirewallOperateRequest: Encodable {
    let operation: String
    let withDockerRestart: Bool
}

/// 端口规则搜索请求（/firewall/search）
nonisolated struct FirewallSearchRequest: Encodable {
    let type: String       // port
    let status: String
    let strategy: String
    let page: Int
    let pageSize: Int
}

/// 创建端口规则请求（/firewall/port）
nonisolated struct FirewallPortRequest: Encodable {
    let protocolField: String
    let source: String
    let strategy: String
    let port: String
    let description: String
    let operation: String   // add
    let address: String

    enum CodingKeys: String, CodingKey {
        case protocolField = "protocol"
        case source, strategy, port, description, operation, address
    }
}

/// 批量操作单条规则（/firewall/batch 的 rules 元素）
nonisolated struct FirewallBatchRule: Encodable {
    let operation: String   // remove
    let chain: String
    let address: String
    let port: String
    let source: String
    let protocolField: String
    let strategy: String

    enum CodingKeys: String, CodingKey {
        case protocolField = "protocol"
        case operation, chain, address, port, source, strategy
    }
}

/// 批量操作请求（/firewall/batch）
nonisolated struct FirewallBatchRequest: Encodable {
    let type: String        // port
    let rules: [FirewallBatchRule]
}

/// 修改端口规则时的完整规则对象（oldRule/newRule 共用）
nonisolated struct FirewallRuleFull: Encodable {
    let id: Int
    let chain: String
    let family: String
    let address: String
    let port: String
    let protocolField: String
    let strategy: String
    let num: String
    let targetIP: String
    let targetPort: String
    let interface: String
    let usedStatus: String
    let description: String
    let usedPorts: [String]
    let source: String
    let operation: String

    enum CodingKeys: String, CodingKey {
        case id, chain, family, address, port, strategy, num
        case targetIP, targetPort, interface, usedStatus, description
        case usedPorts, source, operation
        case protocolField = "protocol"
    }
}

/// 修改端口规则请求（/firewall/update/port）
nonisolated struct FirewallUpdatePortRequest: Encodable {
    let oldRule: FirewallRuleFull
    let newRule: FirewallRuleFull
}

extension FirewallRuleFull {
    /// 由搜索结果 FirewallRule 构造完整规则对象
    /// - operation: "remove"（旧规则）或 "add"（新规则）
    init(from rule: FirewallRule, operation: String) {
        let addr = rule.address ?? ""
        let source = (addr.isEmpty || addr == "Anywhere") ? "anyWhere" : addr
        self.init(
            id: 0,
            chain: rule.chain ?? "",
            family: rule.family ?? "ipv4",
            address: addr,
            port: rule.port ?? "",
            protocolField: rule.protocolField ?? "tcp",
            strategy: rule.strategy ?? "accept",
            num: "",
            targetIP: "",
            targetPort: "",
            interface: "",
            usedStatus: rule.usedStatus ?? "",
            description: rule.description ?? "",
            usedPorts: [],
            source: source,
            operation: operation
        )
    }
}
