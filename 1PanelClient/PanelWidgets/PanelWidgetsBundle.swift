//
//  PanelWidgetsBundle.swift
//  PanelWidgets
//
//  小组件入口：服务器状态(只读概览) + 快捷操作(容器重启按钮)
//

import WidgetKit
import SwiftUI

@main
struct PanelWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ServerStatusWidget()
        QuickOpsWidget()
    }
}

// MARK: - 共享辅助

/// Widget 进程读取服务器（App Group 数据 + 共享 Keychain/镜像凭据）
@MainActor
enum WidgetServerStore {
    static var servers: [PanelServerEntity] {
        ServerManager.shared.servers.map {
            PanelServerEntity(id: $0.id, name: $0.name, baseURL: $0.baseURL)
        }
    }

    static func serverConfig(for entity: PanelServerEntity?) -> ServerConfig? {
        if let entity, let base = ServerManager.shared.servers.first(where: { $0.id == entity.id }) {
            let key = KeychainStore.readShared(for: base.id.uuidString) ?? ""
            return ServerConfig(id: base.id, name: base.name, baseURL: base.baseURL, apiKey: key)
        }
        guard let base = ServerManager.shared.current else { return nil }
        let key = KeychainStore.readShared(for: base.id.uuidString) ?? ""
        return ServerConfig(id: base.id, name: base.name, baseURL: base.baseURL, apiKey: key)
    }
}
