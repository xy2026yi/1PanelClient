//
//  Alert.swift
//  1PanelClient
//
//  告警通知：告警规则 / 告警日志 / 发送方式 数据模型
//  基于 logs/告警通知/告警通知.md、告警管理.md 抓包
//

import Foundation
import SwiftUI

// MARK: - 告警规则

/// 告警规则（/api/v2/alert/search 返回项）
struct AlertRule: Decodable, Identifiable, Hashable {
    let id: Int
    let type: String?
    let cycle: Int?
    let count: Int?
    let method: String?
    let title: String?
    let project: String?
    let status: String?
    let sendCount: Int?
    let advancedParams: String?
    /// 面板新版本提醒固定为 "website"
    let subType: String?
    let createUser: String?
    let updateUser: String?
    let createdAt: String?
    let updatedAt: String?

    var isEnabled: Bool { status == "Enable" }

    /// 磁盘告警的监测类型（cycle 1=占用磁盘 2=占用百分比）
    var diskMonitorKind: Int? {
        guard alertType == .disk else { return nil }
        return cycle
    }

    /// 触发条件描述（按类型区分 cycle/count 语义）
    var conditionDisplay: String {
        switch alertType {
        case .sshLogin, .panelLogin:
            return L10n.f("%ld 分钟内失败 %ld 次", cycle ?? 0, count ?? 0)
        case .panelPwdEndTime, .ssl, .siteEndTime:
            return L10n.f("剩余 %ld 天", cycle ?? 0)
        case .cpu, .memory, .load:
            return L10n.f("5 分钟均值超 %ld%%", count ?? 0)
        case .disk:
            return (cycle == 1 ? L10n.t("占用磁盘超 ") : L10n.t("占用百分比超 ")) + "\(count ?? 0)%"
        case .panelUpdate:
            return L10n.t("面板有新版本时")
        case .unknown:
            return ""
        }
    }

    var alertType: AlertType { AlertType(rawValue: type ?? "") ?? .unknown }
}

/// 支持创建的告警类型（与官方面板一致，见 logs/告警通知/ 下抓包）
enum AlertType: String, CaseIterable, Identifiable {
    case panelPwdEndTime   // 面板密码到期
    case cpu               // CPU 占用过高
    case memory            // 内存占用过高
    case disk              // 磁盘占用过高
    case load              // 负载占用过高
    case ssl               // 网站证书到期
    case siteEndTime       // 网站到期
    case sshLogin          // SSH 登录异常
    case panelLogin        // 面板登录异常
    case panelUpdate       // 面板新版本提醒
    case unknown

    var id: String { rawValue }

    static var creatable: [AlertType] {
        [.panelPwdEndTime, .cpu, .memory, .disk, .load, .ssl, .siteEndTime, .sshLogin, .panelLogin, .panelUpdate]
    }

    var displayName: String {
        switch self {
        case .panelPwdEndTime: return L10n.t("面板密码到期")
        case .cpu:             return L10n.t("CPU 占用过高")
        case .memory:          return L10n.t("内存占用过高")
        case .disk:            return L10n.t("磁盘占用过高")
        case .load:            return L10n.t("负载占用过高")
        case .ssl:             return L10n.t("网站证书到期")
        case .siteEndTime:     return L10n.t("网站到期")
        case .sshLogin:        return L10n.t("SSH 登录异常")
        case .panelLogin:      return L10n.t("面板登录异常")
        case .panelUpdate:     return L10n.t("面板新版本提醒")
        case .unknown:         return L10n.t("未知")
        }
    }

    var icon: String {
        switch self {
        case .panelPwdEndTime: return "key"
        case .cpu:             return "cpu"
        case .memory:          return "gauge.with.needle"
        case .disk:            return "internaldrive"
        case .load:            return "speedometer"
        case .ssl:             return "lock.shield"
        case .siteEndTime:     return "globe"
        case .sshLogin:        return "terminal"
        case .panelLogin:      return "rectangle.and.hand.point.up.left"
        case .panelUpdate:     return "arrow.triangle.2.circlepath"
        case .unknown:         return "bell"
        }
    }

    var color: Color {
        switch self {
        case .panelPwdEndTime: return .orange
        case .cpu:             return .red
        case .memory:          return .pink
        case .disk:            return .yellow
        case .load:            return .mint
        case .ssl:             return .blue
        case .siteEndTime:     return .green
        case .sshLogin:        return .purple
        case .panelLogin:      return .teal
        case .panelUpdate:     return .indigo
        case .unknown:         return .gray
        }
    }

    /// 是否需要选择对象（证书 / 网站）
    var needsProject: Bool { self == .ssl || self == .siteEndTime }

    /// 磁盘告警：选择挂载目录
    var isDisk: Bool { self == .disk }

    /// 是否是「x 分钟内失败 x 次」型触发条件
    var isLoginType: Bool { self == .sshLogin || self == .panelLogin }

    /// CPU/内存/负载：时间窗口固定 5 分钟（监控采集间隔），count 为百分比阈值
    var isPercentType: Bool { self == .cpu || self == .memory || self == .load }

    /// 面板新版本提醒：无触发参数
    var isSimpleNotice: Bool { self == .panelUpdate }

    /// 默认剩余天数 / 时间窗口（分钟）/ 磁盘监测类型（2=占用百分比）
    var defaultCycle: Int {
        switch self {
        case .cpu, .memory, .load: return 5
        case .disk:                return 2
        case .panelUpdate:         return 0
        default:                   return isLoginType ? 30 : 15
        }
    }

    /// 百分比阈值默认值
    var defaultThreshold: Int {
        switch self {
        case .cpu, .memory, .load: return 80
        case .disk:                return 80   // 占用百分比默认 80，占用磁盘默认 30（切换时调整）
        default:                   return 80
        }
    }
}

// MARK: - 告警日志

/// 告警发送日志（/api/v2/alert/logs/search 返回项）
struct AlertLog: Decodable, Identifiable {
    let id: Int
    let type: String?
    let count: Int?
    let alertId: Int?
    let alertDetail: AlertLogDetail?
    let alertRule: AlertRule?
    let status: String?
    let method: String?
    let message: String?
    let createdAt: String?
    let updatedAt: String?

    var isSuccess: Bool { status == "Success" }
    var alertType: AlertType { AlertType(rawValue: type ?? "") ?? .unknown }
}

/// 日志内嵌的告警详情快照
struct AlertLogDetail: Decodable {
    let type: String?
    let subType: String?
    let title: String?
    let method: String?
    let project: String?
    let params: [AlertLogParam]?
    let phone: String?
}

struct AlertLogParam: Decodable, Identifiable {
    let index: String?
    let key: String?
    let value: String?
    var id: String { "\(index ?? "")-\(key ?? "")" }
}

// MARK: - 发送方式

/// 发送方式配置（/api/v2/alert/config/search 返回项，config 为 JSON 字符串）
struct AlertConfigItem: Decodable, Identifiable {
    let id: Int
    let type: String?
    let title: String?
    let status: String?
    let config: String?
    let createUser: String?
    let createdAt: String?
    let updatedAt: String?

    var isEnabled: Bool { status == "Enable" }

    /// 解析 config JSON 字符串（email/bark 字段并集，均可选）
    var sendConfig: AlertSendConfig {
        guard let data = config?.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(AlertSendConfig.self, from: data) else {
            return AlertSendConfig()
        }
        return parsed
    }

    /// 解析 common 全局配置（type == "common" 时有效）
    var commonConfig: AlertCommonConfig {
        guard let data = config?.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(AlertCommonConfig.self, from: data) else {
            return AlertCommonConfig()
        }
        return parsed
    }
}

/// 全局配置（type == "common" 的 config JSON：可发送时间范围）
struct AlertCommonConfig: Codable {
    var isOffline: String?
    var alertSendTimeRange: AlertSendTimeRange?
}

struct AlertSendTimeRange: Codable {
    var noticeAlert: AlertTimeRangeItem?
    var resourceAlert: AlertTimeRangeItem?
}

/// 单类告警的可发送时间范围（sendTimeRange 形如 "07:00:00 - 23:59:59"，type 为覆盖的告警类型，原样保留）
struct AlertTimeRangeItem: Codable {
    var sendTimeRange: String?
    var type: [String]?
}

/// 发送方式 config 字段（email 与 bark 并集）
struct AlertSendConfig: Codable {
    var displayName: String?
    var sender: String?
    var userName: String?
    var password: String?
    var host: String?
    var port: Int?
    var encryption: String?
    var status: String?
    var recipient: String?
    var url: String?
}

/// 支持配置的发送方式类型
enum AlertSendType: String, CaseIterable, Identifiable {
    case email
    case bark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .email: return L10n.t("邮箱通知")
        case .bark:  return "Bark"
        }
    }

    var icon: String {
        switch self {
        case .email: return "envelope"
        case .bark:  return "bell"
        }
    }

    var color: Color {
        switch self {
        case .email: return .blue
        case .bark:  return .indigo
        }
    }

    /// 官方 i18n 标题（config/update 需要原样回传）
    var apiTitle: String {
        switch self {
        case .email: return "xpack.alert.emailConfig"
        case .bark:  return "xpack.alert.bark"
        }
    }
}

// MARK: - 请求体

struct AlertSearchRequest: Encodable {
    var page = 1
    var pageSize = 100
    var type = ""
    var status = ""
    var method = ""
    var orderBy = "created_at"
    var order = "null"
}

struct AlertLogSearchRequest: Encodable {
    var page = 1
    var pageSize = 100
    var count: Int? = nil
    var status = ""
}

struct AlertConfigSearchRequest: Encodable {
    var page = 1
    var pageSize = 1000
    var excludeTypes = ["sms"]
}

struct AlertDeleteRequest: Encodable {
    let id: Int
}

/// 删除发送方式（POST /api/v2/alert/config/del）
struct AlertConfigDeleteRequest: Encodable {
    let id: Int
}

/// 创建 / 更新告警规则（POST /api/v2/alert、/api/v2/alert/update）
/// 编辑时需回传原记录的审计字段（对齐官方请求）
struct AlertUpsertRequest: Encodable {
    var id: Int? = nil
    let type: String
    var cycle: Int
    var count: Int
    var sendCount: Int
    var method: String
    var project: String
    var status: String
    var title: String
    var sendMethod: [String]
    var advancedParams: String? = nil
    /// 面板新版本提醒固定 "website"
    var subType: String? = nil
    var createUser: String? = nil
    var updateUser: String? = nil
    var createdAt: String? = nil
    var updatedAt: String? = nil
}

/// 测试邮箱发送方式（POST /api/v2/alert/config/test）
struct AlertEmailTestRequest: Encodable {
    let displayName: String
    let sender: String
    let userName: String
    let password: String
    let host: String
    let port: Int
    let encryption: String
    let status: String
    let recipient: String
}

/// 创建 / 更新发送方式（POST /api/v2/alert/config/update，config 为 JSON 字符串）
struct AlertConfigUpdateRequest: Encodable {
    var id: Int? = nil
    let type: String
    let title: String
    var status: String
    let config: String
    var displayName: String?
}

// MARK: - 创建告警所需选项（证书 / 网站下拉）

/// 证书下拉项（POST /api/v2/websites/ssl/list）
struct AlertSSLOption: Decodable, Identifiable {
    let id: Int
    let primaryDomain: String?
    let expireDate: String?

    var domain: String { primaryDomain ?? L10n.t("未知域名") }
}

/// 网站下拉项（GET /api/v2/websites/list）
struct AlertWebsiteOption: Decodable, Identifiable {
    let id: Int
    let primaryDomain: String?
    let alias: String?

    var domain: String { primaryDomain ?? alias ?? L10n.t("未知域名") }
}

/// 磁盘下拉项（GET /api/v2/alert/disks/list，单个告警关联 path）
struct AlertDiskOption: Decodable, Identifiable {
    let path: String
    let type: String?
    let device: String?
    let total: Int64?
    let usedPercent: Double?

    var id: String { path }
}

// MARK: - 时间展示

/// 截取 ISO 时间（2026-08-16T08:24:38.20+08:00 → 08-16 08:24），
/// 面板返回纳秒精度时间串，直接切片避免 DateFormatter 解析失败
func alertTimeDisplay(_ iso: String?) -> String {
    guard let iso, iso.count >= 16 else { return iso ?? "—" }
    let date = String(iso.dropFirst(5).prefix(5))   // MM-dd
    let time = String(iso.dropFirst(11).prefix(5))  // HH:mm
    return "\(date) \(time)"
}
