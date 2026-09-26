//
//  WebsiteMonitorModelsTests.swift
//  1PanelClientTests
//
//  网站监控模型的时间范围换算与防御式解码
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("WebsiteMonitorRange 时间范围")
struct WebsiteMonitorRangeTests {
    private let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    /// 固定基准时刻，避免测试跨午夜翻转
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("days：今日/近7天/近30日为 1/7/30")
    func days() {
        #expect(WebsiteMonitorRange.today.days == 1)
        #expect(WebsiteMonitorRange.last7days.days == 7)
        #expect(WebsiteMonitorRange.last30days.days == 30)
    }

    @Test("dayPair：今日同日起止，近7天/近30日分别回退 6/29 天，均对齐当日零点")
    func dayPair() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func pair(_ d: Int) -> String {
            dayFmt.string(from: cal.date(byAdding: .day, value: -d, to: today)!)
        }
        #expect(WebsiteMonitorRange.today.dayPair(now: now) == [pair(0), pair(0)])
        #expect(WebsiteMonitorRange.last7days.dayPair(now: now) == [pair(6), pair(0)])
        #expect(WebsiteMonitorRange.last30days.dayPair(now: now) == [pair(29), pair(0)])
    }

    @Test("logWindow：今日为当日 00:00:00–23:59:59，其余为滚动 N 天到现在")
    func logWindow() {
        let cal = Calendar.current
        let today = WebsiteMonitorRange.today.logWindow(now: now)
        #expect(today.start == cal.startOfDay(for: now))
        #expect(today.end == cal.startOfDay(for: now).addingTimeInterval(86_399))

        let week = WebsiteMonitorRange.last7days.logWindow(now: now)
        #expect(week.start == cal.date(byAdding: .day, value: -6, to: now))
        #expect(week.end == now)

        let month = WebsiteMonitorRange.last30days.logWindow(now: now)
        #expect(month.start == cal.date(byAdding: .day, value: -29, to: now))
        #expect(month.end == now)
    }
}

@Suite("访客趋势/地图模型")
struct WebsiteMonitorModelTests {
    @Test("VisitorTrendPoint.shortLabel：小时段取前 5 位、日期取 MM-dd、短串原样")
    func shortLabel() {
        #expect(VisitorTrendPoint(date: "00:00 - 00:59", pv: 1, uv: 1).shortLabel == "00:00")
        #expect(VisitorTrendPoint(date: "2026-08-15", pv: nil, uv: 2).shortLabel == "08-15")
        #expect(VisitorTrendPoint(date: "abc", pv: 1, uv: 1).shortLabel == "abc")
    }

    @Test("VisitorLocItem：value 容错解码整型/浮点/数字字符串，非法值不拖垮整体")
    func locDecoding() throws {
        func decode(_ json: String) throws -> VisitorLocItem {
            try JSONDecoder().decode(VisitorLocItem.self, from: Data(json.utf8))
        }
        #expect(try decode(#"{"value": 42, "name": "China"}"#).value == 42)
        #expect(try decode(#"{"value": 3.5}"#).value == 3.5)
        #expect(try decode(#"{"value": "123"}"#).value == 123)
        #expect(try decode(#"{"value": "abc", "name": "US"}"#).value == nil)
        #expect(try decode(#"{"name": "US"}"#).value == nil)
        #expect(try decode(#"{"value": 1}"#).name == nil)
    }
}

@Suite("QPS/今日状态 data:null 回退")
struct MonitorQpsEmptyFallbackTests {
    @Test("信封 data=null 解码后为 nil，emptyInstance 按全 0 回退")
    func nullDataFallsBackToZero() throws {
        let envelope = try JSONDecoder().decode(
            APIResponse<MonitorQpsInfo>.self,
            from: Data(#"{"code": 200, "message": "", "data": null}"#.utf8))
        #expect(envelope.isSuccess)
        #expect(envelope.data == nil)

        let qps = MonitorQpsInfo.emptyInstance()
        #expect(qps.qps == 0)
        #expect(qps.flow == 0)

        let stat = WebsiteMonitorStat.emptyInstance()
        #expect(stat.pv == 0 && stat.uv == 0 && stat.req == 0)
        #expect(stat.count4xx == 0 && stat.count5xx == 0)
    }

    @Test("正常返回 {qps:0, flow:0} 与字段缺失 {qps:null} 均可解码")
    func zeroAndNullFieldPayloads() throws {
        let zero = try JSONDecoder().decode(
            MonitorQpsInfo.self, from: Data(#"{"qps":0,"flow":0}"#.utf8))
        #expect(zero.qps == 0 && zero.flow == 0)

        let nulls = try JSONDecoder().decode(
            MonitorQpsInfo.self, from: Data(#"{"qps":null,"flow":null}"#.utf8))
        #expect(nulls.qps == nil && nulls.flow == nil)
    }
}
