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
                        onTap: {
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
                            Label("移除", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                Text("单击切换服务器，长按编辑，左滑移除；下拉刷新健康状态")
            }
        }
        .refreshable {
            await health.checkAll()
        }
        .onAppear {
            health.start()
        }
        .onDisappear {
            health.stop()
        }
        .navigationTitle("服务器")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottomTrailing) {
            FloatingActionButton(accessibilityText: "添加服务器") { showAdd = true }
        }
        .navigationDestination(isPresented: $showAdd) {
            ServerEditView(manager: manager, presentedAsSheet: false)
        }
        .navigationDestination(item: $editingServer) { server in
            ServerEditView(manager: manager, editing: server, presentedAsSheet: false)
        }
        // 移除服务器前确认（会连带清除 Keychain 中的 API 密钥）
        .confirmationDialog(
            "移除服务器",
            isPresented: Binding(
                get: { serverToRemove != nil },
                set: { if !$0 { serverToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移除「\(serverToRemove?.name ?? "")」", role: .destructive) {
                if let server = serverToRemove {
                    manager.remove(server)
                }
                serverToRemove = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将移除该服务器的连接配置与已保存的 API 密钥，此操作不可恢复。")
        }
    }
}

/// 服务器行：样式与设置页「当前服务器」一致（图标 + 名称 + 地址），当前服务器带选中标记，
/// 尾部健康徽标：绿=在线 红=离线 灰=未检测
private struct ServerRow: View {
    let server: ServerConfig
    let isCurrent: Bool
    let health: ServerHealth
    let onTap: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.headline)
                HStack(spacing: 4) {
                    if server.apiKey.isEmpty {
                        Label("API Key 已失效，长按重新录入", systemImage: "exclamationmark.triangle.fill")
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
            }
            Spacer()
            healthBadge
            if isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onLongPressGesture(perform: onLongPress)
    }

    @ViewBuilder
    private var healthBadge: some View {
        switch health {
        case .unknown:
            StatusDot(color: .gray, diameter: 8)
                .accessibilityLabel("健康状态未知")
        case .checking:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("正在检测连接")
        case .online(let host):
            StatusDot(color: .green, diameter: 8)
                .accessibilityLabel("在线\(host.isEmpty ? "" : "：\(host)")")
        case .offline(let msg):
            StatusDot(color: .red, diameter: 8)
                .accessibilityLabel("离线：\(msg)")
        }
    }
}
