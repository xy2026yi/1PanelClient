//
//  MonitorSlotWindowTests.swift
//  1PanelClientTests
//
//  容器监控固定采样位窗口的映射行为（去重、滑窗、吸附往返）
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("MonitorSlotWindow 固定采样位窗口")
struct MonitorSlotWindowTests {
    private func dates(_ offsets: [Double], base: Date = Date(timeIntervalSince1970: 1_000)) -> [Date] {
        offsets.map { base.addingTimeInterval($0) }
    }

    @Test("空数据：无采样位、无吸附目标")
    func empty() {
        let w = MonitorSlotWindow(dates: [])
        #expect(w.dates.isEmpty)
        #expect(w.slotByDate.isEmpty)
        #expect(w.slot(atX: 100, plotWidth: 300) == nil)
    }

    @Test("单点：占据 0 号采样位，触摸任意位置都吸附到它")
    func singlePoint() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let w = MonitorSlotWindow(dates: [t0])
        #expect(w.dates == [t0])
        #expect(w.slotByDate[t0] == 0)
        #expect(w.slot(atX: 0, plotWidth: 300) == 0)
        #expect(w.slot(atX: 300, plotWidth: 300) == 0)
    }

    @Test("填满前：按时间升序依次占位")
    func fillOrder() {
        let w = MonitorSlotWindow(dates: dates([40, 0, 20, 10, 30]))
        #expect(w.dates.count == 5)
        #expect(w.dates.map { w.slotByDate[$0] } == [0, 1, 2, 3, 4])
    }

    @Test("超出窗口容量：保留最近 slotCount 个，最旧被推出")
    func slideWindow() {
        let all = dates(Array(stride(from: 0.0, through: 13.0, by: 1.0)))   // 14 个
        let w = MonitorSlotWindow(dates: all)
        #expect(w.dates.count == MonitorSlotWindow.slotCount)
        #expect(w.dates == all.suffix(MonitorSlotWindow.slotCount))
        #expect(w.slotByDate[all[0]] == nil)   // 最旧两个已出窗
        #expect(w.slotByDate[all[1]] == nil)
        #expect(w.slotByDate[all[2]] == 0)
        #expect(w.slotByDate[all.last!] == MonitorSlotWindow.slotCount - 1)
    }

    @Test("重复时刻：去重后占一个采样位")
    func duplicateDates() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let w = MonitorSlotWindow(dates: [t0, t0, t0.addingTimeInterval(5)])
        #expect(w.dates.count == 2)
        #expect(w.slotByDate[t0] == 0)
    }

    @Test("吸附边界：左端 0 号、右端末号；采样位往返映射不变")
    func snapRoundTrip() {
        let w = MonitorSlotWindow(dates: dates(Array(stride(from: 0.0, through: 55.0, by: 5.0))))
        let plotWidth: CGFloat = 953
        #expect(w.slot(atX: 0, plotWidth: plotWidth) == 0)
        #expect(w.slot(atX: plotWidth, plotWidth: plotWidth) == MonitorSlotWindow.slotCount - 1)
        for slot in 0..<MonitorSlotWindow.slotCount {
            let x = MonitorSlotWindow.xFraction(Double(slot)) * plotWidth
            #expect(w.slot(atX: x, plotWidth: plotWidth) == slot)
        }
    }

    @Test("窗口未填满时：触摸右端吸附到最新样本，不落到空采样位")
    func snapWithinSamples() {
        let w = MonitorSlotWindow(dates: dates([0, 5, 10]))   // 3 个样本
        #expect(w.slot(atX: 953, plotWidth: 953) == 2)
        #expect(w.slot(atX: 900, plotWidth: 953) == 2)
    }

    @Test("值域两端无留白：首尾采样位贴绘图区边缘（时间标签允许悬出）")
    func domainPadding() {
        #expect(MonitorSlotWindow.xFraction(0) == 0)
        #expect(MonitorSlotWindow.xFraction(Double(MonitorSlotWindow.slotCount - 1)) == 1)
        #expect(MonitorSlotWindow.xDomain == 0...Double(MonitorSlotWindow.slotCount - 1))
    }

    @Test("MonitorAxisMath：整洁上/下限按 ladder 取整")
    func axisMath() {
        #expect(MonitorAxisMath.niceCeiling(0) == 1)
        #expect(abs(MonitorAxisMath.niceCeiling(0.138) - 0.15) < 0.0001)   // 1.5×0.1 有浮点尾差
        #expect(MonitorAxisMath.niceCeiling(7.24) == 8)
        #expect(MonitorAxisMath.niceCeiling(80) == 80)
        #expect(MonitorAxisMath.niceCeiling(81) == 100)
        #expect(MonitorAxisMath.niceCeiling(101.9) == 120)
        #expect(MonitorAxisMath.niceFloor(0) == 0)
        #expect(MonitorAxisMath.niceFloor(1026) == 1000)
        #expect(MonitorAxisMath.niceFloor(72) == 60)
        #expect(MonitorAxisMath.niceFloor(80) == 80)
    }

    @Test("inWindow 过滤出窗数据点")
    func inWindowFilter() {
        let base = Date(timeIntervalSince1970: 1_000)
        var points: [LoadSeriesPoint] = []
        for i in 0...12 {   // 13 个：最旧的出窗
            points.append(LoadSeriesPoint(date: base.addingTimeInterval(Double(i)), value: Double(i), kind: "CPU"))
        }
        let w = MonitorSlotWindow(points: points)
        #expect(w.inWindow(points).map(\.date) == points.dropFirst().map(\.date))
    }
}
