//
//  SSHHost.swift
//  1PanelClient
//
//  SSH 连接主机：已保存主机 / 分组 数据模型与请求体
//  基于 logs/SSH连接主机.md 抓包
//

import Foundation

// MARK: - 主机

/// 已保存的 SSH 主机（/api/v2/hosts/search 返回项）
/// password / privateKey / passPhrase 为服务端加密值：编辑未修改时原样回传
struct SSHHostInfo: Decodable, Identifiable, Hashable {
    let id: Int
    let createdAt: String?
    let groupID: Int?
    let groupBelong: String?
    let name: String?
    let addr: String?
    let port: Int?
    let user: String?
    let authMode: String?
    let password: String?
    let privateKey: String?
    let passPhrase: String?
    let rememberPassword: Bool?
    let description: String?

    /// 行显示名：优先标题，否则 地址
    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        return addr ?? "未知主机"
    }

    var endpoint: String {
        let p = port.map { ":\($0)" } ?? ""
        return "\(addr ?? "—")\(p)"
    }

    var isKeyAuth: Bool { authMode == "key" }
}

// MARK: - 分组

/// 主机分组（POST /api/v2/groups/search, type=host）
struct SSHHostGroup: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let type: String?
    let isDefault: Bool?
}

// MARK: - 请求体

struct SSHHostListRequest: Encodable {
    var page = 1
    var pageSize = 100
    var groupID = 0
}

struct SSHHostGroupRequest: Encodable {
    var type = "host"
}

struct SSHHostDeleteRequest: Encodable {
    let ids: [Int]
}

struct SSHHostTestByIDRequest: Encodable {
    let id: Int
}

/// 添加 / 编辑 / 连接测试共用请求体（POST /api/v2/hosts、/hosts/update、/hosts/test/byinfo）
/// 凭据字段：新输入为明文 base64；编辑未修改时回传服务端加密原值
struct SSHHostUpsertRequest: Encodable {
    var id: Int? = nil
    var createdAt: String? = nil
    let groupID: Int
    var groupBelong: String? = nil
    var name: String?
    let addr: String
    let port: Int
    let user: String
    let authMode: String
    var password: String?
    var privateKey: String?
    var passPhrase: String?
    var rememberPassword: Bool
    var description: String?
}
