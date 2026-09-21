//
//  FormCodecs.swift
//  1PanelClient
//
//  表单 ↔ 服务端格式的纯函数编解码（无 UI 依赖，单测覆盖见 FormCodecsTests）：
//  - SupervisorEnvCodec：supervisor environment 串（逗号分隔、引号感知）↔ 行
//  - UnitCodec：秒 ↔ (数值, 单位)（整除取大单位，可整除时往返无损）
//

import Foundation

// MARK: - Supervisor environment 编解码

/// 服务端 environment 串 "K=V,K2=V2"（值可带双引号且内含逗号）↔ 多行编辑。
/// 引号内的逗号不拆分；值含逗号且未带引号时提交自动补引号，
/// 保证往返不拆断（supervisor ini 无转义语义；引号+逗号并存的行视为用户自行处理）
enum SupervisorEnvCodec {
    /// 服务端串 → 行数组（引号内逗号不拆、引号外空白去除；
    /// 抓包确认网页端即此格式，如 environment: "KEY=\"val\",KEY2=\"val2\""）
    static func split(_ raw: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var inQuotes = false
        for ch in raw {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch == ",", !inQuotes {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { lines.append(trimmed) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { lines.append(trimmed) }
        return lines
    }

    /// 行数组 → 服务端逗号分隔串：值含逗号且整行未带引号时给值补双引号
    ///（无逗号行原样保留）
    static func join(_ lines: [String]) -> String {
        lines.map { line in
            guard line.contains(","), !line.contains("\""),
                  let eq = line.firstIndex(of: "=") else { return line }
            let key = String(line[line.startIndex..<eq])
            let value = String(line[line.index(after: eq)...])
            return "\(key)=\"\(value)\""
        }
        .joined(separator: ",")
    }
}

// MARK: - 秒 ↔ (数值, 单位)

/// 秒级时长拆分为 (数值, s/m/h 单位)：整除取大单位，可整除的值往返无损；
/// 不可整除回落「秒」保精确，0 归一为 1 分钟（监控设置既有语义）
enum UnitCodec {
    /// 单位 → 秒（未知单位回落分钟，与表单单位菜单一致）
    static func unitToSeconds(_ unit: String) -> Int {
        switch unit {
        case "s": return 1
        case "h": return 3600
        default:  return 60
        }
    }

    /// 秒 → (数值, 单位)：≥1h 且整除取小时；整除分钟取分钟；否则秒（值钳 ≥1）
    static func scaleTime(seconds: Int) -> (value: Int, unit: String) {
        if seconds >= 3600, seconds % 3600 == 0 {
            return (seconds / 3600, "h")
        }
        if seconds % 60 == 0 {
            return (max(1, seconds / 60), "m")
        }
        return (max(1, seconds), "s")
    }
}
