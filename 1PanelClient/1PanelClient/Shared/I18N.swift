//
//  I18N.swift
//  1PanelClient
//
//  1Panel 部分 API 字段（如脚本库 name/description）以 i18n 映射字符串返回：
//  "{en: Install Docker, zh-hant: 安装Docker}"
//  本工具将其解析为当前偏好的中文（简/繁）文本，纯文本则原样返回。
//

import Foundation

/// 解析 1Panel i18n 映射字符串，提取中文（优先简体），无中文时回退英文。
/// 非 i18n 格式的纯文本直接原样返回。
func resolveI18n(_ raw: String) -> String {
    let s = raw.trimmingCharacters(in: .whitespaces)
    guard s.hasPrefix("{") && s.hasSuffix("}") else { return raw }
    let inner = String(s.dropFirst().dropLast())

    let langPattern = "(?:^|,\\s*)(en|zh-Hant|zh-hant|zh-CN|zh-Hans|zh-TW|zh-tw|zh|ja|ko|fr|de|es|ru|tr|ms|pt-BR|pt)\\s*:\\s*"
    guard let regex = try? NSRegularExpression(pattern: langPattern) else { return raw }
    let matches = regex.matches(in: inner, range: NSRange(inner.startIndex..., in: inner))
    guard !matches.isEmpty else { return raw }

    var entries: [(lang: String, value: String)] = []
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
        var value = String(inner[valStart..<valEnd])
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " ,\t\n\r"))
        entries.append((key, value))
    }

    // 中文优先：简体 → 繁体 → 通用 zh
    let prefs = ["zh-CN", "zh-Hans", "zh-hant", "zh-Hant", "zh-TW", "zh-tw", "zh"]
    for p in prefs {
        if let e = entries.first(where: { $0.lang == p }) { return e.value }
    }
    if let e = entries.first(where: { $0.lang == "en" }) { return e.value }
    return entries.first?.value ?? raw
}
