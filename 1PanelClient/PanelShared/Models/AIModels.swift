//
//  AIModels.swift
//  1PanelClient
//
//  AI 模块通用 DTO（/api/v2/ai/*）：模型引用 / 分页请求 /
//  键值对（MCP 环境变量）/ 域名绑定（MCP 与 Ollama 网关共用）
//

import Foundation

// MARK: - 模型引用

/// 模型池条目（账号模型 / 智能体主模型通用）
nonisolated struct AIModelRef: Codable, Identifiable, Hashable {
    var recordId: Int?
    let id: String
    var name: String?
}

// MARK: - 分页请求

/// AI 模块通用分页查询（accounts/agents/mcp/ollama 列表）
nonisolated struct AISearchPageRequest: Encodable {
    var page: Int = 1
    var pageSize: Int = 20
    var name: String = ""
}

// MARK: - 键值对（MCP 环境变量）

nonisolated struct AIKeyValueItem: Codable, Hashable, Identifiable {
    let key: String
    var value: String
    var id: String { key }
}

// MARK: - 域名绑定（MCP /ai/mcp/domain 与 Ollama 网关 /ai/domain 共用）

/// GET domain/get 返回：{domain, sslID, acmeAccountID, allowIPs, websiteID, connUrl}
nonisolated struct AIDomainInfo: Decodable {
    let domain: String?
    let sslID: Int?
    let acmeAccountID: Int?
    let allowIPs: [String]?
    let websiteID: Int?
    let connUrl: String?
}

/// POST /api/v2/ai/domain/get 请求：Ollama 网关按 appInstallID 查询
nonisolated struct AIDomainGetRequest: Encodable {
    let appInstallID: Int
}

/// bind / update 请求：
/// MCP 未开启 HTTPS 不带 sslID，开启后带；Ollama 网关带 appInstallID；
/// allowIPs 抓包恒为空数组，实际白名单走 ipList 多行文本（\n 分隔）
nonisolated struct AIDomainBindRequest: Encodable {
    var domain: String
    var sslID: Int? = nil
    var ipList: String
    var acmeAccountID: Int = 0
    var enableSSL: Bool
    var allowIPs: [String] = []
    var websiteID: Int = 0
    var appInstallID: Int? = nil
}
