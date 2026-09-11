//
//  AIAgentModels.swift
//  1PanelClient
//
//  AI 智能体（/api/v2/ai/agents）：列表 / 创建（安装应用）/ 删除检查 /
//  网站绑定 / 模型配置 / 技能 / 其他设置 / 配置文件 / 消息频道（7 种）
//

import Foundation

// MARK: - 智能体

/// POST /api/v2/ai/agents/search 返回的智能体
nonisolated struct AIAgent: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let remark: String?
    /// openclaw / hermes-agent / copaw
    let agentType: String?
    let provider: String?
    let providerName: String?
    let model: String?
    let apiType: String?
    let baseUrl: String?
    /// 打码后的密钥（sk-****xxxx）
    let apiKey: String?
    let token: String?
    let dashboardUsername: String?
    let dashboardPassword: String?
    /// Running / Installing / Exited / ...
    let status: String?
    let message: String?
    let appInstallId: Int?
    let websiteId: Int?
    let websitePrimaryDomain: String?
    let websiteType: String?
    let websiteProtocol: String?
    let accountId: Int?
    let appVersion: String?
    let containerName: String?
    let webUIPort: Int?
    let bridgePort: Int?
    let path: String?
    let configPath: String?
    let upgradable: Bool?
    let createdAt: String?

    var isRunning: Bool { (status ?? "").lowercased() == "running" }
    var isInstalling: Bool { (status ?? "").lowercased() == "installing" }
    var displayCreatedAt: String {
        guard let t = createdAt, !t.isEmpty else { return "-" }
        return String(t.prefix(10))
    }
}

/// 智能体类型定义（创建表单用）
nonisolated struct AIAgentType: Identifiable, Hashable {
    let key: String
    let displayName: String
    /// OpenClaw 使用 token / 访问地址；其余使用用户名 + 密码
    let usesToken: Bool

    var id: String { key }

    static let all: [AIAgentType] = [
        AIAgentType(key: "openclaw", displayName: "OpenClaw", usesToken: true),
        AIAgentType(key: "hermes-agent", displayName: "Hermes Agent", usesToken: false),
        AIAgentType(key: "copaw", displayName: "QwenPaw", usesToken: false),
    ]
}

/// POST /api/v2/ai/agents（创建；OpenClaw 带 token/allowedOrigins，其余带用户名/密码）
nonisolated struct AIAgentCreateRequest: Encodable {
    var name: String
    var remark: String
    var appVersion: String
    var webUIPort: Int
    var agentType: String
    var model: String
    var accountId: Int
    var taskID: String
    var advanced: Bool
    var containerName: String
    var allowPort: Bool
    var specifyIP: String
    var restartPolicy: String
    var cpuQuota: Int
    var memoryLimit: Int
    var memoryUnit: String
    var pullImage: Bool
    var editCompose: Bool
    var dockerCompose: String
    // OpenClaw 专属
    var allowedOrigins: [String]? = nil
    var token: String? = nil
    // 非 OpenClaw 专属
    var dashboardUsername: String? = nil
    var dashboardPassword: String? = nil

    enum CodingKeys: String, CodingKey {
        case name, remark, appVersion, webUIPort, agentType, model, accountId
        case taskID, advanced, containerName, allowPort, specifyIP, restartPolicy
        case cpuQuota, memoryLimit, memoryUnit, pullImage, editCompose, dockerCompose
        case allowedOrigins, token, dashboardUsername, dashboardPassword
    }
}

/// POST /api/v2/ai/agents/delete/check {agentId} → 绑定资源列表
nonisolated struct AIAgentDeleteCheckRequest: Encodable {
    let agentId: Int
}

nonisolated struct AIAgentBoundResource: Decodable, Hashable {
    /// website / mcp 等
    let type: String?
    let name: String?
}

/// POST /api/v2/ai/agents/delete {id, taskID, forceDelete}
nonisolated struct AIAgentDeleteRequest: Encodable {
    let id: Int
    let taskID: String
    let forceDelete: Bool
}

// MARK: - 网站绑定

nonisolated struct AIAgentWebsiteBindRequest: Encodable {
    let agentId: Int
    let websiteId: Int
}

nonisolated struct AIAgentWebsiteUnbindRequest: Encodable {
    let agentId: Int
}

// MARK: - 模型配置

nonisolated struct AIAgentModelRequest: Encodable {
    let agentId: Int
}

nonisolated struct AIAgentModelConfig: Decodable, Hashable {
    let accountId: Int?
    let model: String?
    let fallbacks: [String]?
}

nonisolated struct AIAgentModelUpdateRequest: Encodable {
    let agentId: Int
    let accountId: Int
    let model: String
    let fallbacks: [String]
}

// MARK: - 技能

nonisolated struct AIAgentSkillSearchRequest: Encodable {
    let agentId: Int
    /// official / skills-sh
    let source: String
    let keyword: String
}

nonisolated struct AIAgentSkillItem: Decodable, Identifiable, Hashable {
    let slug: String?
    let identifier: String?
    let name: String?
    let description: String?
    let summary: String?
    let version: String?
    /// official / skills-sh / builtin
    let source: String?
    /// official / skills-sh / builtin
    let trust: String?
    let score: String?

    var id: String { identifier ?? slug ?? name ?? UUID().uuidString }
}

nonisolated struct AIAgentSkillInstallRequest: Encodable {
    let agentId: Int
    let source: String
    let slug: String
    let taskID: String
}

nonisolated struct AIAgentSkillInstalled: Decodable, Identifiable, Hashable {
    let name: String?
    let description: String?
    let category: String?
    let tags: [String]?
    let source: String?
    let trust: String?
    let identifier: String?
    let bundled: Bool?
    let disabled: Bool?
    let uninstallable: Bool?

    var id: String { identifier ?? name ?? UUID().uuidString }
}

// MARK: - 其他设置 / 配置文件

nonisolated struct AIAgentOtherConfig: Decodable, Hashable {
    let userTimezone: String?
    let browserEnabled: Bool?
    let npmRegistry: String?
    let dashboardUsername: String?
    let dashboardPassword: String?
}

nonisolated struct AIAgentOtherUpdateRequest: Encodable {
    let agentId: Int
    let userTimezone: String
    let browserEnabled: Bool
    let npmRegistry: String
    let dashboardUsername: String
    let dashboardPassword: String
}

nonisolated struct AIAgentConfigFileRequest: Encodable {
    let agentId: Int
}

nonisolated struct AIAgentConfigFile: Decodable {
    let content: String?
}

// MARK: - 消息频道（通用读取请求）

nonisolated struct AIAgentChannelRequest: Encodable {
    let agentId: Int
}

/// POST /api/v2/ai/agents/channel/delete {agentId, type}
nonisolated struct AIAgentChannelDeleteRequest: Encodable {
    let agentId: Int
    let type: String
}

// MARK: - 频道配置（7 种，字段按抓包全设可选）
// 保存请求为 {agentId} + 配置字段平铺：各结构体带 var agentId（GET 响应不含、
// 保存前由视图填入），编码时自然并入同一层 JSON；
// 凭证类字段（AppID/Secret/Token 等）抓包 get 响应未回显，为表单提交补充

/// 微信：{enabled}
nonisolated struct AIChannelWeixin: Codable, Hashable {
    var agentId: Int? = nil
    var enabled: Bool? = nil
}

/// QQ：{enabled, dmPolicy, allowFrom, groupPolicy, groupAllowFrom, bots, installed} + 表单凭证 appId/appSecret
nonisolated struct AIChannelQQBot: Codable, Hashable {
    var agentId: Int? = nil
    var enabled: Bool? = nil
    var dmPolicy: String? = nil
    var allowFrom: [String]? = nil
    var groupPolicy: String? = nil
    var groupAllowFrom: [String]? = nil
    var appId: String? = nil
    var appSecret: String? = nil
    var bots: [String]? = nil
    var installed: Bool? = nil
}

/// 企业微信：{enabled, dmPolicy, ..., botId, secret, installed}
nonisolated struct AIChannelWecom: Codable, Hashable {
    var agentId: Int? = nil
    var enabled: Bool? = nil
    var dmPolicy: String? = nil
    var allowFrom: [String]? = nil
    var groupPolicy: String? = nil
    var groupAllowFrom: [String]? = nil
    var botId: String? = nil
    var secret: String? = nil
    var installed: Bool? = nil
}

/// 钉钉：{enabled, dmPolicy, ..., bots, installed} + 表单凭证 clientId/clientSecret
nonisolated struct AIChannelDingtalk: Codable, Hashable {
    var agentId: Int? = nil
    var enabled: Bool? = nil
    var dmPolicy: String? = nil
    var allowFrom: [String]? = nil
    var groupPolicy: String? = nil
    var groupAllowFrom: [String]? = nil
    var clientId: String? = nil
    var clientSecret: String? = nil
    var separateSessionByConversation: Bool? = nil
    var groupSessionScope: String? = nil
    var sharedMemoryAcrossConversations: Bool? = nil
    var asyncMode: Bool? = nil
    var ackText: String? = nil
    var bots: [String]? = nil
    var installed: Bool? = nil
}

/// 飞书：{enabled, threadSession, ..., bots, installed} + 表单凭证 appId/appSecret
nonisolated struct AIChannelFeishu: Codable, Hashable {
    var agentId: Int? = nil
    var enabled: Bool? = nil
    var appId: String? = nil
    var appSecret: String? = nil
    var threadSession: Bool? = nil
    var replyMode: String? = nil
    var streaming: Bool? = nil
    var requireMention: String? = nil
    var groupPolicy: String? = nil
    var groupAllowFrom: [String]? = nil
    var dmPolicy: String? = nil
    var domain: String? = nil
    var connectionMode: String? = nil
    var bots: [String]? = nil
    var installed: Bool? = nil
}

/// Telegram：{enabled, dmPolicy, ..., bots} + 表单凭证 botToken
nonisolated struct AIChannelTelegram: Codable, Hashable {
    var agentId: Int? = nil
    var enabled: Bool? = nil
    var botToken: String? = nil
    var dmPolicy: String? = nil
    var allowFrom: [String]? = nil
    var requireMention: Bool? = nil
    var groupPolicy: String? = nil
    var groupAllowFrom: [String]? = nil
    var proxy: String? = nil
    var streaming: String? = nil
    var defaultAccount: String? = nil
    var bots: [String]? = nil
}

/// Discord：与 Telegram 同构 + 表单凭证 token
nonisolated struct AIChannelDiscord: Codable, Hashable {
    var agentId: Int? = nil
    var enabled: Bool? = nil
    var token: String? = nil
    var dmPolicy: String? = nil
    var allowFrom: [String]? = nil
    var requireMention: Bool? = nil
    var groupPolicy: String? = nil
    var groupAllowFrom: [String]? = nil
    var proxy: String? = nil
    var streaming: String? = nil
    var defaultAccount: String? = nil
    var bots: [String]? = nil
}

// MARK: - 频道策略取值 [推测：抓包 get 响应均为空串，按语义推定，联调时修正]

enum AIChannelPolicy {
    /// 私聊策略：配队码 / 开放 / 禁用（计算属性：L10n 语言切换后不固化旧文案）
    static var dmPolicies: [(value: String, label: String)] {
        [
            ("paircode", L10n.t("配队码")),
            ("open", L10n.t("开放")),
            ("disabled", L10n.t("禁用")),
        ]
    }
    /// 群组策略：开放 / 禁用
    static var groupPolicies: [(value: String, label: String)] {
        [
            ("open", L10n.t("开放")),
            ("disabled", L10n.t("禁用")),
        ]
    }
}
