//
//  I18N.swift
//  1PanelClient
//
//  1Panel 部分 API 字段（如脚本库 name/description）以 i18n 映射字符串返回：
//  {"en": "Install Docker", "zh-hant": "安装 Docker"}
//  本工具将其解析为按 App 当前生效语言（L10n）匹配的文本，纯文本则原样返回。
//

import Foundation

/// 解析 1Panel i18n 映射字符串，按 App 当前生效语言取值（英文时英文优先，否则中文优先），
/// 均缺失时回退首项。非 i18n 格式的纯文本直接原样返回。
nonisolated func resolveI18n(_ raw: String) -> String {
    let s = raw.trimmingCharacters(in: .whitespaces)
    guard s.hasPrefix("{") && s.hasSuffix("}") else { return raw }

    // 标准 JSON 格式 {"lang": "text"}（1Panel 实际使用）
    if let data = s.data(using: .utf8),
       let dict = try? JSONDecoder().decode([String: String].self, from: data) {
        return pickLang(dict) ?? raw
    }

    // 兜底：非标准 JSON 的松散格式 {lang: text, lang: 文本}
    return resolveI18nLoose(s) ?? raw
}

/// 从语言映射中取值：App 生效语言为英文时 en → 中文 → 首项，否则中文（简→繁）→ 英文 → 首项
private nonisolated func pickLang(_ dict: [String: String]) -> String? {
    let zhPrefs = ["zh-CN", "zh-Hans", "zh-hant", "zh-Hant", "zh-TW", "zh-tw", "zh"]
    let prefs = L10n.shared.isEnglishEffective ? ["en"] + zhPrefs : zhPrefs + ["en"]
    for p in prefs {
        if let v = dict[p], !v.isEmpty { return v }
    }
    for (_, v) in dict where !v.isEmpty { return v }
    return nil
}

/// 松散格式 {en: text, zh-hant: 文本}（键值无引号）的兜底解析
private nonisolated func resolveI18nLoose(_ s: String) -> String? {
    let inner = String(s.dropFirst().dropLast())
    let langPattern = "(?:^|,\\s*)(en|zh-Hant|zh-hant|zh-CN|zh-Hans|zh-TW|zh-tw|zh|ja|ko|fr|de|es|ru|tr|ms|pt-BR|pt)\\s*:\\s*"
    guard let regex = try? NSRegularExpression(pattern: langPattern) else { return nil }
    let matches = regex.matches(in: inner, range: NSRange(inner.startIndex..., in: inner))
    guard !matches.isEmpty else { return nil }

    var dict: [String: String] = [:]
    for (i, m) in matches.enumerated() {
        guard let keyRange = Range(m.range(at: 1), in: inner),
              let fullRange = Range(m.range, in: inner) else { continue }
        let valStart = fullRange.upperBound
        let valEnd: String.Index
        if i + 1 < matches.count, let nextRange = Range(matches[i + 1].range, in: inner) {
            valEnd = nextRange.lowerBound
        } else {
            valEnd = inner.endIndex
        }
        let key = String(inner[keyRange])
        let value = String(inner[valStart..<valEnd])
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,\t\n\r"))
        dict[key] = value
    }
    return pickLang(dict)
}
