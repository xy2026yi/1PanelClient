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

@Suite("MonitorYAxis / MonitorBubbleLayout 共用轴数学")
struct MonitorYAxisTests {
    @Test("动态：等距对齐后恰好 6 值 6 线、首尾在列")
    func dynamicBasic() {
        let axis = MonitorYAxis.dynamic(peak: 8, low: 0, allZero: false)   // 0...9.2 → 步长 2
        #expect(axis.domain == 0...10)
        #expect(axis.ticks == [0, 2, 4, 6, 8, 10])
        #expect(axis.decimals == 0)
        #expect(axis.cap == nil)
    }

    @Test("动态：数值恒 0 时不加密，退 3 个刻度")
    func dynamicAllZero() {
        let axis = MonitorYAxis.dynamic(peak: 0, low: 0, allZero: true)    // 0...1 → 步长 0.5
        #expect(axis.domain == 0...1)
        #expect(axis.ticks == [0, 0.5, 1])
        #expect(axis.decimals == 1)
    }

    @Test("动态：数据带高位收紧下限贴数据带")
    func dynamicHighBand() {
        // 内存 1140~1260MB：基准 1000...1449 → 步长 100 → 1000...1500
        let axis = MonitorYAxis.dynamic(peak: 1260, low: 1140, allZero: false)
        #expect(axis.domain == 1000...1500)
        #expect(axis.ticks == [1000, 1100, 1200, 1300, 1400, 1500])
    }

    @Test("封顶：数据带高位抬下限、锚定上限")
    func capPinned() {
        let axis = MonitorYAxis.dynamic(peak: 98, low: 80, cap: 100, allZero: false)
        #expect(axis.cap == 100)
        #expect(axis.domain == 75...100)
        #expect(axis.ticks == [75, 80, 85, 90, 95, 100])
        // 峰值恰等于封顶：仍封顶不裁剪
        let edge = MonitorYAxis.dynamic(peak: 100, low: 100, cap: 100, allZero: false)
        #expect(edge.cap == 100)
        #expect(edge.domain == 95...100)
    }

    @Test("封顶：峰值超封顶放弃封顶退动态轴（多核容器 CPU% 按核累加可超 100）")
    func capAbandoned() {
        // 高位窄带 240~250：200...300，超顶数据不被绘图区裁平
        let axis = MonitorYAxis.dynamic(peak: 250, low: 240, cap: 100, allZero: false)
        #expect(axis.cap == nil)
        #expect(axis.domain == 200...300)
        #expect(axis.domain.upperBound >= 250)
        #expect(axis.ticks.first == 200 && axis.ticks.last == 300)
        // 偶发尖峰 120、谷值低位：0...200
        let spike = MonitorYAxis.dynamic(peak: 120, low: 3, cap: 100, allZero: false)
        #expect(spike.cap == nil)
        #expect(spike.domain == 0...200)
    }

    @Test("固定：跨度 10 等分共 11 条等距横线")
    func fixedAxis() {
        let axis = MonitorYAxis.fixed(0...1.5, decimals: 2)
        #expect(axis.domain == 0...1.5)
        #expect(axis.ticks.count == 11)
        #expect(axis.ticks.first == 0)
        #expect(abs((axis.ticks.last ?? 0) - 1.5) < 0.0001)   // 0.15×10 有浮点尾差
        #expect(axis.decimals == 2)
    }

    @Test("气泡布局：贴近顶端或上方放不下时转圆点侧面，常规悬于上方")
    func bubbleLayout() {
        // 圆点在左半边、值贴近顶端 → 气泡放右侧、垂直与圆点对齐
        let side = MonitorBubbleLayout.position(nearCap: true, xCenter: 50, yTop: 40,
                                                halfW: 40, halfH: 10, geoWidth: 300, geoHeight: 150)
        #expect(side.x == 102)   // min(50+12+40, 300-44)
        #expect(side.y == 40)
        // 常规：水平居中、悬于最高圆点正上方
        let above = MonitorBubbleLayout.position(nearCap: false, xCenter: 150, yTop: 60,
                                                 halfW: 40, halfH: 10, geoWidth: 300, geoHeight: 150)
        #expect(above.x == 150)
        #expect(above.y == 38)   // max(60-12-10, 12)
    }
}
