//
//  SettingsTab.swift
//  1PanelClient
//

import SwiftUI

struct SettingsTab: View {
    @ObservedObject var manager: ServerManager
    @State private var showAddSheet = false
    @State private var editingServer: ServerConfig?
    @State private var showAbout = false
    @State private var serverToDelete: ServerConfig?
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue

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
                            serverToDelete = manager.servers[offset]
                        }
                    }
                }
            }

            // MARK: - 外观
            Section {
                Picker("主题", selection: $themeRaw) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme.rawValue)
                    }
                }
            } header: {
                Text("外观")
            } footer: {
                Text("跟随系统时随设备外观自动切换")
            }

            // MARK: - 关于
            AboutSectionView(isPresented: $showAbout)
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.large)
        // navigationDestination 必须挂在 List 外，否则 lazy 容器内会被忽略
        .navigationDestination(isPresented: $showAbout) {
            AboutDetailView()
        }
        .sheet(isPresented: $showAddSheet) {
            ServerEditView(manager: manager)
        }
        .sheet(item: $editingServer) { server in
            ServerEditView(manager: manager, editing: server)
        }
        // 删除服务器前确认（会连带清除 Keychain 中的 API 密钥）
        .confirmationDialog(
            "删除服务器",
            isPresented: Binding(
                get: { serverToDelete != nil },
                set: { if !$0 { serverToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除「\(serverToDelete?.name ?? "")」", role: .destructive) {
                if let server = serverToDelete {
                    manager.remove(server)
                }
                serverToDelete = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将移除该服务器的连接配置与已保存的 API 密钥，此操作不可恢复。")
        }
    }
}

// MARK: - 主题

/// 全局外观主题（rawValue 持久化于 UserDefaults）
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "app.theme"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "亮色"
        case .dark:   return "暗色"
        }
    }

    /// 传给 preferredColorScheme 的值，nil 表示跟随系统
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// MARK: - 关于（居中卡片入口）

/// 设置页底部的「关于APP」入口行：小号圆圈 i 图标 + 左对齐标题与版本号
/// 注意：只负责展示与置位，导航由宿主在 List 外挂载（避免 lazy 容器内 navigationDestination）
struct AboutSectionView: View {
    @Binding var isPresented: Bool

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.3"
    }

    var body: some View {
        Section {
            Button {
                isPresented = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                            .frame(width: 34, height: 34)
                        Image(systemName: "info")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("关于APP")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(appVersion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// 关于详情：版本 / API 版本 / 1Panel 官网
struct AboutDetailView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.3"
    }

    var body: some View {
        List {
            Section("版本信息") {
                LabeledContent("版本", value: appVersion)
                LabeledContent("API 版本", value: "v2")
            }
            Section {
                Link(destination: URL(string: "https://1panel.cn")!) {
                    Label("1Panel 官网", systemImage: "safari")
                }
            }
        }
        .navigationTitle("关于APP")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 供工具箱/外层 NavigationStack 复用的「设置」内容视图
/// SettingsTab 自身保留 NavigationStack 以兼容独立使用；
/// 在工具箱场景下用本视图，由外层提供 NavigationStack。
struct SettingsTabContent: View {
    @ObservedObject var manager: ServerManager
    @State private var showAddSheet = false
    @State private var editingServer: ServerConfig?
    @State private var showAbout = false
    @State private var serverToDelete: ServerConfig?
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue

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
                            serverToDelete = manager.servers[offset]
                        }
                    }
                }
            }

            // MARK: - 外观
            Section {
                Picker("主题", selection: $themeRaw) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme.rawValue)
                    }
                }
            } header: {
                Text("外观")
            } footer: {
                Text("跟随系统时随设备外观自动切换")
            }

            // MARK: - 关于
            AboutSectionView(isPresented: $showAbout)
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.large)
        // navigationDestination 必须挂在 List 外，否则 lazy 容器内会被忽略
        .navigationDestination(isPresented: $showAbout) {
            AboutDetailView()
        }
        .sheet(isPresented: $showAddSheet) {
            ServerEditView(manager: manager)
        }
        .sheet(item: $editingServer) { server in
            ServerEditView(manager: manager, editing: server)
        }
        // 删除服务器前确认（会连带清除 Keychain 中的 API 密钥）
        .confirmationDialog(
            "删除服务器",
            isPresented: Binding(
                get: { serverToDelete != nil },
                set: { if !$0 { serverToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除「\(serverToDelete?.name ?? "")」", role: .destructive) {
                if let server = serverToDelete {
                    manager.remove(server)
                }
                serverToDelete = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将移除该服务器的连接配置与已保存的 API 密钥，此操作不可恢复。")
        }
    }
}
