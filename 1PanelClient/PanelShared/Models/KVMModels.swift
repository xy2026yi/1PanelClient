//
//  KVMModels.swift
//  1PanelClient
//
//  虚拟机管理（KVM，/api/v2/xpack/vms/*，专业版，受高级功能门禁）：
//  环境检测 / 虚拟机（列表·创建·编辑·重命名·转模版·删除·电源操作·同步·监控·
//  快照·健康检查·控制台信息·详情 checkDisks·磁盘扩容）/ 镜像 ISO（服务器选择·
//  本地上传·远程下载·编辑·删除）/ 模版 / 网络 / 存储池。
//
//  抓包来源：logs/高级功能-KVM.md（2026-10-23）。任务类操作（创建/编辑/重命名/
//  转模版/删除/快照/模版删除/磁盘扩容）返回 {taskID}，进度走 logs/tasks/read
//  （operateNode=local）；即时操作（电源/同步/网络·存储启停自启/ISO 增删改）返回 success。
//  ISO 类型 rawValue 见 KVMISOType（全部经网页请求确认，oraclelinux 已修正）。
//

import Foundation

// MARK: - 环境检测

/// GET /xpack/vms/environment：依赖检测（arch / 辅助程序 / KVM 设备 / libvirt / 存储目录），
/// ready 为总判定；未就绪时客户端只显示 libvirt / /dev/kvm / storage 三项启用状态提示
nonisolated struct KVMEnvironment: Decodable, Equatable {
    let arch: String?
    let archSupported: Bool?
    let ready: Bool?
    let helperExist: Bool?
    let helperMessage: String?
    let kvmExist: Bool?
    let kvmMessage: String?
    let libvirtExist: Bool?
    let libvirtActive: Bool?
    let libvirtMessage: String?
    let storageExist: Bool?
    let storageMessage: String?

    var isReady: Bool { ready == true }
}

// MARK: - 虚拟机

/// POST /xpack/vms/search 返回项
nonisolated struct KVMVirtualMachine: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let uuid: String?
    let cpu: Int?
    /// MB
    let memory: Int?
    /// GB
    let diskSize: Int?
    /// virtio / sata
    let diskBus: String?
    let diskPath: String?
    let storagePool: String?
    let isoPaths: [String]?
    let imagePath: String?
    let network: String?
    /// "hd,cdrom"（磁盘优先）/ "cdrom,hd"（镜像优先）/ "hd"
    let bootOrder: String?
    let autoStart: Bool?
    /// running / shut off / paused / in shutdown / crashed / pmsuspended
    let status: String?
    let disks: [KVMDisk]?
    let interfaces: [KVMInterface]?
    let graphics: KVMGraphics?
    let taskID: String?
    let createTaskID: String?
    let description: String?

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return "VM #" + String(id)
    }

    var normalizedStatus: String { (status ?? "").lowercased() }
    var isRunning: Bool { normalizedStatus == "running" }
    var isShutOff: Bool { normalizedStatus == "shut off" || normalizedStatus == "shutoff" }
    var isPaused: Bool { normalizedStatus == "paused" || normalizedStatus == "pmsuspended" }
    /// 创建中 / 关机中等过渡态：列表轮询刷新
    var isTransitioning: Bool {
        ["in shutdown", "creating", "installing", "deleting"].contains(normalizedStatus)
    }
}

nonisolated struct KVMDisk: Decodable, Hashable {
    let capacity: Int64?
    let format: String?
    let readOnly: Bool?
    let shareable: Bool?
    let resizeBlocked: String?
    /// disk / cdrom
    let device: String?
    let type: String?
    let source: String?
    /// vda / sda
    let target: String?
    let bus: String?

    /// 容量 GiB（字节换算，向下取整；0 / 缺失为 nil）
    var capacityGiB: Int? {
        guard let capacity, capacity > 0 else { return nil }
        return Int(capacity / 1_073_741_824)
    }
    /// 是否可扩容：非 cdrom 且 info(checkDisks) 判定无阻塞（resizeBlocked 为空）
    var isResizable: Bool {
        (device ?? "disk") != "cdrom" && (resizeBlocked ?? "").isEmpty
    }
    /// 阻塞原因（抓包值 backing = 磁盘挂在快照链上；未知值回退原值）
    var resizeBlockedDisplay: String {
        switch (resizeBlocked ?? "").lowercased() {
        case "backing": return L10n.t("存在快照链（backing 文件）")
        default: return resizeBlocked ?? ""
        }
    }
}

nonisolated struct KVMInterface: Decodable, Hashable {
    let type: String?
    let source: String?
    let model: String?
    let mac: String?
    let ip: String?
}

/// 图形控制台信息（列表 graphics 字段与 POST /xpack/vms/console 响应同构）
nonisolated struct KVMGraphics: Decodable, Hashable {
    let type: String?
    let port: String?
    let listen: String?
}

/// POST /xpack/vms/search {page, pageSize, info}
nonisolated struct KVMSearchRequest: Encodable {
    var page: Int = 1
    var pageSize: Int = 20
    var info: String = ""
}

/// 任务式响应 {taskID}（创建 / 编辑 / 重命名 / 转模版 / 删除 / 快照 / 模版删除）
nonisolated struct KVMTaskResponse: Decodable {
    let taskID: String?
}

/// 按名定位的请求 {name}（stats / snapshots/list / health/check / console）
nonisolated struct KVMNameRequest: Encodable {
    let name: String
}

/// 操作系统类型（创建表单，非模版路径）
nonisolated enum KVMOSType: String, CaseIterable, Identifiable {
    case linux
    case windows
    case other

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .linux: return "Linux"
        case .windows: return "Windows"
        case .other: return L10n.t("其他")
        }
    }
}

/// 磁盘总线
nonisolated enum KVMDiskBus: String, CaseIterable, Identifiable {
    case virtio
    case sata

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .virtio: return "VirtIO"
        case .sata: return "SATA (AHCI)"
        }
    }
}

/// 启动项（编辑表单形态 3）
nonisolated enum KVMBootOrder: String, CaseIterable, Identifiable {
    case hdFirst = "hd,cdrom"
    case cdromFirst = "cdrom,hd"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .hdFirst: return L10n.t("磁盘优先（HD → CD-ROM）")
        case .cdromFirst: return L10n.t("镜像优先（CD-ROM → HD）")
        }
    }
}

/// POST /xpack/vms 创建；templateID 仅「从模版启动」时携带（nil 不编码），
/// 普通创建 bootOrder="hd,cdrom"、模版创建 "hd"（抓包）
nonisolated struct KVMCreateRequest: Encodable {
    var name: String
    var cpu: Int
    var memory: Int
    var diskSize: Int
    var osType: String
    var diskBus: String
    var templateID: Int? = nil
    var diskPath: String = ""
    var storagePool: String
    var isoPaths: [String]
    var imagePath: String = ""
    var network: String
    var bootOrder: String
    var startAfterCreate: Bool
    var autoStart: Bool
    var description: String
    var taskID: String
}

/// POST /xpack/vms/update（仅 shut off 可用；名称不可改）
nonisolated struct KVMUpdateRequest: Encodable {
    let taskID: String
    let name: String
    let cpu: Int
    let memory: Int
    let isoPaths: [String]
    let network: String
    let bootOrder: String
    let autoStart: Bool
    let description: String
}

/// POST /xpack/vms/rename {taskID, name, newName}
nonisolated struct KVMRenameRequest: Encodable {
    let taskID: String
    let name: String
    let newName: String
}

/// POST /xpack/vms/templates（虚拟机转模版）{taskID, name, templateName, storagePool, description}
nonisolated struct KVMToTemplateRequest: Encodable {
    let taskID: String
    let name: String
    let templateName: String
    let storagePool: String
    let description: String
}

/// POST /xpack/vms/del {taskID, id, force}
nonisolated struct KVMDeleteRequest: Encodable {
    let taskID: String
    let id: Int
    let force: Bool
}

/// 电源操作（POST /xpack/vms/operate {name, operate}）
nonisolated enum KVMOperate: String, CaseIterable, Identifiable {
    case start
    case shutdown
    case reboot
    case suspend
    case resume
    case destroy

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .start: return L10n.t("启动")
        case .shutdown: return L10n.t("停止")
        case .reboot: return L10n.t("重启")
        case .suspend: return L10n.t("暂停")
        case .resume: return L10n.t("恢复")
        case .destroy: return L10n.t("强行停止")
        }
    }

    var icon: String {
        switch self {
        case .start: return "play.fill"
        case .shutdown: return "stop.fill"
        case .reboot: return "arrow.triangle.2.circlepath"
        case .suspend: return "pause.fill"
        case .resume: return "playpause.fill"
        case .destroy: return "bolt.slash.fill"
        }
    }

    /// 按当前状态可用的操作：运行中 停止/重启/暂停/强停；暂停 恢复/强停；关机 启动；其余 启动/强停
    static func available(for vm: KVMVirtualMachine) -> [KVMOperate] {
        if vm.isRunning { return [.shutdown, .reboot, .suspend, .destroy] }
        if vm.isPaused { return [.resume, .destroy] }
        if vm.isShutOff { return [.start] }
        return [.start, .destroy]
    }
}

nonisolated struct KVMOperateRequest: Encodable {
    let name: String
    let operate: String
}

// MARK: - 监控

/// POST /xpack/vms/stats {name}：累计型计数（cpuTime 纳秒、磁盘/网络字节），
/// 速率需两次采样相减；timestamp 为毫秒
nonisolated struct KVMStats: Decodable, Equatable {
    let name: String?
    let status: String?
    let timestamp: Int64?
    let cpuTime: Int64?
    let vcpu: Int?
    let memory: KVMMemoryStats?
    let disk: KVMDiskStats?
    let network: KVMNetworkStats?

    /// CPU 使用率 %：Δ cpuTime（ns）/ Δ 墙钟（ns）/ vCPU 数；首个样本无前值返回 nil
    static func cpuPercent(previous: KVMStats?, current: KVMStats) -> Double? {
        guard let previous,
              let t0 = previous.timestamp, let t1 = current.timestamp, t1 > t0,
              let c0 = previous.cpuTime, let c1 = current.cpuTime, c1 >= c0 else { return nil }
        let wallNs = Double(t1 - t0) * 1_000_000
        let vcpu = Double(max(current.vcpu ?? 1, 1))
        return min(max(Double(c1 - c0) / wallNs / vcpu * 100, 0), 100)
    }

    /// 两次采样间的字节速率（B/s）；计数回绕或无前值返回 nil
    static func rate(previous: (value: Int64?, timestamp: Int64?)?, current: (value: Int64?, timestamp: Int64?)) -> Double? {
        guard let previous, let v0 = previous.value, let v1 = current.value,
              let t0 = previous.timestamp, let t1 = current.timestamp, t1 > t0, v1 >= v0 else { return nil }
        return Double(v1 - v0) / (Double(t1 - t0) / 1000)
    }
}

nonisolated struct KVMMemoryStats: Decodable, Equatable {
    let availableKiB: Int64?
    let unusedKiB: Int64?
    let usableKiB: Int64?
    let rssKiB: Int64?
    let actualKiB: Int64?

    /// 客户机已用 = 分配（actual）- 空闲（unused）；缺 unused 时退 rss
    var usedKiB: Int64? {
        if let actualKiB, let unusedKiB { return max(actualKiB - unusedKiB, 0) }
        return rssKiB
    }

    var usedPercent: Double? {
        guard let actualKiB, actualKiB > 0, let usedKiB else { return nil }
        return Double(usedKiB) / Double(actualKiB) * 100
    }
}

nonisolated struct KVMDiskStats: Decodable, Equatable {
    let readBytes: Int64?
    let writeBytes: Int64?
    let readReqs: Int64?
    let writeReqs: Int64?
}

nonisolated struct KVMNetworkStats: Decodable, Equatable {
    let rxBytes: Int64?
    let txBytes: Int64?
    let rxPackets: Int64?
    let txPackets: Int64?
}

// MARK: - 快照

/// POST /xpack/vms/snapshots/list {name} 返回项；createdAt 为 Unix 秒
nonisolated struct KVMSnapshot: Decodable, Identifiable, Hashable {
    let name: String?
    let description: String?
    let createdAt: Int64?
    /// disk-snapshot / running / shutoff …
    let state: String?
    let parent: String?
    let path: String?
    let size: Int64?
    let current: Bool?
    let children: Int?

    var id: String { name ?? path ?? "" }
    var createdDate: Date? { createdAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
}

/// POST /xpack/vms/snapshots {taskID, name, snapshotName, description}
nonisolated struct KVMSnapshotCreateRequest: Encodable {
    let taskID: String
    let name: String
    let snapshotName: String
    let description: String
}

/// POST /xpack/vms/snapshots/recover {taskID, name, snapshotName}（仅 shut off）
nonisolated struct KVMSnapshotRecoverRequest: Encodable {
    let taskID: String
    let name: String
    let snapshotName: String
}

// MARK: - 详情 / 磁盘扩容

/// POST /xpack/vms/info {name, checkDisks}；checkDisks=true 时服务端逐盘校验
/// 可扩容性并回填 disks[].resizeBlocked（非空即不可扩容，如 "backing"）
nonisolated struct KVMInfoRequest: Encodable {
    let name: String
    let checkDisks: Bool
}

/// POST /xpack/vms/disks/resize {name, target, sizeGiB, taskID}；
/// sizeGiB 为扩容后的总容量；仅 resizeBlocked 为空的磁盘可提交
nonisolated struct KVMDiskResizeRequest: Encodable {
    let name: String
    let target: String
    let sizeGiB: Int
    let taskID: String
}

nonisolated enum KVMSnapshotNaming {
    /// 默认快照名 snap-yyyyMMddHHmmss（对齐网页端自动填充格式）
    static func defaultName(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return "snap-" + formatter.string(from: date)
    }
}

// MARK: - 健康检查

/// POST /xpack/vms/health/check {name} → {pass, warn, fail, items}
nonisolated struct KVMHealthReport: Decodable {
    let pass: Int?
    let warn: Int?
    let fail: Int?
    let items: [KVMHealthItem]?
}

/// 单项检查：level PASS/WARN/FAIL，check 为检查名，params.subject 为检查对象
nonisolated struct KVMHealthItem: Decodable, Hashable {
    let level: String?
    let check: String?
    let params: [String: String]?

    private enum CodingKeys: String, CodingKey { case level, check, params }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = try? c.decode(String.self, forKey: .level)
        check = try? c.decode(String.self, forKey: .check)
        // params 形态未穷举（抓包仅 {subject}），类型不符时整项不丢
        params = try? c.decode([String: String].self, forKey: .params)
    }

    init(level: String?, check: String?, params: [String: String]?) {
        self.level = level
        self.check = check
        self.params = params
    }

    var subject: String? { params?["subject"] }

    /// 检查名本地化（未知键回退原值）
    var checkDisplay: String {
        switch check ?? "" {
        case "architecture": return L10n.t("架构")
        case "virtualizationType": return L10n.t("虚拟化类型")
        case "machineType": return L10n.t("机型")
        case "qemuEmulator": return L10n.t("QEMU 模拟器")
        case "bootOrder": return L10n.t("启动顺序")
        case "blockDevice": return L10n.t("块设备")
        case "isoArchitecture": return L10n.t("ISO 架构")
        case "network": return L10n.t("网络")
        case "qemuLog": return L10n.t("QEMU 日志")
        default: return check ?? "-"
        }
    }
}

// MARK: - 镜像 ISO

/// POST /xpack/vms/iso/list 返回项；status ready / uploading / downloading / error
nonisolated struct KVMISOImage: Decodable, Identifiable, Hashable {
    let id: Int
    let type: String?
    let name: String?
    let path: String?
    let isExist: Bool?
    let size: Int64?
    let status: String?
    let error: String?
    let tempFileID: String?
    let tempFileType: String?
    let createdAt: String?
    let description: String?

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return (path as NSString?)?.lastPathComponent ?? "ISO #\(id)"
    }
    var isReady: Bool { (status ?? "").lowercased() == "ready" }
}

/// 镜像类型（表单形态 3）。rawValue 全部经确认：debian / archlinux 见本文件抓包，
/// 其余（centos / rocky / almalinux / fedora / opensuse / rhel / oraclelinux /
/// windows / freebsd / ubuntu）为 2026-10-23 网页请求确认
nonisolated enum KVMISOType: String, CaseIterable, Identifiable {
    case debian, ubuntu, centos, rocky, almalinux, fedora, opensuse, rhel, oraclelinux, archlinux, windows, freebsd

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .debian: return "Debian"
        case .ubuntu: return "Ubuntu"
        case .centos: return "CentOS"
        case .rocky: return "Rocky Linux"
        case .almalinux: return "AlmaLinux"
        case .fedora: return "Fedora"
        case .opensuse: return "openSUSE"
        case .rhel: return "RHEL"
        case .oraclelinux: return "Oracle Linux"
        case .archlinux: return "Arch Linux"
        case .windows: return "Windows"
        case .freebsd: return "FreeBSD"
        }
    }

    /// 服务端值 → 显示名（未知值回退原值）
    static func display(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "-" }
        return KVMISOType(rawValue: raw.lowercased())?.displayName ?? raw
    }
}

/// 镜像来源（表单形态 3）
nonisolated enum KVMISOSource: String, CaseIterable, Identifiable {
    case server
    case upload
    case download

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .server: return L10n.t("服务器选择")
        case .upload: return L10n.t("本地上传")
        case .download: return L10n.t("远程下载")
        }
    }

    /// 上传 / 下载落盘默认目录（网页端自动回填）
    static let defaultImportDirectory = "/var/lib/libvirt/images/vm-iso"
}

/// POST /xpack/vms/iso（服务器选择）{type, name, path, description}
nonisolated struct KVMISOCreateRequest: Encodable {
    let type: String
    let name: String
    let path: String
    let description: String
}

/// POST /xpack/vms/iso/import/start：上传 status=uploading + tempFileID=uploadID + tempFileType=upload；
/// 下载 status=downloading + tempFileID=""（无 tempFileType 键）→ {id}
nonisolated struct KVMISOImportStartRequest: Encodable {
    let type: String
    let name: String
    let path: String
    let status: String
    let tempFileID: String
    var tempFileType: String? = nil
    let description: String
}

/// POST /xpack/vms/iso/import/update {id, status[, tempFileID, tempFileType]}
nonisolated struct KVMISOImportUpdateRequest: Encodable {
    let id: Int
    let status: String
    var tempFileID: String? = nil
    var tempFileType: String? = nil
}

nonisolated struct KVMIDResponse: Decodable {
    let id: Int?
}

/// POST /xpack/vms/iso/update {id, type, name, path, description}
nonisolated struct KVMISOUpdateRequest: Encodable {
    let id: Int
    let type: String
    let name: String
    let path: String
    let description: String
}

/// POST /xpack/vms/iso/del {id, deleteFile}
nonisolated struct KVMISODeleteRequest: Encodable {
    let id: Int
    let deleteFile: Bool
}

// MARK: - 模版

/// POST /xpack/vms/templates/list 返回项
nonisolated struct KVMTemplate: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let sourceVM: String?
    let cpu: Int?
    let memory: Int?
    let diskSize: Int?
    let diskBus: String?
    let diskPath: String?
    let storagePool: String?
    let network: String?
    let bootOrder: String?
    let isExist: Bool?
    let size: Int64?
    let createdAt: String?
    let description: String?

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return "Template #\(id)"
    }
}

/// POST /xpack/vms/templates/del {taskID, id, deleteDisk}
nonisolated struct KVMTemplateDeleteRequest: Encodable {
    let taskID: String
    let id: Int
    let deleteDisk: Bool
}

// MARK: - 网桥 / 宿主机网卡（创建表单下拉源）

/// GET /xpack/vms/networks/bridges 项：recommended=true 才可被选为桥接名称
///（服务端只推荐由 1Panel 管理的网桥，docker0 / virbr0 等外来网桥不可选）
nonisolated struct KVMBridge: Decodable, Identifiable, Hashable {
    let name: String?
    let recommended: Bool?
    let description: String?

    var id: String { name ?? "" }
    var isSelectable: Bool { recommended == true }
    /// 下拉显示名：带来源说明（如 "docker0 · docker"）
    var displayLabel: String {
        if let description, !description.isEmpty {
            return "\(name ?? "-") · \(description)"
        }
        return name ?? "-"
    }
}

/// GET /xpack/vms/networks/interfaces 项（Macvtap 宿主机网卡）
nonisolated struct KVMHostInterface: Decodable, Identifiable, Hashable {
    let name: String?
    let addresses: [String]?

    var id: String { name ?? "" }
}

// MARK: - 网络

nonisolated struct KVMResourceRef: Decodable, Hashable {
    let id: Int?
    let name: String?
}

/// POST /xpack/vms/networks/list 返回项；status Running / inactive
nonisolated struct KVMNetwork: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    /// nat / bridge / macvtap
    let type: String?
    let bridgeName: String?
    let sourceInterface: String?
    let cidr: String?
    let gateway: String?
    let dhcpStart: String?
    let dhcpEnd: String?
    let autoStart: Bool?
    let description: String?
    let createdAt: String?
    let status: String?
    let vmCount: Int?
    let vms: [KVMResourceRef]?
    let registered: Bool?
    let usedIPs: [String]?
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, type, bridgeName, sourceInterface, cidr, gateway, dhcpStart, dhcpEnd
        case autoStart, description, createdAt, status, vmCount, vms, registered, usedIPs, error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try? c.decode(String.self, forKey: .name)
        type = try? c.decode(String.self, forKey: .type)
        bridgeName = try? c.decode(String.self, forKey: .bridgeName)
        sourceInterface = try? c.decode(String.self, forKey: .sourceInterface)
        cidr = try? c.decode(String.self, forKey: .cidr)
        gateway = try? c.decode(String.self, forKey: .gateway)
        dhcpStart = try? c.decode(String.self, forKey: .dhcpStart)
        dhcpEnd = try? c.decode(String.self, forKey: .dhcpEnd)
        autoStart = try? c.decode(Bool.self, forKey: .autoStart)
        description = try? c.decode(String.self, forKey: .description)
        createdAt = try? c.decode(String.self, forKey: .createdAt)
        status = try? c.decode(String.self, forKey: .status)
        vmCount = try? c.decode(Int.self, forKey: .vmCount)
        vms = try? c.decode([KVMResourceRef].self, forKey: .vms)
        registered = try? c.decode(Bool.self, forKey: .registered)
        // 抓包为 null，元素形态未知：按字符串数组尝试，不符则置 nil
        usedIPs = try? c.decode([String].self, forKey: .usedIPs)
        error = try? c.decode(String.self, forKey: .error)
    }

    var displayName: String { name ?? "Network #\(id)" }
    var isActive: Bool { (status ?? "").lowercased() == "running" || (status ?? "").lowercased() == "active" }
    /// 有关联虚拟机时不可删除（网页端同款限制）
    var hasVMs: Bool { (vmCount ?? 0) > 0 }
}

/// 网络类型（表单形态 3）
nonisolated enum KVMNetworkType: String, CaseIterable, Identifiable {
    case nat
    case bridge
    case macvtap

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .nat: return "NAT"
        case .bridge: return "Bridge"
        case .macvtap: return "Macvtap"
        }
    }
}

/// POST /xpack/vms/networks 创建（id 固定 0）
nonisolated struct KVMNetworkCreateRequest: Encodable {
    var id: Int = 0
    let name: String
    let type: String
    let bridgeName: String
    let sourceInterface: String
    let cidr: String
    let gateway: String
    let dhcpStart: String
    let dhcpEnd: String
    let autoStart: Bool
    let description: String
}

/// 网络 / 存储池 单项更新 POST …/update：{id, status: running|inactive} 或 {id, autoStart}
nonisolated struct KVMResourceUpdateRequest: Encodable {
    let id: Int
    var status: String? = nil
    var autoStart: Bool? = nil
}

/// 网络 / 存储池 删除 POST …/del {id, force}
nonisolated struct KVMResourceDeleteRequest: Encodable {
    let id: Int
    let force: Bool
}

// MARK: - 存储池

/// POST /xpack/vms/storages/list 返回项；容量字节
nonisolated struct KVMStoragePool: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    /// dir
    let type: String?
    let path: String?
    let autoStart: Bool?
    let description: String?
    let createdAt: String?
    let status: String?
    let capacity: Int64?
    let available: Int64?
    let vmCount: Int?
    let vms: [KVMResourceRef]?
    let error: String?

    var displayName: String { name ?? "Storage #\(id)" }
    var isActive: Bool { (status ?? "").lowercased() == "running" || (status ?? "").lowercased() == "active" }
    var hasVMs: Bool { (vmCount ?? 0) > 0 }
    var usedBytes: Int64? {
        guard let capacity, let available else { return nil }
        return max(capacity - available, 0)
    }
    var usedPercent: Double? {
        guard let capacity, capacity > 0, let usedBytes else { return nil }
        return Double(usedBytes) / Double(capacity) * 100
    }
}

/// POST /xpack/vms/storages 创建（id 固定 0，type 固定 dir）
nonisolated struct KVMStorageCreateRequest: Encodable {
    var id: Int = 0
    let name: String
    var type: String = "dir"
    let path: String
    let autoStart: Bool
    let description: String
}
