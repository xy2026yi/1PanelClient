//
//  WebsiteMonitorModels.swift
//  1PanelClient
//
//  网站监控：QPS / 今日统计 / 访客趋势 / 访客地图 / 访问统计排行 / 请求日志
//

import SwiftUI
import Combine

// MARK: - 时间范围

/// 今日 / 近7天 / 近30日：访客趋势与统计接口用 rawValue（today/last7days/last30days），
/// 访问统计排行用 yyyyMMdd 日期对，请求日志用 ISO 时间窗
enum WebsiteMonitorRange: String, CaseIterable, Identifiable {
    case today = "today"
    case last7days = "last7days"
    case last30days = "last30days"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return L10n.t("今日")
        case .last7days: return L10n.t("近7天")
        case .last30days: return L10n.t("近30日")
        }
    }

    var days: Int {
        switch self {
        case .today: return 1
        case .last7days: return 7
        case .last30days: return 30
        }
    }

    /// 访问统计 rank 参数：yyyyMMdd 日期对（今日为同日起止）
    /// now 可注入以便测试；缺省取当前时刻
    func dayPair(now: Date = Date()) -> [String] {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        let cal = Calendar.current
        let end = cal.startOfDay(for: now)
        let start = cal.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        return [fmt.string(from: start), fmt.string(from: end)]
    }

    /// 请求日志时间窗：今日为当日 00:00:00–23:59:59，其余为滚动 N 天到现在
    /// now 可注入以便测试；缺省取当前时刻
    func logWindow(now: Date = Date()) -> (start: Date, end: Date) {
        let cal = Calendar.current
        if self == .today {
            let start = cal.startOfDay(for: now)
            let end = cal.date(byAdding: .second, value: 86399, to: start) ?? now
            return (start, end)
        }
        let start = cal.date(byAdding: .day, value: -(days - 1), to: now) ?? now
        return (start, now)
    }
}

// MARK: - 实时 QPS(1分钟)

nonisolated struct MonitorQpsRequest: Encodable {
    let websiteID: Int
}

nonisolated struct MonitorQpsInfo: Decodable {
    let qps: Int?
    let flow: Int64?
}

// MARK: - 统计(今日状态)

nonisolated struct MonitorStatRequest: Encodable {
    let websiteID: Int
    let dayRange: String
}

nonisolated struct WebsiteMonitorStat: Decodable {
    let pv: Int?
    let uv: Int?
    let ip: Int?
    let flow: Int64?
    let spider: Int?
    let req: Int?
    let count4xx: Int?
    let count5xx: Int?
}

// MARK: - 访客趋势

nonisolated struct MonitorVisitorsRequest: Encodable {
    let websiteID: Int
    let dayRange: String
}

nonisolated struct VisitorTrendPoint: Decodable, Identifiable {
    let date: String
    let pv: Int?
    let uv: Int?

    var id: String { date }

    /// "00:00 - 00:59" → "00:00"；"2026-08-15" → "08-15"
    var shortLabel: String {
        if date.contains(" - ") { return String(date.prefix(5)) }
        if date.count >= 10 { return String(date.suffix(5)) }
        return date
    }
}

// MARK: - 访客地图(30日)

nonisolated struct MonitorLocRequest: Encodable {
    let websiteID: Int
    let resource: String
}

nonisolated struct VisitorLocItem: Decodable, Identifiable {
    /// 服务端整型/浮点/数字字符串都可能出现，统一按 Double 容错解码
    let value: Double?
    let name: String?

    init(value: Double? = nil, name: String? = nil) {
        self.value = value
        self.name = name
    }

    private enum CodingKeys: String, CodingKey { case value, name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let d = try? c.decode(Double.self, forKey: .value) {
            value = d
        } else if let s = try? c.decode(String.self, forKey: .value), let d = Double(s) {
            value = d
        } else {
            value = nil
        }
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
    }

    var id: String { name ?? "\(value ?? 0)" }
}

// MARK: - 访问统计排行

nonisolated struct MonitorRankRequest: Encodable {
    let websiteID: Int
    let type: String
    let dayRange: [String]
    let limit: Int
}

nonisolated struct MonitorRankItem: Decodable, Identifiable {
    let name: String?
    let count: Int?
    let percent: Double?

    var id: String { "\(name ?? "")-\(count ?? 0)" }
}

// MARK: - 请求日志

nonisolated struct MonitorLogSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let total: Int
    let ip: String
    let ipLocation: String
    let url: String
    let websiteID: Int
    let method: String
    let spider: String
    let orderBy: String
    let order: String
    let startTime: String
    let endTime: String
}

/// 列表行只需展示与详情跳转字段，完整信息由详情接口返回
nonisolated struct MonitorLogItem: Decodable, Identifiable {
    let logID: Int?
    let ip: String?
    let ipLocation: String?
    let uri: String?
    let localtime: String?

    enum CodingKeys: String, CodingKey {
        case logID = "id"
        case ip, ipLocation, uri, localtime
    }

    var id: String { "\(logID ?? 0)-\(localtime ?? "")" }
}

// MARK: - 请求日志详情

nonisolated struct MonitorLogDetailRequest: Encodable {
    let id: Int
    let websiteID: Int
}

nonisolated struct MonitorLogDetail: Decodable {
    let ip: String?
    let ipLocation: String?
    let host: String?
    let uri: String?
    let method: String?
    let referer: String?
    let userAgent: String?
    let statusCode: Int?
    let requestTime: Int?
    let sendBytes: Int64?
    let localtime: String?
}
