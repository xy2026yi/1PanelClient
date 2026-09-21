//
//  FormCodecsTests.swift
//  1PanelClientTests
//
//  表单编解码纯函数测试：Supervisor environment 引号拆合（往返不变性）+
//  秒 ↔ (数值, 单位) 换算（整除取大、往返无损、边界钳制）
//

import Testing
@testable import _PanelClient

@Suite("Supervisor environment 编解码")
struct SupervisorEnvCodecTests {

    @Test("拆分：引号内逗号不拆、引号外空白去除、空段丢弃")
    func splitBasics() {
        #expect(SupervisorEnvCodec.split("A=1,B=2") == ["A=1", "B=2"])
        #expect(SupervisorEnvCodec.split("A=1, B=2 ,C=3") == ["A=1", "B=2", "C=3"])
        // 引号内逗号保留在同一段（抓包格式 KEY="val,ue"）
        #expect(SupervisorEnvCodec.split(#"KEY="val,ue",KEY2="v2""#) == [#"KEY="val,ue""#, #"KEY2="v2""#])
        // 空串/空段/尾逗号
        #expect(SupervisorEnvCodec.split("") == [])
        #expect(SupervisorEnvCodec.split(",,A=1,,") == ["A=1"])
        // 不配对引号：按引号态继续拆（固有限制，行为固定即可回归）
        #expect(SupervisorEnvCodec.split(#"A="1,B=2"#) == [#"A="1,B=2"#])
    }

    @Test("拼合：值含逗号补引号，无逗号原样，已带引号不动")
    func joinBasics() {
        #expect(SupervisorEnvCodec.join(["A=1", "B=2"]) == "A=1,B=2")
        #expect(SupervisorEnvCodec.join(["A=a,b"]) == #"A="a,b""#)
        #expect(SupervisorEnvCodec.join([#"A="a,b""#]) == #"A="a,b""#)
        #expect(SupervisorEnvCodec.join([]) == "")
        // 无 = 的行（异常输入）原样保留不崩溃
        #expect(SupervisorEnvCodec.join(["plain"]) == "plain")
    }

    @Test("服务端串往返：拆 → 拼还原原串（含引号值与含逗号值）")
    func rawRoundTrip() {
        let raw = #"A=1,KEY="val,ue",B=2,EMPTY="#
        #expect(SupervisorEnvCodec.join(SupervisorEnvCodec.split(raw)) == raw)
    }

    @Test("编辑路径往返：首次拆拼为含逗号行落形带引号，此后幂等")
    func editedLinesRoundTrip() {
        let lines = ["A=1", "B=x,y", #"C="z""#]
        let joined = SupervisorEnvCodec.join(lines)
        #expect(joined == #"A=1,B="x,y",C="z""#)
        // join 补的引号 split 会保留：首次往返后行落形为带引号版本
        let once = SupervisorEnvCodec.split(joined)
        #expect(once == ["A=1", #"B="x,y""#, #"C="z""#])
        // 已带引号的行 join 原样保留 → 二次往返幂等
        #expect(SupervisorEnvCodec.join(once) == joined)
        #expect(SupervisorEnvCodec.split(SupervisorEnvCodec.join(once)) == once)
    }

    @Test("批量幂等：60 组随机键值（含逗号/空格/Unicode）二次往返不变形")
    func bulkRoundTrip() {
        // 固定种子的伪随机（测试可复现），值不含引号（join 对含引号行原样保留）
        var seed: UInt64 = 20260921
        func next() -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % 1000)
        }
        for _ in 0..<60 {
            let key = "K\(next())"
            let value = "v\(next()),\(next()) 中文 \(next())"
            let line = "\(key)=\(value)"
            let joined = SupervisorEnvCodec.join([line])
            // 首次拆分：含逗号值落形为带引号行
            let once = SupervisorEnvCodec.split(joined)
            #expect(once == ["\(key)=\"\(value)\""])
            // 二次往返幂等
            #expect(SupervisorEnvCodec.join(once) == joined)
            #expect(SupervisorEnvCodec.split(SupervisorEnvCodec.join(once)) == once)
        }
    }
}

@Suite("秒 ↔ (数值, 单位) 换算")
struct UnitCodecTests {

    @Test("scaleTime：整除取大单位，不可整除回落秒")
    func scale() {
        #expect(UnitCodec.scaleTime(seconds: 7200) == (2, "h"))
        #expect(UnitCodec.scaleTime(seconds: 3600) == (1, "h"))
        #expect(UnitCodec.scaleTime(seconds: 300) == (5, "m"))
        #expect(UnitCodec.scaleTime(seconds: 60) == (1, "m"))
        #expect(UnitCodec.scaleTime(seconds: 90) == (90, "s"))
        #expect(UnitCodec.scaleTime(seconds: 1) == (1, "s"))
        // 0 归一为 1 分钟（监控设置既有语义）
        #expect(UnitCodec.scaleTime(seconds: 0) == (1, "m"))
    }

    @Test("unitToSeconds：s/m/h，未知单位回落分钟")
    func unitFactors() {
        #expect(UnitCodec.unitToSeconds("s") == 1)
        #expect(UnitCodec.unitToSeconds("m") == 60)
        #expect(UnitCodec.unitToSeconds("h") == 3600)
        #expect(UnitCodec.unitToSeconds("x") == 60)
    }

    @Test("换算对称：可整除的秒值 拆分→组合 还原原值")
    func roundTripSymmetry() {
        for total in [1, 59, 60, 90, 300, 3600, 7200, 86_400, 525_600 * 60] {
            let scaled = UnitCodec.scaleTime(seconds: total)
            #expect(scaled.value * UnitCodec.unitToSeconds(scaled.unit) == total,
                    "总秒 \(total) 拆为 \(scaled.value)\(scaled.unit) 后未还原")
        }
    }
}
