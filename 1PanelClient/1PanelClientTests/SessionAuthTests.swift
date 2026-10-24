//
//  SessionAuthTests.swift
//  1PanelClientTests
//
//  引导流客户端（logs/登录与会话认证方案.md §3/§4/§7）：
//  - LoginRequest/MfaLoginRequest 编码形状（authMethod 固定 session、captcha 空键、language）
//  - body 业务码判定：HTTP 200 + code 401 → 认证错误分支（勿看 HTTP 状态）
//  - 错误码 → case 映射表（ErrAuth/ErrEntrance/ErrLoginLocked/ErrCaptchaCode/ErrMFA/ErrNotLogin）
//  - 取钥决策：Enable → 直接用现有 key；Disable/空 key → 需确认开启
//  - 请求形状：EntranceCode 条件注入、CSRF 双提交（jar 有 pcsrftoken 的 POST）
//  - cookie 隔离：引导 jar 落 psession/pcsrftoken，.shared 不受染
//  - 密码混合加密上链：jar 有公钥 → 三段式；无公钥 → 明文回落
//

import Testing
import Foundation
@testable import _PanelClient

@MainActor
@Suite("引导流会话客户端", .serialized)
struct SessionAuthTests {

    private let baseURL = "http://panel.test:17331"

    // MARK: - 纯逻辑：请求模型

    @Test("LoginRequest 编码形状：authMethod 固定 session、captcha/captchaID 恒在、language")
    func loginRequestEncoding() throws {
        let request = LoginRequest(
            name: "admin",
            password: "seg1:seg2:seg3",
            captcha: "",
            captchaID: "",
            authMethod: "session",
            authSource: "local",
            language: "zh"
        )
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        #expect(json["name"] as? String == "admin")
        #expect(json["password"] as? String == "seg1:seg2:seg3")
        #expect(json["captcha"] as? String == "")
        #expect(json["captchaID"] as? String == "")
        #expect(json["authMethod"] as? String == "session")
        #expect(json["authSource"] as? String == "local")
        #expect(json["language"] as? String == "zh")
    }

    @Test("MfaLoginRequest 编码形状：sessionId/secret 空串/code")
    func mfaRequestEncoding() throws {
        let request = MfaLoginRequest(sessionId: "tok", secret: "", code: "905646", authMethod: "session")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        #expect(json["sessionId"] as? String == "tok")
        #expect(json["secret"] as? String == "")
        #expect(json["code"] as? String == "905646")
        #expect(json["authMethod"] as? String == "session")
    }

    @Test("LoginResult.mfaRequired：Enable + mfaSession 非空才需要 OTP")
    func mfaRequiredGate() throws {
        func decode(_ json: String) throws -> LoginResult {
            try JSONDecoder().decode(LoginResult.self, from: Data(json.utf8))
        }
        let mfa = try decode(#"{"name":"admin","role":"","token":"","mfaStatus":"Enable","mfaSession":"Dvo7yz"}"#)
        #expect(mfa.mfaRequired)
        let plain = try decode(#"{"name":"admin","role":"ADMIN","token":"","mfaStatus":"","mfaSession":""}"#)
        #expect(!plain.mfaRequired)
        // mfaStatus Enable 但 mfaSession 空（防御：无令牌无法续接，不得误入 OTP 死等）
        let noSession = try decode(#"{"name":"admin","role":"","token":"","mfaStatus":"Enable","mfaSession":""}"#)
        #expect(!noSession.mfaRequired)
        // passwordExpired 防御性可选字段：缺失 → nil
        #expect(plain.passwordExpired == nil)
        let expired = try decode(#"{"name":"admin","role":"","token":"","mfaStatus":"","mfaSession":"","passwordExpired":true}"#)
        #expect(expired.passwordExpired == true)
    }

    // MARK: - 纯逻辑：验证码 data URL

    @Test("验证码 data URL 解析（base64 段提取）")
    func captchaDataURL() {
        let payload = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let resp = CaptchaResponse(
            captchaID: "2T2VPQ2B2AH4TKB4BV7OGQDP3K",
            imagePath: "data:image/png;base64,\(payload)"
        )
        #expect(resp.imageData == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(CaptchaResponse(captchaID: "x", imagePath: nil).imageData == nil)
        #expect(CaptchaResponse(captchaID: "x", imagePath: "data:text/plain,raw").imageData == nil)
    }

    // MARK: - 纯逻辑：错误映射（locale 无关：断言 case 而非文案）

    @Test("业务码 message → 错误 case 映射表")
    func errorMappingTable() {
        func map(_ message: String) -> SessionAuthError {
            SessionAuthError.from(businessCode: 401, message: message)
        }
        if case .badCredentials = map("ErrAuth") {} else { Issue.record("ErrAuth → badCredentials") }
        if case .wrongEntrance = map("ErrEntrance") {} else { Issue.record("ErrEntrance → wrongEntrance") }
        if case .loginLocked = map("ErrLoginLocked") {} else { Issue.record("ErrLoginLocked → loginLocked") }
        if case .captchaInvalid = map("ErrCaptchaCode") {} else { Issue.record("ErrCaptchaCode → captchaInvalid") }
        if case .mfaFailed = map("ErrMFA") {} else { Issue.record("ErrMFA → mfaFailed") }
        if case .notLogin = map("ErrNotLogin") {} else { Issue.record("ErrNotLogin → notLogin") }
        if case .business = map("SomeOtherErr") {} else { Issue.record("未知 message → business") }
    }

    // MARK: - 纯逻辑：取钥决策

    @Test("取钥决策：Enable+key 直接用；Disable/空 key 需确认开启")
    func keyAcquisitionDecision() {
        func info(_ status: String?, _ key: String?) -> CurrentUserInfo {
            CurrentUserInfo(
                name: "admin", role: "ADMIN", mfaStatus: "Disable",
                apiInterfaceStatus: status, apiKey: key,
                ipWhiteList: "0.0.0.0/0\n::/0", apiTrustedProxies: "",
                apiKeyValidityTime: 120
            )
        }
        #expect(
            BootstrapDecision.keyAcquisition(from: info("Enable", "xIvaBQRBeMO93s7IO1xgomK2fE0DBhVt"))
                == .useExisting("xIvaBQRBeMO93s7IO1xgomK2fE0DBhVt")
        )
        #expect(BootstrapDecision.keyAcquisition(from: info("Disable", "xIva")) == .needsEnableConfirm)
        #expect(BootstrapDecision.keyAcquisition(from: info("Enable", "")) == .needsEnableConfirm)
        #expect(BootstrapDecision.keyAcquisition(from: info("Enable", nil)) == .needsEnableConfirm)
        #expect(BootstrapDecision.keyAcquisition(from: info(nil, nil)) == .needsEnableConfirm)
    }

    // MARK: - 纯逻辑：jar 读取

    @Test("cookieValue：同名取末个；csrfToken 空串视为缺失")
    func cookieValueExtraction() {
        func cookie(_ name: String, _ value: String) -> HTTPCookie {
            HTTPCookie(properties: [
                .domain: "panel.test",
                .path: "/",
                .name: name,
                .value: value
            ])!
        }
        let cookies = [cookie("pcsrftoken", "old"), cookie("pcsrftoken", "new"), cookie("psession", "abc")]
        #expect(SessionAuthClient.cookieValue(named: "pcsrftoken", cookies: cookies) == "new")
        #expect(SessionAuthClient.cookieValue(named: "psession", cookies: cookies) == "abc")
        #expect(SessionAuthClient.cookieValue(named: "missing", cookies: cookies) == nil)
        #expect(SessionAuthClient.csrfToken(from: HTTPCookieStorage(), baseURL: "http://panel.test") == nil)
    }

    // MARK: - 网络链路（MockURLProtocol）

    @Test("login：jar 有公钥 → 密码三段式上链 + EntranceCode base64 注入；会话 cookie 落独立 jar")
    func loginWireFormatAndCookieIsolation() async throws {
        let client = SessionAuthClient(
            baseURL: baseURL,
            protocolClasses: [BootstrapMockURLProtocol.self]
        )
        client.entranceCode = "3f89948beb"
        defer { client.invalidate() }
        let jar = client.cookieJar

        // 预种公钥 cookie（模拟 setting 响应 Set-Cookie 后的 jar 状态）
        jar.setCookie(Self.cookie(
            name: "panel_public_key", value: Self.capturedPublicKeyCookie, domain: "panel.test"))
        _ = await Self.waitForCookie(jar, "panel_public_key", baseURL: baseURL)

        BootstrapMockURLProtocol.setHandler { request in
            if request.url?.path.hasSuffix("/core/auth/login") == true {
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "EntranceCode")
                        == Data("3f89948beb".utf8).base64EncodedString())
                let body = (try? JSONSerialization.jsonObject(with: Self.requestBody(request) ?? Data())) as? [String: Any]
                let password = body?["password"] as? String
                #expect(password?.split(separator: ":").count == 3, "公钥在 jar 时密码必须三段混合加密")
                // HTTPURLResponse 单值字典无法表达多条 Set-Cookie，改为在 handler 内
                // 直接种 jar（URLSession 收 Set-Cookie 落独立 jar 的行为由真机验收覆盖）
                jar.setCookie(Self.cookie(name: "psession", value: "sess123", domain: "panel.test"))
                jar.setCookie(Self.cookie(name: "pcsrftoken", value: "csrf456", domain: "panel.test"))
                return (Self.response(request), Self.envelope(
                    #"{"name":"admin","role":"ADMIN","token":"","mfaStatus":"","mfaSession":""}"#))
            }
            return (Self.response(request), Self.envelope(#"{"needCaptcha":false}"#))
        }

        let result = try await client.login(username: "admin", password: "明文密码", captcha: "", captchaID: "")
        #expect(result.name == "admin")
        #expect(!result.mfaRequired)

        // cookie 隔离：ephemeral jar 持有会话 cookie，.shared 不受染
        #expect(await Self.waitForCookie(jar, "psession", baseURL: baseURL) == "sess123")
        #expect(await Self.waitForCookie(jar, "pcsrftoken", baseURL: baseURL) == "csrf456")
        #expect(Self.jarValue(.shared, "psession", baseURL: baseURL) == nil)
    }

    @Test("login：jar 无公钥 → 明文回落（网页端同款）")
    func loginPlaintextFallbackOnWire() async throws {
        let client = SessionAuthClient(
            baseURL: baseURL,
            protocolClasses: [BootstrapMockURLProtocol.self]
        )
        defer { client.invalidate() }
        BootstrapMockURLProtocol.setHandler { request in
            if request.url?.path.hasSuffix("/core/auth/login") == true {
                let body = (try? JSONSerialization.jsonObject(with: Self.requestBody(request) ?? Data())) as? [String: Any]
                #expect(body?["password"] as? String == "raw-secret", "无公钥 cookie 应明文回落")
                return (Self.response(request),
                        Self.envelope(#"{"name":"admin","role":"ADMIN","token":"","mfaStatus":"","mfaSession":""}"#))
            }
            return (Self.response(request), Self.envelope(#"{"needCaptcha":false}"#))
        }
        _ = try await client.login(username: "admin", password: "raw-secret", captcha: "", captchaID: "")
    }

    @Test("body 业务码判定：HTTP 200 + code 401 ErrAuth → 认证错误分支（非网络错误）")
    func businessCodeOverHTTPStatus() async throws {
        let client = SessionAuthClient(
            baseURL: baseURL,
            protocolClasses: [BootstrapMockURLProtocol.self]
        )
        defer { client.invalidate() }
        BootstrapMockURLProtocol.setHandler { request in
            (Self.response(request),
             #"{"code":401,"message":"ErrAuth","data":null}"#.data(using: .utf8)!)
        }
        do {
            _ = try await client.login(username: "admin", password: "wrong", captcha: "", captchaID: "")
            Issue.record("应抛出认证错误")
        } catch let error as SessionAuthError {
            if case .badCredentials = error {} else {
                Issue.record("应映射为 badCredentials，实际 \(error)")
            }
        }
    }

    @Test("CSRF 双提交：jar 有 pcsrftoken 的 POST 注入 X-CSRF-Token，GET 不带")
    func csrfHeaderInjection() async throws {
        let client = SessionAuthClient(
            baseURL: baseURL,
            protocolClasses: [BootstrapMockURLProtocol.self]
        )
        defer { client.invalidate() }
        let jar = client.cookieJar
        jar.setCookie(Self.cookie(name: "pcsrftoken", value: "csrf456", domain: "panel.test"))
        // setCookie 为异步落库：轮询到可见后再发请求，消除时序脆弱
        #expect(await Self.waitForCookie(jar, "pcsrftoken", baseURL: baseURL) == "csrf456")
        BootstrapMockURLProtocol.setHandler { request in
            if request.httpMethod == "POST" {
                #expect(request.value(forHTTPHeaderField: "X-CSRF-Token") == "csrf456")
            } else {
                #expect(request.value(forHTTPHeaderField: "X-CSRF-Token") == nil)
            }
            if request.url?.path.hasSuffix("/core/auth/api/keys/search") == true {
                return (Self.response(request), Self.envelope(
                    #"{"items":[{"id":"legacy","kind":"legacy","name":"Legacy API Key","status":"Disable","revision":3287886918601956}],"total":1}"#))
            }
            if request.url?.path.hasSuffix("/core/auth/api/keys/status") == true {
                return (Self.response(request), Self.envelope(#"{"terminalClosePending":false}"#))
            }
            if request.url?.path.hasSuffix("/core/auth/current") == true {
                return (Self.response(request), Self.envelope(#"{"name":"admin","role":"ADMIN","apiInterfaceStatus":"Disable"}"#))
            }
            return (Self.response(request), Self.envelope("null"))
        }
        // POST keys/search + keys/status + GET current 三段全走一遍
        try await client.enableApiInterface(preserving: Self.info(status: "Disable", key: ""))
        let info = try await client.currentUser()
        #expect(info.name == "admin")
    }

    @Test("enable 流程：keys/search 取 legacy revision → keys/status 原样回传翻 Enable")
    func enableViaLegacyKeyStatus() async throws {
        let client = SessionAuthClient(
            baseURL: baseURL,
            protocolClasses: [BootstrapMockURLProtocol.self]
        )
        defer { client.invalidate() }
        BootstrapMockURLProtocol.setHandler { request in
            if request.url?.path.hasSuffix("/core/auth/api/keys/search") == true {
                let body = (try? JSONSerialization.jsonObject(with: Self.requestBody(request) ?? Data())) as? [String: Any]
                #expect(body?["page"] as? Int == 1)
                #expect(body?["pageSize"] as? Int == 20)
                return (Self.response(request), Self.envelope(
                    #"{"items":[{"id":"legacy","kind":"legacy","status":"Disable","revision":3287886918601956}],"total":1}"#))
            }
            if request.url?.path.hasSuffix("/core/auth/api/keys/status") == true {
                let body = (try? JSONSerialization.jsonObject(with: Self.requestBody(request) ?? Data())) as? [String: Any]
                #expect(body?["id"] as? String == "legacy")
                #expect(body?["revision"] as? Int == 3287886918601956, "乐观锁 revision 必须取自 search 结果")
                #expect(body?["status"] as? String == "Enable")
                return (Self.response(request), Self.envelope(#"{"terminalClosePending":false}"#))
            }
            Issue.record("不应触达其他端点")
            return (Self.response(request), Self.envelope("null"))
        }
        try await client.enableApiInterface(preserving: Self.info(status: "Disable", key: ""))
    }

    @Test("enable 流程：legacy 行缺失 → 明确报错不盲发启停")
    func enableFailsWhenLegacyRowMissing() async throws {
        let client = SessionAuthClient(
            baseURL: baseURL,
            protocolClasses: [BootstrapMockURLProtocol.self]
        )
        defer { client.invalidate() }
        BootstrapMockURLProtocol.setHandler { request in
            if request.url?.path.hasSuffix("/core/auth/api/keys/search") == true {
                return (Self.response(request), Self.envelope(#"{"items":[],"total":0}"#))
            }
            Issue.record("legacy 缺失时不应继续 keys/status")
            return (Self.response(request), Self.envelope("null"))
        }
        do {
            try await client.enableApiInterface(preserving: Self.info(status: "Disable", key: ""))
            Issue.record("应抛出业务错误")
        } catch let error as SessionAuthError {
            if case .business = error {} else {
                Issue.record("应映射为 business，实际 \(error)")
            }
        }
    }

    @Test("enable 流程：keys/* 端点 404（旧面板）→ 回落 api/update 回传现有配置")
    func enableFallbackOnMissingKeysEndpoints() async throws {
        let client = SessionAuthClient(
            baseURL: baseURL,
            protocolClasses: [BootstrapMockURLProtocol.self]
        )
        defer { client.invalidate() }
        BootstrapMockURLProtocol.setHandler { request in
            if request.url?.path.hasSuffix("/core/auth/api/keys/search") == true
                || request.url?.path.hasSuffix("/core/auth/api/keys/status") == true {
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": "application/json"])!,
                        #"{"code":404,"message":"not found","data":null}"#.data(using: .utf8)!)
            }
            if request.url?.path.hasSuffix("/core/auth/api/update") == true {
                let body = (try? JSONSerialization.jsonObject(with: Self.requestBody(request) ?? Data())) as? [String: Any]
                #expect(body?["apiInterfaceStatus"] as? String == "Enable")
                #expect(body?["apiKey"] as? String == "keep")
                return (Self.response(request), Self.envelope("null"))
            }
            Issue.record("不应触达其他端点")
            return (Self.response(request), Self.envelope("null"))
        }
        try await client.enableApiInterface(preserving: Self.info(status: "Disable", key: "keep"))
    }

    @Test("mfalogin：ErrMFA → mfaFailed（保持 OTP 重输状态用）")
    func mfaFailureMapping() async throws {
        let client = SessionAuthClient(
            baseURL: baseURL,
            protocolClasses: [BootstrapMockURLProtocol.self]
        )
        defer { client.invalidate() }
        BootstrapMockURLProtocol.setHandler { request in
            (Self.response(request),
             #"{"code":401,"message":"ErrMFA","data":null}"#.data(using: .utf8)!)
        }
        do {
            _ = try await client.mfaLogin(sessionID: "tok", code: "000000")
            Issue.record("应抛出 mfaFailed")
        } catch let error as SessionAuthError {
            if case .mfaFailed = error {} else {
                Issue.record("应映射为 mfaFailed，实际 \(error)")
            }
        }
    }

    // MARK: - MockURLProtocol 辅助

    /// logs/抓取.md 实捕 panel_public_key cookie 值（与 PanelPasswordCryptoTests 同源）
    nonisolated static let capturedPublicKeyCookie =
        "LS0tLS1CRUdJTiBQVUJMSUMgS0VZLS0tLS0KTUlJQklqQU5CZ2txaGtpRzl3MEJBUUVGQUFPQ0FROEFNSUlCQ2dLQ0FRRUE1SVMyc1E5MERHWWpzaGQzZ0lvUApWZGl6OVlDRkFJckJReW8rVURpQWhWYzBtL2o5UHFXWDR6SmN6TkViTTByYWZYbWRaZkZHR3pvNy84Nm5hYXNtCms1VUw2b3RVcDJqUVQwN20yeXNGemtWTmZFcDNnQ2M2bTZ0K3B3RmRZOTlLaWRKclBSOUs3UGZZbW1CQzJUR2wKRktmNWJzallsSW1BWTI0ZDdMa2pWdWxCcGJMcy9xMlU2K1drSmV0d1lOZjNRdVV1bzNJWlZVMzhBOEdhWFNKUwpPbkFaWVhTQ2hlZEExdXlqNDYxOUxscW1Oa1ZsOTlSSE9YKzA2cGErRG5hSUcwbDRkcy93K2Jqa1NMTWlOcGdwCklsMVdIZTdDZCtCb1JmanQ3NHY4Ym1mZGxHRVk4eG4zclV6b0IzZ2xhSVVYMDVtNmF2dU9PWW1jMEp6c3BjVk0KUHdJREFRQUIKLS0tLS1FTkQgUFVCTElDIEtFWS0tLS0tCg%3D%3D"

    nonisolated private static func response(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json; charset=utf-8"]
        )!
    }

    nonisolated private static func envelope(_ dataJSON: String) -> Data {
        (#"{"code":200,"message":"","data":"# + dataJSON + #"}"#).data(using: .utf8)!
    }

    /// URLProtocol 下 httpBody 变 bodyStream，读回数据供断言
    nonisolated private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    nonisolated private static func cookie(name: String, value: String, domain: String) -> HTTPCookie {
        HTTPCookie(properties: [
            .domain: domain,
            .path: "/",
            .name: name,
            .value: value
        ])!
    }

    nonisolated private static func jarValue(_ jar: HTTPCookieStorage, _ name: String, baseURL: String) -> String? {
        let cookies = jar.cookies(for: URL(string: baseURL)!) ?? []
        return SessionAuthClient.cookieValue(named: name, cookies: cookies)
    }

    /// HTTPCookieStorage 写入异步生效：轮询等待 cookie 可见（超时返回 nil）
    nonisolated private static func waitForCookie(
        _ jar: HTTPCookieStorage,
        _ name: String,
        baseURL: String,
        timeout: TimeInterval = 2
    ) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = jarValue(jar, name, baseURL: baseURL) { return value }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    private static func info(status: String?, key: String?) -> CurrentUserInfo {
        CurrentUserInfo(
            name: "admin", role: "ADMIN", mfaStatus: "Disable",
            apiInterfaceStatus: status, apiKey: key,
            ipWhiteList: "", apiTrustedProxies: "", apiKeyValidityTime: 120
        )
    }
}

/// 引导流 mock：静态 handler 以锁保护（URLProtocol 回调在 URLSession 内部队列）
nonisolated final class BootstrapMockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

    nonisolated static func setHandler(
        _ handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?
    ) {
        lock.lock()
        defer { lock.unlock() }
        Self.handler = handler
    }

    nonisolated private static func currentHandler() -> (@Sendable (URLRequest) -> (HTTPURLResponse, Data))? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.currentHandler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
