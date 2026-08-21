//
//  WAFMonitorModelsTests.swift
//  1PanelClientTests
//
//  WAF 监控模型的时间格式化与防御式解码
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("WAF 监控模型")
struct WAFMonitorModelTests {
    @Test("WAFStatDayItem.shortDay：yyyy-MM-dd 取 MM-dd")
    func shortDay() {
        #expect(WAFStatDayItem(day: "2026-08-15", reqCount: 1, attackCount: 0).shortDay == "08-15")
    }

    @Test("WAFTime.short：纳秒/毫秒/无小数 ISO 均解出 MM-dd HH:mm:ss，非法串原样返回")
    func timeShort() {
        let pattern = "^\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}$"
        func matches(_ s: String?) -> Bool {
            s?.range(of: pattern, options: .regularExpression) != nil
        }
        // 服务端 localtime 实测为纳秒精度
        #expect(matches(WAFTime.short("2026-08-15T08:27:07.739061005+08:00")))
        #expect(matches(WAFTime.short("2026-08-15T08:27:07.739+08:00")))
        #expect(matches(WAFTime.short("2026-08-15T08:27:07+08:00")))
        // 解析失败原样返回、nil 透传
        #expect(WAFTime.short("not a date") == "not a date")
        #expect(WAFTime.short("2026-08-15 08:27:07") == "2026-08-15 08:27:07")
        #expect(WAFTime.short(nil) == nil)
    }

    @Test("WAFLogItem：id 字段映射到 logID，字段全缺仍可解码（id 回退占位串）")
    func logItemDecoding() throws {
        let empty = try JSONDecoder().decode(WAFLogItem.self, from: Data("{}".utf8))
        #expect(empty.logID == nil && empty.ip == nil)
        #expect(empty.id == "0--")   // logID 0 + 空 localtime/ip 拼出的占位 id

        let full = try JSONDecoder().decode(
            WAFLogItem.self,
            from: Data(#"{"id": 7, "ip": "1.2.3.4", "localtime": "2026-08-15T08:27:07+08:00"}"#.utf8)
        )
        #expect(full.logID == 7)
        #expect(full.ip == "1.2.3.4")
    }
}
