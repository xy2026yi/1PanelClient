//
//  App.swift
//  1PanelClient
//

import Foundation

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

/// 已安装应用列表响应（dto.PageResult 包装的 model.AppInstall）
struct AppInstalledListResponse: Decodable {
    let total: Int
    let items: [AppInstall]?
}

/// 已安装应用（model.AppInstall）
struct AppInstall: Decodable, Identifiable, Sendable {
    let id: Int
    let appId: Int?
    let appDetailId: Int?
    let name: String
    let version: String?
    let description: String?
    let status: String?
    let message: String?
    let containerName: String?
    let serviceName: String?
    let env: String?
    let dockerCompose: String?
    let param: String?
    let httpPort: Int?
    let httpsPort: Int?
    let webUI: String?
    let favorite: Bool?
    let createdAt: String?
    let updatedAt: String?

    /// 显示名（优先用 name，否则用 serviceName）
    var displayName: String {
        if !name.isEmpty { return name }
        return serviceName ?? "未命名应用"
    }

    /// 描述信息（可能为空）
    var displayDesc: String {
        if let desc = description, !desc.isEmpty { return desc }
        if let msg = message, !msg.isEmpty { return msg }
        return ""
    }

    /// 状态颜色
    var statusColor: String {
        switch (status ?? "").lowercased() {
        case "running": return "green"
        case "stopped", "exited": return "gray"
        case "error", "failed": return "red"
        case "upgrading", "installing": return "blue"
        case "restarting": return "orange"
        default: return "secondary"
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

/// 应用操作类型
enum AppOperation: String {
    case start = "up"
    case stop = "down"
    case restart = "restart"
}
