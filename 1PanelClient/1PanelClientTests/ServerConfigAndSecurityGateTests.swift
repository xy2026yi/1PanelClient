//
//  ServerConfigAndSecurityGateTests.swift
//  1PanelClientTests
//
//  连接安全：http:// 明文识别 + 「仅允许 HTTPS」拦截
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("ServerConfig 与 SecurityGate")
struct ServerConfigAndSecurityGateTests {
    private func make(_ baseURL: String) -> ServerConfig {
        ServerConfig(id: UUID(), name: "n", baseURL: baseURL, apiKey: "k")
    }

    @Test("isPlainHTTP：http:// 明文识别（含大小写与协议缺省）")
    func plainHTTPDetection() {
        #expect(make("http://10.0.0.1:36130").isPlainHTTP)
        #expect(make("HTTP://Example.com:8080").isPlainHTTP)
        #expect(!make("https://panel.example.com").isPlainHTTP)
        // 未写协议时 URLComponents 解析不出 scheme，不视为明文 HTTP
        //（实际连接按 URL(string:) 规则默认走 http/https 由系统决定）
        #expect(!make("panel.example.com").isPlainHTTP)
        #expect(!make("").isPlainHTTP)
    }

    @Test("normalizedBaseURL：去首尾空白与尾斜杠")
    func normalizedBaseURL() {
        #expect(make("  https://a.com/ ").normalizedBaseURL == "https://a.com")
        #expect(make("https://a.com///").normalizedBaseURL == "https://a.com")
    }

    @Test("Codable 往返")
    func codableRoundTrip() throws {
        let s = make("https://p.example.com")
        let back = try JSONDecoder().decode(ServerConfig.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test("SecurityGate：仅 HTTPS 开启时拦截 http://、放行 https://")
    func gateBlocksPlainHTTP() throws {
        let defaults = UserDefaults.standard
        let original = defaults.bool(forKey: SecurityGate.httpsOnlyKey)
        defer { defaults.set(original, forKey: SecurityGate.httpsOnlyKey) }

        defaults.set(true, forKey: SecurityGate.httpsOnlyKey)

        let httpServer = make("http://10.0.0.1:36130")
        do {
            try SecurityGate.check(httpServer)
            Issue.record("http:// 明文地址应被拦截")
        } catch let err as APIError {
            guard case .businessError = err else {
                Issue.record("拦截应抛出 businessError，实际 \(err)")
                return
            }
        }

        var httpsThrew = false
        do { try SecurityGate.check(make("https://a.com")) } catch { httpsThrew = true }
        #expect(!httpsThrew)
    }

    @Test("SecurityGate：开关关闭时不拦截 http://")
    func gateAllowsPlainHTTPWhenDisabled() {
        let defaults = UserDefaults.standard
        let original = defaults.bool(forKey: SecurityGate.httpsOnlyKey)
        defer { defaults.set(original, forKey: SecurityGate.httpsOnlyKey) }

        defaults.set(false, forKey: SecurityGate.httpsOnlyKey)
        var threw = false
        do { try SecurityGate.check(make("http://10.0.0.1:36130")) } catch { threw = true }
        #expect(!threw)
    }
}
