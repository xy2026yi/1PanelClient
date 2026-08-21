//
//  WAFMonitorModels.swift
//  1PanelClient
//
//  WAF 监控：许可证 / 今日与7日统计 / 拦截记录 / 封锁记录
//

import SwiftUI
import Combine

// MARK: - 概览统计

nonisolated struct WAFStatToday: Decodable {
    let day: String?
    let reqCount: Int?
    let attackCount: Int?
    let count4xx: Int?
    let count5xx: Int?
}

nonisolated struct WAFStatDayItem: Decodable, Identifiable {
    let day: String
    let reqCount: Int?
    let attackCount: Int?

    var id: String { day }

    /// "2026-08-15" → "08-15"
    var shortDay: String { String(day.suffix(5)) }
}

// MARK: - 拦截记录

nonisolated struct WAFLogSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let ip: String
    let ipLocation: String
    let host: String
    let url: String
    let websiteKey: String
    let execRules: [String]
    let action: String
}

nonisolated struct WAFLogItem: Decodable, Identifiable {
    let logID: Int?
    let ip: String?
    let action: String?
    let uri: String?
    let execRule: String?
    let ruleType: String?
    let host: String?
    let localtime: String?
    let ipLocation: String?
    let isBlack: Bool?
    let isWhite: Bool?
    let isWhiteUrl: Bool?
    let matchValueContent: String?
    let nginxLog: String?
    let method: String?
    let userAgent: String?
    let statusCode: String?

    enum CodingKeys: String, CodingKey {
        case logID = "id"
        case ip, action, uri, execRule, ruleType, host, localtime, ipLocation
        case isBlack, isWhite, isWhiteUrl, matchValueContent, nginxLog, method, userAgent, statusCode
    }

    var id: String { "\(logID ?? 0)-\(localtime ?? "")-\(ip ?? "")" }
}

// MARK: - 封锁记录

nonisolated struct WAFBlockSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let total: Int
    let ip: String
}

/// 未抓到非空样例，字段均按可选防御解码
nonisolated struct WAFBlockItem: Decodable, Identifiable {
    let ip: String?
    let ipLocation: String?
    let count: Int?
    let untilTime: String?

    var id: String { ip ?? "\(count ?? 0)-\(untilTime ?? "")" }
}

// MARK: - 时间格式化

enum WAFTime {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()
    private static let output: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    /// ISO8601 → "MM-dd HH:mm:ss"；解析失败原样返回
    static func short(_ s: String?) -> String? {
        guard let s else { return nil }
        guard let d = isoFractional.date(from: s) ?? iso.date(from: s) else { return s }
        return output.string(from: d)
    }
}
