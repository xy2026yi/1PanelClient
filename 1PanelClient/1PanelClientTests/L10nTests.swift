//
//  L10nTests.swift
//  1PanelClientTests
//
//  L10n 查表/切换/回退，以及 resolveI18n 随 App 语言联动的行为
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("L10n 本地化运行时")
struct L10nTests {
    /// 测试内临时切语言，结束后恢复跟随系统
    private func withLanguage(_ lang: L10n.Language, _ body: () throws -> Void) rethrows {
        let original = L10n.shared.language
        L10n.shared.setLanguage(lang)
        defer { L10n.shared.setLanguage(original) }
        try body()
    }

    @Test("zh-Hans 生效：零查表，key 原样返回")
    func chineseReturnsKey() throws {
        withLanguage(.zhHans) {
            #expect(L10n.t("设置") == "设置")
            #expect(L10n.t("不存在的词条") == "不存在的词条")
        }
    }

    @Test("en 生效：查 en 子 bundle，缺失时回退 key")
    func englishLooksUpCatalog() throws {
        withLanguage(.english) {
            #expect(L10n.t("设置") == "Settings")
            #expect(L10n.t("语言") == "Language")
            #expect(L10n.t("不存在的词条") == "不存在的词条")
        }
    }

    @Test("f 格式化插值（中/英各自成句）")
    func formatInterpolation() throws {
        withLanguage(.english) {
            // 该词条已入 catalog（批 6 翻译为 Failed to load: %@）
            #expect(L10n.f("加载失败：%@", "timeout") == "Failed to load: timeout")
        }
        withLanguage(.zhHans) {
            // %@ 只能传对象（传 Int 会读野指针崩溃），整数一律 %ld（同 App 调用约定）
            #expect(L10n.f("%ld 个容器", 3) == "3 个容器")
        }
    }

    @Test("setLanguage 持久化并发通知")
    func setLanguagePersistsAndNotifies() async throws {
        let original = L10n.shared.language
        defer { L10n.shared.setLanguage(original) }

        try await confirmation("languageDidChangeNotification") { notified in
            let obs = NotificationCenter.default.addObserver(
                forName: L10n.languageDidChangeNotification, object: nil, queue: nil
            ) { _ in notified() }
            // NotificationCenter post 在调用线程同步派发，无需额外等待
            L10n.shared.setLanguage(.english)
            NotificationCenter.default.removeObserver(obs)
        }

        #expect(UserDefaults.standard.string(forKey: L10n.storageKey) == "en")
        #expect(L10n.shared.language == .english)
    }

    @Test("locale 随语言切换")
    func localeFollowsLanguage() throws {
        withLanguage(.english) {
            #expect(L10n.locale.identifier == "en_US")
        }
        withLanguage(.zhHans) {
            #expect(L10n.locale.identifier == "zh_CN")
        }
    }
}

@Suite("resolveI18n 随 App 语言联动")
struct ResolveI18nLanguageTests {
    private static let json = #"{"en": "Install Docker", "zh-CN": "安装 Docker"}"#

    @Test("中文模式：中文优先")
    func chinesePreferred() {
        let original = L10n.shared.language
        L10n.shared.setLanguage(.zhHans)
        defer { L10n.shared.setLanguage(original) }
        #expect(resolveI18n(Self.json) == "安装 Docker")
    }

    @Test("英文模式：英文优先")
    func englishPreferred() {
        let original = L10n.shared.language
        L10n.shared.setLanguage(.english)
        defer { L10n.shared.setLanguage(original) }
        #expect(resolveI18n(Self.json) == "Install Docker")
    }

    @Test("纯文本原样返回（两种语言一致）")
    func plainTextPassthrough() {
        #expect(resolveI18n("普通文本") == "普通文本")
        #expect(resolveI18n("plain text") == "plain text")
    }

    @Test("映射缺失目标语言时回退首项")
    func fallbackToFirst() {
        let original = L10n.shared.language
        L10n.shared.setLanguage(.english)
        defer { L10n.shared.setLanguage(original) }
        #expect(resolveI18n(#"{"ja": "Docker をインストール"}"#) == "Docker をインストール")
    }
}

