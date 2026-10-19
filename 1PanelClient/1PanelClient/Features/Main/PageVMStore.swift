//
//  PageVMStore.swift
//  1PanelClient
//
//  页面 ViewModel 快照缓存（stale-while-revalidate）：
//  push 页面的 VM 按页面 + 服务器配置缓存，pop 后再进直接渲染上次数据、
//  .task 静默刷新——消除「返回再进仍全屏转圈」的等待。
//  - key 含完整 ServerConfig 指纹：编辑地址/密钥后自动落到新 VM，
//    不会拿着旧连接继续请求
//  - 服务器移除时经 ServerManager.serverDidRemove 通知清理
//  - LRU 上限 32，防止长会话内存无界增长
//
//  磁盘快照层（跨启动延伸）：实现 PageSnapshotProvider 的 VM 在
//  autoRefresh 完成后把首屏数据写进 Caches/PageSnapshots（信封含原 key），
//  冷启动建 VM 时先回填——兑现隐私政策「离线展示最近一次快照」。
//  读写/解码失败一律忽略，退化为无快照的现行为；Caches 可被系统清理，
//  只当提速手段不当数据存储
//

import SwiftUI
import Combine
import CryptoKit

/// 页面快照落盘协议：实现方以 Data 给出「首屏渲染所需数据」的 Codable
/// 快照（只放列表渲染要用的字段，不放瞬时态/操作态）
@MainActor
protocol PageSnapshotProvider: AnyObject {
    /// nil = 暂无可快照的数据（如首次加载前）
    func snapshotData() -> Data?
    /// 回填快照；解码失败等由实现方自行忽略
    func restore(snapshotData: Data)
}

@MainActor
final class PageVMStore {
    static let shared = PageVMStore()

    private var storage: [String: Any] = [:]
    /// 访问顺序（尾端最新），仅用于 LRU 淘汰
    private var order: [String] = []
    private let capacity = 32
    private var cancellables: Set<AnyCancellable> = []

    // MARK: 磁盘快照层

    /// 快照文件信封：文件名是 key 的 SHA256（key 含 | 与 UUID，不宜直接做
    /// 文件名），信封存原 key 供 purge(serverID:) 反查，savedAt 供上限淘汰
    nonisolated struct SnapshotEnvelope: Codable {
        let key: String
        let savedAt: Date
        let payload: Data
    }

    /// 快照文件数量上限（按 savedAt 淘汰最旧；单文件 KB 级，总量 MB 级）
    nonisolated private static let snapshotFileLimit = 24
    private let snapshotDir: URL

    /// VM 实例 → store key：autoRefresh 落盘时反查（弱引用判活，
    /// 与 autoRefreshedAt 的清理口径一致）
    private struct KeyEntry {
        weak var vm: AnyObject?
        let key: String
    }
    private var keyByVM: [ObjectIdentifier: KeyEntry] = [:]

    /// internal：测试可注入独立快照目录；业务侧用 shared（默认 Caches）
    init(snapshotDirectory: URL? = nil) {
        snapshotDir = snapshotDirectory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PageSnapshots", isDirectory: true)
        NotificationCenter.default.publisher(for: ServerManager.serverDidRemove)
            .sink { [weak self] note in
                guard let id = note.object as? UUID else { return }
                let removed = id
                Task { @MainActor in self?.purge(serverID: removed) }
            }
            .store(in: &cancellables)
    }

    /// 取（或建）该页面的常驻 VM；同一 key 恒返回同一实例
    func vm<T: AnyObject>(key: String, make: () -> T) -> T {
        if let hit = storage[key] as? T {
            touch(key)
            return hit
        }
        let created = make()
        keyByVM[ObjectIdentifier(created)] = KeyEntry(vm: created, key: key)
        // 冷启动回填：磁盘有上次会话的快照先渲染，autoRefresh 静默刷新对齐
        if let provider = created as? PageSnapshotProvider,
           let envelope = Self.readSnapshot(dir: snapshotDir, key: key) {
            provider.restore(snapshotData: envelope.payload)
        }
        storage[key] = created
        order.append(key)
        trim()
        return created
    }


    /// 重访自动刷新的节流表：VM 实例身份 → 上次自动刷新时间。
    /// 持弱引用判活——VM 释放后地址可能被新实例复用，弱引用已置 nil 的
    /// 条目必须先清掉，否则新实例会继承旧节流窗口、首次进页不刷新
    private struct ThrottleEntry {
        weak var vm: AnyObject?
        var at: Date
    }
    private var autoRefreshedAt: [ObjectIdentifier: ThrottleEntry] = [:]

    /// 进页 .task 静默刷新的节流：同一常驻 VM 在 ttl 秒内重访只自动刷一次，
    /// 快照照常即时渲染。手动路径（下拉刷新、重试按钮、通知触达）不经此，
    /// 不受影响。按 VM 实例而非 store key 记录——实例与页面+服务器+配置
    /// 一一对应，且 LRU 淘汰换新实例后自动恢复全量刷新。
    /// 节流窗口在刷新**完成**后记录：中途退出页面（.task 取消）不算完成，
    /// 重访必重刷，快照不会卡在取消时的半途状态
    func autoRefresh(vm: AnyObject, ttl: TimeInterval = 5, action: () async -> Void) async {
        let now = Date.now
        // 清掉宿主 VM 已释放或超过 1 分钟的旧记录，防长会话累积
        //（keyByVM 同口径清理）
        autoRefreshedAt = autoRefreshedAt.filter {
            $0.value.vm != nil && now.timeIntervalSince($0.value.at) < 60
        }
        keyByVM = keyByVM.filter { $0.value.vm != nil }
        let id = ObjectIdentifier(vm)
        if let last = autoRefreshedAt[id], now.timeIntervalSince(last.at) < ttl { return }
        await action()
        if !Task.isCancelled {
            autoRefreshedAt[id] = ThrottleEntry(vm: vm, at: Date.now)
            persistSnapshot(of: vm)
        }
    }

    /// 刷新完成后落盘：快照提取在主线程（读 @Published 数据），编码写盘
    /// 分离到后台任务（KB 级，不阻塞交互）。手动路径（下拉刷新等）不落盘，
    /// 下次进页的 autoRefresh 会补写
    private func persistSnapshot(of vm: AnyObject) {
        guard let provider = vm as? PageSnapshotProvider,
              let key = keyByVM[ObjectIdentifier(vm)]?.key,
              let data = provider.snapshotData() else { return }
        let dir = snapshotDir
        let envelope = SnapshotEnvelope(key: key, savedAt: .now, payload: data)
        Task.detached(priority: .utility) {
            Self.writeSnapshot(envelope, dir: dir)
        }
    }

    /// 清掉某台服务器相关的全部页面 VM（服务器被移除时）；
    /// 磁盘快照同清（信封里的 key 含服务器指纹可反查）
    func purge(serverID: UUID) {
        let marker = "|\(serverID.uuidString)|"
        let dead = storage.keys.filter { $0.contains(marker) }
        guard !dead.isEmpty else { return }
        for key in dead {
            storage.removeValue(forKey: key)
            order.removeAll { $0 == key }
        }
        let dir = snapshotDir
        Task.detached(priority: .utility) {
            Self.purgeSnapshots(marker: marker, dir: dir)
        }
    }

    var count: Int { storage.count }

    private func touch(_ key: String) {
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
    }

    private func trim() {
        while order.count > capacity {
            let evicted = order.removeFirst()
            storage.removeValue(forKey: evicted)
        }
    }

    // MARK: - 磁盘快照读写（可从任意线程调用；调用方频率低，无需加锁——
    // 最坏情况是并发 trim 双删，删除不存在文件只是无害报错）

    nonisolated private static func snapshotFileURL(key: String, dir: URL) -> URL {
        // key 含 | / UUID / hash 等字符，SHA256 十六进制做稳定文件名
        // （String.hashValue 每进程随机种子，跨启动不稳定，不可用）
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("\(name).json")
    }

    /// internal：单测直测落盘/回填（业务侧只经 vm/autoRefresh 间接触达）
    nonisolated static func readSnapshot(dir: URL, key: String) -> SnapshotEnvelope? {
        let url = snapshotFileURL(key: key, dir: dir)
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(SnapshotEnvelope.self, from: data),
              envelope.key == key else { return nil }
        return envelope
    }

    nonisolated static func writeSnapshot(_ envelope: SnapshotEnvelope, dir: URL) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(envelope)
            try data.write(to: snapshotFileURL(key: envelope.key, dir: dir), options: .atomic)
            trimSnapshots(dir: dir)
        } catch {
            // 磁盘满/文件系统错误：快照只是提速手段，失败静默
        }
    }

    /// 超出数量上限时按 savedAt 淘汰最旧
    nonisolated private static func trimSnapshots(dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return }
        var envelopes: [(url: URL, savedAt: Date)] = []
        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let envelope = try? JSONDecoder().decode(SnapshotEnvelope.self, from: data)
            else { continue }
            envelopes.append((url, envelope.savedAt))
        }
        guard envelopes.count > snapshotFileLimit else { return }
        for victim in envelopes.sorted(by: { $0.savedAt < $1.savedAt })
            .prefix(envelopes.count - snapshotFileLimit) {
            try? FileManager.default.removeItem(at: victim.url)
        }
    }

    nonisolated private static func purgeSnapshots(marker: String, dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let envelope = try? JSONDecoder().decode(SnapshotEnvelope.self, from: data),
                  envelope.key.contains(marker) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - 页面 key

extension PageVMStore {
    /// 页面 key 通用组键：无独立 ManageItem 的子页/桥接页（分组管理、数据库
    /// 实例、容器跳应用/网站详情等）用页面标识自组，与 storeKey 同构——
    /// 服务器指纹与节点任一变化即新 VM（同 storeKey 的防错靶语义）
    static func pageKey(_ page: String, server: ServerConfig) -> String {
        let node = NodeScope.current(for: server.id) ?? "local"
        return "page|\(page)|\(server.id.uuidString)|\(server.hashValue)|node|\(node)"
    }
}

extension ManageItem {
    /// VM 缓存键：页面 + 服务器 id + 配置指纹 + 当前节点（任一变化即新 VM）。
    /// 节点维度必须入键：应用/网站/数据库/计划任务页都可从「管理根入口」与
    /// 「多机管理-节点」两条路径进入，请求经 CurrentNode 头按当前节点路由——
    /// 若 key 不含节点，5 秒节流窗口内从节点 A 的页面退回再进节点 B 的页面
    /// 会直接渲染 A 的列表快照，行点击带着 B 的节点头按自增 id 请求，
    /// 极易命中 B 上的同 id 资源（列表显示 A、操作落在 B 的错靶）
    func storeKey(server: ServerConfig) -> String {
        PageVMStore.pageKey(rawValue, server: server)
    }
}
