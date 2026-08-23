//
//  FirewallWhitelistTests.swift
//  1PanelClientTests
//
//  端口白名单原始值解析：同一面板存在逗号分隔（Web 端初始形态）与
//  换行分隔（update 提交回显形态）两种格式，统一拆成一行一个端口。
//

import Testing
@testable import _PanelClient

@Suite("防火墙端口白名单解析")
struct FirewallWhitelistTests {
    @Test("逗号分隔格式（Web 端初始形态）")
    func commaSeparated() {
        let entries = parseFirewallPortWhitelist("80/tcp,443/tcp,443/udp")
        #expect(entries == ["80/tcp", "443/tcp", "443/udp"])
    }

    @Test("换行分隔格式（update 提交后的回显形态）")
    func newlineSeparated() {
        let entries = parseFirewallPortWhitelist("8080\n22\n80\n443")
        #expect(entries == ["8080", "22", "80", "443"])
    }

    @Test("混入 CR 与首尾空白仍能拆净")
    func crlfAndWhitespace() {
        let entries = parseFirewallPortWhitelist(" 80/tcp ,\r\n 443/udp ,,")
        #expect(entries == ["80/tcp", "443/udp"])
    }

    @Test("空值 / nil / 全空段")
    func emptyValues() {
        #expect(parseFirewallPortWhitelist(nil) == [])
        #expect(parseFirewallPortWhitelist("") == [])
        #expect(parseFirewallPortWhitelist(" , \n ") == [])
    }
}
