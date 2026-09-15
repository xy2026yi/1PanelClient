//
//  AIAgentHermesSkillsTests.swift
//  1PanelClientTests
//
//  Hermes 技能测试（样本取自用户 2026-09-15 抓包）：
//  市场来源映射（official / skills.sh）/ 已安装列表解码（builtin 不可卸载、
//  official 可卸载）/ 卸载请求编码与端点
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("Hermes 技能")
struct AIAgentHermesSkillsTests {

    @Test("市场来源按智能体类型区分：Hermes 为 official/skills-sh，其余保持 clawhub 三源")
    func sourcesByAgentType() {
        #expect(AIAgentSkillsView.SkillSource.sources(for: "hermes-agent").map(\.rawValue)
                == ["official", "skills-sh"])
        #expect(AIAgentSkillsView.SkillSource.sources(for: "openclaw").map(\.rawValue)
                == ["clawhub-cn", "clawhub-global", "skillhub"])
        #expect(AIAgentSkillsView.SkillSource.sources(for: nil).map(\.rawValue)
                == ["clawhub-cn", "clawhub-global", "skillhub"])
    }

    @Test("搜索请求编码 {agentId, source, keyword}（抓包样本：skills-sh 来源）")
    func encodeSearch() throws {
        let req = AIAgentSkillSearchRequest(agentId: 23, source: "skills-sh", keyword: "mem")
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
        #expect(obj["agentId"] as? Int == 23)
        #expect(obj["source"] as? String == "skills-sh")
        #expect(obj["keyword"] as? String == "mem")
    }

    @Test("已安装列表解码（抓包样本：official 可卸载 / builtin 不可卸载）")
    func decodeInstalled() throws {
        let json = """
        [{"name": "yuanbao", "description": "Yuanbao (元宝) groups: @mention users, query info/members.",
          "category": "", "tags": null, "source": "official", "trust": "official",
          "identifier": "", "bundled": false, "disabled": false, "uninstallable": true},
         {"name": "claude-code", "description": "Delegate coding to Claude Code CLI (features, PRs).",
          "category": "autonomous-ai-agents", "tags": null, "source": "builtin", "trust": "builtin",
          "identifier": "", "bundled": false, "disabled": false, "uninstallable": false}]
        """
        let list = try JSONDecoder().decode([AIAgentSkillInstalled].self, from: Data(json.utf8))
        #expect(list.count == 2)
        #expect(list[0].source == "official")
        #expect(list[0].uninstallable == true)
        #expect(list[1].source == "builtin")
        #expect(list[1].uninstallable == false)
        // identifier 均为空串：行身份回退 name，两条不撞
        #expect(list[0].id != list[1].id)
    }

    @Test("卸载请求编码 {agentId, name}（抓包样本）")
    func encodeUninstall() throws {
        let req = AIAgentSkillUninstallRequest(agentId: 23, name: "yuanbao")
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
        #expect(obj["agentId"] as? Int == 23)
        #expect(obj["name"] as? String == "yuanbao")
    }

    @Test("卸载端点路径为 skills/uninstall")
    func uninstallEndpoint() {
        #expect(APIEndpoint.aiAgentSkillsUninstall.path == "/api/v2/ai/agents/skills/uninstall")
    }
}
