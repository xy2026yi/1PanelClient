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

    @Test("EmptyInitializable：集合类型回退空实例")
    func emptyInitializableFallback() {
        #expect(([String].emptyInstance()) == [])
        #expect((Set<Int>.emptyInstance()).isEmpty)
        #expect(([String: Int].emptyInstance()) == [:])
    }
}
