//
//  AIAccountModels.swift
//  1PanelClient
//
//  AI 模型账号（/api/v2/ai/accounts）：列表 / 创建 / 编辑 / 删除 /
//  供应商预设 / 模型发现 / 模型池 CRUD
//  注意：请求体 Base URL 键为 baseURL，响应为 baseUrl（后端两侧 tag 不一致）
//

import Foundation

// MARK: - 账号

/// POST /api/v2/ai/accounts/search 返回的模型账号
nonisolated struct AIAccount: Decodable, Identifiable, Hashable {
    let id: Int
    let masterAccountId: Int?
    let provider: String
    let providerName: String?
    let name: String
    let apiKey: String?
    let rememberApiKey: Bool?
    let baseUrl: String?
    let models: [AIModelRef]?
    let apiType: String?
    let authMode: String?
    /// 验证可用性所用的模型 id
    let verifyModel: String?
    let verified: Bool?
    let remark: String?
    let createdAt: String?

    /// 列表展示用日期（Go 纳秒精度时间串取日期段）
    var displayCreatedAt: String {
        guard let t = createdAt, !t.isEmpty else { return "-" }
        return String(t.prefix(10))
    }
}

/// POST /api/v2/ai/accounts（创建）
nonisolated struct AIAccountCreateRequest: Encodable {
    var provider: String
    var name: String
    var baseURL: String
    var apiKey: String
    var rememberApiKey: Bool
    var apiType: String
    var authMode: String
    var verifyModel: String
    var validateAvailability: Bool
    var models: [AIModelRef]
    var remark: String

    enum CodingKeys: String, CodingKey {
        case provider, name, apiKey, rememberApiKey, apiType
        case authMode, verifyModel, validateAvailability, models, remark
        case baseURL
    }
}

/// POST /api/v2/ai/accounts/update（编辑；不含 provider/models，另有 syncAgents）
nonisolated struct AIAccountUpdateRequest: Encodable {
    var id: Int
    var name: String
    var baseURL: String
    var apiKey: String
    var rememberApiKey: Bool
    var apiType: String
    var authMode: String
    var verifyModel: String
    var validateAvailability: Bool
    var remark: String
    var syncAgents: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, apiKey, rememberApiKey, apiType, authMode
        case verifyModel, validateAvailability, remark, syncAgents
        case baseURL
    }
}

/// POST /api/v2/ai/accounts/delete {id}
nonisolated struct AIAccountDeleteRequest: Encodable {
    let id: Int
}

// MARK: - 供应商预设

/// GET /api/v2/ai/accounts/providers 返回的预设供应商
nonisolated struct AIProvider: Decodable, Identifiable, Hashable {
    let provider: String
    let displayName: String?
    let baseUrl: String?
    let defaultApiType: String?
    let apiTypes: [AIProviderApiType]?
    /// 预设模型（DeepSeek/Gemini 等固定清单；custom 为空靠发现/手填）
    let models: [AIModelRef]?

    var id: String { provider }
    var displayTitle: String { displayName ?? provider }
}

/// 供应商支持的 API 类型
nonisolated struct AIProviderApiType: Decodable, Identifiable, Hashable {
    let apiType: String
    let baseUrl: String?
    let editableBaseUrl: Bool?
    let supportsModelDiscovery: Bool?
    let defaultAuthMode: String?
    let authModes: [String]?
    let models: [AIModelRef]?

    var id: String { apiType }
}

// MARK: - 模型发现 / 模型池

/// POST /api/v2/ai/accounts/models/discover {provider, baseURL, apiKey, apiType}
nonisolated struct AIAccountDiscoverRequest: Encodable {
    var provider: String
    var baseURL: String
    var apiKey: String
    var apiType: String

    enum CodingKeys: String, CodingKey {
        case provider, apiKey, apiType
        case baseURL
    }
}

/// POST /api/v2/ai/accounts/models {accountId}
nonisolated struct AIAccountModelsRequest: Encodable {
    let accountId: Int
}

/// POST /api/v2/ai/accounts/models/create | /update
nonisolated struct AIAccountModelUpsertRequest: Encodable {
    let accountId: Int
    let model: AIModelRef
}

/// POST /api/v2/ai/accounts/models/delete
nonisolated struct AIAccountModelDeleteRequest: Encodable {
    let accountId: Int
    let recordId: Int
}
