//
//  ServerCardMonitor.swift
//  1PanelClient
//
//  服务器列表行的实时指标：拉取各服务器 dashboard/current
//  （负载/CPU/内存/各磁盘挂载点）。服务器页进入即拉取并 5 秒轮询
//  （与首页状态卡同频），下拉刷新时同步调用。
//  指标以首页状态卡同款 RingStatView（compact）呈现在服务器行内。
//
//  审计 D1：多服务器请求按 250ms 相位错峰（避免同秒并发打满面板与客户端）；
//  连续失败的服务器指数退避（跳过 1/2/4 轮、封顶 4 轮），成功即恢复。
//

import Combine
import SwiftUI

// MARK: - 指标拉取

/// 拉取全部服务器的实时指标（服务器页 5 秒轮询/下拉刷新时调用）
@MainActor
final class ServerCardMonitor: ObservableObject {
    @Published private(set) var currents: [UUID: DashboardCurrent] = [:]

    /// 全局轮次计数（每 refresh +1），用于退避的「跳过 N 轮」判定
    private var round = 0
    /// 各服务器连续失败次数（成功清零）
    private var failures: [UUID: Int] = [:]
    /// 各服务器恢复拉取的轮次（当前轮 < 该值时跳过）。
    /// 设为「失败轮次 + 跳过轮数 + 1」：第 r 轮失败跳过 N 轮即
    /// r+1…r+N 不参与，r+N+1 起恢复（若少加 1，实际只跳 N-1 轮，
    /// 首次失败会完全无退避）
    private var skipUntil: [UUID: Int] = [:]
    /// 进行中的刷新任务：下拉刷新（force）与定时轮询并发时复用同一次请求，
    /// 避免同接口双发与 round 双跳（退避计时被加快）
    private var refreshTask: Task<Void, Never>?

    /// - Parameter force: 下拉刷新传 true——清空退避状态强制重试全部服务器
    /// （手动手势本就意味着「数据不对，重拉」；定时轮询传 false 维持退避）。
    /// 已有在途刷新时直接等它完成（force 的清退避在下一轮自然生效）
    func refresh(force: Bool = false) async {
        if let task = refreshTask {
            await task.value
            return
        }
        let task = Task { await performRefresh(force: force) }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh(force: Bool) async {
        let targets = ServerManager.shared.servers
        for id in currents.keys where !targets.contains(where: { $0.id == id }) {
            currents.removeValue(forKey: id)
            failures[id] = nil
            skipUntil[id] = nil
        }
        guard !targets.isEmpty else { return }

        round += 1
        if force {
            for s in targets { skipUntil[s.id] = nil }
        }
        // 退避中的服务器本轮不参与（skipUntil 与全局轮次比较，见属性注释）
        let due = targets.enumerated().filter { _, s in
            if (skipUntil[s.id] ?? 0) > round { return false }
            return true
        }
        guard !due.isEmpty else { return }

        await withTaskGroup(of: (UUID, DashboardCurrent?).self) { group in
            for (offset, s) in due {
                group.addTask {
                    // 相位错峰：按序固定延迟 250ms/台，多机时请求不再同秒齐发
                    if offset > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(offset) * 250_000_000)
                    }
                    let client = APIClient.shared(for: s)
                    let resp: DashboardCurrent? = try? await client.send(
                        path: APIEndpoint.dashboardCurrent.path,
                        method: APIEndpoint.dashboardCurrent.method,
                        as: DashboardCurrent.self
                    )
                    return (s.id, resp)
                }
            }
            for await (id, cur) in group {
                currents[id] = cur
                if cur == nil {
                    // 指数退避：连续第 f 次失败跳过 2^(f-1) 轮（1/2/4…），
                    // 封顶 4 轮（5 秒一轮 ≈20s）；+1 见 skipUntil 属性注释
                    let f = (failures[id] ?? 0) + 1
                    failures[id] = f
                    skipUntil[id] = round + min(1 << (f - 1), 4) + 1
                } else {
                    failures[id] = nil
                    skipUntil[id] = nil
                }
            }
        }
    }
}

// MARK: - ServerHealth 便捷判断

extension ServerHealth {
    var isOnline: Bool {
        if case .online = self { return true }
        return false
    }
}
