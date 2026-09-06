//
//  PageVMStoreTests.swift
//  1PanelClientTests
//
//  页面 VM 快照缓存：同 key 同实例 / 配置指纹隔离 / 服务器移除清理 / LRU
//

import Testing
import Foundation
@testable import _PanelClient

@MainActor
@Suite("PageVMStore 页面 VM 快照")
struct PageVMStoreTests {
    private final class FakeVM {}

    /// 独立实例：不污染全局 shared，也不受其他并行套件干扰
    private func makeStore() -> PageVMStore { PageVMStore() }

    @Test("同 key 恒返回同一实例（重访即时渲染的前提）")
    func sameKeySameInstance() {
        let s = makeStore()
        let key = "page|apps|\(UUID().uuidString)|123"
        let a = s.vm(key: key) { FakeVM() }
        let b = s.vm(key: key) { FakeVM() }
        #expect(a === b)
    }

    @Test("不同 key 各自独立实例")
    func differentKeysIndependent() {
        let s = makeStore()
        let id = UUID().uuidString
        let a = s.vm(key: "page|apps|\(id)|1") { FakeVM() }
        let b = s.vm(key: "page|firewall|\(id)|1") { FakeVM() }
        #expect(a !== b)
    }

    @Test("storeKey 含配置指纹：编辑服务器（同 id 不同配置）得到新 key")
    func storeKeyIncludesConfigFingerprint() {
        let base = ServerConfig(name: "t", baseURL: "https://s.local", apiKey: "k1")
        let edited = ServerConfig(id: base.id, name: "t", baseURL: "https://s.local", apiKey: "k2")
        #expect(ManageItem.apps.storeKey(server: base) != ManageItem.apps.storeKey(server: edited))
        #expect(ManageItem.apps.storeKey(server: base) == ManageItem.apps.storeKey(server: base))
    }

    @Test("purge 清掉指定服务器的全部页面 VM")
    func purgeRemovesServerEntries() {
        let s = makeStore()
        let id = UUID()
        let mine = s.vm(key: "page|apps|\(id.uuidString)|1") { FakeVM() }
        _ = s.vm(key: "page|firewall|\(id.uuidString)|1") { FakeVM() }
        let otherID = UUID()
        _ = s.vm(key: "page|apps|\(otherID.uuidString)|1") { FakeVM() }

        s.purge(serverID: id)
        #expect(s.vm(key: "page|apps|\(id.uuidString)|1") { FakeVM() } !== mine)
        // 其他服务器不受影响
        #expect(s.count == 2)
    }

    @Test("超过容量上限按 LRU 淘汰")
    func evictsBeyondCapacity() {
        let s = makeStore()
        let first = s.vm(key: "k0") { FakeVM() }
        for i in 1...32 {
            _ = s.vm(key: "k\(i)") { FakeVM() }
        }
        #expect(s.count == 32)
        // k0 最久未用，已被淘汰（再取会得到新实例）
        #expect(s.vm(key: "k0") { FakeVM() } !== first)
    }

    @Test("重访自动刷新节流：ttl 内同一 VM 只自动刷一次")
    func autoRefreshThrottlesWithinTTL() async throws {
        let s = makeStore()
        let vm = FakeVM()
        var runs = 0
        await s.autoRefresh(vm: vm, ttl: 0.2) { runs += 1 }
        await s.autoRefresh(vm: vm, ttl: 0.2) { runs += 1 }
        #expect(runs == 1)
        try await Task.sleep(for: .milliseconds(250))
        await s.autoRefresh(vm: vm, ttl: 0.2) { runs += 1 }
        #expect(runs == 2)
    }

    @Test("节流按 VM 实例隔离：换新实例即恢复自动刷新")
    func autoRefreshIsPerVMInstance() async {
        let s = makeStore()
        var runs = 0
        await s.autoRefresh(vm: FakeVM(), ttl: 60) { runs += 1 }
        await s.autoRefresh(vm: FakeVM(), ttl: 60) { runs += 1 }
        #expect(runs == 2)
    }

    @Test("刷新被取消不记节流窗口：重访必重刷")
    func cancelledAutoRefreshNotThrottled() async {
        let s = makeStore()
        let vm = FakeVM()
        var runs = 0
        // cancel() 在主执行器同步执行完毕后任务体才可能运行：任务体所见必为已取消
        let t = Task { await s.autoRefresh(vm: vm, ttl: 60) { runs += 1 } }
        t.cancel()
        await t.value
        await s.autoRefresh(vm: vm, ttl: 60) { runs += 1 }
        #expect(runs == 2)
    }
}
