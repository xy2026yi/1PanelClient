//
//  SSLDownloadTests.swift
//  1PanelClientTests
//
//  证书下载解析测试：Content-Disposition 文件名（dev-v2 RFC 5987 / 旧版引号格式）
//  与旧版 JSON 响应里站内下载路径的容错提取（业务包 {url} / 业务包纯字符串 /
//  裸 {url} / 业务错误透传）
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("证书下载解析")
struct SSLDownloadTests {

    // MARK: - Content-Disposition 文件名

    @Test("RFC 5987：filename*=utf-8'' 直接值（dev-v2 服务端格式）", arguments: [
        ("attachment; filename*=utf-8''example.com.zip", "example.com.zip"),
        ("attachment; filename*=utf-8''cert-8.zip", "cert-8.zip"),
    ])
    func rfc5987Plain(header: String, expected: String) {
        #expect(APIClient.fileName(fromContentDisposition: header) == expected)
    }

    @Test("RFC 5987：percent 编码还原（通配符域名等保留字符）", arguments: [
        ("attachment; filename*=utf-8''%2A.example.com.zip", "*.example.com.zip"),
        ("attachment; filename*=utf-8''my%20cert.zip", "my cert.zip"),
    ])
    func rfc5987PercentDecoded(header: String, expected: String) {
        #expect(APIClient.fileName(fromContentDisposition: header) == expected)
    }

    @Test("RFC 5987：带语言段（utf-8'zh'<值>）跳过前两段")
    func rfc5987WithLanguage() {
        #expect(APIClient.fileName(fromContentDisposition: "attachment; filename*=utf-8'zh'%2A.zip") == "*.zip")
    }

    @Test("旧版引号格式：filename=\"...\" 去引号")
    func quotedLegacy() {
        #expect(APIClient.fileName(fromContentDisposition: "attachment; filename=\"my cert.zip\"") == "my cert.zip")
    }

    @Test("无引号直值 filename=plain.zip")
    func plainLegacy() {
        #expect(APIClient.fileName(fromContentDisposition: "attachment; filename=plain.zip") == "plain.zip")
    }

    @Test("缺失 / 空头 / 无 filename 字段返回 nil", arguments: [
        nil,
        "",
        "attachment",
        "inline",
    ])
    func missingHeader(header: String?) {
        #expect(APIClient.fileName(fromContentDisposition: header) == nil)
    }

    // MARK: - 旧版 JSON 站内路径提取

    @Test("业务包 {data:{url}} 形态")
    func wrappedObjectURL() throws {
        let data = Data(#"{"code":200,"message":"","data":{"url":"/46c6a920-77d3-4c1a-aa03-d2e56e067067"}}"#.utf8)
        #expect(try APIClient.inPanelDownloadPath(from: data) == "/46c6a920-77d3-4c1a-aa03-d2e56e067067")
    }

    @Test("业务包纯字符串路径形态（与备份记录下载同型）")
    func wrappedStringURL() throws {
        let data = Data(#"{"code":200,"message":"","data":"/46c6a920-77d3-4c1a-aa03-d2e56e067067"}"#.utf8)
        #expect(try APIClient.inPanelDownloadPath(from: data) == "/46c6a920-77d3-4c1a-aa03-d2e56e067067")
    }

    @Test("裸 {url} 形态（无业务包）")
    func bareObjectURL() throws {
        let data = Data(#"{"url":"/abc.zip"}"#.utf8)
        #expect(try APIClient.inPanelDownloadPath(from: data) == "/abc.zip")
    }

    @Test("业务错误透传服务端 message")
    func businessErrorSurfaced() {
        let data = Data(#"{"code":500,"message":"服务错误: 证书不存在","data":null}"#.utf8)
        #expect(throws: APIError.self) {
            _ = try APIClient.inPanelDownloadPath(from: data)
        }
    }

    @Test("成功但无路径：按无效地址报错")
    func successWithoutURL() {
        let data = Data(#"{"code":200,"message":"","data":null}"#.utf8)
        #expect(throws: APIError.self) {
            _ = try APIClient.inPanelDownloadPath(from: data)
        }
    }

    // MARK: - 站内地址解析（防任意主机 + 同源放行）

    private static let panel = "http://192.168.50.20:17331"

    @Test("相对路径拼到面板 baseURL", arguments: [
        "/46c6a920-77d3-4c1a-aa03-d2e56e067067",
        "/download/ssl/8.zip",
    ])
    func relativePathResolved(path: String) {
        #expect(APIClient.resolveInPanelURL(path, baseURL: Self.panel)?
            .absoluteString == Self.panel + path)
    }

    @Test("同源绝对地址（host:port 一致）原样放行", arguments: [
        "http://192.168.50.20:17331/46c6a920.zip",
        "HTTP://192.168.50.20:17331/uuid",       // host 大小写不敏感
    ])
    func sameOriginAbsoluteAccepted(url: String) {
        #expect(APIClient.resolveInPanelURL(url, baseURL: Self.panel) != nil)
    }

    @Test("缺省端口按 scheme 补齐后比较（https 443）")
    func defaultPortMatch() {
        #expect(APIClient.resolveInPanelURL("https://example.com/a.zip", baseURL: "https://example.com") != nil)
        #expect(APIClient.resolveInPanelURL("http://example.com/a.zip", baseURL: "https://example.com") == nil)
    }

    @Test("跨源 / 协议相对 / 其他 scheme / 非法输入拒绝", arguments: [
        "http://evil.com/uuid",                  // 跨源 host
        "http://192.168.50.20:9999/uuid",        // 同 host 不同端口
        "//192.168.50.20:17331/uuid",            // 协议相对
        "file:///etc/passwd",                    // 非 http(s)
        "ftp://192.168.50.20:17331/uuid",
        "",
        "   ",
    ])
    func foreignOriginsRejected(url: String) {
        #expect(APIClient.resolveInPanelURL(url, baseURL: Self.panel) == nil)
    }

    // MARK: - JSON 形态判定（Content-Type 不可靠时的前缀嗅探）

    @Test("Content-Type 声明 json 即判定为 JSON（不看 body）", arguments: [
        "application/json",
        "application/json; charset=utf-8",
        "APPLICATION/JSON",
    ])
    func jsonContentTypeWins(ct: String) {
        #expect(APIClient.isJSONDownloadBody(contentType: ct, data: Data("PK\u{03}\u{04}".utf8)))
    }

    @Test("body 以 { 开头嗅探为 JSON（text/plain 的 JSON 兜底）")
    func bracePrefixSniffed() {
        #expect(APIClient.isJSONDownloadBody(contentType: "text/plain", data: Data(#"{"code":200}"#.utf8)))
        #expect(APIClient.isJSONDownloadBody(contentType: "", data: Data("{".utf8)))
    }

    @Test("zip 二进制（PK 魔数）不误判为 JSON")
    func zipNotJSON() {
        #expect(!APIClient.isJSONDownloadBody(contentType: "application/zip", data: Data("PK\u{03}\u{04}rest".utf8)))
        #expect(!APIClient.isJSONDownloadBody(contentType: "application/octet-stream", data: Data([0x50, 0x4B, 0x03, 0x04])))
        #expect(!APIClient.isJSONDownloadBody(contentType: "text/plain", data: Data()))
    }
}
