//
//  L10n.swift
//  1PanelClient
//
//  应用内文案本地化运行时：
//  key 即简体中文原文（zh-Hans 为源语言，源码即文案），英文翻译存 Localizable.xcstrings。
//  跟随系统时用 Bundle.main；手动选择语言时切换到对应 .lproj 子 bundle；
//  zh-Hans 生效时零查表直接返回 key。切换后发通知，由根视图 .id() 重建生效。
//

import Foundation

nonisolated final class L10n {
    static let shared = L10n()

    enum Language: String, CaseIterable, Identifiable {
        case system
        case zhHans = "zh-Hans"
        case english = "en"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: return L10n.t("跟随系统")
            case .zhHans: return "简体中文"
            case .english: return "English"
            }
        }
    }

    static let storageKey = "app.language"
    static let languageDidChangeNotification = Notification.Name("l10n.languageDidChange")

    private let lock = NSLock()
    private var _language: Language
    private var _enBundle: Bundle?

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey)
        _language = Language(rawValue: raw ?? "") ?? .system
    }

    var language: Language {
        lock.lock(); defer { lock.unlock() }
        return _language
    }

    func setLanguage(_ new: Language) {
        lock.lock()
        _language = new
        _enBundle = nil
        lock.unlock()
        UserDefaults.standard.set(new.rawValue, forKey: Self.storageKey)
        NotificationCenter.default.post(name: Self.languageDidChangeNotification, object: nil)
    }

    // MARK: - 查表

    /// 当前生效语言是否为英文（含「跟随系统」且系统语言非中文）
    var isEnglishEffective: Bool {
        switch language {
        case .english: return true
        case .zhHans: return false
        case .system: return !systemPrefersChinese
        }
    }

    /// 日期/数字格式化使用的 locale
    static var locale: Locale {
        shared.isEnglishEffective ? Locale(identifier: "en_US") : Locale(identifier: "zh_CN")
    }

    /// 取文案：查不到时回退 key 本身（即中文原文）
    static func t(_ key: String) -> String {
        shared.lookup(key)
    }

    /// 取带参数的格式化文案，key 需含 %@ / %ld 等占位符
    static func f(_ key: String, _ args: any CVarArg...) -> String {
        String(format: shared.lookup(key), locale: locale, arguments: args)
    }

    private func lookup(_ key: String) -> String {
        guard isEnglishEffective, let bundle = englishBundle else { return key }
        // value 传 key：条目缺失时 localizedString 原样返回 key，天然 fallback 到中文
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    private var englishBundle: Bundle? {
        lock.lock(); defer { lock.unlock() }
        if let cached = _enBundle { return cached }
        guard let path = Bundle.main.path(forResource: "Localizable", ofType: "strings",
                                          inDirectory: nil, forLocalization: "en"),
              let bundle = Bundle(path: (path as NSString).deletingLastPathComponent) else {
            return nil // 资源缺失时下次再试，不缓存失败
        }
        _enBundle = bundle
        return bundle
    }

    private var systemPrefersChinese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("zh") ?? true
    }
}
