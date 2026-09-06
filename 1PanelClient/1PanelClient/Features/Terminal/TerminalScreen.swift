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

    /// 终端字号持久化（放大/缩小菜单 9–24，跨会话保留）；AppStorage 不支持 CGFloat，存 Double
    @AppStorage("terminal.fontSize") private var fontSize: Double = 13

    /// 键盘与窗口底部的重叠高度（横屏下 SwiftUI 键盘安全区会残留过期的内缩，
    /// 导致快捷键条在键盘收起后仍悬浮；改为键盘通知驱动，见 body 中的处理）
    @State private var keyboardOverlap: CGFloat = 0

    /// 快速命令选择器
    @State private var showQuickCommands = false

    /// 连接目标标题
    private let title: String
    /// 终端所在服务器（快速命令按当前服务器拉取）
    private let server: ServerConfig

    init(server: ServerConfig, target: TerminalTarget, title: String? = nil, initialCommand: String? = nil) {
        let s = TerminalSession(server: server, target: target, initialCommand: initialCommand)
        _session = StateObject(wrappedValue: s)
        self.server = server
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
            TerminalSurface(session: session, fontSize: CGFloat(fontSize), bridge: bridge)
            quickKeys
        }
        // 关闭 SwiftUI 内建键盘避让，用通知算出的实际重叠高度手动上移，
        // 保证键盘收起时快捷键条始终贴底
        .padding(.bottom, keyboardOverlap)
        .ignoresSafeArea(.keyboard)
        .background(Color.black)
        .animation(Motion.standard, value: keyboardOverlap)
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
        .sheet(isPresented: $showQuickCommands) {
            QuickCommandPickerSheet(server: server) { command in
                sendCommand(command)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let window = (UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first),
                  let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
            let height = window.bounds.height
            let frame = end.cgRectValue
            // 贴底键盘（含收起动画滑出屏幕的越界帧）按其占用的底部高度上移；
            // iPad 浮动键盘不贴底（maxY < 窗口高），不遮挡快捷键条，按 0 处理
            keyboardOverlap = frame.maxY >= height - 0.5
                ? min(max(0, height - frame.minY), height)
                : 0
        }
        .onDisappear {
            session.disconnect()
        }
    }

    // MARK: - 快捷控制键

    /// 快捷键定义：readline/emacs 常用 Ctrl 组合 + 控制/导航键（Blink 辅助条的
    /// 直接组合键形态——SwiftTerm 系统键盘输入无法拦截，粘滞修饰键不可靠，故不提供）
    private struct KeyDef {
        let label: String
        let bytes: String
        /// Ctrl+字母 组合（a=0x01 … z=0x1A）
        init(_ label: String, ctrl letter: Character) {
            self.label = label
            self.bytes = String(UnicodeScalar(letter.asciiValue! & 0x1F))
        }
        init(_ label: String, _ bytes: String) {
            self.label = label
            self.bytes = bytes
        }
    }

    private var keyGroups: [[KeyDef]] {[
        [
            KeyDef("^A", ctrl: "a"), KeyDef("^C", ctrl: "c"), KeyDef("^D", ctrl: "d"),
            KeyDef("^E", ctrl: "e"), KeyDef("^K", ctrl: "k"), KeyDef("^L", ctrl: "l"),
            KeyDef("^U", ctrl: "u"), KeyDef("^W", ctrl: "w"), KeyDef("^Z", ctrl: "z"),
        ],
        [
            KeyDef("Tab", "\t"), KeyDef("Esc", "\u{1B}"),
        ],
        [
            KeyDef("←", "\u{1B}[D"), KeyDef("↑", "\u{1B}[A"),
            KeyDef("↓", "\u{1B}[B"), KeyDef("→", "\u{1B}[C"),
        ],
        [
            KeyDef("Home", "\u{1B}[H"), KeyDef("End", "\u{1B}[F"),
            KeyDef("PgUp", "\u{1B}[5~"), KeyDef("PgDn", "\u{1B}[6~"),
        ],
        [
            KeyDef("~", "~"), KeyDef("-", "-"), KeyDef("/", "/"),
        ],
    ]}

    private var quickKeys: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                StatusDot(color: session.isConnected ? .green : (session.isConnecting ? .orange : .red), diameter: 8)
                ForEach(Array(keyGroups.enumerated()), id: \.offset) { groupIndex, group in
                    if groupIndex > 0 {
                        Divider().frame(height: 18)
                    }
                    ForEach(Array(group.enumerated()), id: \.offset) { _, key in
                        keyButton(key.label) { sendBytes(key.bytes) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private func keyButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptic.selection()
            action()
        } label: {
            Text(label)
                .font(.panelScaled(12, weight: .medium, design: .monospaced))
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
            Button(L10n.t("快速命令")) {
                showQuickCommands = true
            }
            .disabled(!session.isConnected)
            Button(session.isConnected ? L10n.t("断开连接") : L10n.t("重新连接")) {
                // 等菜单完成收起再翻转连接状态：菜单可见期间 isConnected 变化
                // 会触发 UIContextMenuInteraction updateVisibleMenu 系统警告
                let shouldDisconnect = session.isConnected
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if shouldDisconnect {
                        session.disconnect()
                    } else {
                        session.connect()
                    }
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

    // MARK: - 快速命令

    /// 点击命令：作为键盘输入发送（回车立即执行），与快捷键条同通道
    private func sendCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sendBytes(trimmed + "\n")
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
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
            }
        }
        .bottomSheetDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
