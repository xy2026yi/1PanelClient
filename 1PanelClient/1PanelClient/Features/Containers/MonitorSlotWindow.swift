//
//  MonitorSlotWindow.swift
//  1PanelClient
//
//  容器监控图表「固定采样位窗口」的纯映射逻辑（自 ContainerMonitorChart 抽出，便于单测）
//

import Foundation
import CoreGraphics

/// 采样时刻去重升序后取最近 slotCount 个，依次占据 0...slotCount-1 号采样位；
/// X 值域两端各留 edgePad 个采样位边距（首尾时间标签居中可完整显示、两端数据点不贴边）。
struct MonitorSlotWindow {
    /// 窗口采样位总数（首尾贴住绘图区边缘）
    static let slotCount = 12
    /// 绘图区两端的留白（采样位单位）
    static let edgePad = 0.5
    /// X 值域总跨度（slotCount-1 个采样间隔 + 两端留白）
    static let xSpan = Double(slotCount - 1) + 2 * edgePad

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

    /// X 值域（含两端留白）
    static var xDomain: ClosedRange<Double> {
        -edgePad...Double(slotCount - 1) + edgePad
    }

    /// 采样位（0...slotCount-1）→ 绘图区水平比例（两端各留 edgePad 个采样位）
    static func xFraction(_ slot: Double) -> CGFloat {
        CGFloat((slot + edgePad) / xSpan)
    }

    /// 触摸 x（0...plotWidth，相对绘图区）→ 就近吸附的采样位（限制在已有样本范围内）
    func slot(atX x: CGFloat, plotWidth: CGFloat) -> Int? {
        let v = Double(x / plotWidth) * Self.xSpan - Self.edgePad
        let clamped = min(max(Int(v.rounded()), 0), dates.count - 1)
        return clamped >= 0 ? clamped : nil
    }
}
