//
//  Firewall.swift
//  1PanelClient
//
//  防火墙（ufw）状态 / 端口规则
//  POST /api/v2/hosts/firewall/base | operate | search | port | batch
//

import Foundation

/// 防火墙基础状态（POST /firewall/base，body {name:"base"}）
struct FirewallBase: Decodable {
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
struct FirewallRule: Decodable, Identifiable, Hashable {
    let id: Int
    let address: String?
    let port: String?
    let protocolField: String?
    let strategy: String?
    let usedStatus: String?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case id, address, port, strategy, usedStatus, description
        case protocolField = "protocol"
    }
}

/// 操作请求（/firewall/operate）：start / stop / restart / enablePing / disablePing
struct FirewallOperateRequest: Encodable {
    let operation: String
    let withDockerRestart: Bool
}

/// 端口规则搜索请求（/firewall/search）
struct FirewallSearchRequest: Encodable {
    let type: String       // port
    let status: String
    let strategy: String
    let page: Int
    let pageSize: Int
}

/// 创建端口规则请求（/firewall/port）
struct FirewallPortRequest: Encodable {
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
struct FirewallBatchRule: Encodable {
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
struct FirewallBatchRequest: Encodable {
    let type: String        // port
    let rules: [FirewallBatchRule]
}
