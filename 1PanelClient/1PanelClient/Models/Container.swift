//
//  Container.swift
//  1PanelClient
//

import Foundation
import SwiftUI

/// 容器搜索请求（dto.PageContainer）
struct ContainerSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let name: String
    let state: String
    let orderBy: String
    let order: String
}

/// 容器列表响应
struct ContainerListResponse: Decodable {
    let total: Int
    let items: [Container]?
}

/// 单个容器（1Panel v2 实际返回的字段，已通过 logs/输出11.log 验证）
struct Container: Decodable, Identifiable {
    let containerID: String
    let name: String
    let imageName: String?
    let imageID: String?
    let state: String
    let runTime: String?
    let network: [String]?
    let ports: [String]?
    let createTime: String?
    let isFromApp: Bool?
    let isFromCompose: Bool?
    let appName: String?
    let appInstallName: String?
    let isPinned: Bool?
    let description: String?

    var id: String { containerID }

    var displayName: String { appName ?? name }

    var displayImage: String { imageName ?? "unknown" }

    var stateColor: Color {
        switch state.lowercased() {
        case "running": return .green
        case "exited", "stopped": return .gray
        case "paused": return .orange
        case "restarting": return .blue
        default: return .red
        }
    }

    var stateIcon: String {
        switch state.lowercased() {
        case "running": return "play.circle.fill"
        case "exited", "stopped": return "stop.circle.fill"
        case "paused": return "pause.circle.fill"
        case "restarting": return "arrow.triangle.2.circlepath.circle.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }
}
