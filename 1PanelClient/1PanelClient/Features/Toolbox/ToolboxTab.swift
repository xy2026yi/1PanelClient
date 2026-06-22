//
//  ToolboxTab.swift
//  1PanelClient
//
//  工具箱：聚合文件管理、设置以及未来的长尾功能
//  采用九宫格入口 + NavigationLink 推进子页面的形式
//

import SwiftUI

struct ToolboxTab: View {
    @ObservedObject var manager: ServerManager

    /// 工具入口定义
    private enum ToolItem: String, CaseIterable, Identifiable {
        case files
        case settings
        case terminal
        case cronjob
        case firewall
        case database
        case ssl
        case process
        case snapshots

        var id: String { rawValue }

        var title: String {
            switch self {
            case .files:     return "文件管理"
            case .settings:  return "设置"
            case .terminal:  return "终端"
            case .cronjob:   return "计划任务"
            case .firewall:  return "防火墙"
            case .database:  return "数据库"
            case .ssl:       return "SSL 证书"
            case .process:   return "进程"
            case .snapshots: return "快照"
            }
        }

        var icon: String {
            switch self {
            case .files:     return "folder"
            case .settings:  return "gearshape"
            case .terminal:  return "terminal"
            case .cronjob:   return "clock.badge.checkmark"
            case .firewall:  return "flame"
            case .database:  return "cylinder"
            case .ssl:       return "lock.shield"
            case .process:   return "chart.bar"
            case .snapshots: return "camera.viewfinder"
            }
        }

        var color: Color {
            switch self {
            case .files:     return .blue
            case .settings:  return .gray
            case .terminal:  return .black
            case .cronjob:   return .indigo
            case .firewall:  return .orange
            case .database:  return .teal
            case .ssl:       return .green
            case .process:   return .pink
            case .snapshots: return .purple
            }
        }

        var available: Bool {
            switch self {
            case .files, .settings: return true
            default: return false
            }
        }

        var subtitle: String {
            available ? "" : "敬请期待"
        }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(ToolItem.allCases) { item in
                        toolTile(item)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
            .navigationTitle("工具箱")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    @ViewBuilder
    private func toolTile(_ item: ToolItem) -> some View {
        if item.available {
            NavigationLink {
                destination(for: item)
            } label: {
                tileContent(item)
            }
            .buttonStyle(.plain)
        } else {
            tileContent(item)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func destination(for item: ToolItem) -> some View {
        switch item {
        case .files:
            // 传入子页面的 filesRootContent 以共享外层 NavigationStack
            FilesTabContent(manager: manager)
        case .settings:
            SettingsTabContent(manager: manager)
        default:
            EmptyView()
        }
    }

    private func tileContent(_ item: ToolItem) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(item.color.opacity(item.available ? 0.15 : 0.07))
                    .frame(width: 64, height: 64)

                Image(systemName: item.icon)
                    .font(.system(size: 26))
                    .foregroundStyle(item.available ? item.color : item.color.opacity(0.5))
            }

            Text(item.title)
                .font(.caption.bold())
                .foregroundStyle(item.available ? .primary : .secondary)

            Text(item.subtitle)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .opacity(item.available ? 0 : 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemBackground))
                .opacity(item.available ? 1 : 0.5)
        )
    }
}

#Preview {
    ToolboxTab(manager: ServerManager.shared)
}
