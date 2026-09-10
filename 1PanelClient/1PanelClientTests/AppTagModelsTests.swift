//
//  AppTagModelsTests.swift
//  1PanelClientTests
//
//  应用类别模型与搜索请求 tags 参数验证：
//  向量取自网页端抓包（logs/分组与类别.md，GET /api/v2/apps/tags）
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("应用类别模型")
struct AppTagModelsTests {
    @Test("AppTagInfo：apps/tags 响应解码（17 个内置类别之一）")
    func decodeTag() throws {
        let json = """
        {"id":2,"key":"Website","name":"建站"}
        """
        let tag = try JSONDecoder().decode(AppTagInfo.self, from: Data(json.utf8))
        #expect(tag.key == "Website")
        #expect(tag.name == "建站")
        #expect(tag.displayName == "建站")
    }

    @Test("AppTagInfo：name 缺失时 displayName 回退 key")
    func displayNameFallsBackToKey() throws {
        let json = """
        {"id":1,"key":"AI","name":null}
        """
        let tag = try JSONDecoder().decode(AppTagInfo.self, from: Data(json.utf8))
        #expect(tag.displayName == "AI")
    }

    @Test("AppTagInfo：name 为空串时同样回退 key（空名会渲染成无文字的空白 chip）")
    func displayNameFallsBackOnEmptyName() throws {
        let json = """
        {"id":3,"key":"Database","name":""}
        """
        let tag = try JSONDecoder().decode(AppTagInfo.self, from: Data(json.utf8))
        #expect(tag.displayName == "Database")
        #expect(!tag.displayName.isEmpty)
    }

    @Test("AppTagInfo：Identifiable 用 key（chips 筛选条 ForEach 稳定标识）")
    func identifiableByKey() throws {
        let json = """
        [{"id":1,"key":"AI","name":"AI"},{"id":2,"key":"Website","name":"建站"}]
        """
        let tags = try JSONDecoder().decode([AppTagInfo].self, from: Data(json.utf8))
        #expect(tags.map(\.id) == ["AI", "Website"])
    }

    @Test("AppSearchRequest：商店搜索 tags 传 key 数组")
    func encodeStoreSearch() throws {
        let req = AppSearchRequest(
            name: "", page: 1, pageSize: 60,
            recommend: false, resource: "", showCurrentArch: false,
            tags: ["AI"], type: ""
        )
        let dict = try encodeToDict(req)
        #expect(dict["tags"] as? [String] == ["AI"])
    }

    @Test("AppInstalledSearchRequest：已安装应用搜索同样支持 tags")
    func encodeInstalledSearch() throws {
        let req = AppInstalledSearchRequest(
            page: 1, pageSize: 20, name: "", type: "",
            tags: ["AI"], update: false, all: false, unused: false, sync: true
        )
        let dict = try encodeToDict(req)
        #expect(dict["tags"] as? [String] == ["AI"])
        #expect(dict["sync"] as? Bool == true)
    }

    private func encodeToDict<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as? [String: Any] ?? [:]
    }
}
