//
//  TerminalEmulator.swift
//  1PanelClient
//
//  轻量 VT100/ANSI 终端模拟器
//  处理常见转义序列（SGR 颜色、光标移动、清屏/清行），维护可渲染行缓冲
//

import Foundation
import SwiftUI
import Combine

// MARK: - 文本属性

struct TerminalAttributes: Equatable {
    var foreground: Int?   // ANSI: 30-37 / 90-97 / 38(5;n)；nil=默认色
    var background: Int?
    var bold: Bool
    var italic: Bool
    var underline: Bool

    static let `default` = TerminalAttributes(
        foreground: nil, background: nil,
        bold: false, italic: false, underline: false
    )
}

struct TerminalSegment: Identifiable {
    let id = UUID()
    var text: String
    var attrs: TerminalAttributes
}

struct TerminalLine {
    var segments: [TerminalSegment]
    var dirty: Bool = true

    var isEmpty: Bool { segments.allSatisfy { $0.text.isEmpty } }
    var plainText: String { segments.map(\.text).joined() }
}

// MARK: - 颜色映射（16 色标准）

enum TerminalPalette {
    static func color(for code: Int, bright: Bool = false) -> Color {
        // 标准 8 色（30-37）与亮色（90-97）
        let idx = code
        let palette: [Color] = [
            Color(red: 0.40, green: 0.40, blue: 0.40),  // 0 黑（偏深灰，暗底可读）
            Color(red: 0.87, green: 0.25, blue: 0.25),  // 1 红
            Color(red: 0.30, green: 0.78, blue: 0.30),  // 2 绿
            Color(red: 0.85, green: 0.75, blue: 0.30),  // 3 黄
            Color(red: 0.33, green: 0.55, blue: 0.90),  // 4 蓝
            Color(red: 0.78, green: 0.40, blue: 0.85),  // 5 品红
            Color(red: 0.30, green: 0.75, blue: 0.80),  // 6 青
            Color(red: 0.85, green: 0.85, blue: 0.85)   // 7 白
        ]
        let brightPalette: [Color] = [
            Color(red: 0.55, green: 0.55, blue: 0.55),  // 8 亮黑（灰）
            Color(red: 0.98, green: 0.45, blue: 0.45),  // 9 亮红
            Color(red: 0.50, green: 0.95, blue: 0.50),  // 10 亮绿
            Color(red: 0.98, green: 0.92, blue: 0.50),  // 11 亮黄
            Color(red: 0.55, green: 0.75, blue: 1.00),  // 12 亮蓝
            Color(red: 0.95, green: 0.60, blue: 0.98),  // 13 亮品红
            Color(red: 0.50, green: 0.95, blue: 1.00),  // 14 亮青
            Color(red: 1.00, green: 1.00, blue: 1.00)   // 15 亮白
        ]
        if idx >= 0 && idx < 8 {
            return bright ? brightPalette[idx] : palette[idx]
        }
        if idx >= 8 && idx < 16 {
            return brightPalette[idx - 8]
        }
        return .primary
    }

    /// 把 ANSI 码（30-37 / 90-97）转成可读颜色
    static func foregroundColor(for code: Int) -> Color {
        if code >= 30 && code <= 37 {
            return color(for: code - 30, bright: false)
        }
        if code >= 90 && code <= 97 {
            return color(for: code - 90, bright: true)
        }
        return .primary
    }

    static func backgroundColor(for code: Int) -> Color {
        if code >= 40 && code <= 47 {
            return color(for: code - 40, bright: false).opacity(0.35)
        }
        if code >= 100 && code <= 107 {
            return color(for: code - 100, bright: true).opacity(0.35)
        }
        return .clear
    }
}

// MARK: - 终端模拟器

final class TerminalEmulator: ObservableObject {
    /// 可渲染行缓冲（供 SwiftUI 直接观察）
    @Published private(set) var lines: [TerminalLine]
    /// 输出是否产生变更（用于触发视图刷新的计数器）
    @Published var revision: Int = 0

    private(set) var cols: Int
    private(set) var rows: Int

    private var cursorRow: Int = 0
    private var cursorCol: Int = 0
    private var currentAttrs = TerminalAttributes.default
    private var scrollBackLimit = 3000

    // MARK: 解析状态机
    private enum State {
        case ground
        case esc          // 收到 ESC，等待 [ / ( / ) 等
        case csi          // ESC [
        case csiPrivate   // ESC [ ?
        case charset      // ESC ( 等
        case osc          // ESC ] 操作系统命令，以 BEL 或 ST 结束
    }
    private var state: State = .ground
    private var csiBuffer: String = ""
    private var charsetChar: Character? = nil

    init(cols: Int = 80, rows: Int = 24) {
        self.cols = cols
        self.rows = rows
        self.lines = [TerminalLine(segments: [])]
    }

    // MARK: - 尺寸

    func resize(cols: Int, rows: Int) {
        self.cols = max(cols, 1)
        self.rows = max(rows, 1)
        ensureRows()
    }

    // MARK: - 喂入数据

    func feed(_ data: Data) {
        let text = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        for char in text {
            process(char)
        }
        trimExcess()
        revision &+= 1
    }

    func feed(_ string: String) {
        for char in string {
            process(char)
        }
        trimExcess()
        revision &+= 1
    }

    // MARK: - 清空

    func clear() {
        lines = [TerminalLine(segments: [])]
        cursorRow = 0
        cursorCol = 0
        revision &+= 1
    }

    // MARK: - 行缓冲操作

    private func ensureRows() {
        while lines.count < rows {
            lines.append(TerminalLine(segments: []))
        }
    }

    private func ensureCursorRow() {
        while cursorRow >= lines.count {
            lines.append(TerminalLine(segments: []))
        }
    }

    private func currentSegmentAppend(_ char: Character) {
        ensureCursorRow()
        // 合并到末尾同属性段
        if let lastIdx = lines[cursorRow].segments.indices.last,
           lines[cursorRow].segments[lastIdx].attrs == currentAttrs {
            lines[cursorRow].segments[lastIdx].text.append(char)
        } else {
            lines[cursorRow].segments.append(
                TerminalSegment(text: String(char), attrs: currentAttrs)
            )
        }
        lines[cursorRow].dirty = true
    }

    private func putChar(_ char: Character) {
        // 软换行：到达列宽自动换行
        if cursorCol >= cols {
            cursorCol = 0
            cursorRow += 1
            ensureCursorRow()
        }
        currentSegmentAppend(char)
        cursorCol += 1
    }

    private func newline() {
        cursorCol = 0
        cursorRow += 1
        ensureCursorRow()
    }

    private func lineFeed() {
        cursorRow += 1
        ensureCursorRow()
        if cursorRow >= rows {
            scrollUp()
        }
    }

    private func carriageReturn() {
        cursorCol = 0
    }

    private func backspace() {
        if cursorCol > 0 { cursorCol -= 1 }
    }

    private func tab() {
        let next = ((cursorCol / 8) + 1) * 8
        while cursorCol < next && cursorCol < cols {
            putChar(" ")
        }
    }

    private func scrollUp() {
        if lines.count > scrollBackLimit {
            lines.removeFirst(lines.count - scrollBackLimit)
        }
        lines.removeFirst()
        cursorRow = lines.count
        ensureCursorRow()
    }

    private func trimExcess() {
        if lines.count > scrollBackLimit {
            let remove = lines.count - scrollBackLimit
            lines.removeFirst(remove)
            cursorRow = max(0, cursorRow - remove)
        }
    }

    // MARK: - 清屏 / 清行

    private func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 2:
            // 全屏清
            lines = Array(repeating: TerminalLine(segments: []), count: rows)
            cursorRow = 0
            cursorCol = 0
        case 1:
            // 从开始到光标
            for i in 0...min(cursorRow, lines.count - 1) {
                if i < cursorRow {
                    lines[i] = TerminalLine(segments: [])
                } else {
                    eraseLineFromStart(to: cursorCol)
                }
            }
        case 3:
            // 含滚动缓冲全清
            lines = [TerminalLine(segments: [])]
            cursorRow = 0
            cursorCol = 0
        default:
            // 0: 从光标到末尾
            eraseLineFromCursor()
            for i in (cursorRow + 1)..<lines.count {
                lines[i] = TerminalLine(segments: [])
            }
        }
    }

    private func eraseLine(_ mode: Int) {
        switch mode {
        case 1: eraseLineFromStart(to: cursorCol)
        case 2: lines[cursorRow] = TerminalLine(segments: [])
        default: eraseLineFromCursor()
        }
    }

    private func eraseLineFromCursor() {
        ensureCursorRow()
        var line = lines[cursorRow]
        // 精确按列删除：简化为若光标在行首则整行清
        let plain = line.plainText
        if cursorCol >= plain.count {
            return
        }
        let kept = String(plain.prefix(cursorCol))
        line = TerminalLine(segments: kept.isEmpty
            ? []
            : [TerminalSegment(text: kept, attrs: currentAttrs)])
        lines[cursorRow] = line
    }

    private func eraseLineFromStart(to col: Int) {
        ensureCursorRow()
        let plain = lines[cursorRow].plainText
        if col >= plain.count {
            lines[cursorRow] = TerminalLine(segments: [])
        } else {
            let rest = String(plain.dropFirst(col))
            lines[cursorRow] = TerminalLine(segments: [
                TerminalSegment(text: rest, attrs: currentAttrs)
            ])
        }
    }

    // MARK: - 光标移动

    private func moveCursor(row: Int, col: Int) {
        cursorRow = max(0, min(row, rows - 1))
        cursorCol = max(0, min(col, cols - 1))
        ensureCursorRow()
    }

    private func cursorUp(_ n: Int) {
        cursorRow = max(0, cursorRow - n)
    }
    private func cursorDown(_ n: Int) {
        cursorRow = min(lines.count - 1, cursorRow + n)
        ensureCursorRow()
    }
    private func cursorForward(_ n: Int) {
        cursorCol = min(cols - 1, cursorCol + n)
    }
    private func cursorBack(_ n: Int) {
        cursorCol = max(0, cursorCol - n)
    }

    // MARK: - SGR 颜色

    private func processSGR(_ params: [Int]) {
        if params.isEmpty {
            currentAttrs = .default
            return
        }
        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0:
                currentAttrs = .default
            case 1:
                currentAttrs.bold = true
            case 2:
                currentAttrs.bold = false
            case 3:
                currentAttrs.italic = true
            case 4:
                currentAttrs.underline = true
            case 22:
                currentAttrs.bold = false
            case 23:
                currentAttrs.italic = false
            case 24:
                currentAttrs.underline = false
            case 30...37:
                currentAttrs.foreground = p
            case 38:
                // 38;5;n（256 色）或 38;2;r;g;b（真彩）
                if i + 2 < params.count, params[i + 1] == 5 {
                    currentAttrs.foreground = map256(params[i + 2])
                    i += 2
                } else if i + 4 < params.count, params[i + 1] == 2 {
                    currentAttrs.foreground = mapRGB(params[i + 2], params[i + 3], params[i + 4])
                    i += 4
                }
            case 39:
                currentAttrs.foreground = nil
            case 40...47:
                currentAttrs.background = p
            case 48:
                if i + 2 < params.count, params[i + 1] == 5 {
                    currentAttrs.background = map256(params[i + 2])
                    i += 2
                } else if i + 4 < params.count, params[i + 1] == 2 {
                    currentAttrs.background = mapRGB(params[i + 2], params[i + 3], params[i + 4])
                    i += 4
                }
            case 49:
                currentAttrs.background = nil
            case 90...97:
                currentAttrs.foreground = p
            case 100...107:
                currentAttrs.background = p
            default:
                break
            }
            i += 1
        }
    }

    /// 256 色映射到 16 色近似码（存入 foreground，渲染时按区间近似取色）
    private func map256(_ n: Int) -> Int {
        // 0-15 标准/亮色，直接用高位映射回 30-37 / 90-97 区间
        if n < 8 { return 30 + n }
        if n < 16 { return 90 + (n - 8) }
        // 16-231: 6x6x6 立方体，简化为最近标准色
        return 30 + (n % 8)
    }

    /// 真彩色近似到 16 色码
    private func mapRGB(_ r: Int, _ g: Int, _ b: Int) -> Int {
        let cube: [(Int, Color)] = [
            (30, Color(red: 0.4, green: 0.4, blue: 0.4)),
            (31, Color(red: 0.87, green: 0.25, blue: 0.25)),
            (32, Color(red: 0.30, green: 0.78, blue: 0.30)),
            (33, Color(red: 0.85, green: 0.75, blue: 0.30)),
            (34, Color(red: 0.33, green: 0.55, blue: 0.90)),
            (35, Color(red: 0.78, green: 0.40, blue: 0.85)),
            (36, Color(red: 0.30, green: 0.75, blue: 0.80)),
            (37, Color(red: 0.85, green: 0.85, blue: 0.85))
        ]
        var best = 37
        var bestDist = Double.infinity
        let rd = Double(r) / 255, gd = Double(g) / 255, bd = Double(b) / 255
        for (code, c) in cube {
            let dr = Double(UIColor(c).rgba.0) - rd
            let dg = Double(UIColor(c).rgba.1) - gd
            let db = Double(UIColor(c).rgba.2) - bd
            let d = dr * dr + dg * dg + db * db
            if d < bestDist { bestDist = d; best = code }
        }
        return best
    }

    // MARK: - 主状态机

    private func process(_ char: Character) {
        switch state {
        case .ground:
            processGround(char)
        case .esc:
            processEsc(char)
        case .csi:
            processCSI(char)
        case .csiPrivate:
            processCSIPrivate(char)
        case .charset:
            // ESC ( X / ESC ) X：忽略下一个字符
            state = .ground
        case .osc:
            if char == "\u{07}" {
                state = .ground
            } else if char == "\\" {
                state = .ground
            }
        }
    }

    private func processGround(_ char: Character) {
        switch char {
        case "\u{1B}":          // ESC
            state = .esc
        case "\r":
            carriageReturn()
        case "\n", "\u{0B}", "\u{0C}":
            lineFeed()
        case "\u{08}":          // BS
            backspace()
        case "\u{09}":          // HT
            tab()
        case "\u{07}":          // BEL
            break
        default:
            putChar(char)
        }
    }

    private func processEsc(_ char: Character) {
        switch char {
        case "[":
            csiBuffer = ""
            state = .csi
        case "]":
            state = .osc
        case "(", ")", "*", "+":
            state = .charset
        case "7":
            // DEC save cursor，忽略
            state = .ground
        case "8":
            // DEC restore cursor，忽略
            state = .ground
        case "M":
            // Reverse line feed
            if cursorRow > 0 { cursorRow -= 1 }
            state = .ground
        case "D":
            lineFeed()
            state = .ground
        case "E":
            newline()
            state = .ground
        case "c":
            // RIS 重置
            clear()
            state = .ground
        default:
            state = .ground
        }
    }

    private func processCSI(_ char: Character) {
        if char == "?" {
            state = .csiPrivate
            return
        }
        // CSI 以 0x40-0x7E 的 final byte 结束
        if char.isASCII && char.asciiValue != nil {
            let v = char.asciiValue!
            if v >= 0x40 && v <= 0x7E {
                dispatchCSI(csiBuffer, final: char)
                csiBuffer = ""
                state = .ground
                return
            }
        }
        csiBuffer.append(char)
    }

    private func processCSIPrivate(_ char: Character) {
        let v = char.asciiValue ?? 0
        if v >= 0x40 && v <= 0x7E {
            // 私有序列（如 ?25h/l 光标显示、?1049h/l 备用屏幕），基本忽略
            // 备用屏幕切换：退出时简单清屏恢复主缓冲可见性
            if char == "l" && csiBuffer == "1049" {
                // 退出 alternate screen：清屏
                clear()
            } else if char == "h" && csiBuffer == "1049" {
                // 进入 alternate screen：清屏
                clear()
            }
            csiBuffer = ""
            state = .ground
            return
        }
        csiBuffer.append(char)
    }

    private func dispatchCSI(_ buf: String, final: Character) {
        // 解析参数：可能形如 "1;3" / "" / "1;3;5"
        let rawParams = buf.split(separator: ";").map { Int($0) ?? 0 }
        let params = rawParams.isEmpty ? [0] : rawParams

        switch final {
        case "m":
            processSGR(rawParams)
        case "H", "f":
            // CUP 光标定位：默认 1;1
            let row = (params.count >= 1 ? params[0] : 1) - 1
            let col = (params.count >= 2 ? params[1] : 1) - 1
            moveCursor(row: row, col: col)
        case "A":
            cursorUp(max(1, params[0]))
        case "B":
            cursorDown(max(1, params[0]))
        case "C":
            cursorForward(max(1, params[0]))
        case "D":
            cursorBack(max(1, params[0]))
        case "E":
            // CNL 光标下 n 行到行首
            cursorDown(max(1, params[0]))
            cursorCol = 0
        case "F":
            cursorUp(max(1, params[0]))
            cursorCol = 0
        case "G", "`":
            // CHA 水平绝对定位
            cursorCol = max(0, min(cols - 1, (params[0] == 0 ? 1 : params[0]) - 1))
        case "d":
            // VPA 垂直绝对定位
            cursorRow = max(0, min(rows - 1, (params[0] == 0 ? 1 : params[0]) - 1))
            ensureCursorRow()
        case "J":
            eraseInDisplay(params[0])
        case "K":
            eraseLine(params[0])
        case "P":
            // DCH 删字符（简化）
            eraseLineFromCursor()
        case "X":
            // ECH 擦字符（简化为清到行尾）
            eraseLineFromCursor()
        case "L":
            // IL 插入空行
            for _ in 0..<max(1, params[0]) {
                lines.insert(TerminalLine(segments: []), at: min(cursorRow, lines.count))
            }
        case "M":
            // DL 删行
            let n = max(1, params[0])
            for _ in 0..<n {
                if cursorRow < lines.count {
                    lines.remove(at: cursorRow)
                    lines.append(TerminalLine(segments: []))
                }
            }
        case "S":
            scrollUp()
        case "T":
            // 反向滚动，忽略
            break
        case "n":
            // DSR 设备状态报告，忽略（浏览器会回复 [R）
            break
        case "h", "l":
            // 公有模式，忽略
            break
        case "r":
            // DECSTBM 设置滚动区域，简化忽略
            break
        default:
            break
        }
    }
}

// MARK: - UIColor RGBA 辅助

private extension UIColor {
    var rgba: (CGFloat, CGFloat, CGFloat, CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }
}
