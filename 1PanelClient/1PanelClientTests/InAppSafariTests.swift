//
//  InAppSafariTests.swift
//  1PanelClientTests
//
//  应用内浏览器路由：http/https 弹应用内、无 scheme 裸域名补 https、
//  其他 scheme 交系统出路、close 清空
//

import Testing
import Foundation
@testable import _PanelClient

@MainActor
@Suite("应用内浏览器路由")
struct InAppSafariTests {
    @Test("http/https 弹应用内浏览器")
    func httpOpensInApp() {
        let presenter = InAppSafariPresenter(openExternal: { _ in
            Issue.record("http/https 不应走系统出路")
        })
        presenter.open(URL(string: "https://1panel.cn")!)
        #expect(presenter.target?.url.absoluteString == "https://1panel.cn")

        presenter.open(URL(string: "http://example.com/path?a=1")!)
        #expect(presenter.target?.url.absoluteString == "http://example.com/path?a=1")
    }

    @Test("无 scheme 的裸域名补 https 后应用内打开")
    func schemelessDomainGetsHttps() {
        let presenter = InAppSafariPresenter(openExternal: { _ in
            Issue.record("裸域名补 https 后不应走系统出路")
        })
        presenter.open(URL(string: "www.fit2cloud.com")!)
        #expect(presenter.target?.url.absoluteString == "https://www.fit2cloud.com")
    }

    @Test("非 http scheme 交系统处理，不弹应用内")
    func nonHttpGoesExternal() {
        var external: [URL] = []
        let presenter = InAppSafariPresenter(openExternal: { external.append($0) })
        presenter.open(URL(string: "git://github.com/foo/bar")!)
        #expect(presenter.target == nil)
        #expect(external.map(\.absoluteString) == ["git://github.com/foo/bar"])
    }

    @Test("close 清空呈现目标")
    func closeClearsTarget() {
        let presenter = InAppSafariPresenter(openExternal: { _ in })
        presenter.open(URL(string: "https://1panel.cn")!)
        #expect(presenter.target != nil)
        presenter.close()
        #expect(presenter.target == nil)
    }
}
