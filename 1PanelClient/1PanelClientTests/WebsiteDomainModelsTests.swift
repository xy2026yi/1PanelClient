//
//  WebsiteDomainModelsTests.swift
//  1PanelClientTests
//
//  域名增删请求体（POST /websites/domains 抓包 2026-09-23）
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("网站域名模型")
struct WebsiteDomainModelsTests {

    private func encode(_ req: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
    }

    @Test("新增域名请求编码（domainStr 恒空串，domains 为新增项数组）")
    func encodeDomainsAdd() throws {
        let req = try encode(WebsiteDomainsAddRequest(
            websiteID: 1,
            domains: [WebsiteDomainBody(domain: "abc1.test.com",
                                        host: "abc1.test.com",
                                        port: 443, ssl: false)],
            domainStr: ""))
        #expect(req["websiteID"] as? Int == 1)
        #expect(req["domainStr"] as? String == "")
        let domains = try #require(req["domains"] as? [[String: Any]])
        let first = try #require(domains.first)
        #expect(first["domain"] as? String == "abc1.test.com")
        #expect(first["host"] as? String == "abc1.test.com")
        #expect(first["port"] as? Int == 443)
        #expect(first["ssl"] as? Bool == false)
    }
}
