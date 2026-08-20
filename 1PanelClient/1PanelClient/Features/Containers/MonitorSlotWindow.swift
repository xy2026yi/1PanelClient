//
//  MonitorSlotWindow.swift
//  1PanelClient
//
//  监控图表的纯数学（自图表视图抽出，便于复用与单测）：
//  固定采样位窗口（MonitorSlotWindow）、整洁上下限（MonitorAxisMath）、
//  Y 轴形态（MonitorYAxis）、数值气泡放置（MonitorBubbleLayout）——
//  容器实时图表与历史监控图表共用，避免同构逻辑两处维护
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

/// 监控图 Y 轴的完整形态：等距对齐后的值域、刻度值（首尾必在列）与数值小数位。
/// 图表把窗口内全部系列的峰值/谷值（或固定值域）交给工厂方法，
/// 两套图表（容器实时/历史监控）共用同一套轴数学
struct MonitorYAxis: Equatable {
    /// 等距对齐后的值域（chartYScale 直接使用）
    let domain: ClosedRange<Double>
    /// 刻度值（AxisMarks 直接使用；横线等距、首尾必在列）
    let ticks: [Double]
    /// 刻度与气泡数值共用的小数位
    let decimals: Int
    /// 实际生效的封顶：传入 cap 但峰值超顶被放弃时为 nil（气泡「贴近封顶」判断用）
    let cap: Double?

    /// 固定值域（负载 0...1 起步超 1 上扩、CPU/内存 0...100）：
    /// 跨度 10 等分共 11 条等距横线，小数位由调用方指定
    static func fixed(_ range: ClosedRange<Double>, decimals: Int) -> MonitorYAxis {
        let step = (range.upperBound - range.lowerBound) / 10
        return MonitorYAxis(
            domain: range,
            ticks: (0...10).map { range.lowerBound + Double($0) * step },
            decimals: decimals,
            cap: nil
        )
    }

    /// 动态值域：基准值域（见 baseDomain）→ 刻度步长向上归整 → 等距对齐
    ///（跨度 = 5 × 步长，恰好 6 值 6 线；恒 0 时 2 × 步长仅 3 个刻度）。
    /// - Parameters:
    ///   - peak / low: 窗口内全部系列的峰值/谷值
    ///   - cap: 上限封顶（如 CPU 百分比传 100）；峰值超封顶（多核容器 CPU% 按核累加可超 100）
    ///     时放弃封顶退纯动态轴，避免超顶数据被绘图区裁平
    ///   - allZero: 窗口数值恒为 0（如 0MB 的内存/缓存）——此时刻度不加密
    static func dynamic(peak: Double, low: Double, cap: Double? = nil, allZero: Bool) -> MonitorYAxis {
        let effectiveCap = cap.flatMap { $0 > 0 && peak <= $0 ? $0 : nil }
        let base = baseDomain(peak: peak, low: low, cap: effectiveCap)
        let step = tickStep(span: base.upperBound - base.lowerBound, dense: !allZero)
        guard base.upperBound > base.lowerBound, step > 0 else {
            return MonitorYAxis(domain: base, ticks: [base.lowerBound],
                                decimals: decimals(forStep: step), cap: effectiveCap)
        }
        let span = Double(allZero ? 2 : 5) * step
        // 封顶轴锚定上限、下限向下回退；其余锚定下限、上限向上补齐
        let domain: ClosedRange<Double>
        if let effectiveCap, base.upperBound >= effectiveCap {
            domain = max(0, effectiveCap - span)...effectiveCap
        } else {
            domain = base.lowerBound...(base.lowerBound + span)
        }
        return MonitorYAxis(
            domain: domain,
            ticks: tickValues(from: domain.lowerBound, to: domain.upperBound, by: step),
            decimals: decimals(forStep: step),
            cap: effectiveCap
        )
    }

    /// 基准 Y 值域（未做等距对齐）：
    /// - 上限：峰值 × 1.15 的紧凑头寸（顶部不预留气泡位——放不下自动转圆点侧面），
    ///   设有封顶（CPU 100%）时不超过它；
    /// - 下限：封顶轴上限被钉住时抬到窗口谷值下方一个步长（步长 = cap/20，如 100 → 5%）；
    ///   动态轴数据带高位（谷值过半峰值）时收紧贴数据带；其余为 0（全 0 时刻度仍可读）
    private static func baseDomain(peak: Double, low: Double, cap: Double?) -> ClosedRange<Double> {
        if let cap {
            if max(peak, 0.1) * 1.15 >= cap {
                // 上限钉在封顶值：下限抬到窗口谷值下方一个步长（如 80~98% → 75...100%）
                let step = cap / 20
                let lower = max(0, ((low - step) / step).rounded(.down) * step)
                return lower...max(cap, lower + step)
            }
            return 0...max(peak, 0.1) * 1.15
        }
        if peak > 0, low > peak * 0.5 {
            // 动态轴高位窄带：上下限同时收紧贴数据（如内存 1140~1260MB → 1000...1449）
            let upper = peak * 1.15
            let lower = min(MonitorAxisMath.niceFloor(low * 0.9), upper * 0.9)
            return lower...upper
        }
        return 0...max(peak * 1.15, 1)
    }

    /// 刻度步长：跨度按份数（动态 5 份、恒 0 两份）向上归整到 ladder × 10^k——
    /// 配合等距对齐的「跨度 = 份数 × 步长」恒得 6 值 6 线；恒 0 时不加密（无 4 档）
    private static func tickStep(span: Double, dense: Bool) -> Double {
        guard span > 0 else { return 1 }
        let raw = span / (dense ? 5 : 2)
        let magnitude = pow(10, floor(log10(raw)))
        let normalized = raw / magnitude
        let ladder = dense ? [1.0, 2, 2.5, 4, 5, 10] : [1.0, 2, 2.5, 5, 10]
        let nice = ladder.first { $0 >= normalized - 0.0001 } ?? 10
        return nice * magnitude
    }

    /// 刻度值：下限起步按步进到上限（值域已等距对齐，跨度 = 步长整数倍、首尾必在列）
    private static func tickValues(from lower: Double, to upper: Double, by step: Double) -> [Double] {
        guard upper > lower, step > 0 else { return [lower] }
        let n = max(1, Int(((upper - lower) / step).rounded()))
        return (0...n).map { lower + Double($0) * step }
    }

    /// 数值小数位：由刻度步长决定（步长 0.0x → 两位、0.x/2.5 → 一位、整数 → 取整），
    /// 刻度与气泡数值保持一致
    static func decimals(forStep step: Double) -> Int {
        if step.truncatingRemainder(dividingBy: 1) == 0 { return 0 }
        if (step * 10).truncatingRemainder(dividingBy: 1) == 0 { return 1 }
        return 2
    }
}

/// 数值气泡的放置位置（两套监控图共用）：
/// 默认水平居中于选中位（贴边收回边界内）、悬于最高圆点正上方；
/// nearCap（值贴近封顶/值域顶端）或上方放不下时改放圆点侧面——
/// 圆点在图表左半边时气泡放右侧、右半边放左侧，垂直与圆点对齐并收回边界内
enum MonitorBubbleLayout {
    static func position(nearCap: Bool,
                         xCenter: CGFloat, yTop: CGFloat,
                         halfW: CGFloat, halfH: CGFloat,
                         geoWidth: CGFloat, geoHeight: CGFloat) -> (x: CGFloat, y: CGFloat) {
        let noRoomAbove = yTop < 12 + 2 * halfH
        if nearCap || noRoomAbove {
            let toRight = xCenter < geoWidth / 2
            let x = toRight
                ? min(xCenter + 12 + halfW, geoWidth - halfW - 4)
                : max(xCenter - 12 - halfW, halfW + 4)
            let y = min(max(yTop, halfH + 2), geoHeight - halfH - 2)
            return (x, y)
        }
        let x = min(max(xCenter, halfW + 4), geoWidth - halfW - 4)
        let y = max(yTop - 12 - halfH, halfH + 2)
        return (x, y)
    }
}
