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

                VStack(alignment: .leading, spacing: 4) {
                    // 名称行：当前服务器加粗 + 绿勾（与服务器列表行一致）
                    HStack(spacing: 4) {
                        Text(server.name)
                            .font(isCurrent ? .subheadline.bold() : .subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if isCurrent {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }

                    // 副行：地址 · 运行时长（dashboard/current 的 runningTime）
                    HStack(spacing: 4) {
                        Text(server.normalizedBaseURL)
                        if let rt = current?.runningTime {
                            Text("·")
                            Text(L10n.f("运行 %@", rt.displayText))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                    // 指标行：负载/CPU/内存/磁盘 小圆环（首页状态卡的缩小版），单行可横滑
                    if let cur = current {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                miniRing(L10n.t("负载"), percent: cur.loadUsagePercent, color: .teal)
                                miniRing(L10n.t("CPU"), percent: cur.cpuUsedPercent, color: .blue)
                                miniRing(L10n.t("内存"), percent: cur.memoryUsedPercent, color: .purple)
                                miniRing(L10n.t("磁盘"), percent: rootDiskPercent(cur), color: .orange)
                            }
                            .padding(.vertical, 2)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } else if health.isOnline {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.f("%@，%@，点击切换", server.name, health.label))
    }

    /// 根分区（"/"）使用率；无根分区时取第一块盘
    private func rootDiskPercent(_ cur: DashboardCurrent) -> Double? {
        if let root = cur.diskData?.first(where: { $0.path == "/" }) {
            return root.usedPercent
        }
        return cur.diskData?.first?.usedPercent
    }

    /// 小圆环指标（首页 RingStatView 的缩小版）：环内百分比 + 下方标签
    private func miniRing(_ label: String, percent: Double?, color: Color) -> some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.15), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: min(max(percent ?? 0, 0), 100) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(percent.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 28, height: 28)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 44)
    }
}

// MARK: - ServerHealth 便捷判断

extension ServerHealth {
    var isOnline: Bool {
        if case .online = self { return true }
        return false
    }
}
