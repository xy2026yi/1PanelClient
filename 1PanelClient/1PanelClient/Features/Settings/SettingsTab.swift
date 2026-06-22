//
//  SettingsTab.swift
//  1PanelClient
//

import SwiftUI

struct SettingsTab: View {
    @ObservedObject var manager: ServerManager
    @State private var showAddSheet = false
    @State private var editingServer: ServerConfig?

    var body: some View {
        NavigationStack {
            settingsRootContent
        }
    }

    /// 供外部 NavigationStack 复用的根内容（不包含 NavigationStack）
    var settingsRootContent: some View {
        List {
            // MARK: - 当前服务器
            Section("当前服务器") {
                if let current = manager.current {
                    HStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .font(.title2)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(current.name)
                                .font(.headline)
                            Text(current.normalizedBaseURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } else {
                    Text("未连接")
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: - 服务器列表
            if manager.servers.count > 1 {
                Section("所有服务器") {
                    ForEach(manager.servers) { s in
                        Button {
                            manager.select(s)
                        } label: {
                            HStack {
                                Image(systemName: s.id == manager.currentServerID ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(s.id == manager.currentServerID ? .green : .secondary)
                                Text(s.name)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // MARK: - 操作
            Section {
                Button {
                    showAddSheet = true
                } label: {
                    Label("添加服务器", systemImage: "plus.circle")
                }

                ForEach(manager.servers) { s in
                    Button {
                        editingServer = s
                    } label: {
                        Label("编辑 \(s.name)", systemImage: "pencil")
                    }
                }
                .onDelete { offsets in
                    for offset in offsets {
                        if offset < manager.servers.count {
                            manager.remove(manager.servers[offset])
                        }
                    }
                }
            }

            // MARK: - 关于
            Section("关于") {
                LabeledContent("版本", value: "1.0.0")
                LabeledContent("API 版本", value: "v2")
                Link(destination: URL(string: "https://1panel.cn")!) {
                    Label("1Panel 官网", systemImage: "safari")
                }
                Link(destination: URL(string: "https://github.com/xy")!) {
                    Label("项目源码", systemImage: "swift")
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showAddSheet) {
            ServerEditView(manager: manager)
        }
        .sheet(item: $editingServer) { server in
            ServerEditView(manager: manager, editing: server)
        }
    }
}

/// 供工具箱/外层 NavigationStack 复用的「设置」内容视图
/// SettingsTab 自身保留 NavigationStack 以兼容独立使用；
/// 在工具箱场景下用本视图，由外层提供 NavigationStack。
struct SettingsTabContent: View {
    @ObservedObject var manager: ServerManager
    @State private var showAddSheet = false
    @State private var editingServer: ServerConfig?

    var body: some View {
        List {
            Section("当前服务器") {
                if let current = manager.current {
                    HStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .font(.title2)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(current.name)
                                .font(.headline)
                            Text(current.normalizedBaseURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } else {
                    Text("未连接")
                        .foregroundStyle(.secondary)
                }
            }

            if manager.servers.count > 1 {
                Section("所有服务器") {
                    ForEach(manager.servers) { s in
                        Button {
                            manager.select(s)
                        } label: {
                            HStack {
                                Image(systemName: s.id == manager.currentServerID ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(s.id == manager.currentServerID ? .green : .secondary)
                                Text(s.name)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section {
                Button {
                    showAddSheet = true
                } label: {
                    Label("添加服务器", systemImage: "plus.circle")
                }

                ForEach(manager.servers) { s in
                    Button {
                        editingServer = s
                    } label: {
                        Label("编辑 \(s.name)", systemImage: "pencil")
                    }
                }
                .onDelete { offsets in
                    for offset in offsets {
                        if offset < manager.servers.count {
                            manager.remove(manager.servers[offset])
                        }
                    }
                }
            }

            Section("关于") {
                LabeledContent("版本", value: "1.0.0")
                LabeledContent("API 版本", value: "v2")
                Link(destination: URL(string: "https://1panel.cn")!) {
                    Label("1Panel 官网", systemImage: "safari")
                }
                Link(destination: URL(string: "https://github.com/xy")!) {
                    Label("项目源码", systemImage: "swift")
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showAddSheet) {
            ServerEditView(manager: manager)
        }
        .sheet(item: $editingServer) { server in
            ServerEditView(manager: manager, editing: server)
        }
    }
}
