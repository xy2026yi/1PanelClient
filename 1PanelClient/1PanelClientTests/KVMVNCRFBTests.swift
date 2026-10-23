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
        #expect(pf.contains("2018000100ff00ff00ff100800"))  // 32/24/LE/真彩/255³/16-8-0

        let encodings = hex(RFBClientEncoder.setEncodings())
        #expect(encodings == "020000" + "0003" + "00000000" + "00000001" + "ffffff21")
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

    @Test("RAW 矩形按任意切块拼装 + 批次完成回调")
    func assemblerRawChunked() {
        let assembler = RFBMessageAssembler()
        var messages: [RFBServerMessage] = []
        assembler.onMessage = { messages.append($0) }
        let pixels: [UInt8] = (0..<2 * 3 * 4).map { UInt8($0) }   // 2×3 像素
        let stream = makeRawBatch(x: 1, y: 2, width: 2, height: 3, pixel: pixels)

        // 7 字节乱块喂入（WS 切块模拟）
        var index = stream.startIndex
        while index < stream.endIndex {
            let end = stream.index(index, offsetBy: 7, limitedBy: stream.endIndex) ?? stream.endIndex
            assembler.feed(Data(stream[index..<end]))
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
        assembler.onMessage = { messages.append($0) }

        // 一批两矩形：CopyRect + 1×1 RAW
        var stream = Data([0x00, 0x00]) + RFBBytes.be16(2)
        stream.append(contentsOf: RFBBytes.be16(5) + RFBBytes.be16(6)
                       + RFBBytes.be16(2) + RFBBytes.be16(2) + RFBBytes.be32(1)   // CopyRect @5,6 2×2
                       + RFBBytes.be16(0) + RFBBytes.be16(0))                     // src 0,0
        stream.append(contentsOf: makeRawBatch(x: 0, y: 0, width: 1, height: 1, pixel: [9, 9, 9, 9]).dropFirst(4))
        assembler.feed(stream)
        #expect(messages.count == 3)   // copyRect + rawRect + updateComplete

        // DesktopSize 伪编码（重设 800×600）
        messages.removeAll()
        var resize = Data([0x00, 0x00]) + RFBBytes.be16(1)
        resize.append(contentsOf: RFBBytes.be16(0) + RFBBytes.be16(0)
                       + RFBBytes.be16(800) + RFBBytes.be16(600) + RFBBytes.be32(UInt32(bitPattern: -223)))
        assembler.feed(resize)
        #expect(messages.contains(.desktopSize(width: 800, height: 600)))
        #expect(messages.last == .updateComplete)

        // Bell
        messages.removeAll()
        assembler.feed(Data([0x02]))
        #expect(messages == [.bell])

        // ServerCutText
        messages.removeAll()
        var cut = Data([0x03, 0x00, 0x00, 0x00])
        cut.append(contentsOf: RFBBytes.be32(2))
        cut.append(contentsOf: Data("hi".utf8))
        assembler.feed(cut)
        #expect(messages == [.serverCutText("hi")])
    }

    @Test("未宣告编码触发致命错误")
    func assemblerUnknownEncoding() {
        let assembler = RFBMessageAssembler()
        var error: String?
        assembler.onError = { error = $0 }
        var stream = Data([0x00, 0x00]) + RFBBytes.be16(1)
        stream.append(contentsOf: RFBBytes.be16(0) + RFBBytes.be16(0)
                       + RFBBytes.be16(1) + RFBBytes.be16(1) + RFBBytes.be32(16))  // ZRLE 未宣告
        assembler.feed(stream)
        #expect(error?.contains("16") == true)
    }

    // MARK: 帧缓冲

    @Test("RAW 落位与读取（BGRA 字节序）、CopyRect 搬移、resize 清零")
    func framebuffer() {
        let fb = RFBFramebuffer(width: 4, height: 4)
        // 1×2 竖条 @ (1,0)：蓝绿红顺序验证 BGRA
        var pixels = Data([0xff, 0x00, 0x00, 0x00])   // (1,0) 蓝
        pixels.append(contentsOf: [0x00, 0xff, 0x00, 0x00])  // (1,1) 绿
        fb.applyRaw(x: 1, y: 0, width: 1, height: 2, pixels: pixels)
        #expect(fb.pixel(x: 1, y: 0)!.0 == 0xff)   // B
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
