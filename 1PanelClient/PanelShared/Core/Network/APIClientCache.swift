//
//  APIClientCache.swift
//  1PanelClient
//
//  APIClient 共享缓存：同一服务器配置全局复用一个客户端，
//  URLSession 连接池跨页面/跨轮询保持热态，进页请求不再重复
//  TCP/TLS 握手（原先每次 push 页面、ServerCardMonitor 每 5 秒
//  轮询都新建 3 个 session，远程服务器上每次握手多花 1-2 个 RTT）。
//  - 同一 ServerConfig → 同一实例
//  - 配置变化（编辑地址/密钥）→ 换新实例，旧实例仅丢弃引用
//  - ServerManager.remove 时调用 purge 清理并断开连接
//  - LRU 上限保护：编辑草稿/兜底空配置等一次性 UUID 不无限累积
//
//  失效纪律：invalidate() 只允许发生在 purge（服务器移除，后续必无人
//  使用）；其余路径（配置替换、LRU 淘汰）只丢弃引用——被换下的实例
//  可能仍被 PageVMStore 常驻 VM 或在用视图持有，主动失效会令其后续
//  请求永久报错。无人引用的旧连接池由 URLSession 空闲超时自然回收。
//

import Foundation

extension APIClient {
    /// 取共享客户端；首个调用方承担构造，后续复用热连接。
    /// nonisolated：ServerCardMonitor/健康探测的并发任务组在隔离域外调用
    nonisolated static func shared(for server: ServerConfig) -> APIClient {
        ClientCache.sharedCache.client(for: server)
    }

    /// 服务器被移除时清理其缓存连接
    nonisolated static func purge(serverID: UUID) {
        ClientCache.sharedCache.purge(serverID: serverID)
    }
}

/// 线程安全的极简 LRU 缓存。ServerCardMonitor 的并发任务组会跨隔离域
/// 取客户端，APIClient 初始化后不可变（@unchecked Sendable 见主文件）。
/// nonisolated：项目默认 MainActor 隔离，此处靠 NSLock 自保证线程安全
nonisolated final class ClientCache: @unchecked Sendable {
    static let sharedCache = ClientCache()

    private let lock = NSLock()
    private var entries: [UUID: (config: ServerConfig, client: APIClient)] = [:]
    /// 访问顺序（尾端最新），仅用于 LRU 淘汰
    private var order: [UUID] = []
    private let capacity: Int

    /// 容量与 PageVMStore 同量级：常驻 VM 最多持有 32 个 client，
    /// 覆盖常见多机场景；超出时仅退化为逐轮重建，不再破坏在用实例
    init(capacity: Int = 32) {
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
            // 配置已变（编辑草稿探测/保存后的轮询）：换新实例即可。
            // 不 invalidate 旧实例——编辑中页面、旧配置键的常驻 VM 仍可能
            // 持有它，失效会令其后续请求报错（见文件头「失效纪律」）
            remove(server.id)
        }

        let client = APIClient(server: server)
        entries[server.id] = (server, client)
        order.append(server.id)
        trim()
        return client
    }

    /// 服务器移除时调用：唯一确定后续无人再用的路径，才主动断开连接池
    /// （PageVMStore 经 serverDidRemove 同步清理其常驻 VM）
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
            // 只丢弃引用：被淘汰实例可能仍被常驻 VM 持有并发起请求，
            // 闲置连接池由 URLSession 空闲超时自行回收
            let evicted = order.removeFirst()
            entries.removeValue(forKey: evicted)
        }
    }
}
