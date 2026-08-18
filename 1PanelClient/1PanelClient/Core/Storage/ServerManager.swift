//
//  ServerManager.swift
//  1PanelClient
//

import Foundation
import SwiftUI
import Combine
import os

@MainActor
final class ServerManager: ObservableObject {
    static let shared = ServerManager()

    @Published private(set) var servers: [ServerConfig] = []
    @Published private(set) var currentServerID: UUID?

    private let storage = UserDefaults.standard
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
    }

    // MARK: - CRUD

    func add(_ server: ServerConfig) {
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
    }

    /// 一次性迁移：旧版本在模拟器上写入的 API Key 明文镜像读回 Keychain 后删除，
    /// 保证 UserDefaults 中不再留存任何密钥明文
    private func migrateLegacyKeyMirrors() {
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
}
