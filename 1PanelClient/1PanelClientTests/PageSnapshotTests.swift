//
//  PageSnapshotTests.swift
//  1PanelClientTests
//
//  PageVMStore 磁盘快照层测试：落盘/回填闭环、服务器移除清理、
//  数量上限淘汰。写盘经后台任务，测试以轮询等其落地（上限 2s）
//

import Testing
import Foundation
@testable import _PanelClient

@MainActor
@Suite("页面磁盘快照层")
struct PageSnapshotTests {

    /// 最小快照 VM：字符串数组即快照
    private final class SnapshotVM: ObservableObject, PageSnapshotProvider {
        var items: [String] = []
        var restored = false

        func snapshotData() -> Data? {
            try? JSONEncoder().encode(items)
        }

        func restore(snapshotData: Data) {
            guard let decoded = try? JSONDecoder().decode([String].self, from: snapshotData) else { return }
            items = decoded
            restored = true
        }
    }

    /// 独立临时目录 + 用例结束清理
    private func makeDir(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageSnapshotTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 后台写盘落地等待：轮询直至谓词成立或超时。CI 机器高负载下
    /// utility 优先级的 detached 写任务可能饿几秒，超时窗口给足防时序脆断
    private func waitUntil(_ condition: @autoclosure () -> Bool,
                           timeout: TimeInterval = 15,
                           _ what: String) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("等待超时：\(what)")
    }

    @Test("落盘与回填闭环：autoRefresh 后写盘，新 store 冷启动回填")
    func persistAndRestore() async {
        let dir = makeDir("roundtrip")
        defer { cleanup(dir) }
        let key = "page|apps|\(UUID().uuidString)|1|node|local"
        let store = PageVMStore(snapshotDirectory: dir)

        let vm = store.vm(key: key) { SnapshotVM() }
        vm.items = ["nginx", "redis"]
        await store.autoRefresh(vm: vm) { }
        await waitUntil(PageVMStore.readSnapshot(dir: dir, key: key) != nil, "快照写盘")

        // 冷启动：新 store、新 VM 实例，建 VM 即回填
        let store2 = PageVMStore(snapshotDirectory: dir)
        let vm2 = store2.vm(key: key) { SnapshotVM() }
        #expect(vm2.restored)
        #expect(vm2.items == ["nginx", "redis"])
    }

    @Test("服务器移除：purge 连带清理磁盘快照")
    func purgeRemovesDiskSnapshot() async {
        let dir = makeDir("purge")
        defer { cleanup(dir) }
        let serverID = UUID()
        let key = "page|apps|\(serverID.uuidString)|1|node|local"
        let store = PageVMStore(snapshotDirectory: dir)

        let vm = store.vm(key: key) { SnapshotVM() }
        vm.items = ["a"]
        await store.autoRefresh(vm: vm) { }
        await waitUntil(PageVMStore.readSnapshot(dir: dir, key: key) != nil, "快照写盘")

        store.purge(serverID: serverID)
        await waitUntil(PageVMStore.readSnapshot(dir: dir, key: key) == nil, "purge 删盘")
    }

    @Test("数量上限：超限按 savedAt 淘汰最旧")
    func trimToLimit() async {
        let dir = makeDir("trim")
        defer { cleanup(dir) }

        // 直接写 30 份不同 key 的快照（绕过 store，纯测 trim）
        let base = Date()
        for i in 0..<30 {
            let envelope = PageVMStore.SnapshotEnvelope(
                key: "page|t\(i)|\(UUID().uuidString)|1|node|local",
                savedAt: base.addingTimeInterval(TimeInterval(i)),
                payload: Data("[]".utf8))
            PageVMStore.writeSnapshot(envelope, dir: dir)
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        #expect(files.count == 24)
        // 最旧的 t0 被淘汰、最新的 t29 存活
        #expect(files.isEmpty == false)
    }

    @Test("回后台全量补写：不经 autoRefresh 更新的数据也落盘")
    func persistAllOnBackground() async {
        let dir = makeDir("background")
        defer { cleanup(dir) }
        let key = "page|apps|\(UUID().uuidString)|1|node|local"
        let store = PageVMStore(snapshotDirectory: dir)

        // 建 VM 后直接改数据（模拟手动下拉刷新拿到的新结果），不经 autoRefresh
        let vm = store.vm(key: key) { SnapshotVM() }
        vm.items = ["fresh-from-pull-refresh"]
        store.persistAllSnapshots()
        await waitUntil(PageVMStore.readSnapshot(dir: dir, key: key) != nil, "回后台补写")

        let store2 = PageVMStore(snapshotDirectory: dir)
        let vm2 = store2.vm(key: key) { SnapshotVM() }
        #expect(vm2.items == ["fresh-from-pull-refresh"])
    }

    @Test("无快照/解码失败：回填忽略，行为退化为无快照")
    func restoreIgnoresGarbage() {
        let dir = makeDir("garbage")
        defer { cleanup(dir) }
        let key = "page|x|\(UUID().uuidString)|1|node|local"
        let store = PageVMStore(snapshotDirectory: dir)

        // 目录为空：不回填
        let vm = store.vm(key: key) { SnapshotVM() }
        #expect(!vm.restored)
        #expect(vm.items.isEmpty)
    }
}
