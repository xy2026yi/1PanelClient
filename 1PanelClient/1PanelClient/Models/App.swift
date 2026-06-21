//
//  App.swift
//  1PanelClient
//

import Foundation
import SwiftUI

/// 已安装应用搜索请求（request.AppInstalledSearch）
struct AppInstalledSearchRequest: Encodable {
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
struct AppInstalledListResponse: Decodable {
    let total: Int
    let items: [AppInstall]?
}

/// 已安装应用
/// 字段已通过 logs/输出16.log 实际返回数据验证
struct AppInstall: Decodable, Identifiable, Hashable, Sendable {
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
    let canUpdate: Bool?
    let favorite: Bool?
    let ready: Int?
    let total: Int?
    let createdAt: String?
    let app: AppLinks?

    struct AppLinks: Decodable, Hashable, Sendable {
        let website: String?
        let document: String?
        let github: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, name, version, status, message, path, container, serviceName
        case appID, appDetailID, appKey, appName, appType
        case httpPort, httpsPort, dockerCompose, webUI, icon, canUpdate
        case favorite, ready, total, createdAt, app
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
struct AppInstalledOperateRequest: Encodable {
    let installId: Int
    let operate: String
}

/// 应用操作类型（已通过 logs/输出16.log 验证）
/// 注意：up/down 不被支持，会返回 "operate not support"
enum AppOperation: String {
    case start = "start"
    case stop = "stop"
    case restart = "restart"
}

/// 可用更新版本（dto.AppVersion）
struct AppVersion: Decodable, Identifiable, Sendable {
    let detailId: Int
    let version: String?
    let dockerCompose: String?

    var id: Int { detailId }
}

/// 查询可用更新版本的请求 body
struct AppUpdateVersionsRequest: Encodable {
    let appInstallId: Int
}

/// /apps/installed/update/versions 的响应（直接返回数组，套一层 APIResponse）
struct AppVersionsResponse: Decodable {
    let data: [AppVersion]?
}

/// 应用安装/升级请求（request.AppInstallCreate）
/// 升级时用新版本的 appDetailId + 原应用的 name 和 params
struct AppInstallRequest: Encodable {
    let appDetailId: Int
    let params: [String: String]
    let name: String
    let advanced: Bool
    let pullImage: Bool
}
