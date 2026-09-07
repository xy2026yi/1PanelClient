//
//  ServerManager.swift
//  1PanelClient
//

import Foundation
import SwiftUI
import Combine
import os
import WidgetKit

@MainActor
final class ServerManager: ObservableObject {
    static let shared = ServerManager()

    /// 服务器被移除（object 为其 UUID）：PageVMStore 等监听清理关联缓存
    static let serverDidRemove = Notification.Name("serverDidRemove")

    @Published private(set) var servers: [ServerConfig] = []
    @Published private(set) var currentServerID: UUID?

    /// App Group 存储：主 App 与小组件扩展共享服务器列表；
    /// 未签名分发时退化为进程内 UserDefaults（仅主 App 可见）
    private let storage = AppGroup.defaults ?? .standard
    private let serversKey = "servers.v1"
    private let currentKey = "currentServer.v1"
    /// 旧版本曾把 API Key 明文镜像到 UserDefaults（模拟器 Keychain 兜底），存在被
    /// 备份提取的风险，已移除；该前缀仅用于启动时的一次性迁移，迁移后立即删除明文
    private static let legacyKeyMirrorPrefix = "apikey.mirror."

    var current: ServerConfig? {
        guard let id = currentServerID else { return servers.first }
        return servers.first(where: { $0.id == id }) ?? servers.first
    }

    private init() {
        migrateLegacyKeyMirrors()
        load()
        // 冷启动对齐一次小组件：覆盖「重装 App 后桌面小组件冻结在旧时间线」的
        // 场景（重装后不重新添加小组件，它会一直显示旧的空态/数据）
        reloadWidgets()
    }

    // MARK: - CRUD

    func add(_ server: ServerConfig) {
        // 若此前移除过同 id 服务器（正常流程 id 为新 UUID，理论不可达），
        // 解除连接缓存墓碑，恢复复用
        APIClient.revive(serverID: server.id)
        servers.append(server)
        persistServers()
        if currentServerID == nil {
            setCurrent(server.id)
        }
    }

    func update(_ server: ServerConfig) {
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            servers[idx] = server
            persistServers()
        }
    }

    func remove(_ server: ServerConfig) {
        servers.removeAll { $0.id == server.id }
        KeychainStore.delete(for: server.id.uuidString)
        // 同步释放该服务器的共享连接池（下轮 ServerCardMonitor 轮询不会再重建它）
        APIClient.purge(serverID: server.id)
        NotificationCenter.default.post(name: Self.serverDidRemove, object: server.id)
        persistServers()
        if currentServerID == server.id {
            setCurrent(servers.first?.id)
        }
    }

    func select(_ server: ServerConfig) {
        setCurrent(server.id)
    }

    // MARK: - 私有

    private func setCurrent(_ id: UUID?) {
        currentServerID = id
        if let id {
            storage.set(id.uuidString, forKey: currentKey)
        } else {
            storage.removeObject(forKey: currentKey)
        }
        reloadWidgets()
    }

    // MARK: - 持久化（敏感字段只进 Keychain，不落 UserDefaults）

    private func persistServers() {
        let safe: [[String: String]] = servers.map { s in
            [
                "id": s.id.uuidString,
                "name": s.name,
                "baseURL": s.normalizedBaseURL
            ]
        }
        storage.set(safe, forKey: serversKey)

        for s in servers {
            KeychainStore.save(s.apiKey, for: s.id.uuidString)
        }
        reloadWidgets()
    }

    /// 服务器列表/当前服务器变化后重载桌面小组件时间线。真机实测：添加服务器后
    /// 若不主动 reload，小组件要等系统按刷新预算自行重算（30 分钟策略可能拖到
    /// 数小时），期间一直显示「离线：请先添加服务器」空态。PanelShared 同时编入
    /// 主 App 与 Widget 扩展，扩展进程内 reload 无效，跳过。
    private func reloadWidgets() {
        guard !Bundle.main.bundlePath.hasSuffix(".appex") else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 一次性迁移：旧版本在模拟器上写入的 API Key 明文镜像读回 Keychain 后删除，
    /// 保证 UserDefaults 中不再留存任何密钥明文
    private func migrateLegacyKeyMirrors() {
        migrateStandardToGroupIfNeeded()
        let mirrorKeys = storage.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(Self.legacyKeyMirrorPrefix) }
        guard !mirrorKeys.isEmpty else { return }
        for key in mirrorKeys {
            let id = String(key.dropFirst(Self.legacyKeyMirrorPrefix.count))
            if let value = storage.string(forKey: key), !value.isEmpty,
               (KeychainStore.read(for: id) ?? "").isEmpty {
                KeychainStore.save(value, for: id)
            }
            storage.removeObject(forKey: key)
        }
    }

    private func load() {
        guard let arr = storage.array(forKey: serversKey) as? [[String: String]] else { return }
        servers = arr.compactMap { d in
            guard let idStr = d["id"], let id = UUID(uuidString: idStr),
                  let name = d["name"], let baseURL = d["baseURL"] else { return nil }
            let (kcValue, status) = KeychainStore.readWithStatus(for: id.uuidString)
            #if DEBUG
            Logger(subsystem: "com.xy.1PanelClient.debug", category: "keychain")
                .warning("[KEYCHAIN-DEBUG] id=\(id.uuidString, privacy: .public) status=\(status) keychainLen=\(kcValue?.count ?? -1)")
            #endif
            return ServerConfig(id: id, name: name, baseURL: baseURL, apiKey: kcValue ?? "")
        }
        if let idStr = storage.string(forKey: currentKey), let id = UUID(uuidString: idStr) {
            currentServerID = id
        }
    }

    /// 一次性迁移：存量单进程 UserDefaults → App Group（迁移成功后清除旧键）
    private func migrateStandardToGroupIfNeeded() {
        guard let group = AppGroup.defaults, group !== storage else { return }
        let std = UserDefaults.standard
        guard let arr = std.array(forKey: serversKey) as? [[String: String]],
              !arr.isEmpty,
              group.array(forKey: serversKey) == nil else { return }
        group.set(arr, forKey: serversKey)
        if let current = std.string(forKey: currentKey) {
            group.set(current, forKey: currentKey)
        }
        std.removeObject(forKey: serversKey)
        std.removeObject(forKey: currentKey)
    }
}
