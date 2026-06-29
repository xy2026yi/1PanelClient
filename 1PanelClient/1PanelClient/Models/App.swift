//
//  App.swift
//  1PanelClient
//

import Foundation
import SwiftUI

/// 已安装应用搜索请求（request.AppInstalledSearch）
nonisolated struct AppInstalledSearchRequest: Encodable, Sendable {
    let page: Int
    let pageSize: Int
    let name: String
    let type: String
    let tags: [String]
    let update: Bool
    let all: Bool
    let unused: Bool
    let sync: Bool
}

/// 已安装应用列表响应（dto.PageResult 包装）
nonisolated struct AppInstalledListResponse: Decodable, Sendable {
    let total: Int
    let items: [AppInstall]?
}

/// 已安装应用
/// 字段已通过 logs/输出16.log 实际返回数据验证
nonisolated struct AppInstall: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String?
    let appID: Int?
    let appDetailID: Int?
    let appKey: String?
    let appName: String?
    let appType: String?
    let version: String?
    let status: String?
    let message: String?
    let httpPort: Int?
    let httpsPort: Int?
    let path: String?
    let container: String?
    let serviceName: String?
    let dockerCompose: String?
    let webUI: String?
    let icon: String?
    var canUpdate: Bool?
    let favorite: Bool?
    let ready: Int?
    let total: Int?
    let createdAt: String?
    let app: AppLinks?
    let isEdit: Bool?
    let linkDB: Bool?

    /// 从 update=true 的可更新列表合并过来的当前 docker-compose 内容
    /// （list 接口里的 dockerCompose 字段通常为空，只有可更新时才填充）
    var currentDockerCompose: String?

    /// 已忽略升级的记录 ID（来自 /apps/ignored/detail）
    /// 非 nil 表示该应用已被忽略升级，nil 表示未忽略
    var ignoredRecordID: Int?

    nonisolated struct AppLinks: Decodable, Hashable, Sendable {
        let website: String?
        let document: String?
        let github: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, name, version, status, message, path, container, serviceName
        case appID, appDetailID, appKey, appName, appType
        case httpPort, httpsPort, dockerCompose, webUI, icon, canUpdate
        case favorite, ready, total, createdAt, app, isEdit, linkDB
    }

    /// 显示名（优先 appName，其次 name，最后 serviceName）
    var displayName: String {
        if let an = appName, !an.isEmpty { return an }
        if let n = name, !n.isEmpty { return n }
        return serviceName ?? "未命名应用"
    }

    /// 描述信息（优先 message，其次 appType）
    var displayDesc: String {
        if let msg = message, !msg.isEmpty { return msg }
        if let t = appType, !t.isEmpty { return t }
        return ""
    }

    /// 状态颜色
    var statusColor: Color {
        switch (status ?? "").lowercased() {
        case "running": return .green
        case "stopped", "exited": return .gray
        case "error", "failed": return .red
        case "upgrading", "installing": return .blue
        case "restarting": return .orange
        default: return .secondary
        }
    }

    /// 状态图标
    var statusIcon: String {
        switch (status ?? "").lowercased() {
        case "running": return "checkmark.circle.fill"
        case "stopped", "exited": return "stop.circle.fill"
        case "error", "failed": return "xmark.octagon.fill"
        case "upgrading", "installing": return "arrow.down.circle.fill"
        case "restarting": return "arrow.triangle.2.circlepath.circle.fill"
        default: return "questionmark.circle.fill"
        }
    }

    /// 是否运行中
    var isRunning: Bool {
        (status ?? "").lowercased() == "running"
    }
}

/// 应用操作请求（request.AppInstalledOperate）
/// 同一个接口支持多种操作（已通过 logs/输出16.log + 输出22.log 验证）
nonisolated struct AppInstalledOperateRequest: Encodable {
    let installId: Int
    let operate: String
    // 升级专用
    var detailId: Int? = nil
    var backup: Bool? = nil
    var pullImage: Bool? = nil
    /// 升级时若用户修改了 docker-compose.yml，传自定义版本
    var dockerCompose: String? = nil
    // 删除专用
    var deleteDB: Bool? = nil
    var deleteImage: Bool? = nil
    var forceDelete: Bool? = nil
    var deleteBackup: Bool? = nil
    /// 任务 ID（用于跟踪安装/卸载进度）
    var taskID: String? = nil

    // 跳过空值的自定义编码，让请求更干净
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(installId, forKey: .installId)
        try c.encode(operate, forKey: .operate)
        try c.encodeIfPresent(detailId, forKey: .detailId)
        try c.encodeIfPresent(backup, forKey: .backup)
        try c.encodeIfPresent(pullImage, forKey: .pullImage)
        try c.encodeIfPresent(dockerCompose, forKey: .dockerCompose)
        try c.encodeIfPresent(deleteDB, forKey: .deleteDB)
        try c.encodeIfPresent(deleteImage, forKey: .deleteImage)
        try c.encodeIfPresent(forceDelete, forKey: .forceDelete)
        try c.encodeIfPresent(deleteBackup, forKey: .deleteBackup)
        try c.encodeIfPresent(taskID, forKey: .taskID)
    }

    enum CodingKeys: String, CodingKey {
        case installId, operate, detailId, backup, pullImage, dockerCompose
        case deleteDB, deleteImage, forceDelete, deleteBackup, taskID
    }
}

/// 应用操作类型（已通过 logs/输出16.log + 输出22.log 验证）
/// start/stop/restart: 基础生命周期
/// upgrade: 升级到新版本（需要 detailId 指定目标版本）
/// rebuild: 重建容器（使用当前参数重新创建容器）
/// reload: 重载配置（OpenResty 等支持）
/// 注意：up/down 不被支持，会返回 "operate not support"
enum AppOperation: String {
    case start = "start"
    case stop = "stop"
    case restart = "restart"
    case upgrade = "upgrade"
    case rebuild = "rebuild"
    case reload = "reload"

    var displayName: String {
        switch self {
        case .start:    return "启动"
        case .stop:     return "停止"
        case .restart:  return "重启"
        case .upgrade:  return "升级"
        case .rebuild:  return "重建"
        case .reload:   return "重载"
        }
    }
}

/// 可用更新版本（dto.AppVersion）
nonisolated struct AppVersion: Decodable, Identifiable, Sendable {
    let detailId: Int
    let version: String?
    let dockerCompose: String?

    var id: Int { detailId }
}

/// 查询可用更新版本的请求 body
nonisolated struct AppUpdateVersionsRequest: Encodable {
    let appInstallId: Int
}

// MARK: - 更新已安装应用参数（重建应用）

/// 已安装应用参数查询响应（GET /apps/installed/params/:installId）
/// 通过 doc/更新已安装应用参数重建应用抓取信息.log 验证字段
nonisolated struct InstalledParamsResponse: Decodable, Sendable {
    let params: [InstalledParamField]?
    /// 当前生效的 compose（用户上次保存的）
    let rawCompose: String?
    let advanced: Bool?
    let cpuQuota: Int?
    let memoryLimit: Int?
    let memoryUnit: String?
    let containerName: String?
    let allowPort: Bool?
    let editCompose: Bool?
    /// 新版本默认 compose（用于展示对比）
    let dockerCompose: String?
    let hostMode: Bool?
    let pullImage: Bool?
    let gpuConfig: Bool?
    let webUI: String?
    let type: String?
    let specifyIP: String?
    let restartPolicy: String?
}

/// 已安装应用的参数字段（带当前值，区别于 AppFormField 的「安装表单定义」）
nonisolated struct InstalledParamField: Decodable, Identifiable, Hashable, Sendable {
    /// 是否可编辑（false 表示只读展示）
    let edit: Bool?
    let key: String?
    /// 校验规则，如 "paramPort"
    let rule: String?
    let labelZh: String?
    let labelEn: String?
    let type: String?
    let values: [String]?
    let showValue: String?
    let required: Bool?
    let multiple: Bool?
    /// 当前值（可能是 Int 或 String）
    let value: FormFieldValue?

    var id: String { key ?? UUID().uuidString }

    /// 显示标签（优先中文）
    var displayLabel: String {
        labelZh ?? labelEn ?? key ?? "参数"
    }

    enum CodingKeys: String, CodingKey {
        case edit, key, rule, labelZh, labelEn, type, values, showValue
        case required, multiple, value
    }
}

/// 更新已安装应用参数请求（POST /apps/installed/params/update）
/// 通过抓包日志验证字段
nonisolated struct AppParamsUpdateRequest: Encodable {
    let webUI: String
    let installId: Int
    let params: [String: AnyCodableValue]
    let advanced: Bool
    let memoryLimit: Int
    let cpuQuota: Int
    let memoryUnit: String
    let allowPort: Bool
    let containerName: String
    let editCompose: Bool
    let dockerCompose: String
    let restartPolicy: String
}

/// 卸载前检查返回的关联资源项
nonisolated struct AppDeleteCheckItem: Decodable, Identifiable, Hashable, Sendable {
    let type: String?
    let name: String?
    var id: String { "\(type ?? "")-\(name ?? "")" }
}
