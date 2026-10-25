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

    @Test("运行环境网站创建编码（type=runtime + runtimeID/runtimeType + 端口取环境 HTTP 口径，抓包 2026-10-25）")
    func encodeRuntimeCreate() throws {
        var req = WebsiteCreateRequest()
        req.type = "runtime"
        req.alias = "testphp.test.com"
        req.runtimeID = 11
        req.runtimeType = "php"
        req.port = 9000
        req.taskID = "2de5610c-2761-40a7-9241-43421dd6f4d0"
        req.enableSSL = true
        req.websiteSSLID = 3
        req.domains = [WebsiteDomainBody(domain: "testphp.test.com",
                                         host: "testphp.test.com",
                                         port: 443, ssl: false)]
        let body = try encode(req)
        #expect(body["type"] as? String == "runtime")
        #expect(body["runtimeID"] as? Int == 11)
        #expect(body["runtimeType"] as? String == "php")
        #expect(body["port"] as? Int == 9000)
        #expect(body["createDb"] as? Bool == false)
        #expect(body["appType"] as? String == "installed")
        // appinstall 保持零值空结构（抓包口径）
        let appinstall = try #require(body["appinstall"] as? [String: Any])
        #expect(appinstall["appId"] as? Int == 0)
        #expect((appinstall["params"] as? [String: Any])?.isEmpty == true)

        // 创建数据库形态（开）：dbHost 取所选服务 value，字符集 value 发 utf8 系
        var withDB = WebsiteCreateRequest()
        withDB.type = "runtime"
        withDB.runtimeID = 11
        withDB.runtimeType = "php"
        withDB.port = 9000
        withDB.createDb = true
        withDB.dbName = "php-test"
        withDB.dbUser = "php-test"
        withDB.dbPassword = "eNsyes5fe7BmfDkm"
        withDB.dbFormat = "utf8mb4"
        withDB.dbType = "mysql"
        withDB.dbHost = "mysql"
        withDB.taskID = "f78c406f-2689-4700-8a70-3fff62faf5b9"
        let dbBody = try encode(withDB)
        #expect(dbBody["createDb"] as? Bool == true)
        #expect(dbBody["dbName"] as? String == "php-test")
        #expect(dbBody["dbUser"] as? String == "php-test")
        #expect(dbBody["dbHost"] as? String == "mysql")
        #expect(dbBody["dbType"] as? String == "mysql")
        #expect(dbBody["dbFormat"] as? String == "utf8mb4")
        #expect(dbBody["runtimeID"] as? Int == 11)
    }

    @Test("网站类型清单含运行环境（rawValue 与显示名）")
    func runtimeTypeCase() {
        #expect(WebsiteType(rawValue: "runtime") == .runtime)
        #expect(WebsiteType.runtime.rawValue == "runtime")
        #expect(WebsiteType.allCases.contains(.runtime))
    }

    @Test("FTP 密码 base64 编码口径（抓包 eGg1NndYV1d0d2Y1UEdKYw== ← 16 位随机串；静态/运行环境同口径）")
    func encodeFTPPasswordBase64() throws {
        let raw = "xh56wXWWtwf5PGJc"
        var req = WebsiteCreateRequest()
        req.type = "runtime"
        req.enableFtp = true
        req.ftpUser = "testphp"
        req.ftpPassword = Data(raw.utf8).base64EncodedString()
        let body = try encode(req)
        #expect(body["enableFtp"] as? Bool == true)
        #expect(body["ftpUser"] as? String == "testphp")
        // 网页端发 base64 而非明文（服务端按 base64 解码存储）
        #expect(body["ftpPassword"] as? String == "eGg1NndYV1d0d2Y1UEdKYw==")
        #expect(Data(base64Encoded: body["ftpPassword"] as? String ?? "") != nil)
    }
}
