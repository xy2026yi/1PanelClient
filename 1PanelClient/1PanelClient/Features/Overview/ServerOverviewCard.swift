//
//  ServerOverviewCard.swift
//  1PanelClient
//
//  多机总览卡片（ServerCat 式）：显示在「服务器」页顶部，
//  每台一行——健康状态点 + 名称 + CPU/内存微型进度条，点击即切换当前服务器。
//  指标来自每台服务器一次轻量 dashboard/current 请求；健康状态复用 ServerHealthMonitor。
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

// MARK: - 总览卡片

struct ServerOverviewCard: View {
    @ObservedObject var manager: ServerManager
    @ObservedObject var monitor: ServerCardMonitor
    var onSelect: (ServerConfig) -> Void

    private var onlineCount: Int {
        manager.servers.filter { ServerHealthMonitor.shared.state(for: $0.id).isOnline }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(L10n.t("服务器总览"))
                    .font(.subheadline.bold())
                Spacer()
                Text(L10n.f("%ld/%ld 在线", onlineCount, manager.servers.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(manager.servers) { server in
                serverRow(server)
            }
        }
        .padding(16)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
    }

    @ViewBuilder
    private func serverRow(_ server: ServerConfig) -> some View {
        let isCurrent = server.id == manager.currentServerID
        let health = ServerHealthMonitor.shared.state(for: server.id)
        let current = monitor.currents[server.id]

        Button {
            onSelect(server)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(health.isOnline ? Color.statusRunning : (health == .checking ? Color.secondary : Color.statusStopped))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(isCurrent ? .subheadline.bold() : .subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    // 副行：地址 · 面板运行时间（dashboard/current 返回）
                    HStack(spacing: 4) {
                        Text(server.normalizedBaseURL)
                        if let up = current?.timeSinceUptime, !up.isEmpty {
                            Text("·")
                            Text(L10n.f("运行 %@", up))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 12)

                if let cur = current {
                    VStack(alignment: .trailing, spacing: 4) {
                        miniBar(L10n.t("CPU"), percent: cur.cpuUsedPercent, color: .blue)
                        miniBar(L10n.t("内存"), percent: cur.memoryUsedPercent, color: .purple)
                    }
                } else if health.isOnline {
                    ProgressView()
                        .scaleEffect(0.7)
                }

                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.f("%@，%@，点击切换", server.name, health.label))
    }

    /// 微型指标条：标签 + 细进度条 + 百分比
    private func miniBar(_ label: String, percent: Double?, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.15))
                    Capsule()
                        .fill(color)
                        .frame(width: max(proxy.size.width * min(max(percent ?? 0, 0), 100) / 100, 2))
                }
            }
            .frame(width: 44, height: 4)
            Text(percent.map { String(format: "%.0f%%", $0) } ?? "—")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
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
