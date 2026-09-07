//
//  APIClientCacheTests.swift
//  1PanelClientTests
//
//  共享客户端缓存：同配置同实例 / 配置变更换新 / 移除清理 / LRU 淘汰
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("APIClient 共享缓存")
struct APIClientCacheTests {
    private func makeConfig() -> ServerConfig {
        ServerConfig(name: "t", baseURL: "https://cache-test.local", apiKey: "k")
    }

    @Test("同一配置返回同一实例（连接复用的前提）")
    func sameConfigSameInstance() {
        let server = makeConfig()
        #expect(APIClient.shared(for: server) === APIClient.shared(for: server))
    }

    @Test("配置变化（密钥/地址编辑）返回新实例")
    func changedConfigNewInstance() {
        let server = makeConfig()
        let old = APIClient.shared(for: server)
        let edited = ServerConfig(id: server.id, name: "t", baseURL: "https://cache-test.local", apiKey: "new-key")
        let renewed = APIClient.shared(for: edited)
        #expect(old !== renewed)
        // 改回旧配置也不会复用被作废的实例
        #expect(APIClient.shared(for: server) !== old)
    }

    @Test("不同服务器互不影响")
    func distinctServers() {
        let a = makeConfig()
        let b = makeConfig()
        #expect(APIClient.shared(for: a) !== APIClient.shared(for: b))
    }

    @Test("purge 后重建实例")
    func purgeRebuilds() {
        let server = makeConfig()
        let before = APIClient.shared(for: server)
        APIClient.purge(serverID: server.id)
        let after = APIClient.shared(for: server)
        #expect(before !== after)
    }

    /// purge 后在飞的轮询/探测子任务（捕获了删除前的配置值拷贝）会 miss 缓存
    /// 并回插新 client 形成死条目；墓碑须按需构造但不入缓存，revive 后恢复
    @Test("purge 墓碑：在飞调用不回插缓存，revive 恢复")
    func purgeTombstoneBlocksReinsert() {
        let cache = ClientCache()
        let server = ServerConfig(name: "tomb", baseURL: "https://tomb.local", apiKey: "k")
        _ = cache.client(for: server)
        #expect(cache.count == 1)

        cache.purge(serverID: server.id)
        #expect(cache.count == 0)

        // 模拟删除前在飞的子任务：可拿到可用实例，但不得回插
        _ = cache.client(for: server)
        #expect(cache.count == 0)

        // 重新添加同 id 服务器：恢复正常缓存
        cache.revive(serverID: server.id)
        _ = cache.client(for: server)
        #expect(cache.count == 1)
    }

    /// 默认容量需 ≥ PageVMStore 容量：常驻 VM 持有的 client 不因容量不足
    /// 被逐轮淘汰（淘汰虽已不再 invalidate，重建本身也是无谓开销）
    @Test("默认容量与 PageVMStore 同量级（32）")
    func defaultCapacityMatchesPageVMStore() {
        let cache = ClientCache()
        for i in 0..<33 {
            _ = cache.client(for: ServerConfig(id: UUID(), name: "s\(i)", baseURL: "https://cap.local", apiKey: "k"))
        }
        #expect(cache.count == 32)
    }
}

@Suite("ClientCache LRU")
struct ClientCacheLRUTests {
    /// 独立实例 + 小容量，验证淘汰顺序不污染全局缓存
    @Test("超容量淘汰最久未使用")
    func evictsLeastRecentlyUsed() {
        let cache = ClientCache(capacity: 3)
        let s1 = ServerConfig(name: "1", baseURL: "https://lru.local", apiKey: "k")
        let s2 = ServerConfig(id: UUID(), name: "2", baseURL: "https://lru.local", apiKey: "k")
        let s3 = ServerConfig(id: UUID(), name: "3", baseURL: "https://lru.local", apiKey: "k")
        let s4 = ServerConfig(id: UUID(), name: "4", baseURL: "https://lru.local", apiKey: "k")

        let c1 = cache.client(for: s1)
        let c2 = cache.client(for: s2)
        _ = cache.client(for: s3)
        #expect(cache.count == 3)

        // 访问 s1 提升热度后插入第 4 个：被淘汰的应是最久未用的 s2
        _ = cache.client(for: s1)
        _ = cache.client(for: s4)
        #expect(cache.count == 3)
        #expect(cache.client(for: s1) === c1)
        #expect(cache.client(for: s2) !== c2)
    }
}
