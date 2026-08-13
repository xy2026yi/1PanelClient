//
//  Cronjob.swift
//  1PanelClient
//
//  计划任务相关模型，基于 doc/计划任务.md
//

import Foundation
import SwiftUI

// MARK: - 任务类型

/// 计划任务类型
enum CronjobType: String, CaseIterable, Identifiable, Codable {
    case shell      = "shell"       // Shell 脚本
    case app        = "app"         // 备份应用
    case website    = "website"     // 备份网站
    case database   = "database"    // 备份数据库
    case snapshot   = "snapshot"    // 系统快照

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shell:     return "Shell 脚本"
        case .app:       return "备份应用"
        case .website:   return "备份网站"
        case .database:  return "备份数据库"
        case .snapshot:  return "系统快照"
        }
    }

    var icon: String {
        switch self {
        case .shell:     return "terminal"
        case .app:       return "shippingbox"
        case .website:   return "globe"
        case .database:  return "cylinder"
        case .snapshot:  return "camera.metering.center.weighted"
        }
    }

    var color: Color {
        switch self {
        case .shell:     return .black
        case .app:       return .blue
        case .website:   return .green
        case .database:  return .teal
        case .snapshot:  return .purple
        }
    }

    /// 是否需要备份账号选择
    var needsBackupAccount: Bool {
        switch self {
        case .app, .website, .database, .snapshot: return true
        case .shell: return false
        }
    }
}

// MARK: - 计划任务列表

/// 计划任务搜索请求
nonisolated struct CronjobSearchRequest: Encodable {
    var page: Int = 1
    var pageSize: Int = 20
    var orderBy: String = "createdAt"
    var order: String = "null"
}

/// 计划任务列表响应
nonisolated struct CronjobListResponse: Decodable {
    let total: Int
    let items: [Cronjob]?
}

/// 单个计划任务（response.CronjobDTO，仅取列表/详情展示所需字段）
nonisolated struct Cronjob: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let type: String?                  // CronjobType.rawValue
    let groupID: Int?
    let spec: String?                  // cron 表达式
    let specs: [String]?
    let script: String?
    let scriptMode: String?
    let user: String?
    let appID: String?
    let website: String?
    let dbType: String?                // mysql / mariadb / postgresql / mongodb
    let dbName: String?
    /// 备份参数（逗号分隔字符串）。对应服务端 args 字段。
    let args: String?
    /// 备份参数（逐项数组）。对应服务端 argItems 字段。
    let argItems: [String]?
    let url: String?
    let sourceDir: String?
    let containerName: String?
    let inContainer: Bool?
    let retainCopies: Int?
    let status: String?                // Enable/Disable
    let lastRecordStatus: String?      // Success/Failed/...
    let lastExecutionTime: String?
    let executor: String?
    let retryTimes: Int?
    let timeout: Int?
    let timeoutUnit: String?

    /// 任务类型枚举
    var jobType: CronjobType {
        CronjobType(rawValue: type ?? "") ?? .shell
    }

    /// 是否启用
    var isEnabled: Bool {
        (status ?? "").lowercased() == "enable"
    }

    /// 上次执行状态颜色
    var lastStatusColor: Color {
        switch (lastRecordStatus ?? "").lowercased() {
        case "success":  return .green
        case "failed":   return .red
        case "waiting":  return .orange
        default:         return .secondary
        }
    }

    /// cron 表达式友好显示
    var specDisplay: String {
        spec ?? "—"
    }

    /// 保留份数
    var retainCopiesDisplay: String {
        guard let n = retainCopies, n > 0 else { return "—" }
        return "\(n) 份"
    }

    /// 上次执行状态中文
    var lastStatusDisplay: String {
        switch (lastRecordStatus ?? "").lowercased() {
        case "success":  return "成功"
        case "failed":   return "失败"
        case "waiting":  return "等待中"
        case "running":  return "执行中"
        default:         return lastRecordStatus ?? "—"
        }
    }

    /// 数据库类型友好显示（仅 database 任务有效）
    var dbTypeDisplay: String {
        switch (dbType ?? "").lowercased() {
        case "mysql":      return "MySQL"
        case "mariadb":    return "MariaDB"
        case "postgresql": return "PostgreSQL"
        case "mongodb":    return "MongoDB"
        default:           return dbType ?? "—"
        }
    }

    /// 备份参数友好显示（仅 database 任务有效）。
    /// 优先使用逐项数组 argItems，回退到逗号分隔字符串 args。
    var dbBackupParamsDisplay: String {
        if let items = argItems, !items.isEmpty {
            return items.joined(separator: ", ")
        }
        let raw = args ?? ""
        return raw.isEmpty ? "默认（无）" : raw.replacingOccurrences(of: ",", with: ", ")
    }
}

// MARK: - 加载计划任务详情（编辑用）

/// 按 ID 加载计划任务详情的请求（POST /api/v2/cronjobs/load/info）
nonisolated struct CronjobLoadInfoRequest: Encodable {
    let id: Int
}

/// 计划任务详情（POST /api/v2/cronjobs/load/info 返回）。
/// 包含编辑表单预填所需的全部字段，字段命名对应服务端 CronjobInfo DTO。
nonisolated struct CronjobInfo: Decodable {
    let id: Int
    let name: String?
    let type: String?
    let groupID: Int?
    let specCustom: Bool?
    let spec: String?

    let executor: String?
    let scriptMode: String?
    let script: String?
    let command: String?
    let containerName: String?
    let user: String?

    let scriptID: Int?
    let appID: String?
    let website: String?
    let exclusionRules: String?
    let dbType: String?
    let dbName: String?
    let url: String?
    let isDir: Bool?
    let sourceDir: String?
    let retainCopies: Int?
    let retryTimes: Int?
    let timeout: Int?
    let ignoreErr: Bool?

    let sourceAccounts: [String]?
    let downloadAccount: String?
    let sourceAccountIDs: String?
    let downloadAccountID: Int?

    let status: String?
    let secret: String?
    /// 备份参数（逗号分隔字符串）
    let args: String?

    let alertCount: Int?

    /// 任务类型枚举
    var jobType: CronjobType {
        CronjobType(rawValue: type ?? "") ?? .shell
    }

    /// 选中的备份参数集合（从 args 逗号分隔解析）
    var backupParamSet: Set<String> {
        Set((args ?? "").split(separator: ",").map { String($0) }.filter { !$0.isEmpty })
    }
}

// MARK: - 创建/编辑计划任务

/// 计划任务分组（response.CronjobGroup）
nonisolated struct CronjobGroup: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let type: String?
    let isDefault: Bool?
}

/// 备份账号
nonisolated struct BackupOption: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let type: String?
    let isPublic: Bool?
}

/// 数据库实例项（GET /api/v2/databases/db/item/<type> 返回）
nonisolated struct DBItemOption: Decodable, Identifiable, Hashable {
    let id: Int
    let from: String?
    let database: String?     // 服务名，如 "mysql"
    let name: String?         // 数据库名
}

/// 分组查询请求
nonisolated struct CronjobGroupRequest: Encodable {
    let type: String
}

/// 手动执行计划任务请求
nonisolated struct CronjobHandleRequest: Encodable {
    let id: Int
}

/// 删除计划任务请求
nonisolated struct CronjobDeleteRequest: Encodable {
    let ids: [Int]
    var cleanData: Bool = false
    var cleanRemoteData: Bool = false
}

// MARK: - 执行记录

/// 执行记录查询请求
nonisolated struct CronjobRecordSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let cronjobID: Int
    let startTime: String
    let endTime: String
    let status: String
}

/// 执行记录列表响应
nonisolated struct CronjobRecordListResponse: Decodable {
    let total: Int
    let items: [CronjobRecord]?
}

/// 单条执行记录
nonisolated struct CronjobRecord: Decodable, Identifiable, Hashable {
    let id: Int?
    let taskID: String?
    let startTime: String?
    let status: String?
    let message: String?
    let interval: Int?
    let file: String?
    let targetPath: String?

    /// 状态颜色
    var statusColor: Color {
        switch (status ?? "").lowercased() {
        case "success":  return .green
        case "failed":   return .red
        case "waiting":  return .orange
        default:         return .secondary
        }
    }

    /// 状态中文
    var statusDisplay: String {
        switch (status ?? "").lowercased() {
        case "success":  return "成功"
        case "failed":   return "失败"
        case "waiting":  return "等待中"
        case "running":  return "执行中"
        default:         return status ?? "未知"
        }
    }

    /// 耗时格式化（毫秒 → 秒）
    var durationDisplay: String {
        guard let ms = interval, ms > 0 else { return "—" }
        let secs = ms / 1000
        if secs >= 60 {
            return "\(secs / 60) 分 \(secs % 60) 秒"
        }
        return "\(secs) 秒"
    }
}

// MARK: - 任务日志（复用 files/read）

/// 任务日志请求（与 WebsiteLogReadRequest 类似但 taskID 不同）
nonisolated struct CronjobLogRequest: Encodable {
    let type = "task"
    let page: Int
    let pageSize: Int
    let latest: Bool
    let taskID: String
}

/// 任务日志响应
nonisolated struct CronjobLogResponse: Decodable {
    let end: Bool?
    let path: String?
    let total: Int?
    let taskStatus: String?
    let lines: [String]?
    let totalLines: Int?
}

// MARK: - 创建任务请求体（全字段，用于 POST /api/v2/cronjobs）

/// 创建计划任务请求（覆盖 5 种类型，未使用字段保持默认空值）
/// 字段顺序与 1Panel 网页端 POST /api/v2/cronjobs 抓包保持一致。
nonisolated struct CronjobCreateRequest: Encodable {
    var id: Int = 0
    var name: String = ""
    var type: String = "shell"
    var groupID: Int = 0
    var specCustom: Bool = false
    var spec: String = ""
    var specs: [String] = []
    var specObjs: [CronjobSpecObj] = []
    var executor: String = ""
    var isExecutorCustom: Bool = false
    var script: String = ""
    var scriptMode: String = "input"
    var isCustom: Bool = false
    var command: String = ""
    var inContainer: Bool = false
    var containerName: String = ""
    var user: String = "root"
    var scriptID: Int? = nil
    var appID: String = ""
    var website: String = ""
    var ignoreFiles: [String] = []
    var exclusionRules: String = ""
    var dbType: String = "mysql"
    var dbName: String = ""
    var url: String = ""
    var urlItems: [String] = [""]
    var isDir: Bool = true
    var files: [String] = []
    var sourceDir: String = ""
    var snapshotRule = CronjobSnapshotRule()
    var ignoreAppIDs: [Int] = []
    var withImage: Bool = false
    var sourceAccounts: [Int] = []
    var downloadAccount: String = ""
    var sourceAccountIDs: String = ""
    var downloadAccountID: Int = 0
    var sourceAccountItems: [Int] = []
    var websiteList: [String] = []
    var appIdList: [String] = []
    var dbNameList: [String] = []
    var retainCopies: Int = 7
    var ignoreErr: Bool = false
    var retryTimes: Int = 3
    var timeout: Int = 3600
    var timeoutItem: Int = 3600
    var timeoutUnit: String = "s"
    var status: String = ""
    var secret: String = ""
    var hasAlert: Bool = false
    var alertCount: Int = 0
    var alertTitle: String = ""
    var alertMethod: String = ""
    var alertMethodItems: [String] = []
    var scopes: [String] = []
    /// 备份参数（逗号分隔的字符串，如 "--single-transaction,--quick"）。
    /// 仅 MySQL / MariaDB 备份任务使用，对应网页端的 args 字段。
    var args: String = ""
    /// 备份参数数组（与 args 内容一致，逐项）。对应网页端的 argItems 字段。
    var argItems: [String] = []

    /// 从一组 mysqldump 参数项构造 args / argItems。
    /// 传入 nil 或空数组时两者都清空（表示使用默认参数）。
    mutating func setBackupArgs(from items: [String]?) {
        let cleaned = (items ?? []).filter { !$0.isEmpty }
        args = cleaned.joined(separator: ",")
        argItems = cleaned
    }
}

/// cron 周期描述对象（perHour/perDay/perWeek/perMonth）
nonisolated struct CronjobSpecObj: Encodable {
    var specType: String = "perDay"
    var week: Int = 0
    var day: Int = 0
    var hour: Int = 2
    var minute: Int = 30
    var second: Int = 0
}

/// 快照规则（仅 snapshot 类型使用）
nonisolated struct CronjobSnapshotRule: Encodable {
    var withImage: Bool = false
    var ignoreAppIDs: [Int] = []
}
