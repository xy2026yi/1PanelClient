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

import SwiftUI
import Combine

@MainActor
final class PageVMStore {
    static let shared = PageVMStore()

    private var storage: [String: Any] = [:]
    /// 访问顺序（尾端最新），仅用于 LRU 淘汰
    private var order: [String] = []
    private let capacity = 32
    private var cancellables: Set<AnyCancellable> = []

    /// internal：测试可构造独立实例；业务侧用 shared
    init() {
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
        storage[key] = created
        order.append(key)
        trim()
        return created
    }

    /// 清掉某台服务器相关的全部页面 VM（服务器被移除时）
    func purge(serverID: UUID) {
        let marker = "|\(serverID.uuidString)|"
        let dead = storage.keys.filter { $0.contains(marker) }
        guard !dead.isEmpty else { return }
        for key in dead {
            storage.removeValue(forKey: key)
            order.removeAll { $0 == key }
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
}

// MARK: - 页面 key

extension ManageItem {
    /// VM 缓存键：页面 + 服务器 id + 配置指纹（任一变化即新 VM）
    func storeKey(server: ServerConfig) -> String {
        "page|\(rawValue)|\(server.id.uuidString)|\(server.hashValue)"
    }
}
