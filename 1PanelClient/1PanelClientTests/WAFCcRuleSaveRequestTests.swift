//
//  WAFCcRuleSaveRequestTests.swift
//  1PanelClientTests
//
//  CC 频率限制保存请求编码契约（抓包 2026-09-26）：
//  保存默认两键省略；应用到网站时 applyWebsite=true + websites=[所选ID]
//

import Testing
import Foundation
@testable import _PanelClient

@Suite struct WAFCcRuleSaveRequestTests {

    private func encodeToDict(_ req: WAFCcRuleSaveRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(req)
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as! [String: Any]
    }

    private func makeRequest(applyWebsite: Bool?, websites: [Int]?) -> WAFCcRuleSaveRequest {
        WAFCcRuleSaveRequest(
            state: "on", code: 0, action: "deny", type: "cc", res: "",
            ipBlock: "on", ipBlockTime: 650, threshold: 110, duration: 15,
            mode: "uri", scope: "Cc",
            applyWebsite: applyWebsite, websites: websites
        )
    }

    @Test func 保存默认省略ApplyWebsite与Websites键() throws {
        let dict = try encodeToDict(makeRequest(applyWebsite: nil, websites: nil))
        #expect(dict["applyWebsite"] == nil)
        #expect(dict["websites"] == nil)
        #expect(dict["scope"] as? String == "Cc")
        #expect(dict["threshold"] as? Int == 110)
    }

    @Test func 应用到单个网站() throws {
        let dict = try encodeToDict(makeRequest(applyWebsite: true, websites: [1]))
        #expect(dict["applyWebsite"] as? Bool == true)
        #expect((dict["websites"] as? [Int]) == [1])
    }

    @Test func 应用到多个网站() throws {
        let dict = try encodeToDict(makeRequest(applyWebsite: true, websites: [1, 3]))
        #expect(dict["applyWebsite"] as? Bool == true)
        #expect((dict["websites"] as? [Int]) == [1, 3])
    }
}
