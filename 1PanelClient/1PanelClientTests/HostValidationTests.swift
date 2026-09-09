//
//  HostValidationTests.swift
//  1PanelClientTests
//
//  isValidHostOrIP / isValidIPv6：默认访问地址与 DNS/Hosts 子页共用的
//  主机地址校验（IPv4 / IPv6 / 域名；拒绝协议头、端口、路径、空格）
//

import Testing
@testable import _PanelClient

@Suite("主机地址校验")
struct HostValidationTests {
    @Test("IPv4 / 域名 / IPv6（含映射形式）通过")
    func validInputs() {
        #expect(PanelBasicSettingsView.isValidHostOrIP("192.168.1.1"))
        #expect(PanelBasicSettingsView.isValidHostOrIP("8.8.8.8"))
        #expect(PanelBasicSettingsView.isValidHostOrIP("example.com"))
        #expect(PanelBasicSettingsView.isValidHostOrIP("panel.example.co.uk"))
        #expect(PanelBasicSettingsView.isValidHostOrIP("::1"))
        #expect(PanelBasicSettingsView.isValidHostOrIP("fe80::1"))
        #expect(PanelBasicSettingsView.isValidHostOrIP("2001:db8::8a2e:370:7334"))
        // IPv4 映射形式（点分十进制尾部）
        #expect(PanelBasicSettingsView.isValidHostOrIP("::ffff:192.168.1.1"))
    }

    @Test("协议头 / 端口 / 路径 / 空格 / 畸形 IPv6 拒绝")
    func invalidInputs() {
        #expect(!PanelBasicSettingsView.isValidHostOrIP(""))
        #expect(!PanelBasicSettingsView.isValidHostOrIP("http://example.com"))
        #expect(!PanelBasicSettingsView.isValidHostOrIP("example.com:8080"))
        #expect(!PanelBasicSettingsView.isValidHostOrIP("example.com/path"))
        #expect(!PanelBasicSettingsView.isValidHostOrIP("ex ample.com"))
        // 纯标点（无十六进制位）与单冒号（host:port）都拒绝
        #expect(!PanelBasicSettingsView.isValidHostOrIP(":::"))
        #expect(!PanelBasicSettingsView.isValidHostOrIP("999.999.999.999"))
        #expect(!PanelBasicSettingsView.isValidHostOrIP("中文主机"))
    }

    @Test("isValidIPv6 边界：仅十六进制与冒号/点，且至少一位数字")
    func ipv6Boundaries() {
        #expect(PanelBasicSettingsView.isValidIPv6("::1"))
        #expect(PanelBasicSettingsView.isValidIPv6("dead:beef::"))
        #expect(PanelBasicSettingsView.isValidIPv6("::ffff:10.0.0.1"))
        // 无任何十六进制位（纯标点，含 "::" 未指定地址）拒绝
        #expect(!PanelBasicSettingsView.isValidIPv6("::"))
        #expect(!PanelBasicSettingsView.isValidIPv6(":::"))
        // 非法字符（g-z / 空格 / 斜杠）拒绝
        #expect(!PanelBasicSettingsView.isValidIPv6("gg::1"))
        #expect(!PanelBasicSettingsView.isValidIPv6(":: 1"))
    }
}
