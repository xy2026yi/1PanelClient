//
//  AIAgentHermesTerminalView.swift
//  1PanelClient
//
//  Hermes 容器终端（抓包 2026-09-15 核对）：
//  ws /api/v2/hosts/terminal/container?source=container&containerid=<容器名>
//  &user=<hermes|root>&command=/bin/bash，用户切换在三点菜单内，切换后重开新会话
//

import SwiftUI

struct AIAgentHermesTerminalView: View {
    let server: ServerConfig
    let agentName: String
    let containerName: String
    /// 抓包确认仅两档用户：hermes / root（切换即断开重连新会话）
    @State private var user: String = "hermes"

    private let users = ["hermes", "root"]

    var body: some View {
        TerminalScreen(
            server: server,
            target: .container(
                containerID: containerName,
                user: user,
                command: "/bin/bash",
                cols: 80,
                rows: 24),
            title: L10n.f("终端 · %@", agentName),
            userSwitch: TerminalUserSwitch(current: user, users: users) { u in
                selectUser(u)
            })
        // 切换用户重建终端：TerminalScreen 的会话 StateObject 只随视图身份创建一次
        .id(user)
    }

    /// 等三点菜单收起再切换（菜单可见期间重建视图会触发系统警告）；
    /// 选当前用户为空操作，避免无谓的断开重连
    private func selectUser(_ u: String) {
        guard u != user else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            user = u
        }
    }
}
