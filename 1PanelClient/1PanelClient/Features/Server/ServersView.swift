//
//  ServersView.swift
//  1PanelClient
//
//  服务器页面：展示全部服务器，单击切换当前服务器，长按编辑，右下角 + 添加
//

import SwiftUI

struct ServersView: View {
    @ObservedObject var manager: ServerManager
    @ObservedObject private var health = ServerHealthMonitor.shared
    @StateObject private var cardMonitor = ServerCardMonitor()
    @State private var showAdd = false
    @State private var editingServer: ServerConfig?
    @State private var serverToRemove: ServerConfig?

    var body: some View {
        List {
            Section {
                ForEach(manager.servers) { server in
                    ServerRow(
                        server: server,
                        isCurrent: server.id == manager.currentServerID,
                        health: health.state(for: server.id),
                        metrics: cardMonitor.currents[server.id],
                        onTap: {
                            if server.id != manager.currentServerID {
                                Haptic.selection()
                            }
                            manager.select(server)
                        },
                        onLongPress: {
                            editingServer = server
                        }
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            serverToRemove = server
                        } label: {
                            Label(L10n.t("移除"), systemImage: "trash")
                        }
                    }
                }
            } footer: {
                Text(L10n.t("单击切换服务器，长按编辑，左滑移除；下拉刷新健康状态"))
            }
        }
        .refreshable {
            await health.checkAll()
            await cardMonitor.refresh()
        }
        .task {
            await cardMonitor.refresh()
        }
        .onAppear {
            health.start()
        }
        .onDisappear {
            health.stop()
        }
        .navigationTitle(L10n.t("服务器"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottomTrailing) {
            FloatingActionButton(accessibilityText: L10n.t("添加服务器")) { showAdd = true }
        }
        .navigationDestination(isPresented: $showAdd) {
            ServerEditView(manager: manager, presentedAsSheet: false)
        }
        .navigationDestination(item: $editingServer) { server in
            ServerEditView(manager: manager, editing: server, presentedAsSheet: false)
        }
        // 移除服务器前确认（会连带清除 Keychain 中的 API 密钥）—— 居中 alert
        .alert(L10n.t("移除服务器"), isPresented: Binding(
            get: { serverToRemove != nil },
            set: { if !$0 { serverToRemove = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) {
                serverToRemove = nil
            }
            Button(L10n.t("移除"), role: .destructive) {
                if let server = serverToRemove {
                    manager.remove(server)
                }
                serverToRemove = nil
            }
        } message: {
            Text(L10n.f("将移除「%@」的连接配置与已保存的 API 密钥，此操作不可恢复。", serverToRemove?.name ?? ""))
        }
    }

}

/// 服务器行：标题行 = 名称 + 健康点 + 运行时长 + 当前绿勾；副行 = 地址；
/// 指标行 = 负载/CPU/内存/各磁盘挂载点小圆环（与首页状态卡同源同色，可横滑）
private struct ServerRow: View {
    let server: ServerConfig
    let isCurrent: Bool
    let health: ServerHealth
    /// dashboard/current 实时指标（nil=未加载/离线）
    let metrics: DashboardCurrent?
    let onTap: () -> Void
    let onLongPress: () -> Void

    /// 标题行健康点：在线绿 / 离线红 / 其余灰
    private var healthColor: Color {
        switch health {
        case .online:  return .statusRunning
        case .offline: return .statusError
        default:       return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 标题行：名称靠左，健康点 + 运行时长 + 当前绿勾 整体靠右贴边
            HStack(spacing: 6) {
                Text(server.name)
                    .font(.headline)
                Spacer(minLength: 8)
                StatusDot(color: healthColor, diameter: 8)
                    .accessibilityLabel(health.label)
                if let rt = metrics?.runningTime {
                    Text(rt.compactText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            // 副行：地址（含 API Key 失效 / HTTP 明文提示）
            HStack(spacing: 4) {
                if server.apiKey.isEmpty {
                    Label(L10n.t("API Key 已失效，长按重新录入"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                if server.isPlainHTTP {
                    Label("HTTP", systemImage: "lock.open")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Text(server.normalizedBaseURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // 指标行：负载/CPU/内存 + 逐磁盘挂载点，复用首页状态卡 RingStatView（compact 同等大小），单行可横滑
            if let cur = metrics {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ring(L10n.t("负载"), percent: cur.loadUsagePercent, color: .teal)
                        ring("CPU", percent: cur.cpuUsedPercent, color: .blue)
                        ring(L10n.t("内存"), percent: cur.memoryUsedPercent, color: .purple)
                        ForEach(Array((cur.diskData ?? []).enumerated()), id: \.offset) { _, disk in
                            ring(
                                disk.path?.isEmpty == false ? disk.path! : L10n.t("存储"),
                                percent: disk.usedPercent,
                                color: .orange
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .padding(.top, 4)  // 与地址副行拉开间隔，避免环顶与上方信息贴叠
                .fixedSize(horizontal: false, vertical: true)
            } else if health.isOnline {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onLongPressGesture(perform: onLongPress)
    }

    /// 指标环：首页状态卡同款 RingStatView（compact 54pt），定宽以适配横滑行
    private func ring(_ label: String, percent: Double?, color: Color) -> some View {
        RingStatView(
            percent: percent ?? 0,
            color: color,
            topText: percent.map { String(format: "%.0f%%", $0) } ?? "—",
            bottomText: label,
            footer: "",
            compact: true
        )
        .frame(width: 64)
    }
}