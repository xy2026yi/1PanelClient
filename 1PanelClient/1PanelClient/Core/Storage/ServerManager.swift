//
//  ServerManager.swift
//  1PanelClient
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class ServerManager: ObservableObject {
    static let shared = ServerManager()

    @Published private(set) var servers: [ServerConfig] = []
    @Published private(set) var currentServerID: UUID?

    private let storage = UserDefaults.standard
    private let serversKey = "servers.v1"
    private let currentKey = "currentServer.v1"

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

    // MARK: - 持久化（敏感字段进 Keychain）

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

    private func load() {
        guard let arr = storage.array(forKey: serversKey) as? [[String: String]] else { return }
        servers = arr.compactMap { d in
            guard let idStr = d["id"], let id = UUID(uuidString: idStr),
                  let name = d["name"], let baseURL = d["baseURL"] else { return nil }
            let apiKey = KeychainStore.read(for: id.uuidString) ?? ""
            return ServerConfig(id: id, name: name, baseURL: baseURL, apiKey: apiKey)
        }
        if let idStr = storage.string(forKey: currentKey), let id = UUID(uuidString: idStr) {
            currentServerID = id
        }
    }
}
