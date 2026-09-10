//
//  GroupModelsTests.swift
//  1PanelClientTests
//
//  分组模型与请求编解码验证：向量取自网页端抓包（logs/分组与类别.md）
//  与 1Panel 源码 core/app/dto/group.go（agent 与 core 的分组 DTO 一致）
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("分组模型")
struct GroupModelsTests {
    // MARK: - 解码（抓包原始 JSON）

    @Test("PanelGroup：groups/search 响应项解码")
    func decodeGroup() throws {
        let json = """
        {"id":4,"name":"local","type":"website","isDefault":true}
        """
        let group = try JSONDecoder().decode(PanelGroup.self, from: Data(json.utf8))
        #expect(group.id == 4)
        #expect(group.name == "local")
        #expect(group.type == "website")
        #expect(group.isDefault == true)
    }

    @Test("PanelGroup：默认组判断不受名字影响（默认组不一定叫 Default）")
    func defaultGroupByNameAgnostic() throws {
        let json = """
        [{"id":4,"name":"local","type":"website","isDefault":true},
         {"id":1,"name":"Default","type":"website","isDefault":false}]
        """
        let groups = try JSONDecoder().decode([PanelGroup].self, from: Data(json.utf8))
        let def = groups.first(where: { $0.isDefault == true })
        #expect(def?.id == 4)
    }

    // MARK: - 编码（请求字段名对齐服务端 DTO）

    @Test("GroupCreateRequest：创建请求字段")
    func encodeCreate() throws {
        let req = GroupCreateRequest(name: "网站1", type: "website")
        let dict = try encodeToDict(req)
        #expect(dict["id"] as? Int == 0)
        #expect(dict["name"] as? String == "网站1")
        #expect(dict["type"] as? String == "website")
    }

    @Test("GroupUpdateRequest：设为默认 = isDefault true")
    func encodeUpdateSetDefault() throws {
        let req = GroupUpdateRequest(id: 12, name: "1", type: "script", isDefault: true)
        let dict = try encodeToDict(req)
        #expect(dict["id"] as? Int == 12)
        #expect(dict["isDefault"] as? Bool == true)
    }

    @Test("GroupDeleteRequest：删除请求字段")
    func encodeDelete() throws {
        let dict = try encodeToDict(GroupDeleteRequest(id: 3))
        #expect(dict["id"] as? Int == 3)
    }

    // MARK: - 搜索请求的分组过滤参数

    @Test("CronjobSearchRequest：分组过滤是复数数组 groupIDs")
    func encodeCronjobSearch() throws {
        var req = CronjobSearchRequest()
        req.groupIDs = [9]
        let dict = try encodeToDict(req)
        #expect(dict["groupIDs"] as? [Int] == [9])

        // 默认（全部）应为空数组而非 nil，字段始终参与编码
        let all = try encodeToDict(CronjobSearchRequest())
        #expect(all["groupIDs"] as? [Int] == [])
    }

    @Test("WebsiteSearchRequest：分组过滤是单值 websiteGroupId")
    func encodeWebsiteSearch() throws {
        let req = WebsiteSearchRequest(
            name: "", page: 1, pageSize: 20,
            orderBy: "favorite", order: "descending",
            websiteGroupId: 4, type: ""
        )
        let dict = try encodeToDict(req)
        #expect(dict["websiteGroupId"] as? Int == 4)
    }

    // MARK: - GroupScope 路由（website 走 agent，cronjob/script 走 core）

    @Test("GroupScope：两套端点路径与 type")
    func scopePaths() {
        #expect(GroupScope.website.searchPath == "/api/v2/groups/search")
        #expect(GroupScope.website.createPath == "/api/v2/groups")
        #expect(GroupScope.website.updatePath == "/api/v2/groups/update")
        #expect(GroupScope.website.deletePath == "/api/v2/groups/del")

        #expect(GroupScope.cronjob.searchPath == "/api/v2/core/groups/search")
        #expect(GroupScope.cronjob.createPath == "/api/v2/core/groups")
        #expect(GroupScope.script.type == "script")
        #expect(GroupScope.script.updatePath == "/api/v2/core/groups/update")
        #expect(GroupScope.script.deletePath == "/api/v2/core/groups/del")
    }

    // MARK: - 工具

    private func encodeToDict<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as? [String: Any] ?? [:]
    }
}
