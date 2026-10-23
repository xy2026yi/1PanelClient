//
//  KVMVNCConsoleView.swift
//  1PanelClient
//
//  虚拟机 VNC 控制台（MVP）：WS /xpack/vms/console/ws?name=&operateNode=local 承载
//  裸 RFB 3.8 字节流（logs/vnc_ws_dump.txt 抓包为联调 ground truth）。
//  - 鉴权在 WS/HTTP 层（1Panel-Token，与终端同款），RFB 安全类型 None（抓包实证）；
//  - 像素格式 32bpp/24bit 真彩小端、shifts 0/8/16（逐字节对齐网页端——面板
//    代理不接受服务端原生回显；字节序 RGBA，直接落 byteOrder32Little +
//    noneSkipLast 位图，零逐像素转换）；
//  - 编码只宣告 RAW + CopyRect + DesktopSize 伪编码（服务端只能从客户端集合里选），
//    不宣告光标伪编码——qemu 会把客户机光标画进帧缓冲；压缩编码留二期；
//  - 键盘用标准 KeyEvent（keysym），QEMU 扩展键码留二期；
//  - WS 帧与 RFB 消息边界不对齐（代理按 TCP 块切分，抓包实证），必须流式拼装。
//  输入：轻点=左键、长按=右键、拖动=移动指针；捏合缩放（缩放中双指拖动平移）；
//  底部键盘栏接收英文/符号（IME 无法映射 keysym）+ 方向/功能键与粘滞修饰键。
//

import SwiftUI
import CryptoKit
import Combine

// MARK: - RFB 字节序辅助

nonisolated enum RFBBytes {
    static func be16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xff)]
    }

    static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xff),
         UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
    }

    /// 大端 u32（Data 任意切片安全：按 startIndex 寻址）
    static func u32(_ data: Data) -> UInt32? {
        guard data.count == 4 else { return nil }
        let i = data.startIndex
        return UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16
            | UInt32(data[i + 2]) << 8 | UInt32(data[i + 3])
    }
}

// MARK: - RFB 客户端消息编码（字节形状对齐抓包）

nonisolated enum RFBClientEncoder {
    /// 协议版本（抓包帧 1/2：524642203030332e3030380a）
    static func protocolVersion() -> Data { Data("RFB 003.008\n".utf8) }

    /// 选择安全类型 None=1（抓包帧 4：01）
    static func securitySelect() -> Data { Data([0x01]) }

    /// ClientInit shared=1（抓包帧 6：01）
    static func clientInit() -> Data { Data([0x01]) }

    /// SetPixelFormat：32bpp / 24bit / 小端 / 真彩 / max 255·255·255 /
    /// shifts R=0 G=8 B=16 —— 逐字节对齐网页端（dump_3/4：回显服务端原生的
    /// 16/8/0 同样合规，但面板代理只放行网页端同款，其余断线）。
    /// 该格式像素内存字节序为 R,G,B,0（RGBA）
    static func setPixelFormat() -> Data {
        Data([0x00, 0x00, 0x00, 0x00,             // 类型 0 + 3 字节填充
              0x20, 0x18, 0x00, 0x01,             // 32bpp / 24bit / 小端 / 真彩
              0x00, 0xff, 0x00, 0xff, 0x00, 0xff, // max 255·255·255
              0x00, 0x08, 0x10,                   // shifts R=0 G=8 B=16
              0x00, 0x00, 0x00])                  // 3 字节填充
    }

    /// SetEncodings：hextile(5) + RAW(0) + CopyRect(1) + 伪编码（DesktopSize/LastRect/
    /// Cursor/QEMU 扩展键/LED）。qemu 从客户端集合选，无 Tight/ZRLE 时选 hextile。
    ///
    /// ⚠️ 填充 1 字节（RFB 3.3 线上布局），不是 RFC 6143 的 2 字节——dump_1 帧 9
    /// 实证网页端按 1 字节填充发送，1Panel agent 同布局解析；按 6143 发 2 字节
    /// 填充会被读成 0 个编码并使后续字节错位、连接被静默掐断（vnc_probe2 分段
    /// 实验定位：发完 SetPixelFormat 存活、发完 SetEncodings 即死）
    static func setEncodings() -> Data {
        let encodings: [Int32] = [5, 0, 1, -223, -224, -239, -258, -261]
        var data = Data([0x02, 0x00])                     // 类型 + 1 字节填充（3.3 布局）
        data.append(contentsOf: RFBBytes.be16(UInt16(encodings.count)))
        for encoding in encodings {
            data.append(contentsOf: RFBBytes.be32(UInt32(bitPattern: encoding)))
        }
        return data
    }

    /// FramebufferUpdateRequest（抓包帧 10 全量：03000000000004000300；增量：0301…）
    static func framebufferUpdateRequest(incremental: Bool, width: Int, height: Int) -> Data {
        var data = Data([0x03, incremental ? 0x01 : 0x00])
        data.append(contentsOf: RFBBytes.be16(0))
        data.append(contentsOf: RFBBytes.be16(0))
        data.append(contentsOf: RFBBytes.be16(UInt16(width)))
        data.append(contentsOf: RFBBytes.be16(UInt16(height)))
        return data
    }

    /// PointerEvent（抓包：0500026f021c = 移动 623,540；05 01 … = 左键按下）
    static func pointerEvent(buttonMask: UInt8, x: Int, y: Int) -> Data {
        var data = Data([0x05, buttonMask])
        data.append(contentsOf: RFBBytes.be16(UInt16(x)))
        data.append(contentsOf: RFBBytes.be16(UInt16(y)))
        return data
    }

    /// 标准 KeyEvent（类型 4）
    static func keyEvent(down: Bool, keysym: UInt32) -> Data {
        var data = Data([0x04, down ? 0x01 : 0x00, 0x00, 0x00])
        data.append(contentsOf: RFBBytes.be32(keysym))
        return data
    }

    /// QEMU 扩展键盘事件（消息 0xFF，携 keysym + XT set-1 键码；需客户端宣告
    /// -258 伪编码——抓包帧 166/169：按下 'l' = ff0000010000006c00000026）。
    /// 专用键（退格/回车/方向等）走此通道，纯 keysym 在部分客户机内不生效
    static func qemuExtKeyEvent(down: Bool, keysym: UInt32, keycode: UInt32) -> Data {
        var data = Data([0xff, 0x00, 0x00, down ? 0x01 : 0x00])
        data.append(contentsOf: RFBBytes.be32(keysym))
        data.append(contentsOf: RFBBytes.be32(keycode))
        return data
    }
}

// MARK: - ServerInit 解析（抓包帧 7 样本见单测）

nonisolated struct RFBServerInit: Equatable {
    let width: Int
    let height: Int
    /// 服务端名称（如 "QEMU (teat1)"）
    let name: String

    /// 解析 ServerInit 报文（w×h + 16 字节像素格式 + u32 名称长度 + 名称）
    static func parse(_ data: Data) -> RFBServerInit? {
        // 全部按 startIndex 相对寻址：Data 切片（prefix/suffix）保留原下标，
        // 绝对位置 subdata 会取错字节（真机卡「连接中」的根因之一）
        let base = data.startIndex
        guard data.count >= 24,
              let nameLength = RFBBytes.u32(data.subdata(in: (base + 20)..<(base + 24))),
              nameLength <= 4096, data.count >= 24 + Int(nameLength) else { return nil }
        let width = Int(data[base]) << 8 | Int(data[base + 1])
        let height = Int(data[base + 2]) << 8 | Int(data[base + 3])
        let nameData = data.subdata(in: (base + 24)..<(base + 24 + Int(nameLength)))
        return RFBServerInit(width: width, height: height,
                             name: String(data: nameData, encoding: .utf8) ?? "")
    }
}

// MARK: - 服务端消息（ServerInit 之后的正常阶段）

nonisolated enum RFBServerMessage: Equatable {
    /// 一批帧更新全部落位（客户端应补发一次增量请求）
    case updateComplete
    case rawRect(x: Int, y: Int, width: Int, height: Int, pixels: Data)
    case copyRect(x: Int, y: Int, width: Int, height: Int, sourceX: Int, sourceY: Int)
    /// 分辨率变化（重置帧缓冲并补发全量请求）
    case desktopSize(width: Int, height: Int)
    case bell
    case serverCutText(String)
    /// 已消费但客户端无需处理的消息（如 SetColourMapEntries）
    case ignored
}

/// RFB 字节流 → 服务端消息。WS 帧边界与消息边界不对齐（代理按 TCP 块切分），
/// 内部缓存拼装；feed 可任意切块（单测按乱块喂入验证）
nonisolated final class RFBMessageAssembler {
    /// 首个致命错误（未知消息类型 / 未宣告的编码 / 非法长度）；出错后 feed 恒返回空。
    /// 出连接应断开
    private(set) var failure: String?

    private var buffer = Data()
    /// 当前帧更新批次剩余矩形数（跨 feed 保存）
    private var pendingRects = 0
    /// hextile 等多路径矩形完成后由 tryTakeRect 置位，feed 循环据此发 updateComplete
    private var onBatchCompleteFlag = false
    /// hextile 跨瓦片/矩形延续的前景/背景色（RFB 规定未指定时沿用上值）
    private var hextileBackground: [UInt8]?
    private var hextileForeground: [UInt8]?

    /// 复位内部缓存与批次状态（重连时调用）
    func reset() {
        buffer.removeAll()
        pendingRects = 0
        failure = nil
        onBatchCompleteFlag = false
        hextileBackground = nil
        hextileForeground = nil
    }

    /// 喂入并按序取回本段解析出的全部消息（回调式无法保证消费顺序，
    /// 出站消息顺序敏感——SetPixelFormat 必须先于帧更新请求，见 dump_3 抓包）
    func feed(_ data: Data) -> [RFBServerMessage] {
        guard failure == nil else { return [] }
        buffer.append(data)
        var messages: [RFBServerMessage] = []
        while true {
            onBatchCompleteFlag = false
            if pendingRects > 0 {
                guard let message = tryTakeRect() else { return messages }
                var isDesktopSize = false
                if case .desktopSize = message { isDesktopSize = true }
                messages.append(message)
                if isDesktopSize || pendingRects == 0 || onBatchCompleteFlag {
                    messages.append(.updateComplete)
                }
            } else if let rectCount = tryTakeUpdateHeader() {
                pendingRects = rectCount
                if rectCount == 0 { messages.append(.updateComplete) }
            } else if let message = tryTakeNormalMessage() {
                messages.append(message)
            } else {
                return messages  // 字节不足，等下一帧
            }
        }
    }

    // MARK: 内部读取（字节不足时不动缓存返回 nil）

    private func take(_ count: Int) -> Data? {
        guard buffer.count >= count else { return nil }
        let sub = buffer.subdata(in: buffer.startIndex..<(buffer.startIndex + count))
        buffer.removeFirst(count)
        return sub
    }

    private func peekU16(_ index: Int) -> Int? {
        let i = buffer.startIndex + index
        guard buffer.count > index + 1 else { return nil }
        return Int(buffer[i]) << 8 | Int(buffer[i + 1])
    }

    /// 帧更新头（类型 0 + 填充 + 矩形数）；非帧更新返回 nil（不消费字节）。
    /// 矩形数在移除头部之前读（先 take 再 peek 会读到矩形头的 x 坐标）
    private func tryTakeUpdateHeader() -> Int? {
        guard buffer.count >= 4, buffer[buffer.startIndex] == 0 else { return nil }
        let rectCount = peekU16(2) ?? 0
        _ = take(4)
        return rectCount
    }

    /// 单个矩形（12 字节头 + 按 encoding 定长负载）
    private func tryTakeRect() -> RFBServerMessage? {
        guard buffer.count >= 12 else { return nil }
        guard let x = peekU16(0), let y = peekU16(2),
              let width = peekU16(4), let height = peekU16(6),
              let e0 = peekU16(8), let e1 = peekU16(10) else { return nil }
        let encoding = Int32(bitPattern: UInt32(e0) << 16 | UInt32(e1))

        switch encoding {
        case 0:  // RAW
            let byteCount = width * height * 4
            guard width > 0, height > 0, byteCount <= 64 * 1024 * 1024 else {
                failure = String(format: "Illegal RAW rect %dx%d", width, height)
                return nil
            }
            guard let payload = take(12 + byteCount) else { return nil }
            pendingRects -= 1
            let pixels = payload.suffix(byteCount)
            return .rawRect(x: x, y: y, width: width, height: height, pixels: pixels)
        case 5:  // Hextile：16×16 瓦片，展开成 RAW 像素后按 rawRect 落位
            if let pixels = tryExpandHextile(x: x, y: y, width: width, height: height) {
                pendingRects -= 1
                if pendingRects == 0 { onBatchCompleteFlag = true }
                return .rawRect(x: x, y: y, width: width, height: height, pixels: pixels)
            }
            return nil
        case -239:  // 光标伪编码：像素 + 位掩码，仅消费（不绘制本地光标）
            let byteCount = width * height * 4 + (width + 7) / 8 * height
            guard width >= 0, height >= 0, byteCount <= 16 * 1024 * 1024,
                  let _ = take(12 + byteCount) else {
                failure = String(format: "Illegal cursor rect %dx%d", width, height)
                return nil
            }
            pendingRects -= 1
            return .ignored
        case -258, -224:  // QEMU 扩展键宣告 / LastRect：0 长度
            _ = take(12)
            pendingRects -= 1
            return .ignored
        case -261:  // QEMU LED 状态：1 字节
            guard let _ = take(13) else { return nil }
            pendingRects -= 1
            return .ignored
        case 1:  // CopyRect
            guard let payload = take(16), payload.count == 16 else { return nil }
            let sx = Int(payload[payload.startIndex + 12]) << 8 | Int(payload[payload.startIndex + 13])
            let sy = Int(payload[payload.startIndex + 14]) << 8 | Int(payload[payload.startIndex + 15])
            pendingRects -= 1
            return .copyRect(x: x, y: y, width: width, height: height, sourceX: sx, sourceY: sy)
        case -223:  // DesktopSize 伪编码
            _ = take(12)
            pendingRects = 0
            return .desktopSize(width: width, height: height)
        default:
            failure = String(format: "Unannounced encoding %d (%dx%d@%d,%d)",
                             encoding, width, height, x, y)
            return nil
        }
    }


    // MARK: Hextile 展开（peek 式：字节不足不动缓存）

    /// 瓦片流全部解析完成后一次性消费并返回展开的 RAW 像素（w*h*4）。
    /// 控制位：1=Raw瓦片 2=指定背景 4=指定前景 8=含子矩形 16=子矩形带色
    private func tryExpandHextile(x: Int, y: Int, width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, width * height <= 16 * 1024 * 1024 else {
            failure = String(format: "Illegal hextile rect %dx%d", width, height)
            return nil
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var cursor = 12  // 跳过仍在缓存中的 12 字节矩形头（peek，不消费）

        func peekByte() -> UInt8? {
            guard buffer.count > cursor else { return nil }
            return buffer[buffer.startIndex + cursor]
        }
        func peekBytes(_ count: Int) -> [UInt8]? {
            guard buffer.count >= cursor + count else { return nil }
            return [UInt8](buffer[(buffer.startIndex + cursor)..<(buffer.startIndex + cursor + count)])
        }

        for tileY in 0..<((height + 15) / 16) {
            for tileX in 0..<((width + 15) / 16) {
                let tileWidth = min(16, width - tileX * 16)
                let tileHeight = min(16, height - tileY * 16)
                guard let control = peekByte() else { return nil }
                cursor += 1
                let offset = (tileY * 16 * width + tileX * 16) * 4

                if control & 0x01 != 0 {  // Raw 瓦片
                    guard let raw = peekBytes(tileWidth * tileHeight * 4) else { return nil }
                    cursor += raw.count
                    for row in 0..<tileHeight {
                        let source = row * tileWidth * 4
                        let target = offset + row * width * 4
                        pixels.replaceSubrange(target..<(target + tileWidth * 4),
                                               with: raw[source..<(source + tileWidth * 4)])
                    }
                    continue
                }
                if control & 0x02 != 0 {
                    guard let bg = peekBytes(4) else { return nil }
                    cursor += 4
                    hextileBackground = bg
                }
                if control & 0x04 != 0 {
                    guard let fg = peekBytes(4) else { return nil }
                    cursor += 4
                    hextileForeground = fg
                }
                guard let background = hextileBackground else {
                    failure = "Hextile background unspecified"
                    return nil
                }
                // 填背景
                for row in 0..<tileHeight {
                    let target = offset + row * width * 4
                    for column in 0..<tileWidth {
                        pixels.replaceSubrange((target + column * 4)..<(target + column * 4 + 4),
                                               with: background)
                    }
                }
                if control & 0x08 != 0 {
                    guard let count = peekByte() else { return nil }
                    cursor += 1
                    for _ in 0..<count {
                        var color = hextileForeground ?? background
                        if control & 0x10 != 0 {
                            guard let pixelColor = peekBytes(4) else { return nil }
                            cursor += 4
                            color = pixelColor
                        }
                        guard let xywh = peekBytes(2) else { return nil }
                        cursor += 2
                        let sx = Int(xywh[0] >> 4), sy = Int(xywh[0] & 0x0f)
                        let sw = Int(xywh[1] >> 4) + 1, sh = Int(xywh[1] & 0x0f) + 1
                        for row in sy..<min(sy + sh, tileHeight) {
                            let base = offset + row * width * 4
                            for column in sx..<min(sx + sw, tileWidth) {
                                pixels.replaceSubrange((base + column * 4)..<(base + column * 4 + 4),
                                                       with: color)
                            }
                        }
                    }
                }
            }
        }
        guard take(cursor) != nil else { return nil }  // 矩形头 + 瓦片流一次性消费
        return Data(pixels)
    }

    /// 帧更新之外的普通消息（Bell / ServerCutText / SetColourMapEntries）
    private func tryTakeNormalMessage() -> RFBServerMessage? {
        guard let type = buffer.first else { return nil }
        switch type {
        case 1:  // SetColourMapEntries：填充 2 + first 2 + count 2 + count*6
            guard let count = peekU16(4) else { return nil }
            guard take(6 + count * 6) != nil else { return nil }
            return .ignored
        case 2:  // Bell
            _ = take(1)
            return .bell
        case 3:  // ServerCutText：填充 3 + s32 长度 + 文本。
            // 负长度 = qemu 剪贴板扩展帧（dump_1 实证 -8/8 字节），取绝对值消费
            guard buffer.count >= 8,
                  let raw = RFBBytes.u32(buffer.subdata(
                    in: (buffer.startIndex + 4)..<(buffer.startIndex + 8))) else { return nil }
            let signed = Int32(bitPattern: raw)
            let length = signed < 0 ? Int(-signed) : Int(signed)
            guard length <= 1_048_576, let text = take(8 + length) else {
                if length > 1_048_576 { failure = "ServerCutText too long: \(length)" }
                return nil
            }
            return .serverCutText(String(data: text.suffix(length), encoding: .utf8) ?? "")
        default:
            failure = String(format: "Unknown message type %d", type)
            return nil
        }
    }
}

// MARK: - 帧缓冲（BGRA 32bpp）

/// 客户端像素格式（网页端同款 shifts 0/8/16 小端）下，像素内存字节序为
/// R,G,B,0（RGBA），CGImage 用 byteOrder32Little + noneSkipLast 零转换成像
nonisolated final class RFBFramebuffer {
    private(set) var width: Int
    private(set) var height: Int
    /// RGBA 逐行存储（按服务端送达字节序原样落位）
    private(set) var pixels: [UInt8]

    init(width: Int, height: Int) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        pixels = [UInt8](repeating: 0, count: self.width * self.height * 4)
    }

    /// RAW 矩形落位（越界部分裁剪——服务端贴边矩形可能越帧缘）
    func applyRaw(x: Int, y: Int, width: Int, height: Int, pixels: Data) {
        guard pixels.count >= width * height * 4 else { return }
        let copyWidth = min(width, self.width - x)
        let copyHeight = min(height, self.height - y)
        guard copyWidth > 0, copyHeight > 0, x >= 0, y >= 0 else { return }
        pixels.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            for row in 0..<copyHeight {
                let sourceOffset = row * width * 4
                let targetStart = ((y + row) * self.width + x) * 4
                self.pixels.replaceSubrange(targetStart..<(targetStart + copyWidth * 4),
                    with: source[sourceOffset..<(sourceOffset + copyWidth * 4)]
                        .bindMemory(to: UInt8.self))
            }
        }
    }

    /// CopyRect：帧内区域搬移（源与目标可能重叠，先拷出再写回）
    func applyCopyRect(x: Int, y: Int, width: Int, height: Int, sourceX: Int, sourceY: Int) {
        let copyWidth = min(width, self.width - x, self.width - sourceX)
        let copyHeight = min(height, self.height - y, self.height - sourceY)
        guard copyWidth > 0, copyHeight > 0, x >= 0, y >= 0, sourceX >= 0, sourceY >= 0 else { return }
        var staging = [UInt8](repeating: 0, count: copyWidth * copyHeight * 4)
        for row in 0..<copyHeight {
            let sourceStart = ((sourceY + row) * self.width + sourceX) * 4
            staging.replaceSubrange((row * copyWidth * 4)..<((row + 1) * copyWidth * 4),
                                    with: pixels[sourceStart..<(sourceStart + copyWidth * 4)])
        }
        for row in 0..<copyHeight {
            let targetStart = ((y + row) * self.width + x) * 4
            pixels.replaceSubrange(targetStart..<(targetStart + copyWidth * 4),
                                    with: staging[(row * copyWidth * 4)..<((row + 1) * copyWidth * 4)])
        }
    }

    /// 分辨率变化：重置（内容未定义，清黑）
    func resize(width: Int, height: Int) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        pixels = [UInt8](repeating: 0, count: self.width * self.height * 4)
    }

    /// 指定坐标像素（R,G,B,0 四字节；单测用）
    func pixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8)? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let start = (y * width + x) * 4
        return (pixels[start], pixels[start + 1], pixels[start + 2], pixels[start + 3])
    }

    /// 当前帧成像（像素拷贝一份供 CGImage 持有）
    func makeImage() -> CGImage? {
        var copy = pixels
        return copy.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let base = buffer.baseAddress else { return nil }
            guard let context = CGContext(
                data: base, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
            return context.makeImage()
        }
    }
}

// MARK: - X11 keysym

nonisolated enum RFBKeysym {
    static let backspace: UInt32 = 0xff08
    static let tab: UInt32 = 0xff09
    static let enter: UInt32 = 0xff0d
    static let escape: UInt32 = 0xff1b
    static let delete: UInt32 = 0xffff
    static let left: UInt32 = 0xff51
    static let up: UInt32 = 0xff52
    static let right: UInt32 = 0xff53
    static let down: UInt32 = 0xff54
    static let shift: UInt32 = 0xffe1
    static let control: UInt32 = 0xffe3
    static let alt: UInt32 = 0xffe9

    /// XT set-1 键码（QEMU 扩展键盘事件用；专用键与修饰键，
    /// 网页端抓包实证该通道：'l' 的键码 0x26）。E0 前缀键（方向/Delete）
    /// 置高位 0x80——QEMU 按高位识别 E0 前缀（noVNC 同款表：← 0xCB/↑ 0xC8/
    /// → 0xCD/↓ 0xD0/Del 0xD3），不带高位是数字小键区键，受 NumLock 影响
    static func keycode(for keysym: UInt32) -> UInt32? {
        switch keysym {
        case escape: return 0x01
        case backspace: return 0x0e
        case tab: return 0x0f
        case enter: return 0x1c
        case control: return 0x1d
        case shift: return 0x2a
        case alt: return 0x38
        case RFBKeysym.delete: return 0xd3  // Delete（抓包未覆盖，按 noVNC XT 表）
        case left: return 0xcb
        case up: return 0xc8
        case right: return 0xcd
        case down: return 0xd0
        default: return nil
        }
    }

    /// 字符 → keysym：Latin-1 区间（0x20...0xff）码点即 keysym；
    /// 换行归一为 Return；中文 / emoji 等 IME 字符无法映射返回 nil
    static func keysym(for character: Character) -> UInt32? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return nil
        }
        if scalar == "\n" || scalar == "\r" { return enter }
        let value = scalar.value
        return (0x20...0xff).contains(value) ? value : nil
    }
}

// MARK: - VNC 会话

@MainActor
final class KVMVNCSession: ObservableObject {
    enum ConnectionState: Equatable {
        case idle, connecting, connected
        case failed(String)
    }

    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var framebufferImage: CGImage?
    @Published private(set) var framebufferSize: CGSize = .zero
    @Published private(set) var serverName: String = ""
    /// 收到的帧更新批次数（状态条显示）
    @Published private(set) var updateBatches = 0
    /// 已接收字节（握手诊断：卡「连接中」时可判断服务端是否回话）
    @Published private(set) var receivedBytes = 0

    let server: ServerConfig
    let vmName: String

    private var task: URLSessionWebSocketTask?
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = .infinity
        config.timeoutIntervalForResource = .infinity
        return URLSession(configuration: config)
    }()
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var framebuffer: RFBFramebuffer?
    private let assembler = RFBMessageAssembler()
    /// 握手阶段字节缓存（版本 → 安全类型 → 结果 → ServerInit）
    private var handshakeBuffer = [UInt8]()
    private enum HandshakePhase { case version, securityTypes, securityResult, serverInit, normal }
    private var handshakePhase: HandshakePhase = .version
    private var generation = 0

    init(server: ServerConfig, vmName: String) {
        self.server = server
        self.vmName = vmName
    }

    deinit {
        receiveTask?.cancel()
        pingTask?.cancel()
        watchdogTask?.cancel()
        outboundTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: 连接（鉴权与 URL 构造与终端同款）

    func connect() async {
        guard state != .connecting, state != .connected else { return }
        state = .connecting
        handshakePhase = .version
        handshakeBuffer = []
        assembler.reset()
        framebuffer = nil
        framebufferImage = nil
        updateBatches = 0
        receivedBytes = 0

        generation += 1
        receiveTask?.cancel()
        pingTask?.cancel()
        watchdogTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        outbound.removeAll()

        // 对齐网页端流程：先 POST console {name} 挂起 qemu VNC 会话再开 WS
        //（抓包中网页端开 WS 前必调；结果仅作启动引导，失败不阻断——继续试 WS）
        let client = APIClient.shared(for: server)
        _ = try? await client.send(path: APIEndpoint.kvmConsole.path,
                                   body: KVMNameRequest(name: vmName),
                                   as: KVMGraphics.self)

        guard generation == self.generation else { return }  // 期间已断开/重连
        guard let url = makeWebSocketURL() else {
            fail(L10n.t("无法构造控制台连接地址"))
            return
        }
        var request = URLRequest(url: url)
        for (k, v) in authHeaders() {
            request.setValue(v, forHTTPHeaderField: k)
        }
        // 浏览器身份头（网页端 WS 升级携带 Origin；代理可能校验）
        request.setValue(server.normalizedBaseURL, forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) "
                         + "AppleWebKit/605.1.15 (KHTML, like Gecko)", forHTTPHeaderField: "User-Agent")

        let gen = generation
        let ws = urlSession.webSocketTask(with: request)
        // 全屏 RAW 更新一帧可达数 MB（1024×768×4≈3MB），默认 1MB 上限会把连接打死
        ws.maximumMessageSize = 64 * 1024 * 1024
        ws.resume()
        task = ws
        receiveTask = Task { [weak self] in await self?.receiveLoop(gen: gen) }
        pingTask = Task { [weak self] in await self?.pingLoop(gen: gen) }
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, gen == self.generation, self.state == .connecting else { return }
            self.fail(L10n.t("控制台连接超时，请重试；若持续失败请在面板网页端打开控制台确认虚拟机已在运行"))
        }
    }

    func disconnect() {
        generation += 1
        receiveTask?.cancel()
        pingTask?.cancel()
        watchdogTask?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        state = .idle
    }

    private func makeWebSocketURL() -> URL? {
        guard var comp = URLComponents(string: server.normalizedBaseURL) else { return nil }
        comp.scheme = comp.scheme == "https" ? "wss" : "ws"
        comp.path = "/api/v2/xpack/vms/console/ws"
        comp.queryItems = [
            URLQueryItem(name: "name", value: vmName),
            URLQueryItem(name: "operateNode", value: "local"),
        ]
        return comp.url
    }

    private func authHeaders() -> [String: String] {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let raw = "1panel" + server.apiKey + timestamp
        let digest = Insecure.MD5.hash(data: Data(raw.utf8))
        let token = digest.map { String(format: "%02x", $0) }.joined()
        return ["1Panel-Token": token, "1Panel-Timestamp": timestamp]
    }

    // MARK: 接收循环

    private func receiveLoop(gen: Int) async {
        guard let task else { return }
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                guard gen == self.generation else { return }
                guard case .data(let data) = message else { continue }  // VNC 只有二进制帧
                ingest(data)
            } catch {
                guard gen == self.generation, !Task.isCancelled else { return }
                fail(L10n.f("连接已断开：%@", error.localizedDescription))
                return
            }
        }
    }

    private func pingLoop(gen: Int) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            guard gen == self.generation, let task else { break }
            task.sendPing { [weak self] error in
                guard error != nil else { return }
                Task { @MainActor in
                    guard gen == self?.generation else { return }
                    self?.fail(L10n.t("连接已断开"))
                }
            }
        }
    }

    // MARK: 握手与消息分发

    /// 握手用 [UInt8] 而非 Data：Data.removeFirst 不重置 startIndex，
    /// 逐段消费后绝对位置 subdata 会取错字节（真机卡「连接中」根因）
    private func ingest(_ data: Data) {
        receivedBytes += data.count
        switch handshakePhase {
        case .version:
            handshakeBuffer.append(contentsOf: data)
            guard handshakeBuffer.count >= 12 else { return }
            let version = [UInt8](handshakeBuffer.prefix(12))
            handshakeBuffer.removeFirst(12)
            guard version.starts(with: Array("RFB ".utf8)) else {
                fail(L10n.f("非 RFB 协议：%@", String(decoding: version, as: UTF8.self)))
                return
            }
            send(RFBClientEncoder.protocolVersion())
            handshakePhase = .securityTypes
            continueHandshake()

        case .securityTypes:
            handshakeBuffer.append(contentsOf: data)
            guard let typeCount = handshakeBuffer.first else { return }
            if typeCount == 0 {
                // 0 = 失败：u32 原因长度 + 文本
                guard let length = u32(at: 1) else { return }
                guard handshakeBuffer.count >= 5 + Int(length) else { return }
                let reason = String(decoding: handshakeBuffer[5..<(5 + Int(length))], as: UTF8.self)
                fail(L10n.f("服务端拒绝连接：%@", reason))
                return
            }
            guard handshakeBuffer.count >= 1 + Int(typeCount) else { return }
            // 抓包实证类型集合为 [1]=None；直接选 None
            handshakeBuffer.removeFirst(1 + Int(typeCount))
            send(RFBClientEncoder.securitySelect())
            handshakePhase = .securityResult
            continueHandshake()

        case .securityResult:
            handshakeBuffer.append(contentsOf: data)
            guard let result = u32(at: 0) else { return }
            handshakeBuffer.removeFirst(4)
            guard result == 0 else {
                fail(L10n.t("VNC 安全握手失败"))
                return
            }
            send(RFBClientEncoder.clientInit())
            handshakePhase = .serverInit
            continueHandshake()

        case .serverInit:
            handshakeBuffer.append(contentsOf: data)
            guard handshakeBuffer.count >= 24, let nameLength = u32(at: 20) else { return }
            let total = 24 + Int(nameLength)
            guard handshakeBuffer.count >= total else { return }
            let payload = Data(handshakeBuffer.prefix(total))
            handshakeBuffer.removeFirst(total)
            guard let serverInit = RFBServerInit.parse(payload) else {
                fail(L10n.t("ServerInit 解析失败"))
                return
            }
            serverName = serverInit.name
            framebufferSize = CGSize(width: serverInit.width, height: serverInit.height)
            framebuffer = RFBFramebuffer(width: serverInit.width, height: serverInit.height)

            // 客户端格式 + 编码集 + 首次全量请求（顺序对齐网页端）
            send(RFBClientEncoder.setPixelFormat())
            send(RFBClientEncoder.setEncodings())
            send(RFBClientEncoder.framebufferUpdateRequest(
                incremental: false, width: serverInit.width, height: serverInit.height))

            handshakePhase = .normal
            state = .connected
            if !handshakeBuffer.isEmpty {
                // ServerInit 之后可能紧跟首批更新，直接进入正常阶段消费
                for message in assembler.feed(Data(handshakeBuffer)) {
                    handle(message)
                }
                handshakeBuffer.removeAll()
                if let reason = assembler.failure {
                    fail(reason)
                }
            }

        case .normal:
            for message in assembler.feed(data) {
                handle(message)
            }
            if let reason = assembler.failure {
                fail(reason)
            }
        }
    }

    /// 缓冲内偏移处的大端 u32（不足 4 字节返回 nil）
    private func u32(at offset: Int) -> UInt32? {
        guard handshakeBuffer.count >= offset + 4 else { return nil }
        let b = handshakeBuffer
        return UInt32(b[offset]) << 24 | UInt32(b[offset + 1]) << 16
            | UInt32(b[offset + 2]) << 8 | UInt32(b[offset + 3])
    }

    /// 握手各阶段缓冲里可能已带后续报文，原地继续消费
    private func continueHandshake() {
        guard !handshakeBuffer.isEmpty else { return }
        let buffered = Data(handshakeBuffer)
        handshakeBuffer.removeAll()
        ingest(buffered)
    }

    private func handle(_ message: RFBServerMessage) {
        switch message {
        case .rawRect(let x, let y, let width, let height, let pixels):
            framebuffer?.applyRaw(x: x, y: y, width: width, height: height, pixels: pixels)
        case .copyRect(let x, let y, let width, let height, let sx, let sy):
            framebuffer?.applyCopyRect(x: x, y: y, width: width, height: height,
                                       sourceX: sx, sourceY: sy)
        case .desktopSize(let width, let height):
            // 同尺寸（-308 能力宣告矩形）不重建帧缓冲，避免闪屏
            guard width != Int(framebufferSize.width) || height != Int(framebufferSize.height) else {
                return
            }
            framebuffer?.resize(width: width, height: height)
            framebufferSize = CGSize(width: width, height: height)
            send(RFBClientEncoder.framebufferUpdateRequest(
                incremental: false, width: width, height: height))
        case .updateComplete:
            updateBatches += 1
            if let image = framebuffer?.makeImage() {
                framebufferImage = image
            }
            // 请求下一批增量（QEMU 有变化才回包；连接存活交给 ping）
            if let fb = framebuffer {
                send(RFBClientEncoder.framebufferUpdateRequest(
                    incremental: true, width: fb.width, height: fb.height))
            }
        case .bell:
            Haptic.selection()
        case .serverCutText, .ignored:
            break  // 客户机剪贴板不回填（二期可写系统剪贴板）
        }
    }

    // MARK: 输入出口

    func sendPointer(buttonMask: UInt8, x: Int, y: Int) {
        send(RFBClientEncoder.pointerEvent(buttonMask: buttonMask, x: x, y: y))
    }

    /// 带修饰的按键：先按下激活修饰，再击键，最后逆序释放修饰。
    /// keycode 非 nil 时走 QEMU 扩展键盘事件（专用键必需，纯 keysym 在部分
    /// 客户机不生效——⌫/回车实测无效即此因），否则标准 KeyEvent
    func sendKey(keysym: UInt32, keycode: UInt32? = nil, modifiers: [UInt32] = []) {
        func press(_ keysym: UInt32, _ down: Bool) {
            if let keycode {
                send(RFBClientEncoder.qemuExtKeyEvent(down: down, keysym: keysym, keycode: keycode))
            } else {
                send(RFBClientEncoder.keyEvent(down: down, keysym: keysym))
            }
        }
        for modifier in modifiers where modifier != keysym {
            send(RFBClientEncoder.keyEvent(down: true, keysym: modifier))
        }
        press(keysym, true)
        press(keysym, false)
        for modifier in modifiers.reversed() where modifier != keysym {
            send(RFBClientEncoder.keyEvent(down: false, keysym: modifier))
        }
    }

    /// 文本输入逐字符转 keysym（不可映射字符忽略；修饰随字符发送）
    func sendText(_ text: String, modifiers: [UInt32] = []) {
        for character in text {
            if let keysym = RFBKeysym.keysym(for: character) {
                sendKey(keysym: keysym, modifiers: modifiers)
            }
        }
    }

    /// 出站消息串行队列：全部经同一 drain 任务按序发出。
    /// fire-and-forget 各起 Task 会竞速乱序（dump_3 抓包：SetPixelFormat 晚于
    /// 帧更新请求到达，qemu 判协议违序 ABNORMAL_CLOSURE）
    private var outbound: [Data] = []
    private var outboundTask: Task<Void, Never>?

    private func send(_ data: Data) {
        outbound.append(data)
        guard outboundTask == nil else { return }
        outboundTask = Task { [weak self] in
            while let self {
                guard !self.outbound.isEmpty else { break }
                guard let task = self.task else { self.outbound.removeAll(); break }
                let next = self.outbound.removeFirst()
                try? await task.send(.data(next))
            }
            self?.outboundTask = nil
        }
    }

    private func fail(_ reason: String) {
        guard state != .idle else { return }
        generation += 1
        receiveTask?.cancel()
        pingTask?.cancel()
        watchdogTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        outbound.removeAll()
        task = nil
        state = .failed(reason)
    }
}

// MARK: - 控制台视图

struct KVMVNCConsoleView: View {
    @StateObject private var console: KVMVNCSession

    /// 画面显示缩放（1 = 适配屏宽；捏合 1...4 倍）
    @State private var displayScale: CGFloat = 1
    @State private var fitScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var isPinching = false
    @State private var lastPinchValue: CGFloat = 1
    @State private var isKeyboardVisible = false
    @State private var keyboardInput = ""
    @FocusState private var keyboardFocused: Bool
    // 粘滞修饰（随下一次击键发送并自动复位）
    @State private var ctrlOn = false
    @State private var altOn = false
    @State private var shiftOn = false

    init(server: ServerConfig, machineName: String) {
        _console = StateObject(wrappedValue: KVMVNCSession(server: server, vmName: machineName))
    }

    private var activeModifiers: [UInt32] {
        var modifiers: [UInt32] = []
        if ctrlOn { modifiers.append(RFBKeysym.control) }
        if altOn { modifiers.append(RFBKeysym.alt) }
        if shiftOn { modifiers.append(RFBKeysym.shift) }
        return modifiers
    }

    var body: some View {
        VStack(spacing: 0) {
            consoleArea
            if isKeyboardVisible { keyboardBar }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(L10n.t("虚拟机控制台"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isKeyboardVisible.toggle()
                    keyboardFocused = isKeyboardVisible
                } label: {
                    Image(systemName: "keyboard")
                }
                .accessibilityLabel(L10n.t("键盘"))
            }
        }
        .task { await console.connect() }
        .onDisappear { console.disconnect() }
    }

    // MARK: 画面区

    @State private var panAnchor: CGSize = .zero
    @State private var lastContainerSize: CGSize = .zero
    @State private var lastPointerLocation: CGPoint = .zero

    private var consoleArea: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black

                if let image = console.framebufferImage {
                    Image(uiImage: UIImage(cgImage: image))
                        .interpolation(.none)
                        .scaleEffect(displayScale)
                        .offset(offset)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .allowsHitTesting(false)
                } else if case .failed = console.state {
                    EmptyView()  // 失败态由状态条呈现
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(L10n.t("连接中…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // 输入层：固定容器坐标系（不受画面缩放/平移变换影响，
                // 视图坐标 → 帧缓冲坐标统一走 framebufferPoint）
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                lastPointerLocation = value.location
                                if isPinching {
                                    // 捏合进行中（双指）→ 平移画面
                                    offset = CGSize(
                                        width: offset.width + value.translation.width - panAnchor.width,
                                        height: offset.height + value.translation.height - panAnchor.height)
                                    panAnchor = value.translation
                                } else if console.state == .connected {
                                    movePointer(to: value.location, in: geo.size)
                                }
                            }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                if !isPinching { isPinching = true; panAnchor = .zero }
                                let ratio = value / lastPinchValue
                                lastPinchValue = value
                                displayScale = min(max(displayScale * ratio, fitScale), 5)
                            }
                            .onEnded { _ in
                                isPinching = false
                                lastPinchValue = 1
                                clampOffset(in: geo.size)
                            }
                    )
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                            rightClickLast()
                        }
                    )
                    .onTapGesture {
                        tapLast()
                    }

                statusBar
            }
            .onAppear { refit(in: geo.size) }
            .onChange(of: geo.size) { _, _ in refit(in: geo.size) }
            .onChange(of: console.framebufferSize) { _, _ in
                refit(in: geo.size)
            }
        }
    }

    /// 适配缩放（画面 → 容器内完整显示的最小比例）；不打断进行中的捏合
    private func refit(in container: CGSize) {
        lastContainerSize = container
        guard console.framebufferSize.width > 0, container.width > 0 else { return }
        fitScale = min(container.width / console.framebufferSize.width,
                       container.height / console.framebufferSize.height)
        guard !isPinching else { return }
        if displayScale < fitScale || offset == .zero {
            displayScale = fitScale
            offset = .zero
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            switch console.state {
            case .idle:
                EmptyView()
            case .connecting:
                ProgressView().scaleEffect(0.7)
                if console.receivedBytes > 0 {
                    Text(L10n.f("连接中… 已收 %ld 字节", console.receivedBytes))
                } else {
                    Text(L10n.t("连接中…"))
                }
            case .connected:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(console.serverName.isEmpty ? L10n.t("已连接") : console.serverName)
                    .lineLimit(1)
                Spacer()
                Text("\(Int(console.framebufferSize.width))×\(Int(console.framebufferSize.height))")
                    .monospacedDigit()
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(reason).lineLimit(2)
                Spacer()
                Button(L10n.t("重连")) { Task { await console.connect() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .allowsHitTesting(console.state != .connected)
    }

    // MARK: 坐标换算与点击

    /// 视图坐标 → 帧缓冲像素坐标（画面以 position 居中 + scaleEffect + offset 呈现）
    private func framebufferPoint(at location: CGPoint, in container: CGSize) -> (x: Int, y: Int)? {
        guard console.framebufferSize.width > 0, displayScale > 0 else { return nil }
        let imageX = (location.x - container.width / 2 - offset.width) / displayScale
        let imageY = (location.y - container.height / 2 - offset.height) / displayScale
        guard imageX >= 0, imageY >= 0,
              imageX < console.framebufferSize.width,
              imageY < console.framebufferSize.height else { return nil }
        return (Int(imageX), Int(imageY))
    }

    private func movePointer(to location: CGPoint, in container: CGSize) {
        guard let point = framebufferPoint(at: location, in: container) else { return }
        console.sendPointer(buttonMask: 0, x: point.x, y: point.y)
    }

    private func tapLast() {
        guard let point = framebufferPoint(at: lastPointerLocation, in: lastContainerSize) else { return }
        console.sendPointer(buttonMask: 0, x: point.x, y: point.y)
        console.sendPointer(buttonMask: 1, x: point.x, y: point.y)  // 左键按下
        console.sendPointer(buttonMask: 0, x: point.x, y: point.y)
    }

    private func rightClickLast() {
        guard let point = framebufferPoint(at: lastPointerLocation, in: lastContainerSize) else { return }
        Haptic.selection()
        console.sendPointer(buttonMask: 0, x: point.x, y: point.y)
        console.sendPointer(buttonMask: 4, x: point.x, y: point.y)  // 右键按下
        console.sendPointer(buttonMask: 0, x: point.x, y: point.y)
    }

    private func clampOffset(in container: CGSize) {
        guard console.framebufferSize.width > 0 else { return }
        let maxX = max(0, (console.framebufferSize.width * displayScale - container.width) / 2)
        let maxY = max(0, (console.framebufferSize.height * displayScale - container.height) / 2)
        offset = CGSize(width: min(max(offset.width, -maxX), maxX),
                        height: min(max(offset.height, -maxY), maxY))
    }

    // MARK: 键盘栏

    private var keyboardBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // 组合缓冲：逐字符显示，按键即转发（只发增量——编辑/删除不回发）；
                // 键盘回车 = 发送 Enter 并清空；IME 中文/emoji 无法映射 keysym，
                // 入缓冲但不转发（占位注明仅英文与符号）
                TextField(L10n.t("键盘输入（仅英文与符号）"), text: $keyboardInput)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($keyboardFocused)
                    .submitLabel(.send)
                    .onChange(of: keyboardInput) { previous, current in
                        let commonLength = zip(previous, current).prefix { $0.0 == $0.1 }.count
                        let appended = String(current.dropFirst(min(commonLength, current.count)))
                        if !appended.isEmpty {
                            console.sendText(appended, modifiers: activeModifiers)
                            resetModifiers()
                        }
                    }
                    .onSubmit { sendEnterFromKeyboard() }
                if !keyboardInput.isEmpty {
                    Button {
                        keyboardInput = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.t("清空"))
                }
                Button {
                    sendEnterFromKeyboard()
                } label: {
                    Image(systemName: "return")
                }
                .buttonStyle(.bordered)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    stickyModifier("Ctrl", keysym: RFBKeysym.control, isOn: $ctrlOn)
                    stickyModifier("Alt", keysym: RFBKeysym.alt, isOn: $altOn)
                    stickyModifier("Shift", keysym: RFBKeysym.shift, isOn: $shiftOn)
                    specialKey("Esc", keysym: RFBKeysym.escape)
                    specialKey("Tab", keysym: RFBKeysym.tab)
                    specialKey("←", keysym: RFBKeysym.left)
                    specialKey("↑", keysym: RFBKeysym.up)
                    specialKey("↓", keysym: RFBKeysym.down)
                    specialKey("→", keysym: RFBKeysym.right)
                    specialKey("⌫", keysym: RFBKeysym.backspace)
                    specialKey("Del", keysym: RFBKeysym.delete)
                }
                .padding(.horizontal, 2)
            }
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .background(.regularMaterial)
    }

    /// 键盘回车 / 回车按钮：发送 Enter（QEMU 扩展键码）并清空组合缓冲
    private func sendEnterFromKeyboard() {
        console.sendKey(keysym: RFBKeysym.enter,
                        keycode: RFBKeysym.keycode(for: RFBKeysym.enter),
                        modifiers: activeModifiers)
        resetModifiers()
        keyboardInput = ""
    }

    private func stickyModifier(_ label: String, keysym: UInt32, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            Haptic.selection()
        } label: {
            Text(label)
                .font(.caption.weight(isOn.wrappedValue ? .bold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isOn.wrappedValue ? Color.accentColor.opacity(0.25)
                                               : Color.secondary.opacity(0.12),
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func specialKey(_ label: String, keysym: UInt32) -> some View {
        Button {
            console.sendKey(keysym: keysym,
                            keycode: RFBKeysym.keycode(for: keysym),
                            modifiers: activeModifiers)
            resetModifiers()
        } label: {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func resetModifiers() {
        ctrlOn = false
        altOn = false
        shiftOn = false
    }
}
