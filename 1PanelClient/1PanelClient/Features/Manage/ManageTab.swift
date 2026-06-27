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
    @State private var navPath = NavigationPath()
    @State private var showEditSheet = false

    /// 跨 Tab 跳转入口：外部（如 OverviewTab）设置此值时，自动 push 到对应页面
    @Binding var initialItem: ManageItem?
    /// 向 MainTabView 同步导航深度：true=根列表，false=子页面（隐藏 Tab 栏）
    @Binding var atRoot: Bool

    init(manager: ServerManager, initialItem: Binding<ManageItem?> = .constant(nil), atRoot: Binding<Bool> = .constant(true)) {
        self.manager = manager
        self._initialItem = initialItem
        self._atRoot = atRoot
    }

    /// 所有可管理的功能项，按固定分组排列
    private var groups: [(title: String, items: [ManageItem])] {
        [
            ("",          [.apps, .websites, .database, .containers]),
            ("",          [.terminal, .firewall, .toolbox, .cronjob])
        ]
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            List {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group.items) { item in
                            if prefs.isEnabled(item) {
                                manageRow(item)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        showEditSheet = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("编辑")
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ManageItem.self) { item in
                destination(for: item)
            }
            .sheet(isPresented: $showEditSheet) {
                ManageEditView(prefs: prefs)
                    .presentationDetents([.medium])
            }
        }
        .onChange(of: initialItem) { _, newItem in
            guard let newItem else { return }
            if newItem.available {
                navPath.append(newItem)
            }
            initialItem = nil
        }
        .onChange(of: navPath.count) { _, count in
            atRoot = count == 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .popAppDetail)) { _ in
            // 收到通知后 pop 最后一个元素（AppInstall），回到应用列表
            if !navPath.isEmpty { navPath.removeLast() }
        }
        .environmentObject(prefs)
    }

    @ViewBuilder
    private func manageRow(_ item: ManageItem) -> some View {
        NavigationLink(value: item) {
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

                if !item.available {
                    StatusBadge(text: "敬请期待", color: .secondary, backgroundOpacity: 0.1)
                }
            }
            .padding(.vertical, 2)
        }
        .disabled(!item.available)
    }

    /// push 目标（由外层 NavigationStack 提供导航栏与返回按钮）
    @ViewBuilder
    private func destination(for item: ManageItem) -> some View {
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        switch item {
        case .apps:
            AppsTab(manager: manager, showCloseButton: false, standalone: false)
                .environment(\.popDetail, {
                    if !navPath.isEmpty { navPath.removeLast() }
                })
        case .websites:
            WebsitesTab(manager: manager, showCloseButton: false, standalone: false)
        case .containers:
            ContainersTab(manager: manager, showCloseButton: false, standalone: false)
        case .cronjob:
            CronjobsTab(manager: manager, showCloseButton: false, standalone: false)
        case .firewall:
            FirewallView(server: server)
        case .database:
            DatabasesView(server: server)
        case .terminal:
            TerminalView(
                server: server,
                target: .host(cols: 80, rows: 24),
                title: manager.current?.name,
                showCloseButton: false
            )
        case .process:
            ProcessView(server: server)
        case .toolbox:
            ToolboxView(server: server)
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
            ("",  [.terminal, .firewall, .toolbox, .cronjob])
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
    case toolbox

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
        case .toolbox:    return "工具箱"
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
        case .toolbox:    return "Fail2ban 等系统工具"
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
        case .toolbox:    return "wrench.and.screwdriver"
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
        case .toolbox:    return .brown
        }
    }

    var available: Bool {
        switch self {
        case .apps, .websites, .containers, .terminal, .cronjob, .firewall, .database, .process, .toolbox: return true
        default: return false
        }
    }
}
