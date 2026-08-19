//
//  TerminalScreen.swift
//  1PanelClient
//
//  终端界面：SwiftTerm 渲染面（原生键盘输入 + 回滚缓冲）+ 底部快捷控制键
//

import SwiftUI
import SwiftTerm

struct TerminalScreen: View {
    @StateObject private var session: TerminalSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var bridge = TerminalBridge()

    @State private var fontSize: CGFloat = 13

    /// 连接目标标题
    private let title: String

    init(server: ServerConfig, target: TerminalTarget, title: String? = nil, initialCommand: String? = nil) {
        let s = TerminalSession(server: server, target: target, initialCommand: initialCommand)
        _session = StateObject(wrappedValue: s)
        switch target {
        case .host:
            self.title = title ?? L10n.t("终端")
        case .sshHost(let id, _, _):
            self.title = title ?? L10n.t("SSH 终端")
            _ = id
        case .container(let id, _, _, _, _):
            self.title = title ?? L10n.t("容器终端")
            _ = id
        case .scriptRun:
            self.title = title ?? L10n.t("执行脚本")
        case .redis:
            self.title = title ?? L10n.t("Redis 终端")
        case .database:
            self.title = title ?? L10n.t("数据库终端")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TerminalSurface(session: session, fontSize: fontSize, bridge: bridge)
            quickKeys
        }
        .background(Color.black)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                toolbarMenu
            }
        }
        .task {
            session.connect()
        }
        .onDisappear {
            session.disconnect()
        }
    }

    // MARK: - 快捷控制键

    private var quickKeys: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                StatusDot(color: session.isConnected ? .green : (session.isConnecting ? .orange : .red), diameter: 8)
                keyButton("Ctrl+C") { sendBytes("\u{03}") }
                keyButton("Ctrl+D") { sendBytes("\u{04}") }
                keyButton("Tab") { sendBytes("\t") }
                keyButton("Esc") { sendBytes("\u{1B}") }
                keyButton("↑") { sendBytes("\u{1B}[A") }
                keyButton("↓") { sendBytes("\u{1B}[B") }
                keyButton("←") { sendBytes("\u{1B}[D") }
                keyButton("→") { sendBytes("\u{1B}[C") }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private func keyButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
        }
        .disabled(!session.isConnected)
    }

    // MARK: - 顶部菜单

    private var toolbarMenu: some View {
        Menu {
            Button(session.isConnected ? L10n.t("断开连接") : L10n.t("重新连接")) {
                if session.isConnected {
                    session.disconnect()
                } else {
                    session.connect()
                }
            }
            Button(L10n.t("放大字号")) {
                fontSize = min(fontSize + 1, 24)
            }
            Button(L10n.t("缩小字号")) {
                fontSize = max(fontSize - 1, 9)
            }
            Button(L10n.t("清屏")) {
                bridge.view?.getTerminal().softReset()
            }
            Button(L10n.t("滚动到底部")) {
                bridge.view?.scroll(toPosition: 1)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(L10n.t("更多操作"))
    }

    // MARK: - 输入

    private func sendBytes(_ s: String) {
        guard session.isConnected else { return }
        session.send(data: Data(s.utf8))
    }
}

// MARK: - 容器终端命令选择器

/// 打开容器终端前选择/输入执行命令（默认 /bin/sh、/bin/bash、/bin/ash，支持自定义）
struct TerminalCommandPicker: View {
    @Binding var command: String
    var onConnect: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let presets = ["/bin/sh", "/bin/bash", "/bin/ash"]

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.t("预设命令")) {
                    ForEach(presets, id: \.self) { (preset: String) in
                        Button {
                            command = preset
                        } label: {
                            CheckRow(title: preset, isSelected: command == preset)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section(L10n.t("自定义")) {
                    TextField(L10n.t("命令路径"), text: $command)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                }

                Section {
                    Button {
                        onConnect()
                    } label: {
                        Text(L10n.t("连接"))
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .listRowBackground(Color.clear)
            }
            .navigationTitle(L10n.t("终端命令"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("取消")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
