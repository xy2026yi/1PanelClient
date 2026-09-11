//
//  AIMcpModels.swift
//  1PanelClient
//
//  MCP Server（/api/v2/ai/mcp）：分页搜索 / 创建 / 编辑（全字段回传）/
//  启停重启 / 状态同步 / 测试连接 / 删除
//

import Foundation

// MARK: - 列表项

/// POST /api/v2/ai/mcp/search 返回的 MCP Server
nonisolated struct McpServer: Decodable, Identifiable, Hashable {
    let id: Int
    let createdAt: String?
    let updatedAt: String?
    let name: String
    let dockerCompose: String?
    /// 启动命令（多行：多个 stdio 命令换行分隔）
    let command: String?
    let containerName: String?
    /// var：status/sync 批量回写
    var message: String?
    let port: Int?
    /// Running / ...（var：status/sync 批量回写）
    var status: String?
    /// 服务端渲染好的环境变量快照（编辑时原样回传）
    let env: String?
    let baseUrl: String?
    let ssePath: String?
    let websiteID: Int?
    let dir: String?
    let hostIP: String?
    let streamableHttpPath: String?
    /// sse / streamableHttp
    let outputTransport: String?
    /// npx / uvx
    let type: String?
    let gatewayImage: String?
    let protocolVersion: String?
    let gatewayArgs: String?
    let environments: [AIKeyValueItem]?
    let volumes: [String]?

    var isRunning: Bool { (status ?? "").lowercased() == "running" }
}

// MARK: - 创建 / 编辑

/// POST /api/v2/ai/mcp/server（创建）/server/update（编辑）
/// 编辑为全字段回传：createdAt/updatedAt/status/message/env/dockerCompose 等
/// 服务端生成字段需按原值带上，protocol/url 为 UI 辅助字段一并提交
nonisolated struct McpServerUpsertRequest: Encodable {
    var id: Int
    var createdAt: String
    var updatedAt: String
    var name: String
    var dockerCompose: String
    var command: String
    var containerName: String
    var message: String
    var port: Int
    var status: String
    var env: String
    var baseUrl: String
    var ssePath: String
    var websiteID: Int
    var dir: String
    var hostIP: String
    var streamableHttpPath: String
    var outputTransport: String
    var type: String
    var gatewayImage: String
    var protocolVersion: String
    var gatewayArgs: String
    var environments: [AIKeyValueItem]
    var volumes: [String]
    var protocolScheme: String
    var urlHost: String
    var taskID: String

    enum CodingKeys: String, CodingKey {
        case id, createdAt, updatedAt, name, dockerCompose, command, containerName
        case message, port, status, env, baseUrl, ssePath, websiteID, dir, hostIP
        case streamableHttpPath, outputTransport, type, gatewayImage, protocolVersion
        case gatewayArgs, environments, volumes, taskID
        case protocolScheme = "protocol"
        case urlHost = "url"
    }
}

/// POST /api/v2/ai/mcp/server/del {id}
nonisolated struct McpServerDeleteRequest: Encodable {
    let id: Int
}

/// POST /api/v2/ai/mcp/server/op {id, operate}
nonisolated struct McpServerOperateRequest: Encodable {
    let id: Int
    let operate: String
}

// MARK: - 状态同步 / 测试连接

/// POST /api/v2/ai/mcp/server/status/sync {ids}
nonisolated struct McpStatusSyncRequest: Encodable {
    let ids: [Int]
}

nonisolated struct McpStatusItem: Decodable, Identifiable, Hashable {
    let id: Int
    let status: String?
    let message: String?
}

/// POST /api/v2/ai/mcp/server/connection/test {id}
nonisolated struct McpConnectionTestRequest: Encodable {
    let id: Int
}

nonisolated struct McpConnectionTestResult: Decodable, Hashable {
    let success: Bool?
    let endpoint: String?
    let outputTransport: String?
    let protocolVersion: String?
    let message: String?
}
