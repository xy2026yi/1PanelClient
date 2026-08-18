//
//  TerminalSurface.swift
//  1PanelClient
//
//  SwiftTerm 渲染面：桥接 TerminalSession（WebSocket 字节流）与 SwiftTerm 的
//  UIKit TerminalView（完整 VT 引擎 + 原生键盘输入 + 回滚缓冲）。
//  iOS 版 TerminalView 在自身 layoutSubviews 中完成行列重算，无需外部干预
//

import SwiftUI
import Combine
import SwiftTerm

// MARK: - 桥（SwiftUI 侧操作底层终端用）

@MainActor
final class TerminalBridge: ObservableObject {
    weak var view: SwiftTerm.TerminalView?
}

// MARK: - UIViewRepresentable

struct TerminalSurface: UIViewRepresentable {
    @ObservedObject var session: TerminalSession
    var fontSize: CGFloat
    let bridge: TerminalBridge

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let tv = SwiftTerm.TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        tv.backgroundColor = .black
        tv.nativeForegroundColor = .white
        tv.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        bridge.view = tv
        session.onOutput = { [weak tv] data in
            tv?.feed(byteArray: ArraySlice([UInt8](data)))
        }
        return tv
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        if uiView.font.pointSize != fontSize {
            uiView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
    }

    func dismantleUIView(_ uiView: SwiftTerm.TerminalView, coordinator: Coordinator) {
        session.onOutput = nil
        bridge.view = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    // MARK: - 终端事件 → WebSocket

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: TerminalSession

        init(session: TerminalSession) {
            self.session = session
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            session.send(data: Data(data))
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            // 布局变化 → 通知远端 PTY 调整尺寸
            session.sendResize(cols: newCols, rows: newRows)
        }

        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}

        func bell(source: SwiftTerm.TerminalView) {}

        /// OSC 52 剪贴板写入（远程 tmux/vim 复制到本机剪贴板）
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
        }

        /// OSC 52 读取请求默认拒绝，避免远程程序静默读走本机剪贴板
        func clipboardRead(source: SwiftTerm.TerminalView) -> Data? { nil }

        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}

        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
