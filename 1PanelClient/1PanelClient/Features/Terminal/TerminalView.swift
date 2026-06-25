//
//  TerminalView.swift
//  1PanelClient
//
//  终端界面：渲染模拟器行缓冲 + 底部输入栏 + 快捷控制键
//

import SwiftUI

struct TerminalView: View {
    @StateObject private var session: TerminalSession
    @ObservedObject private var emulator: TerminalEmulator
    @Environment(\.dismiss) private var dismiss

    @State private var inputText = ""
    @State private var autoScroll = true
    @FocusState private var inputFocused: Bool

    /// 是否显示关闭按钮（fullScreen 模式用 true）
    var showCloseButton: Bool = false

    /// 连接目标标题
    private let title: String

    init(server: ServerConfig, target: TerminalTarget, title: String? = nil, showCloseButton: Bool = false) {
        let s = TerminalSession(server: server, target: target)
        _session = StateObject(wrappedValue: s)
        _emulator = ObservedObject(wrappedValue: s.emulator)
        self.showCloseButton = showCloseButton
        switch target {
        case .host:
            self.title = title ?? "终端"
        case .container(let id, _, _, _, _):
            self.title = title ?? "容器终端"
            _ = id
        case .scriptRun:
            self.title = title ?? "执行脚本"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            outputArea
            inputBar
        }
        .background(Color(.systemBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showCloseButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                toolbarMenu
            }
        }
        .task {
            inputFocused = false
            session.connect()
        }
        .onDisappear {
            session.disconnect()
        }
    }

    // MARK: - 输出区

    private var outputArea: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(emulator.lines.enumerated()), id: \.offset) { idx, line in
                        lineView(line)
                            .id(idx)
                    }
                    // 末尾锚点
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .background(Color.black.opacity(0.04))
            .onChange(of: emulator.revision) { _, _ in
                if autoScroll {
                    withAnimation(.none) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func lineView(_ line: TerminalLine) -> some View {
        if line.segments.isEmpty {
            Text(" ")
                .font(font)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(buildAttributedString(line))
                .font(font)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var font: Font {
        .system(size: 12, weight: .regular, design: .monospaced)
    }

    private func buildAttributedString(_ line: TerminalLine) -> AttributedString {
        var result = AttributedString()
        for seg in line.segments where !seg.text.isEmpty {
            var attr = AttributedString(seg.text)
            // 前景色
            if let fg = seg.attrs.foreground {
                attr.foregroundColor = TerminalPalette.foregroundColor(for: fg)
            } else {
                attr.foregroundColor = nil
            }
            // 加粗
            if seg.attrs.bold {
                attr.font = .system(size: 12, weight: .bold, design: .monospaced)
            }
            if seg.attrs.italic {
                attr.font = .system(size: 12, weight: seg.attrs.bold ? .bold : .regular, design: .monospaced).italic()
            }
            if seg.attrs.underline {
                attr.underlineStyle = .single
            }
            result += attr
        }
        return result
    }

    // MARK: - 输入栏

    private var inputBar: some View {
        VStack(spacing: 0) {
            quickKeys
            HStack(spacing: 8) {
                // 状态指示
                statusDot
                TextField("输入命令，回车发送", text: $inputText, axis: .horizontal)
                    .font(.system(size: 14, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit(submitInput)
                Button {
                    submitInput()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(session.isConnected ? Color.accentColor : Color.gray, in: Circle())
                }
                .disabled(!session.isConnected)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        Circle()
            .fill(session.isConnected ? Color.green : (session.isConnecting ? Color.orange : Color.red))
            .frame(width: 8, height: 8)
    }

    // MARK: - 快捷控制键

    private var quickKeys: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                keyButton("Ctrl+C") { sendSpecial("\u{03}") }
                keyButton("Ctrl+D") { sendSpecial("\u{04}") }
                keyButton("Tab") { sendSpecial("\t") }
                keyButton("Esc") { sendSpecial("\u{1B}") }
                keyButton("↑") { sendSpecial("\u{1B}[A") }
                keyButton("↓") { sendSpecial("\u{1B}[B") }
                keyButton("clear") { emulator.clear() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(.secondarySystemBackground))
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
            Button {
                if session.isConnected {
                    session.disconnect()
                } else {
                    session.connect()
                }
            } label: {
                Label(
                    session.isConnected ? "断开连接" : "重新连接",
                    systemImage: session.isConnected ? "stop.circle" : "play.circle"
                )
            }
            Button {
                emulator.clear()
            } label: {
                Label("清屏", systemImage: "trash")
            }
            Toggle("自动滚动到底部", isOn: $autoScroll)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    // MARK: - 输入提交

    private func submitInput() {
        let text = inputText
        guard !text.isEmpty else {
            // 空输入只发回车
            if session.isConnected { session.send("\r") }
            return
        }
        session.send(text + "\r")
        inputText = ""
    }

    private func sendSpecial(_ s: String) {
        guard session.isConnected else { return }
        session.send(s)
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
                Section("预设命令") {
                    ForEach(presets, id: \.self) { (preset: String) in
                        Button {
                            command = preset
                        } label: {
                            HStack {
                                Text(preset)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if command == preset {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("自定义") {
                    TextField("命令路径", text: $command)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                }

                Section {
                    Button {
                        onConnect()
                    } label: {
                        Text("连接")
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .listRowBackground(Color.clear)
            }
            .navigationTitle("终端命令")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
