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
    /// API Key 的 UserDefaults 镜像前缀：模拟器重装 app 后 Keychain 条目可能整体不可读
    /// （读出空 Key，所有请求被 1Panel 拒绝「API 接口密钥错误」），镜像兜底保证已保存
    /// 的服务器仍可连接；真机上 Keychain 稳定，Keychain 始终优先
    private let keyMirrorPrefix = "apikey.mirror."

    var current: ServerConfig? {
        guard let id = currentServerID else { return servers.first }
        return servers.first(where: { $0.id == id }) ?? servers.first
    }

    private init() {
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
        storage.removeObject(forKey: keyMirrorPrefix + server.id.uuidString)
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

    // MARK: - 持久化（敏感字段进 Keychain，另写 UserDefaults 镜像兜底）

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
            storage.set(s.apiKey, forKey: keyMirrorPrefix + s.id.uuidString)
        }
    }

    private func load() {
        guard let arr = storage.array(forKey: serversKey) as? [[String: String]] else { return }
        servers = arr.compactMap { d in
            guard let idStr = d["id"], let id = UUID(uuidString: idStr),
                  let name = d["name"], let baseURL = d["baseURL"] else { return nil }
            let (kcValue, status) = KeychainStore.readWithStatus(for: id.uuidString)
            let apiKey = kcValue ?? storage.string(forKey: keyMirrorPrefix + id.uuidString) ?? ""
            #if DEBUG
            Logger(subsystem: "com.xy.1PanelClient.debug", category: "keychain")
                .warning("[KEYCHAIN-DEBUG] id=\(id.uuidString, privacy: .public) status=\(status) keychainLen=\(kcValue?.count ?? -1) finalLen=\(apiKey.count)")
            #endif
            return ServerConfig(id: id, name: name, baseURL: baseURL, apiKey: apiKey)
        }
        if let idStr = storage.string(forKey: currentKey), let id = UUID(uuidString: idStr) {
            currentServerID = id
        }
    }
}
