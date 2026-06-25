//
//  ManageTab.swift
//  1PanelClient
//
//  管理：分组列表聚合各功能入口，支持隐藏未使用模块
//  对齐 1Panel 官方 App 的「管理」Tab 结构
//

import SwiftUI
import Combine

struct ManageTab: View {
    @ObservedObject var manager: ServerManager
    @StateObject private var prefs = ManagePrefs()
    @State private var presentedItem: ManageItem?
    @State private var showEditSheet = false

    /// 跨 Tab 跳转入口：外部（如 OverviewTab）设置此值时，自动打开对应 fullScreen
    @Binding var initialItem: ManageItem?

    init(manager: ServerManager, initialItem: Binding<ManageItem?> = .constant(nil)) {
        self.manager = manager
        self._initialItem = initialItem
    }

    /// 所有可管理的功能项，按固定分组排列
    private var groups: [(title: String, items: [ManageItem])] {
        [
            ("",          [.apps, .websites, .database, .containers]),
            ("",          [.terminal, .process]),
            ("",          [.firewall]),
            ("",          [.cronjob])
        ]
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    if group.title.isEmpty {
                        Section {
                            ForEach(group.items) { item in
                                if prefs.isEnabled(item) {
                                    manageRow(item)
                                }
                            }
                        }
                    } else {
                        Section(group.title) {
                            ForEach(group.items) { item in
                                if prefs.isEnabled(item) {
                                    manageRow(item)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("管理")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("编辑") { showEditSheet = true }
                }
            }
            .sheet(isPresented: $showEditSheet) {
                ManageEditView(prefs: prefs)
                    .presentationDetents([.medium])
            }
        }
        .fullScreenCover(item: $presentedItem) { item in
            destination(for: item)
        }
        .onChange(of: initialItem) { _, newItem in
            guard let newItem else { return }
            // 仅 available 的项才会真正打开；其它项忽略并清空
            if newItem.available {
                presentedItem = newItem
            }
            initialItem = nil
        }
        .environmentObject(prefs)
    }

    @ViewBuilder
    private func manageRow(_ item: ManageItem) -> some View {
        Button {
            if item.available {
                presentedItem = item
            }
        } label: {
            HStack(spacing: 14) {
                IconBadge(systemName: item.icon, color: item.color, size: 38, cornerRadius: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .foregroundStyle(item.available ? .primary : .secondary)
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if item.available {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    StatusBadge(text: "敬请期待", color: .secondary, backgroundOpacity: 0.1)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.available)
    }

    /// fullScreen 目标（每个功能自带 NavigationStack）
    @ViewBuilder
    private func destination(for item: ManageItem) -> some View {
        switch item {
        case .apps:
            AppsTab(manager: manager)
        case .websites:
            WebsitesTab(manager: manager)
        case .containers:
            ContainersTab(manager: manager)
        case .cronjob:
            CronjobsTab(manager: manager)
        case .firewall:
            NavigationStack {
                FirewallView(server: manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
            }
        case .database:
            NavigationStack {
                DatabasesView(server: manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
            }
        case .terminal:
            NavigationStack {
                TerminalView(
                    server: manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""),
                    target: .host(cols: 80, rows: 24),
                    title: manager.current?.name,
                    showCloseButton: true
                )
            }
        default:
            EmptyView()
        }
    }
}

// MARK: - 编辑（显示/隐藏）视图

struct ManageEditView: View {
    @ObservedObject var prefs: ManagePrefs
    @Environment(\.dismiss) private var dismiss

    /// 与 ManageTab 保持一致的分组
    private var groups: [(title: String, items: [ManageItem])] {
        [
            ("",  [.apps, .websites, .database, .containers]),
            ("",  [.terminal, .process]),
            ("",  [.firewall]),
            ("",  [.cronjob])
        ]
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("隐藏的功能将从管理列表中移除，但不会影响服务器上的实际运行。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group.items) { item in
                            HStack(spacing: 12) {
                                IconBadge(systemName: item.icon, color: item.color, size: 34, cornerRadius: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                    Text(item.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { prefs.isEnabled(item) },
                                    set: { prefs.setEnabled($0, for: item) }
                                ))
                                .labelsHidden()
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("自定义功能")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        // sheet 里 environmentObject 会重新注入，避免与 sheet 内部新建冲突
        .environmentObject(prefs)
    }
}

// MARK: - 持久化偏好

/// 管理模块的显示/隐藏偏好，持久化到 UserDefaults
final class ManagePrefs: ObservableObject {
    @Published private(set) var disabledItems: Set<String>

    private let key = "manage.disabledItems"

    init() {
        if let raw = UserDefaults.standard.array(forKey: key) as? [String] {
            disabledItems = Set(raw)
        } else {
            disabledItems = []
        }
    }

    func isEnabled(_ item: ManageItem) -> Bool {
        !disabledItems.contains(item.rawValue)
    }

    func setEnabled(_ enabled: Bool, for item: ManageItem) {
        if enabled {
            disabledItems.remove(item.rawValue)
        } else {
            disabledItems.insert(item.rawValue)
        }
        UserDefaults.standard.set(Array(disabledItems), forKey: key)
    }
}

// MARK: - 管理项定义

/// 管理功能项（顶层枚举，供 ManageTab / ManageEditView / ManagePrefs 共用）
enum ManageItem: String, Identifiable {
    case apps
    case websites
    case database
    case containers
    case terminal
    case process
    case firewall
    case cronjob

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apps:       return "应用程序"
        case .websites:   return "网站"
        case .database:   return "数据库"
        case .containers: return "容器"
        case .terminal:   return "终端"
        case .process:    return "进程"
        case .firewall:   return "防火墙"
        case .cronjob:    return "计划任务"
        }
    }

    var subtitle: String {
        switch self {
        case .apps:       return "已安装应用 / 应用商店"
        case .websites:   return "网站 / SSL 证书"
        case .database:   return "管理数据库实例"
        case .containers: return "Docker 容器"
        case .terminal:   return "远程终端连接"
        case .process:    return "系统进程监控"
        case .firewall:   return "防火墙规则"
        case .cronjob:    return "定时备份与脚本"
        }
    }

    var icon: String {
        switch self {
        case .apps:       return "app.badge"
        case .websites:   return "globe"
        case .database:   return "cylinder"
        case .containers: return "shippingbox"
        case .terminal:   return "terminal"
        case .process:    return "chart.bar"
        case .firewall:   return "flame"
        case .cronjob:    return "clock.badge.checkmark"
        }
    }

    var color: Color {
        switch self {
        case .apps:       return .blue
        case .websites:   return .green
        case .database:   return .purple
        case .containers: return .indigo
        case .terminal:   return .black
        case .process:    return .pink
        case .firewall:   return .orange
        case .cronjob:    return .teal
        }
    }

    var available: Bool {
        switch self {
        case .apps, .websites, .containers, .terminal, .cronjob, .firewall, .database: return true
        default: return false
        }
    }
}
