//
//  DashboardModels.swift
//  1PanelClient
//

import Foundation

/// 操作系统基础信息
/// 对应 GET /api/v2/dashboard/base/os（已通过 logs/输出14.log 验证）
nonisolated struct OsInfo: Decodable, Sendable {
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
nonisolated struct DashboardBase: Decodable, Sendable {
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
nonisolated struct DashboardCurrent: Decodable, Sendable {
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

    // 磁盘数据（数组，每个挂载点一项）
    let diskData: [DiskData]?
}

/// 单个挂载点的磁盘使用信息
nonisolated struct DiskData: Decodable, Sendable {
    let path: String?
    let type: String?
    let device: String?
    let total: Int64?
    let free: Int64?
    let used: Int64?
    let usedPercent: Double?
}

/// CPU/内存 TOP 进程（GET /dashboard/current/top/cpu）
nonisolated struct ProcessInfo: Decodable, Identifiable, Sendable {
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

/// 面板系统设置信息（POST /core/settings/search）
/// 用于获取面板版本号等
nonisolated struct SettingInfo: Decodable, Sendable {
    let systemVersion: String?
    let systemIP: String?
    let timeZone: String?
    let localTime: String?
    let monitorStatus: String?
    let monitorInterval: String?
    let monitorStoreDays: String?
    let appStoreVersion: String?
    let appStoreSyncStatus: String?
    let appStoreLastModified: String?
    let dockerSockPath: String?
    let defaultIO: String?
    let defaultNetwork: String?
    let fileRecycleBin: String?
    let ntpSite: String?
}

/// 面板版本更新检查结果
/// 对应 GET /api/v2/core/settings/upgrade
nonisolated struct PanelUpgradeInfo: Decodable {
    let latestVersion: String?
    let releaseNote: String?

    var hasUpdate: Bool {
        guard let v = latestVersion, !v.isEmpty else { return false }
        return true
    }
}

/// 版本更新日志条目
/// 对应 GET /api/v2/core/settings/upgrade/releases 返回数组中的元素
nonisolated struct PanelRelease: Decodable, Identifiable {
    let version: String
    let createdAt: String?
    let content: String?
    let newCount: Int?
    let optimizationCount: Int?
    let fixCount: Int?

    var id: String { version }
}

/// 面板版本升级请求
nonisolated struct PanelUpgradeRequest: Encodable {
    let version: String
}
