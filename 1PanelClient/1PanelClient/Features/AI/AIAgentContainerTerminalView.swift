//
//  AIAgentContainerTerminalView.swift
//  1PanelClient
//
//  智能体容器终端（抽屉入口，抓包 2026-09-15 核对）：
//  ws /api/v2/hosts/terminal/container?source=container&containerid=<容器名>
//  &user=<...>&command=/bin/bash；用户切换在三点菜单内，切换后重开新会话。
//  可用用户按智能体类型传入：Hermes hermes/root、QwenPaw node/root
//

import SwiftUI

struct AIAgentContainerTerminalView: View {
    let server: ServerConfig
    let agentName: String
    let containerName: String
    /// 可登录用户（抓包确认：Hermes hermes/root、QwenPaw node/root）
    let users: [String]
    /// 初始用户（取该智能体抓包的默认档）
    let defaultUser: String

    @State private var user: String

    init(server: ServerConfig, agentName: String, containerName: String,
         users: [String], defaultUser: String) {
        self.server = server
        self.agentName = agentName
        self.containerName = containerName
        self.users = users
        self.defaultUser = defaultUser
        _user = State(initialValue: defaultUser)
    }

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
