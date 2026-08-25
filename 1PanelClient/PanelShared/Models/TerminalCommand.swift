//
//  TerminalCommand.swift
//  1PanelClient
//
//  终端快速命令 + 终端设置（默认连接 / 连接信息）数据模型与请求体
//  基于 doc/终端-1.md 抓包（core/commands*、settings/ssh*）
//

import Foundation

// MARK: - 快速命令

/// 快速命令（POST /api/v2/core/commands/search, type=command 返回项）
struct QuickCommand: Decodable, Identifiable, Hashable {
    let id: Int
    let groupID: Int?
    let name: String?
    let type: String?
    let command: String?
    let groupBelong: String?
}

/// 快速命令分页查询
struct QuickCommandSearchRequest: Encodable {
    var page = 1
    var pageSize = 100
    var groupID = 0
    var orderBy = "name"
    var order = "ascending"
    var type = "command"
    var info = ""
}

/// 创建 / 更新快速命令（更新带 id 与 groupBelong）
struct QuickCommandUpsertRequest: Encodable {
    var id: Int? = nil
    var type = "command"
    var groupID: Int
    var name: String
    var command: String
    var groupBelong: String? = nil
}

/// 删除快速命令（服务端 CommandDelete 要求 type + ids）
struct QuickCommandDeleteRequest: Encodable {
    var type = "command"
    let ids: [Int]
}

/// 命令分组查询（POST /api/v2/core/groups/search, type=command）
struct QuickCommandGroupRequest: Encodable {
    var type = "command"
}

// MARK: - 终端设置

/// GET /api/v2/settings/ssh/conn：默认连接状态 + 连接信息
/// password / privateKey / passPhrase 为 base64 值：未修改时原样回传
struct TerminalSSHConn: Decodable, Identifiable {
    let addr: String?
    let port: Int?
    let user: String?
    let authMode: String?
    let password: String?
    let privateKey: String?
    let passPhrase: String?
    /// 默认连接开关：Enable / Disable
    let localSSHConnShow: String?

    /// 单记录模型：稳定占位 id
    var id: String { "\(user ?? "")@\(addr ?? ""):\(port ?? 0)" }

    var isDefaultConnEnabled: Bool { localSSHConnShow == "Enable" }
}

/// POST /api/v2/settings/ssh/default：默认连接开关
struct TerminalSSHDefaultRequest: Encodable {
    let withReset: Bool
    let defaultConn: String
}

/// POST /api/v2/settings/ssh/check/info 与 /settings/ssh：连接信息测试 / 保存
/// 凭据字段为 base64（新输入明文 base64，未修改回传服务端原值）
struct TerminalSSHConnUpdateRequest: Encodable {
    var user: String
    var addr: String
    var port: Int
    var authMode: String
    var password: String
    var privateKey: String
    var passPhrase: String
    var isLocal = true
    var id = 0
    var name = ""
    var groupID = 0
    var description = ""
    var rememberPassword = false
    var localSSHConnShow = ""
}
