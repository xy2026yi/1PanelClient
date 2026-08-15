//
//  Monitor.swift
//  1PanelClient
//
//  监控模块模型：POST /api/v2/hosts/monitor/search
//  基于网页端抓包（logs/监控/*.json），param 为 load/cpu/memory/io/network
//

import Foundation

// MARK: - 请求

/// 监控历史查询请求（param: load / cpu / memory / io / network）
nonisolated struct MonitorSearchRequest: Encodable {
    let param: String
    var io: String = "all"
    var network: String = "all"
    let startTime: String   // ISO8601 毫秒，如 "2026-08-14T16:00:00.000Z"
    let endTime: String
}

// MARK: - 响应

/// 单个监控指标序列：date 与 value 按索引一一对应
nonisolated struct MonitorSeries: Decodable {
    let param: String?       // 实际返回 "base"(负载/CPU/内存) / "io" / "network"
    let date: [String]?
    let value: [MonitorRecord]?
}

/// 监控记录（三种形态共用，未用字段为 nil）
/// - base: cpu/memory/loadUsage/cpuLoad1/5/15/topCPUItems/topMemItems
/// - io:   name/read/write/count/time
/// - network: name/up/down
nonisolated struct MonitorRecord: Decodable {
    let createdAt: String?
    // base 形态
    let cpu: Double?         // CPU 使用率 %
    let memory: Double?      // 内存使用率 %
    let loadUsage: Double?   // 负载使用率 %
    let cpuLoad1: Double?    // 1 分钟负载（原始值）
    let cpuLoad5: Double?
    let cpuLoad15: Double?
    let topCPUItems: [MonitorTopItem]?
    let topMemItems: [MonitorTopItem]?
    // io 形态
    let name: String?
    let read: Double?        // 读取 KB/s
    let write: Double?       // 写入 KB/s
    let count: Double?
    let time: Double?
    // network 形态
    let up: Double?          // 上行 KB/s
    let down: Double?        // 下行 KB/s
}

/// Top 进程项（base 记录内嵌）
nonisolated struct MonitorTopItem: Decodable, Identifiable {
    let name: String?
    let pid: Int?
    let percent: Double?     // CPU% 或 内存%
    let memory: Int64?       // 内存字节数（topMem 用）
    let cmd: String?
    let user: String?

    var id: String { "\(name ?? "")#\(pid ?? 0)" }
}

// MARK: - 日期工具

/// 监控接口的 ISO8601 毫秒格式转换。
/// 服务端返回纳秒精度（"2026-08-15T08:27:07.739061005+08:00"），需截断到毫秒再解析。
enum MonitorDate {
    /// 请求用：Date → "2026-08-14T16:00:00.000Z"
    static let requestFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// 解析用：毫秒精度
    static let parseFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// 无小数秒的兜底解析器
    static let plainFormatter = ISO8601DateFormatter()

    static func requestString(_ date: Date) -> String {
        requestFormatter.string(from: date)
    }

    /// 解析服务端时间串（容忍纳秒/毫秒/无小数秒三种精度）
    static func parse(_ string: String) -> Date? {
        if let d = parseFormatter.date(from: string) { return d }
        if let d = plainFormatter.date(from: string) { return d }
        // 纳秒精度：截断小数部分到 3 位后重试
        if let dot = string.firstIndex(of: "."),
           let zoneStart = string.firstIndex(where: { $0 == "+" || $0 == "Z" }),
           dot < zoneStart {
            let fracStart = string.index(after: dot)
            let keep = min(3, string.distance(from: fracStart, to: zoneStart))
            let truncated = String(string[..<string.index(fracStart, offsetBy: keep)]) + string[zoneStart...]
            return parseFormatter.date(from: truncated) ?? plainFormatter.date(from: truncated)
        }
        return nil
    }
}
