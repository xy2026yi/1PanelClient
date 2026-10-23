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
    }

    @Test("像素格式与编码集：BGRA 原生格式 + RAW/CopyRect/DesktopSize")
    func pixelFormatAndEncodings() {
        let pf = hex(RFBClientEncoder.setPixelFormat())
        #expect(pf.count == 40)
        #expect(pf.hasPrefix("00000000"))          // 类型 + 填充
        #expect(pf.contains("2018000100ff00ff00ff000810"))  // 32/24/LE/真彩/255³/0-8-16（网页端同款）

        // 网页端 24 项编码集逐字节复刻（dump_1 帧 9 原样字节）
        let encodings = hex(RFBClientEncoder.setEncodings())
        #expect(encodings == "020000" + "0018"
            + "00000001" + "00000007" + "fffffefc" + "00000010" + "00000015"
            + "00000005" + "00000002" + "00000006" + "00000000"
            + "ffffffe6" + "ffffff02" + "ffffff21" + "ffffff20"
            + "fffffefe" + "fffffefb" + "fffffecc" + "fffffecb"
            + "fffffec8" + "fffffec7" + "fffffecd" + "c0a1e5ce"
            + "fffffec4" + "574d5664" + "ffffff11")
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

    @Test("光标伪编码与 ServerCutText 负长度（qemu 剪贴板扩展帧）消费不报错")
    func pseudoAndNegativeCutText() {
        let assembler = RFBMessageAssembler()
        var messages: [RFBServerMessage] = []
        // 2×2 光标：2*2*4 像素 + 1 字节掩码行
        var cursor = Data([0x00, 0x00]) + RFBBytes.be16(1)
        cursor.append(contentsOf: RFBBytes.be16(0) + RFBBytes.be16(0)
                       + RFBBytes.be16(2) + RFBBytes.be16(2) + RFBBytes.be32(UInt32(bitPattern: -239)))
        cursor.append(contentsOf: [UInt8](repeating: 7, count: 2 * 2 * 4 + 2))  // 16 像素 + 2 行掩码
        messages.append(contentsOf: assembler.feed(cursor))
        #expect(messages.first == .ignored)
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

    // MARK: 帧缓冲

    @Test("RAW 落位与读取（RGBA 字节序，按送达原样存储）、CopyRect 搬移、resize 清零")
    func framebuffer() {
        let fb = RFBFramebuffer(width: 4, height: 4)
        // 1×2 竖条 @ (1,0)：按网页端同款格式首字节为 R
        var pixels = Data([0xff, 0x00, 0x00, 0x00])   // (1,0) R=255
        pixels.append(contentsOf: [0x00, 0xff, 0x00, 0x00])  // (1,1) G=255
        fb.applyRaw(x: 1, y: 0, width: 1, height: 2, pixels: pixels)
        #expect(fb.pixel(x: 1, y: 0)!.0 == 0xff)   // R
        #expect(fb.pixel(x: 1, y: 1)!.1 == 0xff)   // G
        #expect(fb.pixel(x: 0, y: 0)!.0 == 0x00)   // 未动区域为黑

        // CopyRect：(1,0) 1×2 → (3,2)
        fb.applyCopyRect(x: 3, y: 2, width: 1, height: 2, sourceX: 1, sourceY: 0)
        #expect(fb.pixel(x: 3, y: 2)!.0 == 0xff)
        #expect(fb.pixel(x: 3, y: 3)!.1 == 0xff)

        // 越界裁剪不崩
        fb.applyRaw(x: 3, y: 3, width: 4, height: 4, pixels: Data(repeating: 0x80, count: 4 * 4 * 4))

        fb.resize(width: 2, height: 2)
        #expect(fb.width == 2)
        #expect(fb.pixel(x: 1, y: 1) ?? (1, 1, 1, 1) == (0, 0, 0, 0))  // resize 清黑

        let image = fb.makeImage()
        #expect(image?.width == 2)
        #expect(image?.height == 2)
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
