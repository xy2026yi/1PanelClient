//
//  Disk.swift
//  1PanelClient
//
//  磁盘管理模型（/api/v2/hosts/disks*，GET disks / POST partition / mount / unmount）
//  通过 logs/SSH服务管理.md 抓包与 1Panel 源码 agent/app/dto/response/disk.go 验证
//

import Foundation

// MARK: - 模型

/// 磁盘/分区基础信息（response.DiskBasicInfo；分区与磁盘共用同一结构）
nonisolated struct DiskBasicInfo: Decodable, Identifiable, Hashable {
    /// 磁盘为 "sdb"；分区为 "/dev/sda1"
    let device: String?
    let size: String?
    let model: String?
    /// SSD / HDD
    let diskType: String?
    let isRemovable: Bool?
    let isSystem: Bool?
    /// ext4 / xfs / swap / vfat…
    let filesystem: String?
    let used: String?
    let avail: String?
    let usePercent: Int?
    let mountPoint: String?
    let isMounted: Bool?
    let serial: String?

    /// 同一分区可能重复上报同一 device（如根分区与 swap 都是 /dev/sda4，
    /// 见抓包样本），id 用 设备|挂载点|文件系统 组合保证唯一
    var id: String { "\(device ?? "")|\(mountPoint ?? "")|\(filesystem ?? "")" }

    /// 设备短名（/dev/sda1 → sda1；sdb → sdb），标题与确认文案用
    var shortDevice: String {
        (device ?? "").replacingOccurrences(of: "/dev/", with: "")
    }

    var isSwap: Bool { filesystem == "swap" }
}

/// 完整磁盘（response.DiskInfo；含分区列表）
nonisolated struct DiskInfo: Decodable, Identifiable, Hashable {
    let device: String?
    let size: String?
    let model: String?
    let diskType: String?
    let isRemovable: Bool?
    let isSystem: Bool?
    let filesystem: String?
    let used: String?
    let avail: String?
    let usePercent: Int?
    let mountPoint: String?
    let isMounted: Bool?
    let serial: String?
    let partitions: [DiskBasicInfo]?

    var id: String { device ?? UUID().uuidString }

    var shortDevice: String {
        (device ?? "").replacingOccurrences(of: "/dev/", with: "")
    }
}

/// 磁盘总览（response.CompleteDiskInfo）
nonisolated struct DisksResponse: Decodable {
    /// 已挂载的数据磁盘（抓包样本为 null）
    let disks: [DiskInfo]?
    /// 未分区磁盘（仅这类磁盘可「立即分区」）
    let unpartitionedDisks: [DiskBasicInfo]?
    let systemDisks: [DiskInfo]?
    let totalDisks: Int?
    let totalCapacity: Int64?
}

// MARK: - 请求

/// 立即分区（POST /api/v2/hosts/disks/partition；仅未分区磁盘）
nonisolated struct DiskPartitionRequest: Encodable {
    let device: String
    /// ext4 / xfs
    let filesystem: String
    var label: String = ""
    var autoMount: Bool = true
    var noFail: Bool = true
    let mountPoint: String
}

/// 挂载（POST /api/v2/hosts/disks/mount；文件系统不可更改，沿用分区现有格式）
nonisolated struct DiskMountRequest: Encodable {
    /// 分区设备全名（/dev/sdb1）
    let device: String
    let mountPoint: String
    let filesystem: String
    var autoMount: Bool = true
    var noFail: Bool = true
}

/// 取消挂载（POST /api/v2/hosts/disks/unmount）
nonisolated struct DiskUnmountRequest: Encodable {
    let mountPoint: String
}
