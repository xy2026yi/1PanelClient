//
//  AIAgentChannelModelsTests.swift
//  1PanelClientTests
//
//  智能体频道模型测试（样本取自 logs/增加和修正.md 抓包 2026-09-12）：
//  bots 数组解码 / update 请求编码（凭证在 bots 内）/ 配对批准请求 / 策略取值
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("智能体频道模型")
struct AIAgentChannelModelsTests {

    @Test("QQ 频道 get 响应解码（bots 数组 + installed 标记）")
    func decodeQQChannel() throws {
        let json = """
        {"enabled": true, "dmPolicy": "open", "allowFrom": [], "groupPolicy": "open",
         "groupAllowFrom": [], "installed": false,
         "bots": [{"accountId": "default", "name": "Default", "enabled": true, "isDefault": true,
                   "appId": "123456", "clientSecret": "123456", "allowFrom": null, "systemPrompt": ""}]}
        """
        let c = try JSONDecoder().decode(AIChannelQQBot.self, from: Data(json.utf8))
        #expect(c.enabled == true)
        #expect(c.dmPolicy == "open")
        #expect(c.installed == false)
        let bot = try #require(c.bots?.first)
        #expect(bot.accountId == "default")
        #expect(bot.appId == "123456")
        #expect(bot.allowFrom == nil)
    }

    @Test("QQ 频道 update 请求编码（凭证在 bots[0]，与抓包一致）")
    func encodeQQUpdate() throws {
        var c = AIChannelQQBot()
        c.agentId = 8
        c.enabled = true
        c.dmPolicy = "open"
        c.allowFrom = []
        c.groupPolicy = "open"
        c.groupAllowFrom = []
        c.bots = [AIChannelQQBotItem(
            accountId: "default", name: "Default", enabled: true, isDefault: true,
            appId: "1906699778", clientSecret: "xxxxxxxxx",
            allowFrom: [], systemPrompt: "")]
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as? [String: Any])
        #expect(obj["agentId"] as? Int == 8)
        #expect(obj["dmPolicy"] as? String == "open")
        // 凭证不在顶层（旧实现错误位置）
        #expect(obj["appId"] == nil)
        let bots = try #require(obj["bots"] as? [[String: Any]])
        let bot = try #require(bots.first)
        #expect(bot["accountId"] as? String == "default")
        #expect(bot["appId"] as? String == "1906699778")
        #expect(bot["isDefault"] as? Bool == true)
    }

    @Test("Telegram 频道 get 响应解码（多 Bot + 流式/代理字段）")
    func decodeTelegramChannel() throws {
        let json = """
        {"enabled": true, "dmPolicy": "pairing", "allowFrom": [], "requireMention": false,
         "groupPolicy": "open", "groupAllowFrom": [], "proxy": "", "streaming": "partial",
         "defaultAccount": "123",
         "bots": [
            {"accountId": "123", "name": "123", "enabled": true, "isDefault": true,
             "botToken": "123456", "dmPolicy": "pairing", "groupPolicy": "allowlist", "streaming": "block"},
            {"accountId": "123456", "name": "123456", "enabled": true, "isDefault": false,
             "botToken": "1234567", "dmPolicy": "allowlist", "groupPolicy": "disabled", "streaming": "progress"}
         ]}
        """
        let c = try JSONDecoder().decode(AIChannelTelegram.self, from: Data(json.utf8))
        #expect(c.requireMention == false)
        #expect(c.streaming == "partial")
        #expect(c.bots?.count == 2)
        #expect(c.bots?.first?.streaming == "block")
        #expect(c.bots?.last?.groupPolicy == "disabled")
    }

    @Test("钉钉频道 get 解码（会话/异步字段在顶层，凭证在 bots）")
    func decodeDingtalkChannel() throws {
        let json = """
        {"enabled": true, "dmPolicy": "pairing", "allowFrom": [], "groupPolicy": "",
         "groupAllowFrom": [], "separateSessionByConversation": false, "groupSessionScope": "",
         "sharedMemoryAcrossConversations": false, "asyncMode": false, "ackText": "",
         "bots": [{"accountId": "default", "name": "Default", "enabled": true,
                   "isDefault": true, "clientId": "123456", "clientSecret": "123456"}],
         "installed": false}
        """
        let c = try JSONDecoder().decode(AIChannelDingtalk.self, from: Data(json.utf8))
        #expect(c.separateSessionByConversation == false)
        #expect(c.asyncMode == false)
        #expect(c.bots?.first?.clientId == "123456")
    }

    @Test("飞书频道 get 解码（requireMention 为字符串）")
    func decodeFeishuChannel() throws {
        let json = """
        {"enabled": true, "threadSession": false, "replyMode": "", "streaming": false,
         "requireMention": "", "groupPolicy": "open", "groupAllowFrom": [],
         "domain": "feishu", "connectionMode": "websocket",
         "bots": [{"accountId": "default", "name": "Default", "enabled": true,
                   "isDefault": true, "appId": "123456", "appSecret": "123456",
                   "dmPolicy": "open", "allowFrom": []}],
         "installed": false}
        """
        let c = try JSONDecoder().decode(AIChannelFeishu.self, from: Data(json.utf8))
        #expect(c.requireMention == "")
        #expect(c.threadSession == false)
        #expect(c.bots?.first?.dmPolicy == "open")
    }

    @Test("配对批准请求编码（基础不带 accountId，多 Bot 带默认账户）")
    func encodePairingApprove() throws {
        let basic = AIAgentChannelPairingApproveRequest(agentId: 8, type: "qqbot", pairingCode: "123456")
        let basicObj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(basic)) as? [String: Any])
        #expect(basicObj["agentId"] as? Int == 8)
        #expect(basicObj["type"] as? String == "qqbot")
        #expect(basicObj["pairingCode"] as? String == "123456")
        #expect(basicObj["accountId"] == nil)

        let multi = AIAgentChannelPairingApproveRequest(agentId: 10, type: "telegram", pairingCode: "123456", accountId: "123")
        let multiObj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(multi)) as? [String: Any])
        #expect(multiObj["accountId"] as? String == "123")
    }

    @Test("QwenPaw 创建请求不含模型绑定字段（抓包确认）")
    func encodeCopawCreate() throws {
        var req = AIAgentCreateRequest(
            name: "QwenPaw", remark: "", appVersion: "2.2.0", webUIPort: 8088,
            agentType: "copaw", taskID: "5b02afc1",
            advanced: true, containerName: "", allowPort: true, specifyIP: "",
            restartPolicy: "unless-stopped", cpuQuota: 0, memoryLimit: 0, memoryUnit: "M",
            pullImage: true, editCompose: false, dockerCompose: "")
        req.dashboardUsername = "admin"
        req.dashboardPassword = "dZGGf58A"
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
        #expect(obj["agentType"] as? String == "copaw")
        #expect(obj["dashboardUsername"] as? String == "admin")
        // copaw 无模型绑定（nil 不编码）
        #expect(obj["model"] == nil)
        #expect(obj["accountId"] == nil)

        // OpenClaw/Hermes 仍携带模型绑定
        var withModel = req
        withModel.model = "gpt-5.5"
        withModel.accountId = 4
        let obj2 = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(withModel)) as? [String: Any])
        #expect(obj2["model"] as? String == "gpt-5.5")
        #expect(obj2["accountId"] as? Int == 4)
    }

    @Test("Discord 频道 update 编码（多 Bot + 代理 + defaultAccount，抓包对齐）")
    func encodeDiscordUpdate() throws {
        var c = AIChannelDiscord()
        c.agentId = 12
        c.enabled = true
        c.dmPolicy = "pairing"
        c.allowFrom = []
        c.requireMention = false
        c.groupPolicy = "open"
        c.proxy = ""
        c.defaultAccount = "1234"
        c.bots = [
            AIChannelDiscordBotItem(accountId: "1234", name: "1", enabled: true, isDefault: true, token: "123456"),
            AIChannelDiscordBotItem(accountId: "234", name: "234", enabled: true, isDefault: false, token: "234564789"),
        ]
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as? [String: Any])
        #expect(obj["dmPolicy"] as? String == "pairing")
        #expect(obj["defaultAccount"] as? String == "1234")
        #expect((obj["bots"] as? [[String: Any]])?.count == 2)
        #expect(obj["streaming"] == nil)
        #expect(obj["groupAllowFrom"] == nil)
    }

    @Test("账号搜索请求 textOnly 编码（模型绑定场景过滤图片账号）")
    func encodeTextOnlySearch() throws {
        let req = AISearchPageRequest(page: 1, pageSize: 200, textOnly: true)
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
        #expect(obj["textOnly"] as? Bool == true)
        #expect(obj["page"] as? Int == 1)
        // 普通列表查询不携带该字段
        let plain = AISearchPageRequest()
        let plainObj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        #expect(plainObj["textOnly"] == nil)
    }

    @Test("update 体剥离 get 回传标记：视图置 nil 后 installed / domain / connectionMode 不编码")
    func encodeStripsGetOnlyFields() throws {
        var qq = AIChannelQQBot()
        qq.agentId = 13
        qq.enabled = true
        qq.dmPolicy = "open"
        qq.groupPolicy = "open"
        qq.installed = false
        qq.bots = [AIChannelQQBotItem(accountId: "default", name: "Default", enabled: true,
                                      isDefault: true, appId: "123", clientSecret: "123",
                                      allowFrom: [], systemPrompt: "")]
        // 视图保存前的剥离动作：get 回传标记置 nil，编码即省略（与网页端 update 体一致）
        qq.installed = nil
        let qqObj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(qq)) as? [String: Any])
        #expect(qqObj["installed"] == nil)

        var feishu = AIChannelFeishu()
        feishu.agentId = 13
        feishu.enabled = true
        feishu.installed = false
        feishu.domain = "feishu"
        feishu.connectionMode = "websocket"
        feishu.installed = nil
        feishu.domain = nil
        feishu.connectionMode = nil
        let feishuObj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(feishu)) as? [String: Any])
        #expect(feishuObj["installed"] == nil)
        #expect(feishuObj["domain"] == nil)
        #expect(feishuObj["connectionMode"] == nil)
    }

    @Test("Bot 行身份：空串视为缺失（accountId 优先，其次 name，全空兜底 UUID）")
    func botIdentityEmptyStrings() {
        #expect(AIChannelBotIdentity.make("123", nil) == "123")
        #expect(AIChannelBotIdentity.make("", "bot-name") == "bot-name")
        #expect(AIChannelBotIdentity.make("", "") != "")
        // 多条空 accountId 的 Bot 不会互相撞身份
        let a = AIChannelBotIdentity.make("", nil)
        let b = AIChannelBotIdentity.make("", nil)
        #expect(a != b)
        // 条目 id 走同一规则
        let emptyBot = AIChannelTelegramBotItem(accountId: "", name: "")
        #expect(!emptyBot.id.isEmpty)
    }

    @Test("策略取值与抓包一致（pairing / allowlist）")
    func policyValues() {
        let dmValues = AIChannelPolicy.dmPoliciesFull.map(\.value)
        #expect(dmValues == ["pairing", "open", "allowlist", "disabled"])
        let groupValues = AIChannelPolicy.groupPoliciesFull.map(\.value)
        #expect(groupValues == ["open", "allowlist", "disabled"])
        let basicDm = AIChannelPolicy.dmPoliciesBasic.map(\.value)
        #expect(!basicDm.contains("allowlist"))
        let streaming = AIChannelStreaming.options.map(\.value)
        #expect(streaming == ["off", "partial", "block", "progress"])
    }
}
