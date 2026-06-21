//
//  DashboardModels.swift
//  1PanelClient
//

import Foundation

/// 操作系统基础信息
/// 对应 GET /api/v2/dashboard/base/os（已通过 logs/输出14.log 验证）
struct OsInfo: Decodable, Sendable {
    let os: String?
    let platform: String?
    let platformFamily: String?
    let platformVersion: String?
    let prettyDistro: String?
    let kernelArch: String?
    let kernelVersion: String?
    let diskSize: Int64?
}

/// 仪表盘完整基础信息
/// 对应 GET /api/v2/dashboard/base/:ioOption/:netOption
struct DashboardBase: Decodable, Sendable {
    let hostname: String?
    let os: String?
    let platform: String?
    let platformVersion: String?
    let prettyDistro: String?
    let kernelVersion: String?
    let kernelArch: String?

    let cpuModelName: String?
    let cpuCores: Int?
    let cpuLogicalCores: Int?
    let cpuMhz: Double?

    let ipV4Addr: String?
    let virtualizationSystem: String?
    let systemProxy: String?

    let websiteNumber: Int?
    let appInstalledNumber: Int?
    let databaseNumber: Int?
    let cronjobNumber: Int?

    let currentInfo: DashboardCurrent?
}

/// 实时监控数据（DashboardBase.currentInfo）
struct DashboardCurrent: Decodable, Sendable {
    let cpuUsedPercent: Double?
    let cpuUsed: Double?
    let cpuTotal: Int?

    let memoryTotal: Int64?
    let memoryUsed: Int64?
    let memoryAvailable: Int64?
    let memoryUsedPercent: Double?
    let memoryCache: Int64?

    let swapMemoryTotal: Int64?
    let swapMemoryUsed: Int64?
    let swapMemoryUsedPercent: Double?

    let load1: Double?
    let load5: Double?
    let load15: Double?
    let loadUsagePercent: Double?

    let uptime: Int?
    let timeSinceUptime: String?
    let procs: Int?

    let ioReadBytes: Int64?
    let ioWriteBytes: Int64?
    let netBytesSent: Int64?
    let netBytesRecv: Int64?
}

/// CPU/内存 TOP 进程（GET /dashboard/current/top/cpu）
struct ProcessInfo: Decodable, Identifiable, Sendable {
    let pid: Int?
    let name: String?
    let cmd: String?
    let cpuPercent: Double?
    let memory: Int64?
    let memoryPercent: Double?
    let user: String?

    var id: Int { pid ?? 0 }

    var displayName: String { name ?? "未知" }
    var displayCmd: String { cmd ?? "" }
}
