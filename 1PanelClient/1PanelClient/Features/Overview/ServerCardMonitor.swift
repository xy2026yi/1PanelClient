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
    /// 各服务器恢复拉取的轮次（当前轮 < 该值时跳过）
    private var skipUntil: [UUID: Int] = [:]

    /// - Parameter force: 下拉刷新传 true——清空退避状态强制重试全部服务器
    /// （手动手势本就意味着「数据不对，重拉」；定时轮询传 false 维持退避）
    func refresh(force: Bool = false) async {
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
        // 退避中的服务器本轮不请求（跳过计数每轮 -1，归零后重试）
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
                    // 指数退避：连续第 f 次失败跳过 2^(f-1) 轮（1/2/4…），封顶 4 轮（≈20s）
                    let f = (failures[id] ?? 0) + 1
                    failures[id] = f
                    skipUntil[id] = round + min(1 << (f - 1), 4)
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
