//
//  Logs.swift
//  1PanelClient
//
//  日志模块模型：操作日志 / 访问日志 / 系统日志 / SSH 登陆日志 / 网站日志
//  基于网页端抓包（logs/日志/*.md）
//

import Foundation

// MARK: - 操作日志（POST /api/v2/core/logs/operation）

nonisolated struct OperationLogRequest: Encodable {
    var operation: String = ""
    var page: Int = 1
    var pageSize: Int = 100
    var status: String = ""
    var source: String = ""
    var node: String = ""
}

nonisolated struct OperationLogResponse: Decodable {
    let total: Int
    let items: [OperationLogItem]?
}

nonisolated struct OperationLogItem: Decodable, Identifiable {
    let id: Int
    let source: String?
    let user: String?
    let ip: String?
    let path: String?
    let method: String?
    let latency: Int64?          // 纳秒
    let status: String?
    let message: String?
    let detailZH: String?
    let createdAt: String?

    /// 延迟毫秒显示
    var latencyDisplay: String {
        guard let ns = latency, ns > 0 else { return "" }
        return "\(ns / 1_000_000)ms"
    }
}

// MARK: - 访问日志（POST /api/v2/core/logs/login）

nonisolated struct LoginLogRequest: Encodable {
    var info: String = ""
    var status: String = ""
    var page: Int = 1
    var pageSize: Int = 100
}

nonisolated struct LoginLogResponse: Decodable {
    let total: Int
    let items: [LoginLogItem]?
}

nonisolated struct LoginLogItem: Decodable, Identifiable {
    let id: Int
    let ip: String?
    let user: String?
    let address: String?
    let agent: String?
    let status: String?
    let message: String?
    let createdAt: String?
}

// MARK: - SSH 登陆日志（POST /api/v2/hosts/ssh/log）

nonisolated struct SSHLogRequest: Encodable {
    var status: String = "All"
    var page: Int = 1
    var pageSize: Int = 100
}

nonisolated struct SSHLogResponse: Decodable {
    let total: Int
    let items: [SSHLogItem]?
}

nonisolated struct SSHLogItem: Decodable, Identifiable {
    /// 无 id 字段，用 date+port 组合
    let date: String?
    let dateStr: String?
    let area: String?
    let user: String?
    let authMode: String?
    let address: String?
    let port: String?
    let status: String?
    let message: String?

    var id: String { "\(date ?? "")-\(port ?? "")-\(user ?? "")" }
}

// MARK: - 系统日志（GET /api/v2/logs/system/files + POST /api/v2/files/read/system）

/// 系统日志读取请求（name 为日期，如 "2026-08-15"）
nonisolated struct SystemLogReadRequest: Encodable {
    let type: String = "system"
    let name: String
    let page: Int
    let pageSize: Int
    let latest: Bool
}

// MARK: - 网站日志
// 读取请求复用 Models/Website.swift 的 WebsiteLogReadRequest（网站详情日志同款）
// 响应复用 WebsiteLogResponse

// MARK: - 任务中心（POST /api/v2/logs/tasks/search?operateNode=local，基于网页端抓包 logs/任务中心-1.md）

nonisolated struct TaskCenterSearchRequest: Encodable {
    /// 任务类型（AppStore / App / Container / Image…），空 = 全部
    let type: String
    /// 状态筛选："" 全部 / Success / Failed / Executing
    let status: String
    let page: Int
    let pageSize: Int
}

nonisolated struct TaskCenterResponse: Decodable {
    let total: Int
    let items: [TaskCenterItem]?
}

nonisolated struct TaskCenterItem: Decodable, Identifiable {
    let id: String
    let name: String?
    let type: String?
    let operate: String?
    let logFile: String?
    let status: String?
    let errorMsg: String?
    let currentStep: String?
    let endAt: String?
    let createdAt: String?
}

/// 任务日志读取请求（POST /api/v2/logs/tasks/read?operateNode=local，字段对齐网页端抓包）
nonisolated struct TaskCenterLogReadRequest: Encodable {
    let id = 0
    let type = "task"
    let name = ""
    let page: Int
    let pageSize: Int
    let latest: Bool
    let taskID: String
    let taskType = ""
    let taskOperate = ""
    let resourceID = 0
}
// 响应复用下方 LogFileReadResponse（end/path/taskStatus/lines/totalLines 同构）

// MARK: - 日志行读取响应（system/website 共用，同任务日志结构）

nonisolated struct LogFileReadResponse: Decodable {
    let end: Bool?
    let path: String?
    let total: Int?
    let taskStatus: String?
    let lines: [String]?
    let totalLines: Int?
}
