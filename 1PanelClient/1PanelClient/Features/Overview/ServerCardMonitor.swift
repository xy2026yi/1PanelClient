//
//  ServerCardMonitor.swift
//  1PanelClient
//
//  服务器列表行的实时指标：一次性并发拉取各服务器 dashboard/current
//  （负载/CPU/内存/各磁盘挂载点），服务器页出现/下拉刷新时调用。
//  指标以首页状态卡同款 RingStatView（compact）呈现在服务器行内。
//

import Combine
import SwiftUI

// MARK: - 指标拉取

/// 按需拉取全部服务器的实时指标（无轮询，首页出现/下拉刷新时调用）
@MainActor
final class ServerCardMonitor: ObservableObject {
    @Published private(set) var currents: [UUID: DashboardCurrent] = [:]

    func refresh() async {
        let targets = ServerManager.shared.servers
        for id in currents.keys where !targets.contains(where: { $0.id == id }) {
            currents.removeValue(forKey: id)
        }
        guard !targets.isEmpty else { return }

        await withTaskGroup(of: (UUID, DashboardCurrent?).self) { group in
            for s in targets {
                group.addTask {
                    let client = APIClient(server: s)
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
