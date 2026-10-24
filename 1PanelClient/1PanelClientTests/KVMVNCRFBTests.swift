//
//  KVMVNCRFBTests.swift
//  1PanelClientTests
//
//  VNC 控制台 RFB 协议测试：客户端消息编码 / ServerInit 解析 / 流式消息拼装 /
//  帧缓冲落位 / keysym 映射。期望字节直接取自 logs/vnc_ws_dump.txt 抓包
//（2026-10-23 网页端连接 teat1 实录：RFB 003.008、None 鉴权、1024×768 BGRA）
//

import Testing
import Foundation
import CoreGraphics
@testable import _PanelClient

@Suite("VNC RFB 协议")
struct KVMVNCRFBTests {

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: 客户端消息编码（对齐抓包字节）

    @Test("编码形状对齐抓包：版本 / 请求 / 指针 / 按键")
    func encoderShapes() {
        #expect(hex(RFBClientEncoder.protocolVersion()) == "524642203030332e3030380a")
        #expect(hex(RFBClientEncoder.securitySelect()) == "01")
        #expect(hex(RFBClientEncoder.clientInit()) == "01")

        // 抓包帧 10（全量）与后续增量请求（1024×768）
        #expect(hex(RFBClientEncoder.framebufferUpdateRequest(
            incremental: false, width: 1024, height: 768)) == "03000000000004000300")
        #expect(hex(RFBClientEncoder.framebufferUpdateRequest(
            incremental: true, width: 1024, height: 768)) == "03010000000004000300")

        // 抓包：移动到 (623,540) 与左键按下
        #expect(hex(RFBClientEncoder.pointerEvent(buttonMask: 0, x: 623, y: 540)) == "0500026f021c")
        #expect(hex(RFBClientEncoder.pointerEvent(buttonMask: 1, x: 623, y: 540)) == "0501026f021c")

        // 标准 KeyEvent：'l'（keysym 0x6c）按下 / 释放
        #expect(hex(RFBClientEncoder.keyEvent(down: true, keysym: 0x6c)) == "040100000000006c")
        #expect(hex(RFBClientEncoder.keyEvent(down: false, keysym: 0x6c)) == "040000000000006c")

        // QEMU 扩展键盘事件（抓包帧 166/169 逐字节：'l' 按下/释放，键码 0x26）
        #expect(hex(RFBClientEncoder.qemuExtKeyEvent(down: true, keysym: 0x6c, keycode: 0x26))
                == "ff0000010000006c00000026")
        #expect(hex(RFBClientEncoder.qemuExtKeyEvent(down: false, keysym: 0x6c, keycode: 0x26))
                == "ff0000000000006c00000026")

        // 专用键 XT set-1 键码（E0 前缀键置 0x80 高位：0x4B 是小键盘 4，受
        // NumLock 影响；noVNC XT 表 ← 0xCB / Del 0xD3 / Home 0xC7 / Win 0xDB）
        #expect(RFBKeysym.keycode(for: RFBKeysym.backspace) == 0x0e)
        #expect(RFBKeysym.keycode(for: RFBKeysym.enter) == 0x1c)
        #expect(RFBKeysym.keycode(for: RFBKeysym.left) == 0xcb)
        #expect(RFBKeysym.keycode(for: RFBKeysym.up) == 0xc8)
        #expect(RFBKeysym.keycode(for: RFBKeysym.right) == 0xcd)
        #expect(RFBKeysym.keycode(for: RFBKeysym.down) == 0xd0)
        #expect(RFBKeysym.keycode(for: RFBKeysym.delete) == 0xd3)
        #expect(RFBKeysym.keycode(for: RFBKeysym.escape) == 0x01)
        #expect(RFBKeysym.keycode(for: RFBKeysym.home) == 0xc7)
        #expect(RFBKeysym.keycode(for: RFBKeysym.end) == 0xcf)
        #expect(RFBKeysym.keycode(for: RFBKeysym.pageUp) == 0xc9)
        #expect(RFBKeysym.keycode(for: RFBKeysym.pageDown) == 0xd1)
        #expect(RFBKeysym.keycode(for: RFBKeysym.insert) == 0xd2)
        #expect(RFBKeysym.keycode(for: RFBKeysym.superKey) == 0xdb)
        #expect(RFBKeysym.keycode(for: RFBKeysym.capsLock) == 0x3a)
        #expect(RFBKeysym.keycode(for: RFBKeysym.f1) == 0x3b)
        #expect(RFBKeysym.keycode(for: RFBKeysym.f10) == 0x44)
        #expect(RFBKeysym.keycode(for: RFBKeysym.f11) == 0x57)
        #expect(RFBKeysym.keycode(for: RFBKeysym.f12) == 0x58)
        #expect(RFBKeysym.keycode(for: 0x61) == nil)  // 字母走标准 KeyEvent

        // ClientCutText 形状
        #expect(hex(RFBClientEncoder.clientCutText("hi")) == "06000000000000026869")
    }

    @Test("像素格式与编码集：32bpp/24bit 原生格式 + Tight/hextile/RAW/CopyRect")
    func pixelFormatAndEncodings() {
        let pf = hex(RFBClientEncoder.setPixelFormat())
        #expect(pf.count == 40)
        #expect(pf.hasPrefix("00000000"))          // 类型 + 填充
        #expect(pf.contains("2018000100ff00ff00ff000810"))  // 32/24/LE/真彩/255³/0-8-16（网页端同款）

        // SetEncodings 为 RFB 3.3 线上布局：类型 + 1 字节填充 + 数量（dump_1 帧 9
        // 实证；2 字节填充的 6143 布局会被 1Panel agent 解析成 0 编码并断线）。
        // Tight 首位：qemu 逆向遍历、列表首个帧编码胜出（vnc.c set_encodings）
        let encodings = hex(RFBClientEncoder.setEncodings())
        #expect(encodings == "0200" + "0009"
            + "00000007" + "00000005" + "00000000" + "00000001"
            + "ffffff21" + "ffffff20" + "ffffff11" + "fffffefe" + "fffffefb")
    }

    // MARK: ServerInit（抓包帧 7）

    @Test("ServerInit 解析：1024×768 + QEMU (teat1)；截断返回 nil")
    func serverInit() throws {
        let capture = Data(hexString: "040003002018000100ff00ff00ff1008000000000000000c51454d552028746561743129")
        let serverInit = try #require(RFBServerInit.parse(capture))
        #expect(serverInit.width == 1024)
        #expect(serverInit.height == 768)
        #expect(serverInit.name == "QEMU (teat1)")
        #expect(RFBServerInit.parse(capture.prefix(30)) == nil)

        // 回归（真机卡「连接中」根因）：Data 切片保留原下标，
        // parse 必须按 startIndex 相对寻址——用偏移切片模拟 removeFirst 后的缓冲
        var padded = Data([0xaa]) + capture + Data([0xbb])
        padded.removeFirst(1)                       // startIndex = 1
        let sliced = padded.prefix(capture.count)   // 仍是 startIndex=1 的切片
        let fromSlice = try #require(RFBServerInit.parse(sliced))
        #expect(fromSlice == serverInit)
    }

    // MARK: 流式拼装（WS 帧 ≠ 消息边界，乱块喂入）

    private func makeRawBatch(x: Int, y: Int, width: Int, height: Int, pixel: [UInt8]) -> Data {
        var data = Data([0x00, 0x00]) + RFBBytes.be16(1)   // 类型 0 + 矩形数 1
        data.append(contentsOf: RFBBytes.be16(UInt16(x)))
        data.append(contentsOf: RFBBytes.be16(UInt16(y)))
        data.append(contentsOf: RFBBytes.be16(UInt16(width)))
        data.append(contentsOf: RFBBytes.be16(UInt16(height)))
        data.append(contentsOf: RFBBytes.be32(0))           // RAW
        data.append(contentsOf: [UInt8](repeating: 0, count: 0) + pixel)
        return data
    }

    @Test("RAW 矩形按任意切块拼装 + 批次完成消息")
    func assemblerRawChunked() {
        let assembler = RFBMessageAssembler()
        var messages: [RFBServerMessage] = []
        let pixels: [UInt8] = (0..<2 * 3 * 4).map { UInt8($0) }   // 2×3 像素
        let stream = makeRawBatch(x: 1, y: 2, width: 2, height: 3, pixel: pixels)

        // 7 字节乱块喂入（WS 切块模拟）
        var index = stream.startIndex
        while index < stream.endIndex {
            let end = stream.index(index, offsetBy: 7, limitedBy: stream.endIndex) ?? stream.endIndex
            messages.append(contentsOf: assembler.feed(Data(stream[index..<end])))
            index = end
        }

        guard case .rawRect(let x, let y, let width, let height, let gotPixels)? = messages.first else {
            Issue.record("首条应为 rawRect，实际 \(messages)")
            return
        }
        #expect((x, y, width, height) == (1, 2, 2, 3))
        #expect(gotPixels == Data(pixels))
        #expect(messages.last == .updateComplete)
    }

    @Test("同批多矩形：逐个落位后仅一次完成；CopyRect / DesktopSize / Bell")
    func assemblerVariants() {
        let assembler = RFBMessageAssembler()
        var messages: [RFBServerMessage] = []

        // 一批两矩形：CopyRect + 1×1 RAW
        var stream = Data([0x00, 0x00]) + RFBBytes.be16(2)
        stream.append(contentsOf: RFBBytes.be16(5) + RFBBytes.be16(6)
                       + RFBBytes.be16(2) + RFBBytes.be16(2) + RFBBytes.be32(1)   // CopyRect @5,6 2×2
                       + RFBBytes.be16(0) + RFBBytes.be16(0))                     // src 0,0
        stream.append(contentsOf: makeRawBatch(x: 0, y: 0, width: 1, height: 1, pixel: [9, 9, 9, 9]).dropFirst(4))
        messages.append(contentsOf: assembler.feed(stream))
        #expect(messages.count == 3)   // copyRect + rawRect + updateComplete

        // DesktopSize 伪编码（重设 800×600）
        messages.removeAll()
        var resize = Data([0x00, 0x00]) + RFBBytes.be16(1)
        resize.append(contentsOf: RFBBytes.be16(0) + RFBBytes.be16(0)
                       + RFBBytes.be16(800) + RFBBytes.be16(600) + RFBBytes.be32(UInt32(bitPattern: -223)))
        messages.append(contentsOf: assembler.feed(resize))
        #expect(messages.contains(.desktopSize(width: 800, height: 600)))
        #expect(messages.last == .updateComplete)

        // Bell
        messages = assembler.feed(Data([0x02]))
        #expect(messages == [.bell])

        // ServerCutText
        messages.removeAll()
        var cut = Data([0x03, 0x00, 0x00, 0x00])
        cut.append(contentsOf: RFBBytes.be32(2))
        cut.append(contentsOf: Data("hi".utf8))
        messages = assembler.feed(cut)
        #expect(messages == [.serverCutText("hi")])
    }

    @Test("未宣告编码触发致命错误（failure 置位，后续 feed 返回空）")
    func assemblerUnknownEncoding() {
        let assembler = RFBMessageAssembler()
        var stream = Data([0x00, 0x00]) + RFBBytes.be16(1)
        stream.append(contentsOf: RFBBytes.be16(0) + RFBBytes.be16(0)
                       + RFBBytes.be16(1) + RFBBytes.be16(1) + RFBBytes.be32(16))  // ZRLE 未宣告
        _ = assembler.feed(stream)
        #expect(assembler.failure?.contains("16") == true)
        #expect(assembler.feed(Data([0x02])).isEmpty)
    }


    @Test("Hextile 瓦片展开：背景/前景/子矩形，产出 RAW 像素")
    func hextileExpansion() {
        let assembler = RFBMessageAssembler()
        var messages: [RFBServerMessage] = []
        // 16×16 hextile：控制位 2|4|8（指定背景+前景+1 个子矩形）
        // bg=(11,22,33)，fg=(44,55,66)，子矩形 @ (1,2) 尺寸 2×2
        var stream = Data([0x00, 0x00]) + RFBBytes.be16(1)
        stream.append(contentsOf: RFBBytes.be16(0) + RFBBytes.be16(0)
                       + RFBBytes.be16(16) + RFBBytes.be16(16) + RFBBytes.be32(5))
        stream.append(contentsOf: [0x0e, 11, 22, 33, 0, 44, 55, 66, 0, 1, 0x12, 0x11])
        messages.append(contentsOf: assembler.feed(stream))

        guard case .rawRect(_, _, 16, 16, let pixels)? = messages.first else {
            Issue.record("应展开为 rawRect，实际 \(messages)")
            return
        }
        #expect(pixels.count == 16 * 16 * 4)
        // 背景像素
        #expect([UInt8](pixels.prefix(4)) == [11, 22, 33, 0])
        // 子矩形 (1,2) 前景色
        let subPixelStart = (2 * 16 + 1) * 4
        #expect([UInt8](pixels[subPixelStart..<(subPixelStart + 4)]) == [44, 55, 66, 0])
        // 邻近像素仍是背景
        let nextStart = (0 * 16 + 0) * 4
        #expect([UInt8](pixels[nextStart..<(nextStart + 4)]) == [11, 22, 33, 0])
        #expect(messages.last == .updateComplete)
    }

    @Test("光标伪编码产出 cursor 消息；0 尺寸 = 隐藏；ServerCutText 负长度（qemu 扩展帧）")
    func pseudoAndNegativeCutText() {
        let assembler = RFBMessageAssembler()
        var messages: [RFBServerMessage] = []
        // 2×2 光标 @ 热区 (1,1)：2*2*4 像素 + 1 字节掩码行
        let pixelBytes = [UInt8](repeating: 7, count: 2 * 2 * 4)
        var cursor = Data([0x00, 0x00]) + RFBBytes.be16(1)
        cursor.append(contentsOf: RFBBytes.be16(1) + RFBBytes.be16(1)
                       + RFBBytes.be16(2) + RFBBytes.be16(2) + RFBBytes.be32(UInt32(bitPattern: -239)))
        cursor.append(contentsOf: pixelBytes)
        cursor.append(contentsOf: [0x40, 0x00])  // 掩码：首像素不透明（位 0x80），其余透明
        messages.append(contentsOf: assembler.feed(cursor))
        #expect(messages.first == .cursor(hotX: 1, hotY: 1, width: 2, height: 2,
                                          pixels: Data(pixelBytes), mask: Data([0x40, 0x00])))
        #expect(messages.last == .updateComplete)

        // 0×0 光标 = 隐藏（掩码/像素为空）
        messages.removeAll()
        var hide = Data([0x00, 0x00]) + RFBBytes.be16(1)
        hide.append(contentsOf: RFBBytes.be16(0) + RFBBytes.be16(0)
                    + RFBBytes.be16(0) + RFBBytes.be16(0) + RFBBytes.be32(UInt32(bitPattern: -239)))
        messages.append(contentsOf: assembler.feed(hide))
        #expect(messages.first == .cursor(hotX: 0, hotY: 0, width: 0, height: 0,
                                          pixels: Data(), mask: Data()))
        #expect(messages.last == .updateComplete)

        // cuttext 长度 -8（dump_1 实证 qemu 扩展帧）
        messages = []
        var cut = Data([0x03, 0x00, 0x00, 0x00])
        cut.append(contentsOf: RFBBytes.be32(UInt32(bitPattern: -8)))
        cut.append(contentsOf: [UInt8](repeating: 9, count: 8))
        messages = assembler.feed(cut)
        guard case .serverCutText? = messages.first else {
            Issue.record("负长度 cuttext 应被消费为 serverCutText，实际 \(messages)")
            return
        }
    }

    @Test("LastRect：声明计数未满即清零结束本批，不再解析后续矩形")
    func assemblerLastRect() {
        let assembler = RFBMessageAssembler()
        // 一批声明 3 矩形：1 个 RAW + LastRect（剩余 2 个不再期待）
        var stream = Data([0x00, 0x00]) + RFBBytes.be16(3)
        stream.append(contentsOf: makeRawBatch(x: 0, y: 0, width: 1, height: 1,
                                               pixel: [1, 2, 3, 4]).dropFirst(4))
        stream.append(contentsOf: RFBBytes.be16(0) + RFBBytes.be16(0)
                       + RFBBytes.be16(0) + RFBBytes.be16(0)
                       + RFBBytes.be32(UInt32(bitPattern: -224)))   // LastRect 0×0
        let messages = assembler.feed(stream)
        #expect(messages.count == 3)   // rawRect + ignored(LastRect) + updateComplete
        #expect(messages[0] == .rawRect(x: 0, y: 0, width: 1, height: 1, pixels: Data([1, 2, 3, 4])))
        #expect(messages[1] == .ignored)
        #expect(messages[2] == .updateComplete)

        // 后续字节按新消息解析（LastRect 未吞掉下一批）
        let next = assembler.feed(Data([0x02]))
        #expect(next == [.bell])
    }

    // MARK: Tight 解码（布局经 noVNC tight.js / qemu vnc-enc-tight.c / 抓包三方实证）
    // 测试 blob 为 Python zlib 单流 Z_SYNC_FLUSH 产物（模拟 qemu 持久流逐段压缩）

    private func makeTightRect(x: Int, y: Int, width: Int, height: Int, payload: [UInt8]) -> Data {
        var data = Data([0x00, 0x00]) + RFBBytes.be16(1)   // FBU 头 + 矩形数 1
        data.append(contentsOf: RFBBytes.be16(UInt16(x)))
        data.append(contentsOf: RFBBytes.be16(UInt16(y)))
        data.append(contentsOf: RFBBytes.be16(UInt16(width)))
        data.append(contentsOf: RFBBytes.be16(UInt16(height)))
        data.append(contentsOf: RFBBytes.be32(7))           // Tight
        data.append(contentsOf: payload)
        return data
    }

    /// copy 过滤器矩形 payload（ctl = 流号，隐式 copy；blob 前置紧凑长度）
    private func copyPayload(stream: UInt8, blob: Data, resetStreams: UInt8 = 0) -> [UInt8] {
        var payload: [UInt8] = [stream << 4 | resetStreams]
        payload.append(UInt8(blob.count))   // < 128 单字节长度
        payload.append(contentsOf: blob)
        return payload
    }

    @Test("Tight fill：0x80 + 3 字节 RGB → 纯色矩形（帧缓冲字节序 [pad,B,G,R]）")
    func tightFill() {
        let assembler = RFBMessageAssembler()
        let stream = makeTightRect(x: 0, y: 0, width: 2, height: 2,
                                   payload: [0x80, 0xff, 0x80, 0x00])  // RGB(255,128,0)
        let messages = assembler.feed(stream)
        #expect(messages[0] == .rawRect(x: 0, y: 0, width: 2, height: 2,
                                        pixels: Data((0..<(2 * 2)).flatMap { _ in [0x00, 0x00, 0x80, 0xff] })))
        #expect(messages.last == .updateComplete)
    }

    @Test("Tight copy 未压缩（usz<12 直发）与 fill 同帧缓冲字节序")
    func tightCopyRaw() {
        let assembler = RFBMessageAssembler()
        // 2×1（usz=6 < 12）：ctl 0x00（流 0 隐式 copy）+ 6 字节 RGB
        let stream = makeTightRect(x: 1, y: 1, width: 2, height: 1,
                                   payload: [0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0xff])
        let messages = assembler.feed(stream)
        // 红(ff,00,00) → [00,00,00,ff]；蓝(00,00,ff) → [00,ff,00,00]
        #expect(messages[0] == .rawRect(x: 1, y: 1, width: 2, height: 1,
                                        pixels: Data([0x00, 0x00, 0x00, 0xff,
                                                      0x00, 0xff, 0x00, 0x00])))
    }

    @Test("Tight copy zlib：紧凑长度 + 跳 RFC1950 头，逐字节乱块喂入")
    func tightCopyZlib() {
        let assembler = RFBMessageAssembler()
        // 4×1（usz=12 → zlib）；流 0。blob1 为 rgb 红/绿/蓝/白 的 zlib 流首段（含 789c 头）
        let blob1 = Data(hexString: "789cfacfc0c0f01f848100000000ffff")
        let stream = makeTightRect(x: 0, y: 0, width: 4, height: 1,
                                   payload: copyPayload(stream: 0, blob: blob1))

        // 逐字节喂入（WS 切块极端情形）
        var messages: [RFBServerMessage] = []
        for byte in stream {
            messages.append(contentsOf: assembler.feed(Data([byte])))
        }
        #expect(messages.first == .rawRect(x: 0, y: 0, width: 4, height: 1,
                                           pixels: Data(hexString: "000000ff0000ff0000ff000000ffffff")))
        #expect(messages.last == .updateComplete)
        #expect(assembler.failure == nil)
    }

    @Test("Tight zlib 同流续段：无头 blob 依赖流字典续解（持久状态）")
    func tightStreamContinuation() {
        let assembler = RFBMessageAssembler()
        // 首段（含头）流 0
        let blob1 = Data(hexString: "789cfacfc0c0f01f848100000000ffff")
        _ = assembler.feed(makeTightRect(x: 0, y: 0, width: 4, height: 1,
                                         payload: copyPayload(stream: 0, blob: blob1)))
        #expect(assembler.failure == nil)
        // 续段（同 Python 流第二段，无 789c 头）——同一 stream 0 续解
        let blob1b = Data(hexString: "12543276094d2bef98b96af71900000000ffff")
        let messages = assembler.feed(makeTightRect(
            x: 4, y: 0, width: 4, height: 1, payload: copyPayload(stream: 0, blob: blob1b)))
        guard case .rawRect(let x, _, 4, 1, let pixels)? = messages.first else {
            Issue.record("续段应解出 rawRect，实际 \(messages) failure=\(assembler.failure ?? "")")
            return
        }
        #expect(x == 4)
        #expect(pixels == Data(hexString: "00332211006655440099887700ccbbaa"))
    }

    @Test("Tight gradient：delta 预测还原（含回绕加），独立流含头 blob")
    func tightGradient() {
        // decodeGradient 纯函数：3×2 手工推演值（末像素 466 & 0xff = 210 回绕）
        let gradInput: [UInt8] = [10, 20, 30, 5, 5, 5, 0, 0, 0,
                                  1, 1, 1, 200, 100, 50, 250, 250, 250]
        let expectedRGB: [UInt8] = [10, 20, 30, 15, 25, 35, 15, 25, 35,
                                     11, 21, 31, 216, 126, 86, 210, 120, 80]
        #expect(RFBMessageAssembler.decodeGradient(gradInput, width: 3, height: 2) == expectedRGB)

        // 整矩形：ctl 0x70（流 3 + 显式过滤器）+ filter 2 + 紧凑长度 + blobG
        let assembler = RFBMessageAssembler()
        let blobG = Data(hexString: "789ce212916365656560606064643c9162f4ebd72f00000000ffff")
        #expect(blobG.count == 27)
        var payload: [UInt8] = [0x70, 0x02, 27]
        payload.append(contentsOf: blobG)
        let messages = assembler.feed(makeTightRect(x: 2, y: 3, width: 3, height: 2, payload: payload))
        guard case .rawRect(_, _, 3, 2, let pixels)? = messages.first else {
            Issue.record("应为 rawRect，实际 \(messages) failure=\(assembler.failure ?? "")")
            return
        }
        // 期望帧缓冲字节（Python 逐像素换算）：[pad,B,G,R]
        #expect(pixels == Data(hexString: "001e140a0023190f0023190f001f150b00567ed8005078d2"))
    }

    @Test("Tight palette：≤2 色 1bpp 索引直发；>2 色 8bpp 索引 zlib")
    func tightPalette() {
        let assembler = RFBMessageAssembler()

        // 16×1 mono：ctl 0x50（流 1 + 显式过滤器）+ filter 1 + nc=2 + 调色板 6 字节 +
        // 索引 usz=2×1=2 < 12 直发（黑底白前景，位 1 = 前景）
        var mono: [UInt8] = [0x50, 0x01, 0x01]
        mono += [0x00, 0x00, 0x00, 0xff, 0xff, 0xff]        // 黑、白
        mono += [0xaa, 0x80]                                 // 10101010 10000000
        let messages = assembler.feed(makeTightRect(x: 0, y: 0, width: 16, height: 1, payload: mono))
        guard case .rawRect(_, _, 16, 1, let pixels)? = messages.first else {
            Issue.record("mono 应为 rawRect，实际 \(messages)")
            return
        }
        let bytes = [UInt8](pixels)
        #expect(Array(bytes[0..<4]) == [0x00, 0xff, 0xff, 0xff])   // 索引 1 = 白
        #expect(Array(bytes[4..<8]) == [0x00, 0x00, 0x00, 0x00])   // 索引 0 = 黑
        #expect(Array(bytes[32..<36]) == [0x00, 0xff, 0xff, 0xff]) // 像素 8 索引 1 = 白
        #expect(Array(bytes[60..<64]) == [0x00, 0x00, 0x00, 0x00]) // 末像素索引 0 = 黑

        // 8×2 三色调色板：ctl 0x60（流 2 + 显式过滤器）+ filter 1 + nc=3 + 9 字节调色板
        // + 紧凑长度 + blobP（独立流含头；idx = [0,1,2,0,1,2,0,1, 1,2,0,1,2,0,1,2]）
        let blobP = Data(hexString: "789c62606462002128c504000000ffff")
        #expect(blobP.count == 16)
        var palette8: [UInt8] = [0x60, 0x01, 0x02]
        palette8 += [0xff, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0xff]  // 红/绿/蓝
        palette8.append(16)
        palette8 += Array(blobP)
        let messages2 = assembler.feed(makeTightRect(x: 0, y: 0, width: 8, height: 2, payload: palette8))
        guard case .rawRect(_, _, 8, 2, let pixels2)? = messages2.first else {
            Issue.record("palette8 应为 rawRect，实际 \(messages2) failure=\(assembler.failure ?? "")")
            return
        }
        // 索引 0=红 → 000000ff；1=绿 → 0000ff00；2=蓝 → 00ff0000
        // idx = [0,1,2,0,1,2,0,1, 1,2,0,1,2,0,1,2]
        #expect(pixels2 == Data(hexString: "000000ff0000ff0000ff0000000000ff"
                                           + "0000ff0000ff0000000000ff0000ff00"
                                           + "0000ff0000ff0000000000ff0000ff00"
                                           + "00ff0000000000ff0000ff0000ff0000"))
    }

    @Test("Tight zlib 流重置位：reset 后重新跳 RFC1950 头")
    func tightStreamReset() {
        let assembler = RFBMessageAssembler()
        // 先用流 0 解一段（带头的 blob）
        let blob1 = Data(hexString: "789cfacfc0c0f01f848100000000ffff")
        _ = assembler.feed(makeTightRect(x: 0, y: 0, width: 4, height: 1,
                                         payload: copyPayload(stream: 0, blob: blob1)))
        #expect(assembler.failure == nil)

        // ctl 0x01：低位重置流 0（其余同隐式 copy 流 0）+ 新流压缩的 blob（含新头）
        let blobN = Data(hexString: "789c125030700848286898b060c30100000000ffff")
        #expect(blobN.count == 21)
        let messages = assembler.feed(makeTightRect(
            x: 0, y: 0, width: 4, height: 1, payload: copyPayload(stream: 0, blob: blobN, resetStreams: 0x01)))
        guard case .rawRect(_, _, 4, 1, let pixels)? = messages.first else {
            Issue.record("重置后应正常解出 rawRect，实际 \(messages) failure=\(assembler.failure ?? "")")
            return
        }
        #expect(pixels == Data(hexString: "00302010006050400090807000c0b0a0"))
    }

    @Test("Tight 未宣告类型（JPEG/PNG）触发致命错误")
    func tightUnexpectedType() {
        let assembler = RFBMessageAssembler()
        // ctl 0x90 = JPEG（未宣告质量等级不应出现）
        let stream = makeTightRect(x: 0, y: 0, width: 4, height: 1, payload: [0x90, 0x02, 0xff, 0xd8])
        _ = assembler.feed(stream)
        #expect(assembler.failure?.contains("JPEG") == true)
    }

    // MARK: 帧缓冲

    @Test("RAW 落位与读取（按送达原样存储）、CopyRect 搬移、resize 清零")
    func framebuffer() {
        let fb = RFBFramebuffer(width: 4, height: 4)
        // 1×2 竖条 @ (1,0)：像素值 R|G<<8|B<<16 经面板代理按大端落字节 [pad,B,G,R]
        var pixels = Data([0x00, 0x00, 0x00, 0xff])   // (1,0) 红像素值 0xff
        pixels.append(contentsOf: [0x00, 0x00, 0xff, 0x00])  // (1,1) 绿像素值 0xff00
        fb.applyRaw(x: 1, y: 0, width: 1, height: 2, pixels: pixels)
        #expect(fb.pixel(x: 1, y: 0)!.3 == 0xff)   // R（第 4 字节）
        #expect(fb.pixel(x: 1, y: 1)!.2 == 0xff)   // G（第 3 字节）
        #expect(fb.pixel(x: 0, y: 0)!.0 == 0x00)   // 未动区域为黑

        // CopyRect：(1,0) 1×2 → (3,2)
        fb.applyCopyRect(x: 3, y: 2, width: 1, height: 2, sourceX: 1, sourceY: 0)
        #expect(fb.pixel(x: 3, y: 2)!.3 == 0xff)
        #expect(fb.pixel(x: 3, y: 3)!.2 == 0xff)

        // 越界裁剪不崩
        fb.applyRaw(x: 3, y: 3, width: 4, height: 4, pixels: Data(repeating: 0x80, count: 4 * 4 * 4))

        fb.resize(width: 2, height: 2)
        #expect(fb.width == 2)
        #expect(fb.pixel(x: 1, y: 1) ?? (1, 1, 1, 1) == (0, 0, 0, 0))  // resize 清黑

        let image = fb.makeImage()
        #expect(image?.width == 2)
        #expect(image?.height == 2)
    }

    @Test("成像字节序：[pad,B,G,R] + noneSkipLast|32Little → 正确颜色（生产路径实证）")
    func framebufferImagingColors() throws {
        let fb = RFBFramebuffer(width: 2, height: 1)
        fb.applyRaw(x: 0, y: 0, width: 2, height: 1,
                    pixels: Data([0x00, 0x00, 0x00, 0xff,   // 红（值 0xff）
                                  0x00, 0x00, 0xff, 0x00]))  // 绿（值 0xff00）
        let image = try #require(fb.makeImage())
        // 画入 premultipliedLast（默认字节序，内存 R,G,B,A）验证最终颜色
        //（若该组合读内存非 X,B,G,R，红/绿会互换或丢失——此测试即防线）
        var probe = [UInt8](repeating: 0x00, count: 8)
        let ctx = try #require(CGContext(data: &probe, width: 2, height: 1, bitsPerComponent: 8,
                                         bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 1))
        #expect(probe[0] >= 0xf0 && probe[1] <= 0x0f && probe[2] <= 0x0f)  // 左 = 红
        #expect(probe[4] <= 0x0f && probe[5] >= 0xf0 && probe[6] <= 0x0f)  // 右 = 绿
    }

    @Test("光标成像：帧缓冲同序像素 + 掩码（1=透明）→ 带 alpha 的 CGImage")
    func cursorImaging() throws {
        // 2×1 光标：像素 [pad,B,G,R] 红/绿；掩码 0x80 → 左像素透明、右不透明
        let pixels = Data([0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00])
        let mask = Data([0x80])
        let cursor = try #require(KVMVNCSession.makeCursor(hotX: 3, hotY: 4, width: 2, height: 1,
                                                           pixels: pixels, mask: mask))
        #expect(cursor.hotX == 3)
        #expect(cursor.hotY == 4)
        var probe = [UInt8](repeating: 0x55, count: 8)
        let ctx = try #require(CGContext(data: &probe, width: 2, height: 1, bitsPerComponent: 8,
                                         bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cursor.image, in: CGRect(x: 0, y: 0, width: 2, height: 1))
        // 左像素全透明：源合成后保持背景 0x55
        #expect(Array(probe[0..<4]) == [0x55, 0x55, 0x55, 0x55])
        // 右像素不透明绿
        #expect(probe[4] <= 0x0f && probe[5] >= 0xf0 && probe[6] <= 0x0f && probe[7] == 0xff)

        // 0 尺寸光标 = 隐藏（makeCursor 返回 nil）
        #expect(KVMVNCSession.makeCursor(hotX: 0, hotY: 0, width: 0, height: 0,
                                         pixels: Data(), mask: Data()) == nil)
    }

    // MARK: keysym

    @Test("keysym 映射：Latin-1 / 换行归一 Return；中文与 emoji 不可映射")
    func keysyms() {
        #expect(RFBKeysym.keysym(for: "a") == 0x61)
        #expect(RFBKeysym.keysym(for: "l") == 0x6c)
        #expect(RFBKeysym.keysym(for: " ") == 0x20)
        #expect(RFBKeysym.keysym(for: "é") == 0xe9)
        #expect(RFBKeysym.keysym(for: "\n") == RFBKeysym.enter)
        #expect(RFBKeysym.keysym(for: "\r") == RFBKeysym.enter)
        #expect(RFBKeysym.keysym(for: "中") == nil)
        #expect(RFBKeysym.keysym(for: "👍") == nil)
    }
}

nonisolated extension Data {
    /// 十六进制串 → Data（测试构造用）
    init(hexString: String) {
        self.init()
        var iterator = hexString.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            if let byte = UInt8(String([high, low]), radix: 16) {
                append(byte)
            }
        }
    }
}
