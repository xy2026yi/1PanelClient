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
    /// 创建时名称默认值（与网页端一致，如 Hermes Agent → Hermes-Agent）
    let defaultName: String
    /// OpenClaw 使用 token / 访问地址；其余使用用户名 + 密码
    let usesToken: Bool
    /// QwenPaw(copaw) 创建时不绑定模型账号（请求体无 model/accountId 字段）
    let needsModel: Bool

    var id: String { key }

    static let all: [AIAgentType] = [
        AIAgentType(key: "openclaw", displayName: "OpenClaw", defaultName: "OpenClaw", usesToken: true, needsModel: true),
        AIAgentType(key: "hermes-agent", displayName: "Hermes Agent", defaultName: "Hermes-Agent", usesToken: false, needsModel: true),
        AIAgentType(key: "copaw", displayName: "QwenPaw", defaultName: "QwenPaw", usesToken: false, needsModel: false),
    ]
}

/// POST /api/v2/ai/agents（创建；OpenClaw 带 token/allowedOrigins，QwenPaw 无模型绑定）
nonisolated struct AIAgentCreateRequest: Encodable {
    var name: String
    var remark: String
    var appVersion: String
    var webUIPort: Int
    var agentType: String
    /// QwenPaw(copaw) 不携带
    var model: String? = nil
    var accountId: Int? = nil
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
    /// Hermes 抓包确认：official / skills-sh；OpenClaw 抓包确认：clawhub-cn / clawhub-global / skillhub
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
    /// clawhub-* / skillhub（市场返回）
    let source: String?
    /// 同 source 取值集
    let trust: String?
    let score: String?

    /// 跳过空串并保持稳定（不能用 UUID()：每次访问变化会导致身份漂移）
    var id: String {
        let key = [identifier, slug, name]
            .compactMap { $0 }
            .first { !$0.isEmpty }
        if let key { return key }
        return [name ?? "", slug ?? "", source ?? ""].joined(separator: "|")
    }
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

    /// 服务端 identifier 可能为空串：跳过空值，避免所有行 ID 相同
    var id: String {
        let key = [identifier, name, source]
            .compactMap { $0 }
            .first { !$0.isEmpty }
        if let key { return key }
        return [name ?? "", source ?? "", description ?? ""]
            .joined(separator: "|")
    }
}

// MARK: - 其他设置 / 配置文件

nonisolated struct AIAgentOtherConfig: Decodable, Hashable {
    let userTimezone: String?
    let browserEnabled: Bool?
    let npmRegistry: String?
    let dashboardUsername: String?
    let dashboardPassword: String?
}

/// other/update：OpenClaw 无控制台账号、QwenPaw 不带时区（抓包确认；nil 不编码）
nonisolated struct AIAgentOtherUpdateRequest: Encodable {
    let agentId: Int
    var userTimezone: String? = nil
    let browserEnabled: Bool
    let npmRegistry: String
    var dashboardUsername: String? = nil
    var dashboardPassword: String? = nil
}

// MARK: - 安全设置（OpenClaw 专属：allowedOrigins）

/// POST security/get 响应 / security/update 请求体 {agentId, allowedOrigins}
nonisolated struct AIAgentSecurityConfig: Codable, Hashable {
    var agentId: Int? = nil
    var allowedOrigins: [String]? = nil
}

nonisolated struct AIAgentConfigFileRequest: Encodable {
    let agentId: Int
}

nonisolated struct AIAgentConfigFile: Decodable {
    let content: String?
}

// MARK: - 消息频道（logs/增加和修正.md 2026-09-12 抓包确认）

nonisolated struct AIAgentChannelRequest: Encodable {
    let agentId: Int
}

/// POST /api/v2/ai/agents/channel/delete {agentId, type}
nonisolated struct AIAgentChannelDeleteRequest: Encodable {
    let agentId: Int
    let type: String
}

/// POST /api/v2/ai/agents/channel/pairing/approve
/// {agentId, type, pairingCode[, accountId]}（多 Bot 频道带 accountId）
nonisolated struct AIAgentChannelPairingApproveRequest: Encodable {
    let agentId: Int
    let type: String
    let pairingCode: String
    var accountId: String? = nil
}

// MARK: - 角色（OpenClaw 多角色：/api/v2/ai/agents/agent/*）

/// POST agent/list {agentId} 返回的角色
nonisolated struct AIAgentRole: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let workspace: String?
    let model: String?
    let agentDir: String?
    let bindings: [AIAgentRoleBinding]?
}

nonisolated struct AIAgentRoleBinding: Codable, Hashable, Identifiable {
    var channel: String?
    var accountId: String?
    var id: String { (channel ?? "?") + ":" + (accountId ?? "?") }
}

/// POST agent/channels {agentId} 返回的可绑定频道（含账号列表）
nonisolated struct AIAgentRoleChannel: Decodable, Hashable, Identifiable {
    let name: String
    let bound: Bool?
    let accountIds: [String]?
    var id: String { name }
}

/// POST agent/create {agentId, name, model, bindings}
nonisolated struct AIAgentRoleCreateRequest: Encodable {
    let agentId: Int
    let name: String
    let model: String
    let bindings: [AIAgentRoleBinding]
}

/// POST agent/bind {agentId, id, channel, accountId}
nonisolated struct AIAgentRoleBindRequest: Encodable {
    let agentId: Int
    let id: String
    let channel: String
    let accountId: String
}

/// POST agent/unbind [推测：抓包缺失，与 bind 对称]
nonisolated struct AIAgentRoleUnbindRequest: Encodable {
    let agentId: Int
    let id: String
    let channel: String
    let accountId: String
}

/// POST agent/delete {agentId, id}
nonisolated struct AIAgentRoleDeleteRequest: Encodable {
    let agentId: Int
    let id: String
}

// MARK: - 技能启停（skills/update）

/// POST /api/v2/ai/agents/skills/update {agentId, name, enabled}
nonisolated struct AIAgentSkillUpdateRequest: Encodable {
    let agentId: Int
    let name: String
    let enabled: Bool
}

/// POST /api/v2/ai/agents/skills/uninstall {agentId, name}（Hermes 抓包确认，同步返回）
nonisolated struct AIAgentSkillUninstallRequest: Encodable {
    let agentId: Int
    let name: String
}

// MARK: - 智能体插件（OpenClaw：plugins/*，与频道插件 plugin/* 是两套端点）

/// POST plugins/list {agentId} 返回的已安装插件
nonisolated struct AIAgentPluginInfo: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let version: String?
    /// bundled / global 等
    let origin: String?
    let enabled: Bool?
}

/// POST plugins/operate {agentId, pluginId, operate, taskID}（启停，带任务进度）
nonisolated struct AIAgentPluginsOperateRequest: Encodable {
    let agentId: Int
    let pluginId: String
    let operate: String
    let taskID: String
}

/// POST plugins/search {agentId, keyword, limit} 返回的市场插件
nonisolated struct AIAgentMarketPlugin: Decodable, Identifiable, Hashable {
    let package: String
    let pluginId: String?
    let name: String?
    let description: String?
    let version: String?
    let channel: String?
    let verificationTier: String?
    let categories: [String]?
    let official: Bool?
    let downloads: Int?
    let score: Int?
    var id: String { package }
}

nonisolated struct AIAgentPluginsSearchRequest: Encodable {
    let agentId: Int
    let keyword: String
    let limit: Int
}

/// POST plugins/install {agentId, package, version, taskID}（带任务进度）
nonisolated struct AIAgentPluginsInstallRequest: Encodable {
    let agentId: Int
    let package: String
    let version: String
    let taskID: String
}

// MARK: - Hermes 对话会话（/api/v2/ai/agents/hermes/chat/*，logs/会话.md 抓包 2026-09-14）

/// POST hermes/chat/sessions {agentId} 返回的会话
nonisolated struct AIHermesChatSession: Decodable, Identifiable, Hashable {
    /// 20260914_090643_dbbadc 形式
    let id: String
    let title: String?
    let model: String?
    let messageCount: Int?
    /// 2026-09-14T01:08:32Z
    let startedAt: String?
    let lastActive: String?

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        return L10n.t("新对话")
    }
}

/// POST hermes/chat/sessions/delete {agentId, id}
nonisolated struct AIHermesChatSessionDeleteRequest: Encodable {
    let agentId: Int
    let id: String
}

/// POST hermes/chat/sessions/rename {agentId, id, title}
nonisolated struct AIHermesChatSessionRenameRequest: Encodable {
    let agentId: Int
    let id: String
    let title: String
}

// MARK: - 频道插件（OpenClaw 频道为插件：安装检查 / 版本 / 卸载）

/// POST /api/v2/ai/agents/plugin/check {agentId, type, checkLatest}
nonisolated struct AIAgentPluginCheckRequest: Encodable {
    let agentId: Int
    let type: String
    let checkLatest: Bool
}

/// plugin/check 返回：installed / currentVersion / latestVersion / upgradable
nonisolated struct AIAgentPluginStatus: Decodable, Hashable {
    let installed: Bool?
    let currentVersion: String?
    let latestVersion: String?
    let upgradable: Bool?
}

/// POST /api/v2/ai/agents/plugin/uninstall {agentId, type, taskID}
nonisolated struct AIAgentPluginUninstallRequest: Encodable {
    let agentId: Int
    let type: String
    let taskID: String
}

/// POST /api/v2/ai/agents/plugin/install {agentId, type, taskID}（进度同卸载）
nonisolated struct AIAgentPluginInstallRequest: Encodable {
    let agentId: Int
    let type: String
    let taskID: String
}

/// POST /api/v2/ai/agents/plugin/upgrade {agentId, type, taskID}（进度同安装/卸载）
nonisolated struct AIAgentPluginUpgradeRequest: Encodable {
    let agentId: Int
    let type: String
    let taskID: String
}

/// POST /api/v2/ai/agents/channel/weixin/login {agentId, taskID}
/// taskID 由客户端生成（抓包确认：响应 data 为 null，进度按该 taskID 查询）
nonisolated struct AIAgentWeixinLoginRequest: Encodable {
    let agentId: Int
    let taskID: String
}

// MARK: - 频道 Bot 条目（凭证在 bots 数组内，各频道字段不同）

/// Bot 行身份：accountId / name 非空串优先，全空兜底 UUID
/// （空串视为缺失——服务端可能返回 ""，多条会互相撞身份）
nonisolated enum AIChannelBotIdentity {
    static func make(_ accountId: String?, _ name: String?) -> String {
        if let id = accountId, !id.isEmpty { return id }
        if let n = name, !n.isEmpty { return n }
        return UUID().uuidString
    }
}

/// QQ Bot：{accountId, name, enabled, isDefault, appId, clientSecret, allowFrom, systemPrompt}
nonisolated struct AIChannelQQBotItem: Codable, Hashable, Identifiable {
    var accountId: String? = nil
    var name: String? = nil
    var enabled: Bool? = nil
    var isDefault: Bool? = nil
    var appId: String? = nil
    var clientSecret: String? = nil
    var allowFrom: [String]? = nil
    var systemPrompt: String? = nil
    var id: String { AIChannelBotIdentity.make(accountId, name) }
}

/// 飞书 Bot：{accountId, name, enabled, isDefault, appId, appSecret, dmPolicy, allowFrom}
nonisolated struct AIChannelFeishuBotItem: Codable, Hashable, Identifiable {
    var accountId: String? = nil
    var name: String? = nil
    var enabled: Bool? = nil
    var isDefault: Bool? = nil
    var appId: String? = nil
    var appSecret: String? = nil
    var dmPolicy: String? = nil
    var allowFrom: [String]? = nil
    var id: String { AIChannelBotIdentity.make(accountId, name) }
}

/// Telegram Bot：{accountId, name, enabled, isDefault, botToken, dmPolicy, groupPolicy, streaming}
nonisolated struct AIChannelTelegramBotItem: Codable, Hashable, Identifiable {
    var accountId: String? = nil
    var name: String? = nil
    var enabled: Bool? = nil
    var isDefault: Bool? = nil
    var botToken: String? = nil
    var dmPolicy: String? = nil
    var groupPolicy: String? = nil
    var streaming: String? = nil
    var id: String { AIChannelBotIdentity.make(accountId, name) }
}

/// Discord Bot：{accountId, name, enabled, isDefault, token}
nonisolated struct AIChannelDiscordBotItem: Codable, Hashable, Identifiable {
    var accountId: String? = nil
    var name: String? = nil
    var enabled: Bool? = nil
    var isDefault: Bool? = nil
    var token: String? = nil
    var id: String { AIChannelBotIdentity.make(accountId, name) }
}

/// 钉钉 Bot：{accountId, name, enabled, isDefault, clientId, clientSecret}
nonisolated struct AIChannelDingtalkBotItem: Codable, Hashable, Identifiable {
    var accountId: String? = nil
    var name: String? = nil
    var enabled: Bool? = nil
    var isDefault: Bool? = nil
    var clientId: String? = nil
    var clientSecret: String? = nil
    var id: String { AIChannelBotIdentity.make(accountId, name) }
}

// MARK: - 频道配置（get 响应 + update 请求体同构：{agentId} + 字段平铺）

/// QQ：抓包 update 请求体（凭证在 bots[0]，非顶层）
nonisolated struct AIChannelQQBot: Codable, Hashable {
    var agentId: Int? = nil
    var enabled: Bool? = nil
    var dmPolicy: String? = nil
    var allowFrom: [String]? = nil
    var groupPolicy: String? = nil
    var groupAllowFrom: [String]? = nil
    var bots: [AIChannelQQBotItem]? = nil
    var installed: Bool? = nil
}

/// 企业微信：{enabled, dmPolicy, ..., botId, secret}
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

/// 钉钉：{enabled, dmPolicy, 会话/异步设置, bots[{clientId, clientSecret}]}
nonisolated struct AIChannelDingtalk: Codable, Hashable {
    var agentId: Int? = nil
    var enabled: Bool? = nil
    var dmPolicy: String? = nil
    var allowFrom: [String]? = nil
    var groupPolicy: String? = nil
    var groupAllowFrom: [String]? = nil
    var separateSessionByConversation: Bool? = nil
    var groupSessionScope: String? = nil
    var sharedMemoryAcrossConversations: Bool? = nil
    var asyncMode: Bool? = nil
    var ackText: String? = nil
    var bots: [AIChannelDingtalkBotItem]? = nil
    var installed: Bool? = nil
}

/// 飞书：{enabled, threadSession, replyMode, streaming, requireMention,
/// groupPolicy, ..., bots[{appId, appSecret, dmPolicy}]}
nonisolated struct AIChannelFeishu: Codable, Hashable {
    var agentId: Int? = nil
    var enabled: Bool? = nil
    var threadSession: Bool? = nil
    var replyMode: String? = nil
    var streaming: Bool? = nil
    /// 抓包为字符串 "true" / ""
    var requireMention: String? = nil
    var groupPolicy: String? = nil
    var groupAllowFrom: [String]? = nil
    var dmPolicy: String? = nil
    var domain: String? = nil
    var connectionMode: String? = nil
    var bots: [AIChannelFeishuBotItem]? = nil
    var installed: Bool? = nil
}

/// Telegram：{enabled, dmPolicy, requireMention, groupPolicy, proxy,
/// streaming, defaultAccount, bots[{botToken, 策略, streaming}]}
nonisolated struct AIChannelTelegram: Codable, Hashable {
    var agentId: Int? = nil
    var enabled: Bool? = nil
    var dmPolicy: String? = nil
    var allowFrom: [String]? = nil
    var requireMention: Bool? = nil
    var groupPolicy: String? = nil
    var groupAllowFrom: [String]? = nil
    var proxy: String? = nil
    /// off / partial / block / progress
    var streaming: String? = nil
    var defaultAccount: String? = nil
    var bots: [AIChannelTelegramBotItem]? = nil
}

/// Discord：与 Telegram 同构，bots 凭证为 token
nonisolated struct AIChannelDiscord: Codable, Hashable {
    var agentId: Int? = nil
    var enabled: Bool? = nil
    var dmPolicy: String? = nil
    var allowFrom: [String]? = nil
    var requireMention: Bool? = nil
    var groupPolicy: String? = nil
    var groupAllowFrom: [String]? = nil
    var proxy: String? = nil
    var defaultAccount: String? = nil
    var bots: [AIChannelDiscordBotItem]? = nil
}

// MARK: - 频道策略与流式取值（抓包确认：pairing / open / allowlist / disabled）

enum AIChannelPolicy {
    /// 私聊策略全集：配队码 / 开放 / 白名单 / 禁用
    static var dmPoliciesFull: [(value: String, label: String)] {
        [
            ("pairing", L10n.t("配队码")),
            ("open", L10n.t("开放")),
            ("allowlist", L10n.t("白名单")),
            ("disabled", L10n.t("禁用")),
        ]
    }
    /// 基础私聊策略（QQ / 飞书 / 钉钉 / 企微）：配队码 / 开放 / 禁用
    static var dmPoliciesBasic: [(value: String, label: String)] {
        dmPoliciesFull.filter { $0.value != "allowlist" }
    }
    /// 配队码 / 开放（Hermes 抓包核对：私聊策略无白名单与禁用）
    static var dmPoliciesPairingOpen: [(value: String, label: String)] {
        dmPoliciesFull.filter { $0.value == "pairing" || $0.value == "open" }
    }
    /// 群组策略全集：开放 / 白名单 / 禁用
    static var groupPoliciesFull: [(value: String, label: String)] {
        [
            ("open", L10n.t("开放")),
            ("allowlist", L10n.t("白名单")),
            ("disabled", L10n.t("禁用")),
        ]
    }
    /// 基础群组策略：开放 / 禁用
    static var groupPoliciesBasic: [(value: String, label: String)] {
        groupPoliciesFull.filter { $0.value != "allowlist" }
    }
}

/// Telegram 流式传输取值（抓包：off / partial / block / progress）
enum AIChannelStreaming {
    static var options: [(value: String, label: String)] {
        [
            ("off", L10n.t("关闭")),
            ("partial", L10n.t("部分输出")),
            ("block", L10n.t("阻塞输出")),
            ("progress", L10n.t("进度输出")),
        ]
    }
}
