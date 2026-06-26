//
//  ToolboxView.swift
//  1PanelClient
//
//  工具箱入口列表：Fail2ban / WAF / 文件 等
//

import SwiftUI

struct ToolboxView: View {
    let server: ServerConfig

    var body: some View {
        List {
            NavigationLink {
                Fail2banView(server: server)
            } label: {
                toolRow(
                    icon: "shield.lefthalf.filled",
                    color: .blue,
                    title: "Fail2ban",
                    subtitle: "SSH 防暴力破解"
                )
            }

            NavigationLink {
                WAFView(server: server)
            } label: {
                toolRow(
                    icon: "flame.fill",
                    color: .red,
                    title: "WAF",
                    subtitle: "Web 应用防火墙"
                )
            }
            NavigationLink {
                FilesView(server: server)
            } label: {
                toolRow(
                    icon: "folder.fill",
                    color: .yellow,
                    title: "文件",
                    subtitle: "服务器文件管理"
                )
            }
            NavigationLink {
                SSHView(server: server)
            } label: {
                toolRow(
                    icon: "terminal.fill",
                    color: .gray,
                    title: "SSH",
                    subtitle: "SSH 服务管理"
                )
            }

            NavigationLink {
                ProcessView(server: server)
            } label: {
                toolRow(
                    icon: "chart.bar",
                    color: .pink,
                    title: "进程",
                    subtitle: "系统进程监控"
                )
            }
        }
        .navigationTitle("工具箱")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toolRow(icon: String, color: Color, title: String, subtitle: String, available: Bool = true) -> some View {
        HStack(spacing: 14) {
            IconBadge(systemName: icon, color: color, size: 38, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(available ? .primary : .secondary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !available {
                StatusBadge(text: "敬请期待", color: .secondary, backgroundOpacity: 0.1)
            }
        }
        .padding(.vertical, 2)
    }
}
