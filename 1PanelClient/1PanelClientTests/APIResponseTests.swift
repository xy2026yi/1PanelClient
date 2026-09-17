//
//  APIResponseTests.swift
//  1PanelClientTests
//
//  1Panel 业务信封 {code, message, data} 的解码行为
//

import Testing
import Foundation
@testable import _PanelClient

private struct HostPayload: Decodable {
    let hostname: String
}

@Suite("APIResponse 信封解析")
struct APIResponseTests {
    @Test("code=200 携带 data")
    func successWithData() throws {
        let json = #"{"code":200,"message":"success","data":{"hostname":"prod-1"}}"#
        let resp = try JSONDecoder().decode(APIResponse<HostPayload>.self, from: Data(json.utf8))
        #expect(resp.isSuccess)
        #expect(resp.data?.hostname == "prod-1")
    }

    @Test("data 为 null 时解为 nil（对应空列表回退路径的上游）")
    func nullData() throws {
        let json = #"{"code":200,"message":"","data":null}"#
        let resp = try JSONDecoder().decode(APIResponse<[String]>.self, from: Data(json.utf8))
        #expect(resp.isSuccess)
        #expect(resp.data == nil)
    }

    @Test("业务失败：code 非 200 且带 message")
    func businessFailure() throws {
        let json = #"{"code":400,"message":"API 接口密钥错误"}"#
        let resp = try JSONDecoder().decode(APIResponse<EmptyResponse>.self, from: Data(json.utf8))
        #expect(!resp.isSuccess)
        #expect(resp.message == "API 接口密钥错误")
    }

    @Test("取消可识别（页面退出取消不算失败，保留快照）")
    func cancellationDetection() {
        #expect(APIError.networkError(URLError(.cancelled)).isCancellation)
        #expect(APIError.networkError(CancellationError()).isCancellation)
        #expect(!APIError.networkError(URLError(.cannotConnectToHost)).isCancellation)
        #expect(!APIError.httpError(500, "").isCancellation)
    }

    @Test("EmptyInitializable：集合类型回退空实例")
    func emptyInitializableFallback() {
        #expect(([String].emptyInstance()) == [])
        #expect((Set<Int>.emptyInstance()).isEmpty)
        #expect(([String: Int].emptyInstance()) == [:])
    }
}

// MARK: - PageEnvelope 防御解码（M0：total 置 null/缺失不再整页失败）

@Suite("PageEnvelope 防御解码")
struct PageEnvelopeTests {
    nonisolated private struct Item: Decodable { let id: Int }

    @Test("total 正常解码")
    func normalTotal() throws {
        let page = try JSONDecoder().decode(PageEnvelope<Item>.self,
                                            from: Data(#"{"total": 42, "items": [{"id":1}]}"#.utf8))
        #expect(page.total == 42)
        #expect(page.items?.count == 1)
    }

    @Test("total 为 null 回退 0（上游 schema 漂移防御）")
    func nullTotalFallsBackToZero() throws {
        let page = try JSONDecoder().decode(PageEnvelope<Item>.self,
                                            from: Data(#"{"total": null, "items": [{"id":1}]}"#.utf8))
        #expect(page.total == 0)
        #expect(page.items?.count == 1)
    }

    @Test("total 缺失 + items 缺失（空页形状）")
    func missingFieldsDecode() throws {
        let page = try JSONDecoder().decode(PageEnvelope<Item>.self,
                                            from: Data(#"{}"#.utf8))
        #expect(page.total == 0)
        #expect(page.items == nil)
    }

    @Test("七个老信封 typealias 走同一防御解码")
    func typealiasesShareDefense() throws {
        let json = #"{"items": []}"#
        let websites = try JSONDecoder().decode(WebsiteListResponse.self, from: Data(json.utf8))
        let containers = try JSONDecoder().decode(ContainerListResponse.self, from: Data(json.utf8))
        let cronjobs = try JSONDecoder().decode(CronjobListResponse.self, from: Data(json.utf8))
        #expect(websites.total == 0 && containers.total == 0 && cronjobs.total == 0)
    }
}
