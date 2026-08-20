//
//  MonitorSlotWindow.swift
//  1PanelClient
//
//  容器监控图表「固定采样位窗口」的纯映射逻辑（自 ContainerMonitorChart 抽出，便于单测）
//

import Foundation
import CoreGraphics

/// 采样时刻去重升序后取最近 slotCount 个，依次占据 0...slotCount-1 号采样位；
/// X 值域即 0...slotCount-1（首尾数据点贴绘图区两缘，时间标签允许悬出行边界）。
struct MonitorSlotWindow {
    /// 窗口采样位总数（首尾贴住绘图区边缘）
    static let slotCount = 12
    /// X 值域总跨度（slotCount-1 个采样间隔）
    static let xSpan = Double(slotCount - 1)

    /// 窗口内的采样时刻（升序，最多 slotCount 个）
    let dates: [Date]
    /// 采样时刻 → 窗口内采样位（0...slotCount-1）
    let slotByDate: [Date: Int]

    init(dates: [Date]) {
        let unique = Array(Set(dates).sorted().suffix(Self.slotCount))
        self.dates = unique
        self.slotByDate = Dictionary(unique.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    }

    init(points: [LoadSeriesPoint]) {
        self.init(dates: points.map(\.date))
    }

    /// 落在窗口内的数据点
    func inWindow(_ points: [LoadSeriesPoint]) -> [LoadSeriesPoint] {
        points.filter { slotByDate[$0.date] != nil }
    }

    /// X 值域（首尾采样位贴绘图区两缘）
    static var xDomain: ClosedRange<Double> {
        0...Double(slotCount - 1)
    }

    /// 采样位（0...slotCount-1）→ 绘图区水平比例
    static func xFraction(_ slot: Double) -> CGFloat {
        CGFloat(slot / xSpan)
    }

    /// 触摸 x（0...plotWidth，相对绘图区）→ 就近吸附的采样位（限制在已有样本范围内）
    func slot(atX x: CGFloat, plotWidth: CGFloat) -> Int? {
        let v = Double(x / plotWidth) * Self.xSpan
        let clamped = min(max(Int(v.rounded()), 0), dates.count - 1)
        return clamped >= 0 ? clamped : nil
    }
}

/// 监控图 y 轴值域/刻度的纯数学（整洁上/下限），自图表视图抽出便于复用与单测
enum MonitorAxisMath {
    private static let ladder = [1.0, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]

    /// 整洁上限：向上取 ladder × 10^k 中不小于 x 的最小值
    static func niceCeiling(_ peak: Double) -> Double {
        guard peak > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(peak)))
        let normalized = peak / magnitude
        let nice = ladder.first { $0 >= normalized - 0.0001 } ?? 10
        return nice * magnitude
    }

    /// 整洁下限：向下取 ladder × 10^k 中不超过 x 的最大值
    static func niceFloor(_ x: Double) -> Double {
        guard x > 0 else { return 0 }
        let magnitude = pow(10, floor(log10(x)))
        let normalized = x / magnitude
        let nice = ladder.last { $0 <= normalized + 0.0001 } ?? 1
        return nice * magnitude
    }
}
