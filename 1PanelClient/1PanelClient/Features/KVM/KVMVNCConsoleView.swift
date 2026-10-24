//
//  KVMVNCConsoleView.swift
//  1PanelClient
//
//  虚拟机 VNC 控制台：WS /xpack/vms/console/ws?name=&operateNode= 承载
//  裸 RFB 3.8 字节流（logs/vnc_ws_dump*.txt 抓包为联调 ground truth）。
//  - 鉴权在 WS/HTTP 层（1Panel-Token，与终端同款），RFB 安全类型 None（抓包实证）；
//  - 像素格式 32bpp/24bit 真彩小端、shifts 0/8/16（逐字节对齐网页端）；像素值经
//    面板代理后按大端落字节，内存序 [pad,B,G,R]，CGImage 用 byteOrder32Little +
//    noneSkipLast 位图零逐像素转换（探针实证：该组合读内存为 X,B,G,R）；
//  - 编码宣告 Tight + hextile + RAW + CopyRect + 伪编码（DesktopSize/LastRect/
//    Cursor/QEMU 扩展键/LED）；Tight 支持-fill/copy/palette/gradient 过滤器与
//    4 条持久 zlib 流（不宣告质量等级与 TightPNG，故无 JPEG/PNG 矩形）；
//  - 光标伪编码本地渲染（cirrus-vga 由模拟器画进帧缓冲，virtio 系显卡走 -239）；
//  - 键盘：文本走标准 KeyEvent（keysym），专用键/修饰走 QEMU 扩展键事件
//    （XT set-1 键码）；iPad 外接键盘经 .onKeyPress 接管；
//  - 输入：轻点=左键、长按=右键、拖动=移动指针；拖拽模式下按下-移动-释放=
//    左键拖动；双指滚动=滚轮（UIKit 2 指手势，±3% 内不视为捏合）；
//    捏合缩放（缩放中双指拖动平移）；底部键盘栏含修饰键与功能键。
//  - WS 帧与 RFB 消息边界不对齐（代理按 TCP 块切分，抓包实证），必须流式拼装。
//

import SwiftUI
import CryptoKit
import Combine
import Compression

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

    /// SetEncodings：Tight(7) + hextile(5) + RAW(0) + CopyRect(1) + 伪编码
    /// （DesktopSize/LastRect/Cursor/QEMU 扩展键/LED）。qemu 逆向遍历编码表、
    /// 列表首个帧编码胜出（vnc.c set_encodings 注释实证），故 Tight 放首位；
    /// 不宣告质量等级（-32..-23）与 TightPNG(-260)，qemu 不会发 JPEG/PNG 矩形。
    ///
    /// ⚠️ 填充 1 字节（RFB 3.3 线上布局），不是 RFC 6143 的 2 字节——dump_1 帧 9
    /// 实证网页端按 1 字节填充发送，1Panel agent 同布局解析；按 6143 发 2 字节
    /// 填充会被读成 0 个编码并使后续字节错位、连接被静默掐断（vnc_probe2 分段
    /// 实验定位：发完 SetPixelFormat 存活、发完 SetEncodings 即死）
    static func setEncodings() -> Data {
        let encodings: [Int32] = [7, 5, 0, 1, -223, -224, -239, -258, -261]
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

    /// ClientCutText（类型 6）：发送 iOS 剪贴板文本给客户机。qemu 侧需 vdagent
    /// 才会落到客户机剪贴板（无代理则静默忽略，无害）
    static func clientCutText(_ text: String) -> Data {
        let bytes = Array(text.utf8)
        var data = Data([0x06, 0x00, 0x00, 0x00])
        data.append(contentsOf: RFBBytes.be32(UInt32(bytes.count)))
        data.append(contentsOf: bytes)
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
    /// 光标形状（热区 = 矩形坐标 x,y；0 尺寸 = 隐藏光标）
    case cursor(hotX: Int, hotY: Int, width: Int, height: Int, pixels: Data, mask: Data)
    case bell
    case serverCutText(String)
    /// 已消费但客户端无需处理的消息（如 SetColourMapEntries）
    case ignored
}

// MARK: - Tight zlib 持久解压流

/// Tight 的 zlib 流跨矩形复用（同流字典续压，qemu 每段 Z_SYNC_FLUSH、无 adler）。
/// Apple COMPRESSION_ZLIB 实为裸 DEFLATE（探针实证：编码产物无 RFC1950 头、
/// 需跳 2 字节头后解压），故每条流首次使用跳过对端的 2 字节 zlib 头；
/// 重置位到达时重置流并重新跳头。多余输入（同步刷新尾）留存流内续用
nonisolated final class TightZlibStream {
    private var stream = compression_stream(
        dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0,
        state: nil)
    private var active = false
    private var skippedHeader = false
    /// 上轮未消费输入（Z_SYNC_FLUSH 尾等），续入下个矩形
    private var pending = [UInt8]()

    init?() {
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else { return nil }
        active = true
    }

    deinit {
        if active { compression_stream_destroy(&stream) }
    }

    /// 服务端控制字节重置位：重置流（下个 blob 重新带头）
    func reset() {
        guard active else { return }
        compression_stream_destroy(&stream)
        _ = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        pending.removeAll()
        skippedHeader = false
    }

    /// 喂入一个矩形的压缩数据，产出恰好 outputSize 字节。
    /// 输入不足或损坏返回 nil；多余输入留存流内
    func inflate(_ input: [UInt8], outputSize: Int) -> [UInt8]? {
        guard active else { return nil }
        guard outputSize > 0 else { return [] }
        pending.append(contentsOf: input)
        if !skippedHeader {
            guard pending.count >= 2 else { return nil }
            pending.removeFirst(2)
            skippedHeader = true
        }
        var output = [UInt8](repeating: 0, count: outputSize)
        var produced = 0
        var consumed = 0
        var failed = false
        var exhausted = false

        pending.withUnsafeMutableBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                while produced < outputSize {
                    stream.src_ptr = UnsafePointer(inputBuffer.baseAddress! + consumed)
                    stream.src_size = inputBuffer.count - consumed
                    stream.dst_ptr = outputBuffer.baseAddress! + produced
                    stream.dst_size = outputBuffer.count - produced
                    let status = compression_stream_process(&stream, 0)
                    consumed = inputBuffer.count - stream.src_size
                    produced = outputBuffer.count - stream.dst_size
                    if status == COMPRESSION_STATUS_ERROR { failed = true; return }
                    if stream.src_size == 0, produced < outputSize { exhausted = true; return }
                }
            }
        }
        if failed || exhausted || produced < outputSize { return nil }
        pending.removeFirst(consumed)
        return output
    }
}

// MARK: - RFB 字节流拼装

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
    /// Tight 的 4 条持久 zlib 流（同流字典跨矩形续压；qemu 实证 stream0=copy/
    /// 1=mono/2=palette/3=gradient），惰性创建
    private var tightStreams: [TightZlibStream?] = [nil, nil, nil, nil]

    /// 复位内部缓存与批次状态（重连时调用）
    func reset() {
        buffer.removeAll()
        pendingRects = 0
        failure = nil
        onBatchCompleteFlag = false
        hextileBackground = nil
        hextileForeground = nil
        tightStreams = [nil, nil, nil, nil]
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
        case 7:  // Tight：qemu 首选编码（fill/copy/palette/gradient + 持久 zlib 流）
            if let message = tryTakeTightRect(x: x, y: y, width: width, height: height) {
                pendingRects -= 1
                return message
            }
            return nil
        case -239:  // 光标伪编码：w*h*4 像素 + 位掩码，本地渲染（热区 = 矩形坐标）
            let byteCount = width * height * 4 + (width + 7) / 8 * height
            guard byteCount <= 16 * 1024 * 1024, let payload = take(12 + byteCount) else {
                if byteCount > 16 * 1024 * 1024 {
                    failure = String(format: "Illegal cursor rect %dx%d", width, height)
                }
                return nil  // 字节不足：等待，不置失败
            }
            pendingRects -= 1
            let body = payload.suffix(byteCount)
            return .cursor(hotX: x, hotY: y, width: width, height: height,
                           pixels: body.prefix(width * height * 4),
                           mask: body.suffix((width + 7) / 8 * height))
        case -258:  // QEMU 扩展键宣告回执：0 尺寸矩形（正常参与计数）
            _ = take(12)
            pendingRects -= 1
            return .ignored
        case -224:  // LastRect：服务端提前结束本批——矩形数清零（noVNC 同款；
            // qemu 实际按真实计数发送、不用 LastRect，此为 TightVNC 系服务端兼容）
            _ = take(12)
            pendingRects = 0
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

    // MARK: Tight 解码（协议布局经 noVNC tight.js / qemu vnc-enc-tight.c / 抓包三方实证）

    /// 控制字节：低 4 位 = 4 条 zlib 流的重置位；高半字节：
    /// 0x08 fill（后随 3 字节 RGB）｜0x09 JPEG｜0x0A PNG｜否则 basic——
    /// bit2 = 显式过滤器字节（0 copy / 1 palette / 2 gradient），bit0-1 = zlib 流号。
    /// 压缩数据前置紧凑长度（压缩后字节数，7bit/字节续位编码，第 3 字节全 8 位）；
    /// 未压缩数据 < 12 字节时直发不压缩（qemu VNC_TIGHT_MIN_TO_COMPRESS）。
    /// 像素数据为 24bit RGB 三元组（tight_pack24 按 shift 取值，与端序无关），
    /// 展开为帧缓冲字节序 [pad,B,G,R]（与 hextile/RAW 原样落位一致）
    private func tryTakeTightRect(x: Int, y: Int, width: Int, height: Int) -> RFBServerMessage? {
        guard width > 0, height > 0, width * height <= 16 * 1024 * 1024 else {
            failure = String(format: "Illegal tight rect %dx%d", width, height)
            return nil
        }
        var cursor = 12  // 矩形头仍在缓存中（peek，不消费）
        func peekByte() -> UInt8? {
            guard buffer.count > cursor else { return nil }
            defer { cursor += 1 }
            return buffer[buffer.startIndex + cursor]
        }
        func peekBytes(_ count: Int) -> [UInt8]? {
            guard buffer.count >= cursor + count else { return nil }
            defer { cursor += count }
            return [UInt8](buffer[(buffer.startIndex + cursor)..<(buffer.startIndex + cursor + count)])
        }
        /// 紧凑长度（压缩后大小）：b&0x7f 逐字节 7bit，0x80 续位；第 3 字节全 8 位
        func peekCompactLength() -> Int? {
            guard let b0 = peekByte() else { return nil }
            var length = Int(b0 & 0x7f)
            if b0 & 0x80 != 0 {
                guard let b1 = peekByte() else { return nil }
                length |= Int(b1 & 0x7f) << 7
                if b1 & 0x80 != 0 {
                    guard let b2 = peekByte() else { return nil }
                    length |= Int(b2) << 14
                }
            }
            guard length <= 64 * 1024 * 1024 else {
                failure = "Tight blob too long: \(length)"
                return nil
            }
            return length
        }

        guard let control = peekByte() else { return nil }
        for i in 0..<4 where (control >> i) & 1 == 1 { tightStreams[i]?.reset() }
        let high = control >> 4

        // RGB 三元组 → 帧缓冲 4 字节（[pad,B,G,R]，与 hextile/RAW 送达序一致）
        func framebufferPixels(rgb: [UInt8]) -> Data {
            var pixels = [UInt8](repeating: 0, count: rgb.count / 3 * 4)
            for i in 0..<(rgb.count / 3) {
                pixels[i * 4] = 0
                pixels[i * 4 + 1] = rgb[i * 3 + 2]
                pixels[i * 4 + 2] = rgb[i * 3 + 1]
                pixels[i * 4 + 3] = rgb[i * 3]
            }
            return Data(pixels)
        }

        if high == 0x08 {  // fill：纯色矩形（3 字节 RGB）
            guard let rgb = peekBytes(3) else { return nil }
            guard take(cursor) != nil else { return nil }
            var repeated = [UInt8]()
            repeated.reserveCapacity(width * height * 3)
            for _ in 0..<(width * height) { repeated.append(contentsOf: rgb) }
            let pixels = framebufferPixels(rgb: repeated)
            return .rawRect(x: x, y: y, width: width, height: height, pixels: pixels)
        }
        guard high & 0x08 == 0 else {
            // 0x09 JPEG / 0x0A PNG：未宣告质量等级与 TightPNG，不应出现
            failure = String(format: "Unexpected tight type %#04x (JPEG/PNG not announced)", control)
            return nil
        }
        let streamIndex = Int(high & 0x03)
        var filter: UInt8 = 0
        if high & 0x04 != 0 {
            guard let f = peekByte() else { return nil }
            filter = f
        }
        /// 过滤器数据：≥ 12 字节走 zlib（紧凑长度 + 压缩块），否则直发
        func peekFilterData(uncompressedSize: Int) -> [UInt8]? {
            if uncompressedSize < 12 { return peekBytes(uncompressedSize) }
            guard let compressedLength = peekCompactLength() else { return nil }
            guard let blob = peekBytes(compressedLength) else { return nil }
            guard let stream = tightStream(at: streamIndex) else { return nil }
            guard let data = stream.inflate(blob, outputSize: uncompressedSize) else {
                failure = "Tight zlib inflate failed (stream \(streamIndex))"
                return nil
            }
            return data
        }

        var pixels: Data
        switch filter {
        case 0, 2:  // copy / gradient：w*h*3 RGB（gradient 为 delta 预测编码）
            let uncompressedSize = width * height * 3
            guard var data = peekFilterData(uncompressedSize: uncompressedSize) else { return nil }
            if filter == 2 { data = Self.decodeGradient(data, width: width, height: height) }
            pixels = framebufferPixels(rgb: data)
        case 1:  // palette：1 字节数量-1 + 数量×3 RGB 调色板 + 索引（≤2 色 1bpp，否则 8bpp）
            guard let colorByte = peekByte() else { return nil }
            let colors = Int(colorByte) + 1
            guard let palette = peekBytes(colors * 3) else { return nil }
            let bitsPerPixel = colors <= 2 ? 1 : 8
            let rowBytes = (width * bitsPerPixel + 7) / 8
            guard let indices = peekFilterData(uncompressedSize: rowBytes * height) else { return nil }
            var rgb = [UInt8](repeating: 0, count: width * height * 3)
            for row in 0..<height {
                for column in 0..<width {
                    let index: Int
                    if bitsPerPixel == 1 {
                        index = Int(indices[row * rowBytes + column / 8] >> (7 - column % 8) & 1)
                    } else {
                        index = Int(indices[row * width + column])
                    }
                    for c in 0..<3 {
                        rgb[(row * width + column) * 3 + c] = palette[index * 3 + c]
                    }
                }
            }
            pixels = framebufferPixels(rgb: rgb)
        default:
            failure = "Illegal tight filter \(filter)"
            return nil
        }
        guard take(cursor) != nil else { return nil }
        return .rawRect(x: x, y: y, width: width, height: height, pixels: pixels)
    }

    /// 惰性取用/创建 Tight zlib 流
    private func tightStream(at index: Int) -> TightZlibStream? {
        if let stream = tightStreams[index] { return stream }
        guard let stream = TightZlibStream() else {
            failure = "zlib stream init failed"
            return nil
        }
        tightStreams[index] = stream
        return stream
    }

    /// gradient 过滤器还原（noVNC _gradientFilter 逐式移植，输出改为 3 字节/像素）：
    /// 首行左预测，其余行 clamp(左 + 上 - 左上)，delta 按字节回绕加
    static func decodeGradient(_ data: [UInt8], width: Int, height: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: width * height * 3)
        var dataIndex = 0
        var left = [UInt8](repeating: 0, count: 3)
        for column in 0..<width {
            for c in 0..<3 {
                let value = data[dataIndex] &+ left[c]
                output[column * 3 + c] = value
                left[c] = value
                dataIndex += 1
            }
        }
        for row in 1..<height {
            left = [0, 0, 0]
            var upperLeft = [UInt8](repeating: 0, count: 3)
            let upperRow = (row - 1) * width * 3
            for column in 0..<width {
                for c in 0..<3 {
                    let upper = output[upperRow + column * 3 + c]
                    let prediction = min(255, max(0, Int(left[c]) + Int(upper) - Int(upperLeft[c])))
                    let value = data[dataIndex] &+ UInt8(prediction)
                    output[row * width * 3 + column * 3 + c] = value
                    upperLeft[c] = upper
                    left[c] = value
                    dataIndex += 1
                }
            }
        }
        return output
    }

    /// 帧更新之外的普通消息（Bell / ServerCutText / SetColourMapEntries）。
    /// 类型 0 属帧更新头（由 tryTakeUpdateHeader 处理）——字节不足时此处须等待
    /// 而非报错（窄 WS 帧可使 FBU 头跨帧截断，逐字节喂入单测实证）
    private func tryTakeNormalMessage() -> RFBServerMessage? {
        guard let type = buffer.first, type != 0 else { return nil }
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

// MARK: - 帧缓冲（像素值大端落字节：[pad,B,G,R]）

/// 客户端像素格式（网页端同款 shifts 0/8/16）下像素值经面板代理后按大端落字节，
/// 内存序 [pad,B,G,R]，CGImage 用 byteOrder32Little + noneSkipLast 零转换成像
///（探针实证：该组合读内存为 X,B,G,R）。Tight 展开亦产出同序
nonisolated final class RFBFramebuffer {
    private(set) var width: Int
    private(set) var height: Int
    /// 逐行存储，字节序与送达原样一致（[pad,B,G,R]）
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

    /// 指定坐标像素（按送达原样 4 字节；单测用）
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
    static let home: UInt32 = 0xff50
    static let end: UInt32 = 0xff57
    static let pageUp: UInt32 = 0xff55   // Prior
    static let pageDown: UInt32 = 0xff56  // Next
    static let insert: UInt32 = 0xff63
    static let shift: UInt32 = 0xffe1
    static let control: UInt32 = 0xffe3
    static let alt: UInt32 = 0xffe9
    static let superKey: UInt32 = 0xffeb  // Super_L（Win 键）
    static let capsLock: UInt32 = 0xffe5
    static let space: UInt32 = 0x20
    static let f1: UInt32 = 0xffbe
    static let f2: UInt32 = 0xffbf
    static let f3: UInt32 = 0xffc0
    static let f4: UInt32 = 0xffc1
    static let f5: UInt32 = 0xffc2
    static let f6: UInt32 = 0xffc3
    static let f7: UInt32 = 0xffc4
    static let f8: UInt32 = 0xffc5
    static let f9: UInt32 = 0xffc6
    static let f10: UInt32 = 0xffc7
    static let f11: UInt32 = 0xffc8
    static let f12: UInt32 = 0xffc9

    /// XT set-1 键码（QEMU 扩展键盘事件用；网页端抓包实证该通道：'l' 键码 0x26）。
    /// E0 前缀键（方向/Delete/Home/End/PgUp/PgDn/Ins/Win）置高位 0x80——QEMU 按
    /// 高位识别 E0 前缀（noVNC 同款表：← 0xCB/↑ 0xC8/→ 0xCD/↓ 0xD0/Del 0xD3/
    /// Home 0xC7/End 0xCF/PgUp 0xC9/PgDn 0xD1/Ins 0xD2/Win 0xDB），
    /// 不带高位是小键区键，受 NumLock 影响
    static func keycode(for keysym: UInt32) -> UInt32? {
        switch keysym {
        case escape: return 0x01
        case backspace: return 0x0e
        case tab: return 0x0f
        case enter: return 0x1c
        case control: return 0x1d
        case shift: return 0x2a
        case alt: return 0x38
        case superKey: return 0xdb
        case capsLock: return 0x3a
        case home: return 0xc7
        case end: return 0xcf
        case pageUp: return 0xc9
        case pageDown: return 0xd1
        case insert: return 0xd2
        case RFBKeysym.delete: return 0xd3  // Delete（抓包未覆盖，按 noVNC XT 表）
        case left: return 0xcb
        case up: return 0xc8
        case right: return 0xcd
        case down: return 0xd0
        case f1: return 0x3b
        case f2: return 0x3c
        case f3: return 0x3d
        case f4: return 0x3e
        case f5: return 0x3f
        case f6: return 0x40
        case f7: return 0x41
        case f8: return 0x42
        case f9: return 0x43
        case f10: return 0x44
        case f11: return 0x57
        case f12: return 0x58
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

/// 本地渲染的光标形状（-239 伪编码下发；热区随指针位置叠加显示）
struct VNCursorShape {
    let image: CGImage
    let hotX: Int
    let hotY: Int
}

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
    /// 光标形状（nil = 无下发/隐藏；cirrus-vga 不下发，virtio 系显卡走此通道）
    @Published private(set) var cursor: VNCursorShape?
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
        // 跟随多机管理切换的当前节点（与终端 WS 同款；REST 侧 APIClient 自动附带）
        comp.queryItems = [
            URLQueryItem(name: "name", value: vmName),
            URLQueryItem(name: "operateNode", value: NodeScope.current(for: server.id) ?? "local"),
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
            // 同尺寸不重建帧缓冲（防御性：避免无谓闪屏）
            guard width != Int(framebufferSize.width) || height != Int(framebufferSize.height) else {
                return
            }
            framebuffer?.resize(width: width, height: height)
            framebufferSize = CGSize(width: width, height: height)
            send(RFBClientEncoder.framebufferUpdateRequest(
                incremental: false, width: width, height: height))
        case .cursor(let hotX, let hotY, let width, let height, let pixels, let mask):
            cursor = Self.makeCursor(hotX: hotX, hotY: hotY, width: width, height: height,
                                     pixels: pixels, mask: mask)
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
        case .serverCutText(let text):
            // 客户机剪贴板 → 系统剪贴板（qemu 仅在扩展剪贴板协商后下发，多为休眠路径）
            if !text.isEmpty { UIPasteboard.general.string = text }
        case .ignored:
            break
        }
    }

    /// 光标像素（帧缓冲同序 [pad,B,G,R]）+ 位掩码（1 = 透明）→ 带 alpha 的 CGImage。
    /// premultipliedLast（默认字节序）内存即 R,G,B,A（探针实证）。0 尺寸 = 隐藏
    nonisolated static func makeCursor(hotX: Int, hotY: Int, width: Int, height: Int,
                                       pixels: Data, mask: Data) -> VNCursorShape? {
        guard width > 0, height > 0, pixels.count >= width * height * 4,
              mask.count >= (width + 7) / 8 * height else { return nil }
        let maskRowBytes = (width + 7) / 8
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let px = pixels.startIndex, mk = mask.startIndex
        for row in 0..<height {
            for column in 0..<width {
                let i = row * width + column
                let transparent = mask[mk + row * maskRowBytes + column / 8] & (0x80 >> (column % 8)) != 0
                rgba[i * 4] = pixels[px + i * 4 + 3]
                rgba[i * 4 + 1] = pixels[px + i * 4 + 2]
                rgba[i * 4 + 2] = pixels[px + i * 4 + 1]
                rgba[i * 4 + 3] = transparent ? 0 : 255
            }
        }
        let image: CGImage? = rgba.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return context.makeImage()
        }
        guard let image else { return nil }
        return VNCursorShape(image: image, hotX: hotX, hotY: hotY)
    }

    // MARK: 输入出口

    func sendPointer(buttonMask: UInt8, x: Int, y: Int) {
        send(RFBClientEncoder.pointerEvent(buttonMask: buttonMask, x: x, y: y))
    }

    /// 带修饰的按键：先按下激活修饰，再击键，最后逆序释放修饰。
    /// 有 XT 键码的键（专用键/修饰键）走 QEMU 扩展键盘事件——纯 keysym 在部分
    /// 客户机不生效（⌫/回车实测无效即此因）；字母等无键码走标准 KeyEvent
    func sendKey(keysym: UInt32, keycode: UInt32? = nil, modifiers: [UInt32] = []) {
        func press(_ keysym: UInt32, _ keycode: UInt32?, _ down: Bool) {
            if let keycode {
                send(RFBClientEncoder.qemuExtKeyEvent(down: down, keysym: keysym, keycode: keycode))
            } else {
                send(RFBClientEncoder.keyEvent(down: down, keysym: keysym))
            }
        }
        for modifier in modifiers where modifier != keysym {
            press(modifier, RFBKeysym.keycode(for: modifier), true)
        }
        press(keysym, keycode, true)
        press(keysym, keycode, false)
        for modifier in modifiers.reversed() where modifier != keysym {
            press(modifier, RFBKeysym.keycode(for: modifier), false)
        }
    }

    /// 文本输入逐字符转 keysym（不可映射字符忽略；修饰随字符发送；
    /// 换行/制表等有键码的字符自动走扩展键事件）
    func sendText(_ text: String, modifiers: [UInt32] = []) {
        for character in text {
            if let keysym = RFBKeysym.keysym(for: character) {
                sendKey(keysym: keysym, keycode: RFBKeysym.keycode(for: keysym), modifiers: modifiers)
            }
        }
    }

    /// 系统剪贴板文本 → 客户机剪贴板（需客户机 vdagent；无则 qemu 静默忽略）
    func sendClientCutText(_ text: String) {
        send(RFBClientEncoder.clientCutText(text))
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

// MARK: - 双指滚动手势（UIKit 侧识别）

/// UIKit 识别器 ↔ SwiftUI 手势的互斥门（引用类型，跨手势回调读写）：
/// DragGesture 拿不到触点数，双指手势只能由 UIKit 2 指 pan 识别；
/// 双指拖动期间 DragGesture 停止指针跟随，捏合进行中让位。
/// 拖动语义按画面状态二选一：放大溢出 → 平移画面；适配 → 滚轮
@MainActor
final class ConsoleGestureModel: ObservableObject {
    var twoFingerPanActive = false
    /// 双指滚轮回调（参数 = 手指纵向位移增量，正 = 向下）
    var onWheel: ((CGFloat) -> Void)?
    /// 双指平移回调（参数 = 手指位移增量）
    var onPan: ((CGSize) -> Void)?
    /// 画面放大溢出（双指拖动优先平移而非滚轮）
    var wantsPan: () -> Bool = { false }
    /// 捏合/平移进行中（滚轮抑制）
    var pinchActive: () -> Bool = { false }
}

/// 透明 UIKit 层：UIPanGestureRecognizer(2 指) → 滚轮；SwiftUI 手势挂本层。
/// 允许与 SwiftUI 识别器并行识别；平移过阈值且未进入捏合才产生滚轮
private struct ScrollWheelOverlay: UIViewRepresentable {
    let model: ConsoleGestureModel

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let model: ConsoleGestureModel
        private var engaged = false
        private var isPan = false
        private var lastTranslation = CGPoint.zero

        init(model: ConsoleGestureModel) { self.model = model }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began:
                engaged = false
                isPan = false
                lastTranslation = .zero
                model.twoFingerPanActive = true
            case .changed:
                let translation = gesture.translation(in: gesture.view)
                if !engaged {
                    // 启动阈值滤掉轻触抖动；捏合/平移进行中让位。
                    // 语义二选一：画面放大溢出 → 平移（可调显示区域），否则滚轮
                    guard !model.pinchActive(),
                          abs(translation.x) > 10 || abs(translation.y) > 10 else { return }
                    engaged = true
                    isPan = model.wantsPan()
                    lastTranslation = translation
                }
                let delta = CGSize(width: translation.x - lastTranslation.x,
                                   height: translation.y - lastTranslation.y)
                lastTranslation = translation
                if isPan {
                    model.onPan?(delta)
                } else if delta.height != 0 {
                    model.onWheel?(delta.height)
                }
            default:
                model.twoFingerPanActive = false
            }
        }
    }
}

// MARK: - 控制台视图

struct KVMVNCConsoleView: View {
    @StateObject private var console: KVMVNCSession
    @Environment(\.scenePhase) private var scenePhase

    /// 画面显示缩放（1 = 适配屏宽；捏合 1...4 倍）
    @State private var displayScale: CGFloat = 1
    @State private var fitScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var isPinching = false
    @State private var lastPinchValue: CGFloat = 1
    @State private var isKeyboardVisible = false
    @State private var keyboardInput = ""
    @FocusState private var keyboardFocused: Bool
    /// 硬件键盘接管时控制台持有焦点（键盘栏隐藏期间）
    @FocusState private var consoleFocused: Bool
    // 粘滞修饰（随下一次击键发送并自动复位）
    @State private var ctrlOn = false
    @State private var altOn = false
    @State private var shiftOn = false
    @State private var winOn = false
    /// 拖拽模式：按下-移动-释放 = 左键按住拖动（触摸模式为 移动指针/轻点/长按右键）
    @State private var dragMode = false
    @State private var leftDragActive = false
    /// 滚动手势互斥门
    @State private var gestureModel = ConsoleGestureModel()
    /// 滚轮位移累积（约 40pt = 1 滚轮格）
    @State private var wheelAccumulator: CGFloat = 0
    /// 最近一次指针的帧缓冲坐标（光标叠加 / 滚轮锚点）
    @State private var lastFramebufferPoint: (x: Int, y: Int)?
    /// 粘贴提示（含不可键入字符时提示已走剪贴板通道）
    @State private var pasteHint = ""

    init(server: ServerConfig, machineName: String) {
        _console = StateObject(wrappedValue: KVMVNCSession(server: server, vmName: machineName))
    }

    private var activeModifiers: [UInt32] {
        var modifiers: [UInt32] = []
        if ctrlOn { modifiers.append(RFBKeysym.control) }
        if altOn { modifiers.append(RFBKeysym.alt) }
        if shiftOn { modifiers.append(RFBKeysym.shift) }
        if winOn { modifiers.append(RFBKeysym.superKey) }
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
                    dragMode.toggle()
                    leftDragActive = false
                    Haptic.selection()
                } label: {
                    Image(systemName: dragMode ? "hand.draw.fill" : "hand.draw")
                }
                .accessibilityLabel(dragMode ? L10n.t("拖拽模式（按住左键拖动）")
                                             : L10n.t("触摸模式（轻点左键，长按右键）"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isKeyboardVisible.toggle()
                    keyboardFocused = isKeyboardVisible
                    consoleFocused = !isKeyboardVisible
                    if isKeyboardVisible { pasteHint = "" }
                } label: {
                    Image(systemName: "keyboard")
                }
                .accessibilityLabel(L10n.t("键盘"))
            }
        }
        .task { await console.connect() }
        .onDisappear { console.disconnect() }
        .onChange(of: scenePhase) { _, phase in
            // 回前台自动重连（后台挂起后 WS 已断，状态为 failed）
            if phase == .active, case .failed = console.state {
                Task { await console.connect() }
            }
        }
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

                // 本地光标（-239 下发的形状；cirrus-vga 不下发则不叠加）
                if let cursor = console.cursor, let point = lastFramebufferPoint {
                    cursorOverlay(cursor, at: point, in: geo.size)
                }

                // 输入层：UIKit 双指滚轮 + SwiftUI 触控手势，固定容器坐标系
                //（视图坐标 → 帧缓冲坐标统一走 framebufferPoint）
                ScrollWheelOverlay(model: gestureModel)
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
                                    if dragMode {
                                        // 拖拽模式：按下即左键、移动持续按住
                                        if leftDragActive {
                                            dragPointer(to: value.location, in: geo.size)
                                        } else if let point = framebufferPoint(at: value.location, in: geo.size) {
                                            leftDragActive = true
                                            dispatchPointer(buttonMask: 1, x: point.x, y: point.y)
                                        }
                                    } else if !gestureModel.twoFingerPanActive {
                                        movePointer(to: value.location, in: geo.size)
                                    }
                                }
                            }
                            .onEnded { _ in
                                if leftDragActive {
                                    // 释放锚定最近有效位置（手指移出画面边缘也必须释放按键）
                                    let anchor = lastFramebufferPoint ?? (0, 0)
                                    dispatchPointer(buttonMask: 0, x: anchor.x, y: anchor.y)
                                    leftDragActive = false
                                }
                            }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                if !isPinching {
                                    // ±3% 内的抖动不视为捏合——把纯双指平移让给滚轮
                                    guard abs(value - 1) > 0.03 else { return }
                                    isPinching = true
                                    panAnchor = .zero
                                    lastPinchValue = value
                                }
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
                            guard !dragMode else { return }  // 拖拽模式长按 = 按住左键
                            rightClickLast()
                        }
                    )
                    .onTapGesture {
                        consoleFocused = true
                        guard !dragMode else { return }  // 按下/释放已构成单击
                        tapLast()
                    }
                    .focusable()
                    .focused($consoleFocused)
                    .onKeyPress(phases: [.down, .repeat]) { press in
                        handleHardwareKey(press)
                    }

                statusBar
            }
            .onAppear {
                refit(in: geo.size)
                consoleFocused = !isKeyboardVisible
                gestureModel.pinchActive = { isPinching }
                gestureModel.onWheel = { wheelScrolled($0) }
                gestureModel.wantsPan = { hasDisplayOverflow }
                gestureModel.onPan = { panDisplay(by: $0) }
            }
            .onChange(of: geo.size) { _, _ in refit(in: geo.size) }
            .onChange(of: console.framebufferSize) { _, _ in
                refit(in: geo.size)
            }
        }
    }

    /// 光标叠加：帧缓冲坐标 → 容器坐标（与画面同变换），热区对齐指针位置
    private func cursorOverlay(_ cursor: VNCursorShape, at point: (x: Int, y: Int),
                               in container: CGSize) -> some View {
        let fx = (CGFloat(point.x - cursor.hotX) + CGFloat(cursor.image.width) / 2
                  - console.framebufferSize.width / 2) * displayScale
        let fy = (CGFloat(point.y - cursor.hotY) + CGFloat(cursor.image.height) / 2
                  - console.framebufferSize.height / 2) * displayScale
        return Image(uiImage: UIImage(cgImage: cursor.image))
            .interpolation(.none)
            .scaleEffect(displayScale)
            .position(x: container.width / 2 + offset.width + fx,
                      y: container.height / 2 + offset.height + fy)
            .allowsHitTesting(false)
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

    /// 指针出口统一记账（光标叠加与滚轮锚点需要最近位置）
    private func dispatchPointer(buttonMask: UInt8, x: Int, y: Int) {
        lastFramebufferPoint = (x, y)
        console.sendPointer(buttonMask: buttonMask, x: x, y: y)
    }

    private func movePointer(to location: CGPoint, in container: CGSize) {
        guard let point = framebufferPoint(at: location, in: container) else { return }
        dispatchPointer(buttonMask: 0, x: point.x, y: point.y)
    }

    /// 拖拽模式的持续按住移动
    private func dragPointer(to location: CGPoint, in container: CGSize) {
        guard let point = framebufferPoint(at: location, in: container) else { return }
        dispatchPointer(buttonMask: 1, x: point.x, y: point.y)
    }

    private func tapLast() {
        guard let point = framebufferPoint(at: lastPointerLocation, in: lastContainerSize) else { return }
        dispatchPointer(buttonMask: 0, x: point.x, y: point.y)
        dispatchPointer(buttonMask: 1, x: point.x, y: point.y)  // 左键按下
        dispatchPointer(buttonMask: 0, x: point.x, y: point.y)
    }

    private func rightClickLast() {
        guard let point = framebufferPoint(at: lastPointerLocation, in: lastContainerSize) else { return }
        Haptic.selection()
        dispatchPointer(buttonMask: 0, x: point.x, y: point.y)
        dispatchPointer(buttonMask: 4, x: point.x, y: point.y)  // 右键按下
        dispatchPointer(buttonMask: 0, x: point.x, y: point.y)
    }

    /// 双指滚动 → 滚轮事件（约 40pt = 1 格；手指下移 = 滚轮向下 = 按钮 5/0x10）
    private func wheelScrolled(_ delta: CGFloat) {
        guard console.state == .connected else { return }
        wheelAccumulator += delta
        let downward = wheelAccumulator > 0
        let ticks = Int(abs(wheelAccumulator) / 40)
        guard ticks > 0 else { return }
        wheelAccumulator -= CGFloat(ticks) * 40 * (downward ? 1 : -1)
        let anchor = lastFramebufferPoint ?? (Int(console.framebufferSize.width / 2),
                                              Int(console.framebufferSize.height / 2))
        let mask: UInt8 = downward ? 0x10 : 0x08
        for _ in 0..<ticks {
            dispatchPointer(buttonMask: mask, x: anchor.0, y: anchor.1)
            dispatchPointer(buttonMask: 0, x: anchor.0, y: anchor.1)
        }
    }

    /// 画面放大溢出（任一方向超出可视区）→ 双指拖动用于平移调整显示区域
    private var hasDisplayOverflow: Bool {
        guard console.framebufferSize.width > 0, lastContainerSize.width > 0 else { return false }
        return console.framebufferSize.width * displayScale > lastContainerSize.width + 1
            || console.framebufferSize.height * displayScale > lastContainerSize.height + 1
    }

    /// 双指拖动平移画面（越界钳制）
    private func panDisplay(by delta: CGSize) {
        offset = CGSize(width: offset.width + delta.width, height: offset.height + delta.height)
        clampOffset(in: lastContainerSize)
    }

    private func clampOffset(in container: CGSize) {
        guard console.framebufferSize.width > 0 else { return }
        let maxX = max(0, (console.framebufferSize.width * displayScale - container.width) / 2)
        let maxY = max(0, (console.framebufferSize.height * displayScale - container.height) / 2)
        offset = CGSize(width: min(max(offset.width, -maxX), maxX),
                        height: min(max(offset.height, -maxY), maxY))
    }

    // MARK: 硬件键盘（iPad 外接；键盘栏隐藏期间由控制台持有焦点接管）

    private func handleHardwareKey(_ press: KeyPress) -> KeyPress.Result {
        guard console.state == .connected, !isKeyboardVisible else { return .ignored }
        // Ctrl/Alt/Win 直通（characters 已含 Shift 产物，字符路径不重复叠加 Shift）
        var modifiers: [UInt32] = []
        if press.modifiers.contains(.control) { modifiers.append(RFBKeysym.control) }
        if press.modifiers.contains(.option) { modifiers.append(RFBKeysym.alt) }
        if press.modifiers.contains(.command) { modifiers.append(RFBKeysym.superKey) }
        if press.modifiers.contains(.shift) { modifiers.append(RFBKeysym.shift) }

        let characters = press.characters
        if characters.count == 1,
           let keysym = RFBKeysym.keysym(for: characters.first!),
           keysym != RFBKeysym.enter {  // 回车走扩展键码分支
            let characterModifiers = modifiers.filter { $0 != RFBKeysym.shift }
            console.sendKey(keysym: keysym, keycode: RFBKeysym.keycode(for: keysym),
                            modifiers: characterModifiers.isEmpty ? [] : characterModifiers)
            return .handled
        }
        let keysym: UInt32?
        switch press.key {
        case .return: keysym = RFBKeysym.enter
        case .delete: keysym = RFBKeysym.backspace      // KeyEquivalent.delete = 退格
        case .deleteForward: keysym = RFBKeysym.delete
        case .escape: keysym = RFBKeysym.escape
        case .tab: keysym = RFBKeysym.tab
        case .space: keysym = RFBKeysym.space
        case .leftArrow: keysym = RFBKeysym.left
        case .rightArrow: keysym = RFBKeysym.right
        case .upArrow: keysym = RFBKeysym.up
        case .downArrow: keysym = RFBKeysym.down
        case .home: keysym = RFBKeysym.home
        case .end: keysym = RFBKeysym.end
        case .pageUp: keysym = RFBKeysym.pageUp
        case .pageDown: keysym = RFBKeysym.pageDown
        default: keysym = nil
        }
        guard let keysym else { return .ignored }
        console.sendKey(keysym: keysym, keycode: RFBKeysym.keycode(for: keysym),
                        modifiers: modifiers)
        return .handled
    }

    // MARK: 键盘栏

    private var keyboardBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // 组合缓冲：逐字符显示，按键即转发增量，删除按差值补发 Backspace
                //（保持缓冲与客户机内容一致）；键盘回车 = 发送 Enter 并清空；
                // IME 中文/emoji 无法映射 keysym，入缓冲但不转发
                TextField(L10n.t("键盘输入（仅英文与符号）"), text: $keyboardInput)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($keyboardFocused)
                    .submitLabel(.send)
                    .onChange(of: keyboardInput) { previous, current in
                        let commonLength = zip(previous, current).prefix { $0.0 == $0.1 }.count
                        // 删除：按差值补发 Backspace（iOS 键盘删除键的直觉语义）
                        let removed = previous.count - commonLength
                        if removed > 0 {
                            for _ in 0..<removed {
                                console.sendKey(keysym: RFBKeysym.backspace,
                                                keycode: RFBKeysym.keycode(for: RFBKeysym.backspace),
                                                modifiers: [])
                            }
                        }
                        let appended = String(current.dropFirst(commonLength))
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
                    pasteFromClipboard()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(L10n.t("粘贴"))
                Button {
                    sendEnterFromKeyboard()
                } label: {
                    Image(systemName: "return")
                }
                .buttonStyle(.bordered)
            }

            if !pasteHint.isEmpty {
                Text(pasteHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        stickyModifier("Ctrl", keysym: RFBKeysym.control, isOn: $ctrlOn)
                        stickyModifier("Alt", keysym: RFBKeysym.alt, isOn: $altOn)
                        stickyModifier("Shift", keysym: RFBKeysym.shift, isOn: $shiftOn)
                        stickyModifier("Win", keysym: RFBKeysym.superKey, isOn: $winOn)
                        specialCombo("Ctrl+Alt+Del", keysym: RFBKeysym.delete,
                                     modifiers: [RFBKeysym.control, RFBKeysym.alt])
                        specialKey("Caps", keysym: RFBKeysym.capsLock)
                    }
                    HStack(spacing: 8) {
                        specialKey("Esc", keysym: RFBKeysym.escape)
                        specialKey("Tab", keysym: RFBKeysym.tab)
                        specialKey("⌫", keysym: RFBKeysym.backspace)
                        specialKey("Del", keysym: RFBKeysym.delete)
                        specialKey("Ins", keysym: RFBKeysym.insert)
                        specialKey("Home", keysym: RFBKeysym.home)
                        specialKey("End", keysym: RFBKeysym.end)
                        specialKey("PgUp", keysym: RFBKeysym.pageUp)
                        specialKey("PgDn", keysym: RFBKeysym.pageDown)
                        specialKey("←", keysym: RFBKeysym.left)
                        specialKey("↑", keysym: RFBKeysym.up)
                        specialKey("↓", keysym: RFBKeysym.down)
                        specialKey("→", keysym: RFBKeysym.right)
                        specialKey("F1", keysym: RFBKeysym.f1)
                        specialKey("F2", keysym: RFBKeysym.f2)
                        specialKey("F3", keysym: RFBKeysym.f3)
                        specialKey("F4", keysym: RFBKeysym.f4)
                        specialKey("F5", keysym: RFBKeysym.f5)
                        specialKey("F6", keysym: RFBKeysym.f6)
                        specialKey("F7", keysym: RFBKeysym.f7)
                        specialKey("F8", keysym: RFBKeysym.f8)
                        specialKey("F9", keysym: RFBKeysym.f9)
                        specialKey("F10", keysym: RFBKeysym.f10)
                        specialKey("F11", keysym: RFBKeysym.f11)
                        specialKey("F12", keysym: RFBKeysym.f12)
                    }
                }
                .padding(.horizontal, 2)
            }
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .background(.regularMaterial)
    }

    /// 粘贴：可键入文本直接敲进客户机（所有客户机可用）；
    /// 含不可映射字符（中文等）时改走 ClientCutText（需客户机 vdagent）并提示
    private func pasteFromClipboard() {
        pasteHint = ""
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        if text.allSatisfy({ RFBKeysym.keysym(for: $0) != nil }) {
            console.sendText(text)
        } else {
            console.sendClientCutText(text)
            pasteHint = L10n.t("文本含无法键入的字符，已发送到客户机剪贴板（需客户机安装 spice-vdagent）")
        }
        Haptic.selection()
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

    /// 组合键（如 Ctrl+Alt+Del）：修饰按下 → 击键 → 逆序释放
    private func specialCombo(_ label: String, keysym: UInt32, modifiers: [UInt32]) -> some View {
        Button {
            console.sendKey(keysym: keysym,
                            keycode: RFBKeysym.keycode(for: keysym),
                            modifiers: modifiers)
            resetModifiers()
            Haptic.selection()
        } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.2), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func resetModifiers() {
        ctrlOn = false
        altOn = false
        shiftOn = false
        winOn = false
    }
}
