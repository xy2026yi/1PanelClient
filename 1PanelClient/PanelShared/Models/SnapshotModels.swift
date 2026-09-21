//
//  SnapshotModels.swift
//  1PanelClient
//
//  面板快照 / 监控设置 / 虚拟内存模型
//  （logs/推荐实现-计划任务和面板.md 抓包 2026-09-14）
//

import Foundation

// MARK: - 计划任务扩展

/// POST /cronjobs/stop {id}
nonisolated struct CronjobStopRequest: Encodable {
    let id: Int
}

/// POST /cronjobs/next {spec} → 接下来 5 次执行时间
nonisolated struct CronjobNextRequest: Encodable {
    let spec: String
}

/// POST /cronjobs/records/clean {cronjobID}
nonisolated struct CronjobRecordsCleanRequest: Encodable {
    let cronjobID: Int
}

// MARK: - 快照数据树

/// 快照数据树节点（load 返回 / create 全量回传，字段同构）
nonisolated struct SnapshotNode: Codable, Identifiable, Hashable {
    var id: String
    var label: String
    var key: String
    var name: String
    var isLocal: Bool
    /// 字节
    var size: Int64
    /// 提交时回传勾选态（load 默认值即网页端默认勾选）
    var isCheck: Bool
    /// true = 不可取消（docker/geo/runtime/task）
    var isDisable: Bool
    var path: String
    var relationItemID: String
    var children: [SnapshotNode]?

    /// 是否作为叶子勾选项（父节点是分组标题，仅子节点参与勾选）
    var isLeaf: Bool { (children ?? []).isEmpty }

    /// 勾选子节点的总字节数（父节点展示用）
    var checkedChildrenSize: Int64 {
        (children ?? []).filter(\.isCheck).reduce(0) { $0 + $1.size }
    }
}

/// GET /settings/snapshot/load 返回
nonisolated struct SnapshotLoadData: Decodable {
    let appData: [SnapshotNode]?
    let backupData: [SnapshotNode]?
    let panelData: [SnapshotNode]?
    let withDockerConf: Bool?
    let withMonitorData: Bool?
    let withLoginLog: Bool?
    let withOperationLog: Bool?
    let withSystemLog: Bool?
    let withTaskLog: Bool?
    let ignoreFiles: [String]?
}

/// POST /settings/snapshot（创建；load 数据回传 + 基础配置，抓包全字段）
nonisolated struct SnapshotCreateRequest: Encodable {
    let id: Int
    let taskID: String
    let downloadAccountID: Int
    let fromAccounts: [Int]
    /// 逗号串（抓包："1"）
    let sourceAccountIDs: String
    let description: String
    let secret: String
    /// 秒
    let timeout: Int
    let timeoutItem: Int
    /// s / m / h（抓包恒 "s"，timeout 已按单位换算）
    let timeoutUnit: String
    let backupAllImage: Bool
    let withDockerConf: Bool
    let withLoginLog: Bool
    let withOperationLog: Bool
    let withSystemLog: Bool
    let withTaskLog: Bool
    let withMonitorData: Bool
    let panelData: [SnapshotNode]
    let backupData: [SnapshotNode]
    let appData: [SnapshotNode]
    let ignoreFiles: [String]
}

/// POST /settings/snapshot/del {ids, deleteWithFile}
nonisolated struct SnapshotDeleteRequest: Encodable {
    let ids: [Int]
    let deleteWithFile: Bool
}

/// POST /settings/snapshot/recover {id, taskID, isNew, reDownload, secret}
nonisolated struct SnapshotRecoverRequest: Encodable {
    let id: Int
    let taskID: String
    let isNew: Bool
    let reDownload: Bool
    let secret: String
}

/// POST /settings/snapshot/search（orderBy/order 必填，抓包 2026-09-14 确认：
/// 缺失时后端返回 400 Field validation failed）
nonisolated struct SnapshotSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let orderBy: String
    let order: String
}

nonisolated struct SnapshotSearchResponse: Decodable {
    let total: Int?
    let items: [SnapshotItem]?
}

/// POST /settings/snapshot/search 返回的快照条目（抓包 2026-09-14 字段全集）
nonisolated struct SnapshotItem: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let description: String?
    let sourceAccounts: [String]?
    let downloadAccount: String?
    /// Success / ...
    let status: String?
    let message: String?
    let createdAt: String?
    /// 字节
    let size: Int64?
    let version: String?
    let lastRecoveredAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description, sourceAccounts, downloadAccount
        case status, message, createdAt, size, version, lastRecoveredAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeDefault(Int.self, forKey: .id, 0)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        sourceAccounts = try c.decodeIfPresent([String].self, forKey: .sourceAccounts)
        downloadAccount = try c.decodeIfPresent(String.self, forKey: .downloadAccount)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        lastRecoveredAt = try c.decodeIfPresent(String.self, forKey: .lastRecoveredAt)
    }

    var displayName: String { name ?? "#\(id)" }
    var displayCreatedAt: String {
        guard let t = createdAt, !t.isEmpty else { return "—" }
        return String(t.prefix(19)).replacingOccurrences(of: "T", with: " ")
    }
    var isOK: Bool { (status ?? "").lowercased() == "success" }
}

// MARK: - 监控设置

/// POST /hosts/monitor/setting/update {key, value}
/// key：MonitorStatus / MonitorStoreDays / MonitorInterval / DefaultNetwork / DefaultIO
nonisolated struct MonitorSettingUpdateRequest: Encodable {
    let key: String
    let value: String
}

/// GET /hosts/monitor/setting 响应（未抓包：按扁平 [String:String] 防御性解码，
/// 键大小写不敏感匹配）
nonisolated struct MonitorSettings {
    var monitorStatus = true
    var storeDays = 7
    /// 秒
    var interval = 300
    var defaultNetwork = "all"
    var defaultIO = "all"

    static func from(dict: [String: String]) -> MonitorSettings {
        var s = MonitorSettings()
        func v(_ keys: [String]) -> String? {
            let lower = Dictionary(uniqueKeysWithValues: dict.map { ($0.key.lowercased(), $0.value) })
            for k in keys { if let x = lower[k.lowercased()], !x.isEmpty { return x } }
            return nil
        }
        if let x = v(["MonitorStatus", "monitorStatus"]) { s.monitorStatus = x.lowercased() == "enable" }
        if let x = v(["MonitorStoreDays", "monitorStoreDays"]), let d = Int(x) { s.storeDays = d }
        if let x = v(["MonitorInterval", "monitorInterval"]), let d = Int(x) { s.interval = d }
        if let x = v(["DefaultNetwork", "defaultNetwork"]) { s.defaultNetwork = x }
        if let x = v(["DefaultIO", "defaultIO"]) { s.defaultIO = x }
        return s
    }
}

// MARK: - 虚拟内存（Swap）

/// POST /toolbox/device/base 返回（Swap 相关字段）
nonisolated struct DeviceBase: Decodable {
    let swapMemoryTotal: Int64?
    let swapMemoryAvailable: Int64?
    let swapMemoryUsed: Int64?
    /// 单个 Swap 可设上限（字节）
    let maxSize: Int64?
    let swapDetails: [SwapDetail]?
}

/// Swap 明细：size 为 KB、used 为 KB 数值字符串（抓包确认）
nonisolated struct SwapDetail: Decodable, Hashable, Identifiable {
    let path: String
    let size: Int
    let used: String?
    let isNew: Bool?
    let taskID: String?

    enum CodingKeys: String, CodingKey { case path, size, used, isNew, taskID }

    /// 成员构造（解码 init 会隐藏 memberwise；合成行如 /opt/.1panel_swap 使用）
    init(path: String, size: Int, used: String? = nil, isNew: Bool? = nil, taskID: String? = nil) {
        self.path = path
        self.size = size
        self.used = used
        self.isNew = isNew
        self.taskID = taskID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = c.decodeDefault(String.self, forKey: .path, "")
        size = c.decodeDefault(Int.self, forKey: .size, 0)
        used = try c.decodeIfPresent(String.self, forKey: .used)
        isNew = try c.decodeIfPresent(Bool.self, forKey: .isNew)
        taskID = try c.decodeIfPresent(String.self, forKey: .taskID)
    }

    var id: String { path }
    /// KB → GB
    var sizeGB: Double { Double(size) / 1024 / 1024 }
    var usedKB: Int { Int(used ?? "") ?? 0 }
}

/// POST /toolbox/device/update/swap（size 为 KB；used 回传原字符串；带任务进度）
nonisolated struct SwapUpdateRequest: Encodable {
    let path: String
    let size: Int
    let used: String
    let isNew: Bool
    let taskID: String
}
