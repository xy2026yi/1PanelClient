//
//  ManageTab.swift
//  1PanelClient
//
//  管理：以列表形式聚合应用、网站、容器、计划任务等功能入口
//  对齐 1Panel 官方 App 的「管理」Tab 结构
//

import SwiftUI

struct ManageTab: View {
    @ObservedObject var manager: ServerManager
    @State private var presentedItem: ManageItem?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    manageRow(.apps)
                    manageRow(.websites)
                }

                Section {
                    manageRow(.containers)
                    manageRow(.cronjob)
                }

                Section {
                    manageRow(.database)
                    manageRow(.terminal)
                    manageRow(.firewall)
                    manageRow(.process)
                }
            }
            .navigationTitle("管理")
            .navigationBarTitleDisplayMode(.large)
        }
        .fullScreenCover(item: $presentedItem) { item in
            destination(for: item)
        }
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
        }
        .buttonStyle(.plain)
        .disabled(!item.available)
    }

    /// fullScreen 目标（每个功能自带 NavigationStack）
    @ViewBuilder
    private func destination(for item: ManageItem) -> some View {
        switch item {
        case .apps:
            UnifiedAppsTab(manager: manager)
        case .websites:
            UnifiedWebsitesTab(manager: manager)
        case .containers:
            ContainersTab(manager: manager)
        case .cronjob:
            CronjobsTab(manager: manager)
        default:
            EmptyView()
        }
    }
}

// MARK: - 管理项定义

extension ManageTab {
    enum ManageItem: String, Identifiable {
        case apps
        case websites
        case containers
        case cronjob
        case database
        case terminal
        case firewall
        case process

        var id: String { rawValue }

        var title: String {
            switch self {
            case .apps:       return "应用"
            case .websites:   return "网站"
            case .containers: return "容器"
            case .cronjob:    return "计划任务"
            case .database:   return "数据库"
            case .terminal:   return "终端"
            case .firewall:   return "防火墙"
            case .process:    return "进程"
            }
        }

        var subtitle: String {
            switch self {
            case .apps:       return "已安装应用 / 应用商店"
            case .websites:   return "网站 / SSL 证书"
            case .containers: return "Docker 容器"
            case .cronjob:    return "定时备份与脚本"
            case .database:   return "管理数据库实例"
            case .terminal:   return "远程终端连接"
            case .firewall:   return "防火墙规则"
            case .process:    return "系统进程监控"
            }
        }

        var icon: String {
            switch self {
            case .apps:       return "app.badge"
            case .websites:   return "globe"
            case .containers: return "shippingbox"
            case .cronjob:    return "clock.badge.checkmark"
            case .database:   return "cylinder"
            case .terminal:   return "terminal"
            case .firewall:   return "flame"
            case .process:    return "chart.bar"
            }
        }

        var color: Color {
            switch self {
            case .apps:       return .blue
            case .websites:   return .green
            case .containers: return .indigo
            case .cronjob:    return .teal
            case .database:   return .purple
            case .terminal:   return .black
            case .firewall:   return .orange
            case .process:    return .pink
            }
        }

        var available: Bool {
            switch self {
            case .apps, .websites, .containers, .cronjob: return true
            default: return false
            }
        }
    }
}
