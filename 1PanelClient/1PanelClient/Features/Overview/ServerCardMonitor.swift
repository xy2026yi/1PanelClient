//
//  ServerCardMonitor.swift
//  1PanelClient
//
//  服务器列表行的实时指标：一次性并发拉取各服务器 dashboard/current
//  （负载/CPU/内存/各磁盘挂载点），服务器页出现/下拉刷新时调用。
//  指标以 MetricRing（32pt 小圆环）呈现在服务器行内，与首页状态卡同源同色。
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

// MARK: - 指标小圆环（首页 RingStatView 的缩小版）

/// 单个指标环：环内百分比 + 下方标签（磁盘环标签为挂载点路径）
struct MetricRing: View {
    let label: String
    let percent: Double?
    let color: Color

    private var percentText: String {
        percent.map { String(format: "%.0f", $0) } ?? "—"
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.15), lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: min(max(percent ?? 0, 0), 100) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(percentText)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 32, height: 32)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)  // 磁盘路径完整显示，超宽靠横滑
        }
        .frame(width: 48)
    }
}

// MARK: - ServerHealth 便捷判断

extension ServerHealth {
    var isOnline: Bool {
        if case .online = self { return true }
        return false
    }
}
