//
//  SSHSessionsView.swift
//  1PanelClient
//
//  SSH 在线会话：process/ws (type=ssh) 实时列表 + 长按断开（POST /api/v2/process/stop）
//  接口见 logs/SSH服务管理.md；WS 连接复用 ProcessMonitor（会话模式）
//

import SwiftUI

struct SSHSessionsView: View {
    let server: ServerConfig

    @StateObject private var monitor: ProcessMonitor
    /// 长按弹出的断开菜单目标
    @State private var actionSession: SSHSessionItem?

    init(server: ServerConfig) {
        self.server = server
        _monitor = StateObject(wrappedValue: ProcessMonitor(server: server))
    }

    var body: some View {
        Group {
            if monitor.isConnecting && monitor.sessions.isEmpty {
                LoadingStateView()
            } else if let err = monitor.errorMessage, !err.isEmpty, monitor.sessions.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button(L10n.t("重试")) {
                        monitor.connect()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if monitor.sessions.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无会话"),
                    systemImage: "person.crop.circle.badge.checkmark",
                    description: Text(L10n.t("当前没有在线的 SSH 会话"))
                )
            } else {
                sessionList
            }
        }
        .navigationTitle(L10n.t("SSH 会话"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            monitor.mode = .sessions
            monitor.connect()
        }
        .onDisappear { monitor.disconnect() }
        .localToast(message: $monitor.successMessage)
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { monitor.errorMessage != nil && !monitor.sessions.isEmpty },
            set: { if !$0 { monitor.errorMessage = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) { monitor.errorMessage = nil }
        } message: {
            Text(monitor.errorMessage ?? "")
        }
    }

    private var sessionList: some View {
        List {
            ForEach(monitor.sessions) { session in
                SessionRow(session: session, isStopping: monitor.isStopping)
                    // 行级操作收长按菜单（断开）；simultaneousGesture 保证点击/滚动不受影响
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                            Haptic.selection()
                            actionSession = session
                        }
                    )
            }
        }
        .listStyle(.insetGrouped)
        .sheet(item: $actionSession) { session in
            ActionBottomSheet(
                title: session.displayTitle,
                items: [
                    ActionMenuItem(title: L10n.t("断开"), icon: "bolt.slash", color: .red, role: .destructive) {
                        Task { await monitor.stopSession(pid: session.pid) }
                    },
                ],
                onDismiss: { actionSession = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: 1))])
            .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - 会话列表行

private struct SessionRow: View {
    let session: SSHSessionItem
    var isStopping: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "person.fill", color: .indigo)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayTitle)
                    .font(.body.bold())
                    .lineLimit(1)
                if let time = session.loginTime, !time.isEmpty {
                    Text(time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isStopping {
                ProgressView()
            } else {
                StatusBadge(text: "PID \(session.pid)", color: .secondary, monospaced: true)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
