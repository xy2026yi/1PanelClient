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
    let swapMemoryAvailable: Int64?
    let swapMemoryUsedPercent: Double?

    let load1: Double?
    let load5: Double?
    let load15: Double?
    let loadUsagePercent: Double?

    let uptime: Int?
    let timeSinceUptime: String?
    let runningTime: RunningTime?
    let procs: Int?

    let ioReadBytes: Int64?
    let ioWriteBytes: Int64?
    let netBytesSent: Int64?
    let netBytesRecv: Int64?

    // 磁盘数据（数组，每个挂载点一项）
    let diskData: [DiskData]?
}

/// 系统运行时长
nonisolated struct RunningTime: Decodable, Sendable {
    let days: Int?
    let hours: Int?
    let minutes: Int?
    let seconds: Int?

    var displayText: String {
        let dayCount = days ?? 0
        let hourCount = hours ?? 0
        let minuteCount = minutes ?? 0
        let secondCount = seconds ?? 0

        if dayCount > 0 {
            return L10n.f("%ld天 %ld小时 %ld分钟", dayCount, hourCount, minuteCount)
        }
        if hourCount > 0 {
            return L10n.f("%ld小时 %ld分钟", hourCount, minuteCount)
        }
        if minuteCount > 0 {
            return L10n.f("%ld分钟 %ld秒", minuteCount, secondCount)
        }
        return L10n.f("%ld秒", secondCount)
    }

    /// 紧凑格式（服务器行标题等宽度受限处）：40d 23h 6m 42s，精确到秒
    var compactText: String {
        L10n.f("%ldd %ldh %ldm %lds", days ?? 0, hours ?? 0, minutes ?? 0, seconds ?? 0)
    }
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

    var displayName: String { name ?? L10n.t("未知") }
    var displayCmd: String { cmd ?? "" }
}

/// 面板系统设置信息（POST /core/settings/search）
/// 用于获取面板版本号等。
/// 容错解码（decodeDefault）：面板升级改字段口径（如字符串改数字）时仅该字段
/// 回落空值，不再整对象 decode 失败——否则 try? 吞错后旧值长驻，
/// 首页版本在网页升级面板后怎么刷新都不更新
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
    /// 脚本库自动同步开关：Enable / Disable
    let scriptSync: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        systemVersion = c.decodeDefault(String?.self, forKey: .systemVersion, nil)
        systemIP = c.decodeDefault(String?.self, forKey: .systemIP, nil)
        timeZone = c.decodeDefault(String?.self, forKey: .timeZone, nil)
        localTime = c.decodeDefault(String?.self, forKey: .localTime, nil)
        monitorStatus = c.decodeDefault(String?.self, forKey: .monitorStatus, nil)
        monitorInterval = c.decodeDefault(String?.self, forKey: .monitorInterval, nil)
        monitorStoreDays = c.decodeDefault(String?.self, forKey: .monitorStoreDays, nil)
        appStoreVersion = c.decodeDefault(String?.self, forKey: .appStoreVersion, nil)
        appStoreSyncStatus = c.decodeDefault(String?.self, forKey: .appStoreSyncStatus, nil)
        appStoreLastModified = c.decodeDefault(String?.self, forKey: .appStoreLastModified, nil)
        dockerSockPath = c.decodeDefault(String?.self, forKey: .dockerSockPath, nil)
        defaultIO = c.decodeDefault(String?.self, forKey: .defaultIO, nil)
        defaultNetwork = c.decodeDefault(String?.self, forKey: .defaultNetwork, nil)
        fileRecycleBin = c.decodeDefault(String?.self, forKey: .fileRecycleBin, nil)
        ntpSite = c.decodeDefault(String?.self, forKey: .ntpSite, nil)
        scriptSync = c.decodeDefault(String?.self, forKey: .scriptSync, nil)
    }

    enum CodingKeys: String, CodingKey {
        case systemVersion, systemIP, timeZone, localTime
        case monitorStatus, monitorInterval, monitorStoreDays
        case appStoreVersion, appStoreSyncStatus, appStoreLastModified
        case dockerSockPath, defaultIO, defaultNetwork, fileRecycleBin, ntpSite
        case scriptSync
    }
}

/// 面板版本更新检查结果
/// 对应 GET /api/v2/core/settings/upgrade
nonisolated struct PanelUpgradeInfo: Decodable {
    let latestVersion: String?
    let releaseNote: String?

    var hasUpdate: Bool {
        guard let version = latestVersion, !version.isEmpty else { return false }
        return true
    }

    /// 语义化比较：latest > current 才算有更新。原实现为字符串不等判断，
    /// rc/beta 与同名正式版（2.3.0-rc1 vs 2.3.0）会被误报为有更新
    func hasUpdate(comparedTo currentVersion: String?) -> Bool {
        PanelVersionTools.compare(latestVersion, currentVersion) == .orderedDescending
    }
}

/// 面板版本号解析与比较（v/V 前缀、rc/beta 预发布后缀容忍）。
/// 上游保持月度发版，客户端适配策略见 docs/1panel-upstream-adaptation-roadmap-2026-09.md
enum PanelVersionTools {
    /// 客户端当前适配的面板基线（README 对外承诺同一版本；升级适配流程完成后改此值）。
    /// v2.3.0（2026-09-17 M1）：防火墙模块已对齐 v2.3.0 重构后 API（旧面板访问防火墙页
    /// 会提示升级）；其余模块经源码 diff 证实 v2.2.5→v2.3.0 无 API 变更。
    /// nonisolated：nonisolated 模型（PanelUpgradeInfo.hasUpdate）与视图层都会访问
    nonisolated static let adaptedBaseline = "v2.3.0"

    /// a > b → orderedDescending；任一无法解析视为相同（不提示），
    /// a 可解析而 b 缺失/无法解析 → orderedDescending（维持旧语义：当前版本未知即提示更新）
    nonisolated static func compare(_ a: String?, _ b: String?) -> ComparisonResult {
        guard let pa = parse(a) else { return .orderedSame }
        guard let pb = parse(b) else { return .orderedDescending }
        let count = max(pa.nums.count, pb.nums.count)
        for i in 0..<count {
            let x = i < pa.nums.count ? pa.nums[i] : 0
            let y = i < pb.nums.count ? pb.nums[i] : 0
            if x != y { return x > y ? .orderedDescending : .orderedAscending }
        }
        // 数字段全等：正式版 > 预发布（rc/beta）
        switch (pa.pre, pb.pre) {
        case (nil, nil): return .orderedSame
        case (nil, _):   return .orderedDescending
        case (_, nil):   return .orderedAscending
        case let (l, r): return l! < r! ? .orderedAscending : (l! == r! ? .orderedSame : .orderedDescending)
        }
    }

    /// "v2.3.0-rc1" → (nums [2,3,0], pre "rc1")
    nonisolated private static func parse(_ version: String?) -> (nums: [Int], pre: String?)? {
        guard var s = version?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        var pre: String? = nil
        if let dash = s.firstIndex(of: "-") {
            pre = String(s[s.index(after: dash)...])
            s = String(s[..<dash])
        }
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        let nums = parts.compactMap { Int($0) }
        guard !nums.isEmpty, nums.count == parts.count else { return nil }
        return (nums, pre.flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// 版本更新日志条目
/// 对应 GET /api/v2/core/settings/upgrade/releases 返回数组中的元素
nonisolated struct PanelRelease: Decodable, Identifiable {
    let version: String
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case version, createdAt, content, newCount, optimizationCount, fixCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.decodeDefault(String.self, forKey: .version, "")
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        newCount = try c.decodeIfPresent(Int.self, forKey: .newCount)
        optimizationCount = try c.decodeIfPresent(Int.self, forKey: .optimizationCount)
        fixCount = try c.decodeIfPresent(Int.self, forKey: .fixCount)
    }

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
