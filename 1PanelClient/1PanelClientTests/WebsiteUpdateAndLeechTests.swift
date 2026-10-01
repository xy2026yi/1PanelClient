//
//  WebsiteUpdateAndLeechTests.swift
//  1PanelClientTests
//
//  网站基础信息更新（expireDate 日期截断）+ 防盗链缓存单位（上游 Units 对齐）
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("网站更新与防盗链模型")
struct WebsiteUpdateAndLeechTests {

    private func encode(_ req: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
    }

    private func decodeDetail(_ json: String) throws -> WebsiteFull {
        try JSONDecoder().decode(WebsiteFull.self, from: Data(json.utf8))
    }

    // MARK: expireDate 截断（服务端 time.Parse(DateLayout) 只收 yyyy-MM-dd）

    @Test("完整时间戳截断为日期（9999-12-31T00:00:00Z → 9999-12-31）")
    func expireDateTruncated() throws {
        let detail = try decodeDetail(
            """
            {"id":1,"primaryDomain":"abc.test.com","remark":"","IPV6":false,
             "webSiteGroupId":3,"favorite":false,"expireDate":"9999-12-31T00:00:00Z"}
            """)
        let req = try encode(WebsiteUpdateRequest(from: detail))
        #expect(req["expireDate"] as? String == "9999-12-31")
        #expect(req["id"] as? Int == 1)
        #expect(req["primaryDomain"] as? String == "abc.test.com")
        #expect(req["IPV6"] as? Bool == false)
        #expect(req["webSiteGroupID"] as? Int == 3)
    }

    @Test("缺失 expireDate 编码为空串（服务端空串跳过解析）")
    func expireDateNilEncodesEmpty() throws {
        let detail = try decodeDetail(
            """
            {"id":1,"primaryDomain":"abc.test.com","remark":"","IPV6":false,
             "webSiteGroupId":3,"favorite":false}
            """)
        let req = try encode(WebsiteUpdateRequest(from: detail))
        #expect(req["expireDate"] as? String == "")
    }

    @Test("dateOnly：已是日期原样透传、空入空出")
    func dateOnlyPassthrough() {
        #expect(WebsiteUpdateRequest.dateOnly("2027-01-02") == "2027-01-02")
        #expect(WebsiteUpdateRequest.dateOnly("2027-01-02T00:00:00Z") == "2027-01-02")
        #expect(WebsiteUpdateRequest.dateOnly("") == "")
        #expect(WebsiteUpdateRequest.dateOnly(nil) == "")
    }

    // MARK: 防盗链缓存单位（对齐上游 Units：s/m/h/d/w/M/y，月为大写 M）

    @Test("单位枚举取值与顺序")
    func cacheUnitValues() {
        #expect(LeechCacheUnit.allCases.map(\.rawValue) == ["s", "m", "h", "d", "w", "M", "y"])
        #expect(LeechCacheUnit.month.rawValue == "M")
        #expect(LeechCacheUnit.fallback == .day)
        #expect(LeechCacheUnit.fallback.rawValue == "d")
    }

    @Test("单位原始值可逆解析（提交/回填共用）")
    func cacheUnitRoundTrip() {
        for unit in LeechCacheUnit.allCases {
            #expect(LeechCacheUnit(rawValue: unit.rawValue) == unit)
        }
        // 服务端空串/未知值不可解析（视图层回落「天」）
        #expect(LeechCacheUnit(rawValue: "") == nil)
        #expect(LeechCacheUnit(rawValue: "x") == nil)
    }

    @Test("防盗链配置宽容解码：缺失 cacheUint 为空串")
    func leechConfigDecodeDefaults() throws {
        let config = try JSONDecoder().decode(
            WebsiteLeechConfig.self,
            from: Data(#"{"enable":true,"cache":true,"cacheTime":30}"#.utf8))
        #expect(config.cacheUint == "")
        #expect(config.cacheTime == 30)
        #expect(config.enable)
        #expect(config.serverNames.isEmpty)
    }
}
