//
//  ServersView.swift
//  1PanelClient
//
//  服务器页面：展示全部服务器，单击切换当前服务器，长按编辑，右下角 + 添加
//

import SwiftUI

struct ServersView: View {
    @ObservedObject var manager: ServerManager
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
                Text("单击切换服务器，长按编辑，左滑移除")
            }
        }
        .navigationTitle("服务器")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottomTrailing) {
            FloatingActionButton { showAdd = true }
                .accessibilityLabel("添加服务器")
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

/// 服务器行：样式与设置页「当前服务器」一致（图标 + 名称 + 地址），当前服务器带选中标记
private struct ServerRow: View {
    let server: ServerConfig
    let isCurrent: Bool
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
                Text(server.normalizedBaseURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
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
}
