//
//  APIClientCache.swift
//  1PanelClient
//
//  APIClient 共享缓存：同一服务器配置全局复用一个客户端，
//  URLSession 连接池跨页面/跨轮询保持热态，进页请求不再重复
//  TCP/TLS 握手（原先每次 push 页面、ServerCardMonitor 每 5 秒
//  轮询都新建 3 个 session，远程服务器上每次握手多花 1-2 个 RTT）。
//  - 同一 ServerConfig → 同一实例
//  - 配置变化（编辑地址/密钥）→ 淘汰旧实例并断开旧连接
//  - ServerManager.remove 时调用 purge 清理
//  - LRU 上限保护：编辑草稿/兜底空配置等一次性 UUID 不无限累积
//

import Foundation

extension APIClient {
    /// 取共享客户端；首个调用方承担构造，后续复用热连接
    static func shared(for server: ServerConfig) -> APIClient {
        ClientCache.sharedCache.client(for: server)
    }

    /// 服务器被移除时清理其缓存连接
    static func purge(serverID: UUID) {
        ClientCache.sharedCache.purge(serverID: serverID)
    }
}

/// 线程安全的极简 LRU 缓存。ServerCardMonitor 的并发任务组会跨隔离域
/// 取客户端，APIClient 初始化后不可变（@unchecked Sendable 见主文件）
final class ClientCache: @unchecked Sendable {
    static let sharedCache = ClientCache()

    private let lock = NSLock()
    private var entries: [UUID: (config: ServerConfig, client: APIClient)] = [:]
    /// 访问顺序（尾端最新），仅用于 LRU 淘汰
    private var order: [UUID] = []
    private let capacity: Int

    init(capacity: Int = 8) {
        self.capacity = max(1, capacity)
    }

    func client(for server: ServerConfig) -> APIClient {
        lock.lock()
        defer { lock.unlock() }

        if let hit = entries[server.id] {
            if hit.config == server {
                touch(server.id)
                return hit.client
            }
            // 配置已变（编辑过地址/密钥）：旧连接池指向旧服务端，作废重建
            hit.client.invalidate()
            remove(server.id)
        }

        let client = APIClient(server: server)
        entries[server.id] = (server, client)
        order.append(server.id)
        trim()
        return client
    }

    func purge(serverID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        entries[serverID]?.client.invalidate()
        remove(serverID)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    private func remove(_ id: UUID) {
        entries.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    private func touch(_ id: UUID) {
        if let idx = order.firstIndex(of: id) {
            order.remove(at: idx)
            order.append(id)
        }
    }

    private func trim() {
        while order.count > capacity {
            let evicted = order.removeFirst()
            entries[evicted]?.client.invalidate()
            entries.removeValue(forKey: evicted)
        }
    }
}
