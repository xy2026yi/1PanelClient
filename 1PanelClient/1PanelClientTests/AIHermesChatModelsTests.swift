//
//  AIHermesChatModelsTests.swift
//  1PanelClientTests
//
//  Hermes 对话会话模型测试（样本取自 logs/会话.md 抓包 2026-09-14）：
//  会话列表解码 / 删除与重命名请求编码 / 标题兜底
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("Hermes 对话会话模型")
struct AIHermesChatModelsTests {

    @Test("会话列表解码（抓包样本：id/标题/模型/消息数/时间）")
    func decodeSessions() throws {
        let json = """
        [{"id": "20260914_090643_dbbadc", "title": "你好", "model": "gpt-5.5",
          "messageCount": 1, "startedAt": "2026-09-14T01:08:32Z",
          "lastActive": "2026-09-14T01:08:31Z"}]
        """
        let list = try JSONDecoder().decode([AIHermesChatSession].self, from: Data(json.utf8))
        let s = try #require(list.first)
        #expect(s.id == "20260914_090643_dbbadc")
        #expect(s.title == "你好")
        #expect(s.model == "gpt-5.5")
        #expect(s.messageCount == 1)
        #expect(s.lastActive == "2026-09-14T01:08:31Z")
    }

    @Test("删除请求编码 {agentId, id}")
    func encodeDelete() throws {
        let req = AIHermesChatSessionDeleteRequest(agentId: 13, id: "20260914_090643_dbbadc")
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
        #expect(obj["agentId"] as? Int == 13)
        #expect(obj["id"] as? String == "20260914_090643_dbbadc")
    }

    @Test("重命名请求编码 {agentId, id, title}")
    func encodeRename() throws {
        let req = AIHermesChatSessionRenameRequest(agentId: 13, id: "20260914_091410_edae9f", title: "测试1")
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
        #expect(obj["agentId"] as? Int == 13)
        #expect(obj["id"] as? String == "20260914_091410_edae9f")
        #expect(obj["title"] as? String == "测试1")
    }

    @Test("标题兜底：空标题回退「新对话」占位")
    func displayTitleFallback() throws {
        let json = """
        {"id": "x", "title": "", "model": null, "messageCount": 0,
         "startedAt": null, "lastActive": null}
        """
        let s = try JSONDecoder().decode(AIHermesChatSession.self, from: Data(json.utf8))
        #expect(!s.displayTitle.isEmpty)
        #expect(s.displayTitle == L10n.t("新对话"))
    }

    @Test("终端命令构造：新对话 hermes，恢复会话 hermes --resume <id>（抓包对齐）")
    func terminalCommands() {
        let new = AIHermesChatTarget.new("Hermes-Agent")
        #expect(new.initialCommand == "hermes\n")

        let session = AIHermesChatSession(
            id: "20260914_094214_eedba8", title: "回复邮件", model: nil,
            messageCount: 2, startedAt: nil, lastActive: nil)
        let resume = AIHermesChatTarget.resume(session)
        #expect(resume.initialCommand == "hermes --resume 20260914_094214_eedba8\n")
        #expect(resume.title == "回复邮件")
    }
}
