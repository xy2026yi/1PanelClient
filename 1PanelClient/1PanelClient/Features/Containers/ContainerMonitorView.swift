//
//  ContainerMonitorView.swift
//  1PanelClient
//

import SwiftUI
import Combine
import Charts

// MARK: - 容器监控页

/// 单容器实时监控：按所选间隔轮询 /containers/stats/:id，
/// CPU / 内存(含缓存) / 磁盘I/O / 网络 四张曲线图（仅标题+图表）
@MainActor
final class ContainerMonitorViewModel: ObservableObject {
    @Published var cpuPoints: [MonitorPoint] = []      // CPU %
    @Published var memPoints: [MonitorPoint] = []      // 内存 MB
    @Published var cachePoints: [MonitorPoint] = []    // 缓存 MB
    @Published var ioReadPoints: [MonitorPoint] = []   // 读取 MB/s
    @Published var ioWritePoints: [MonitorPoint] = []  // 写入 MB/s
    @Published var netTXPoints: [MonitorPoint] = []    // 上行 KB/s
    @Published var netRXPoints: [MonitorPoint] = []    // 下行 KB/s
    @Published var errorMessage: String?

    /// 每系列最多保留采样点数（与网页端一致保留 20 个）
    private let maxPoints = 20
    private let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    /// 拉取一次快照并追加到各曲线
    func sample(containerID: String) async {
        let path = APIEndpoint.containersStats.path
            .replacingOccurrences(of: ":containerID", with: containerID)
        do {
            let stats: ContainerStatsSnapshot = try await client.send(
                path: path, method: APIEndpoint.containersStats.method, as: ContainerStatsSnapshot.self
            )
            errorMessage = nil
            guard let date = MonitorDate.parse(stats.shotTime ?? "") else { return }
            push(.init(date: date, value: stats.cpuPercent ?? 0), into: &cpuPoints)
            push(.init(date: date, value: stats.memory ?? 0), into: &memPoints)
            push(.init(date: date, value: stats.cache ?? 0), into: &cachePoints)
            push(.init(date: date, value: stats.ioRead ?? 0), into: &ioReadPoints)
            push(.init(date: date, value: stats.ioWrite ?? 0), into: &ioWritePoints)
            push(.init(date: date, value: stats.networkTX ?? 0), into: &netTXPoints)
            push(.init(date: date, value: stats.networkRX ?? 0), into: &netRXPoints)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func push(_ point: MonitorPoint, into points: inout [MonitorPoint]) {
        points.append(point)
        if points.count > maxPoints {
            points.removeFirst(points.count - maxPoints)
        }
    }
}

struct ContainerMonitorView: View {
    let container: Container
    @StateObject private var vm: ContainerMonitorViewModel
    /// 刷新间隔（秒），默认 5s
    @State private var interval = 5
    @Environment(\.scenePhase) private var scenePhase
    @State private var isSceneActive = true

    init(container: Container) {
        self.container = container
        _vm = StateObject(wrappedValue: ContainerMonitorViewModel(
            server: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        ))
    }

    var body: some View {
        List {
            Section {
                Picker("刷新间隔", selection: $interval) {
                    Text("3s").tag(3)
                    Text("5s").tag(5)
                    Text("10s").tag(10)
                    Text("30s").tag(30)
                    Text("60s").tag(60)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
            }

            if let err = vm.errorMessage, vm.cpuPoints.isEmpty {
                Section {
                    ContentUnavailableView(
                        "获取监控数据失败", systemImage: "exclamationmark.triangle", description: Text(err)
                    )
                }
            } else {
                monitorSection("CPU", single: vm.cpuPoints, color: .blue, unit: "%")
                monitorSection("内存", dual: memorySeries, styles: ["内存": .purple, "缓存": .orange], unit: "MB")
                monitorSection("磁盘 I/O", dual: ioSeries, styles: ["读取": .blue, "写入": .orange], unit: "MB")
                monitorSection("网络", dual: networkSeries, styles: ["上行": .green, "下行": .purple], unit: "KB")
            }
        }
        .environment(\.defaultMinListRowHeight, 32)
        .navigationTitle("监控")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, phase in
            isSceneActive = phase == .active
        }
        // 按所选间隔轮询（仅页面存活且 App 前台活跃时采样）
        .task {
            while !Task.isCancelled {
                if isSceneActive {
                    await vm.sample(containerID: container.containerID)
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    // MARK: 数据系列

    private var memorySeries: [LoadSeriesPoint] {
        vm.memPoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: "内存") }
            + vm.cachePoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: "缓存") }
    }

    private var ioSeries: [LoadSeriesPoint] {
        vm.ioReadPoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: "读取") }
            + vm.ioWritePoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: "写入") }
    }

    private var networkSeries: [LoadSeriesPoint] {
        vm.netTXPoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: "上行") }
            + vm.netRXPoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: "下行") }
    }

    // MARK: 图表区（标题 + 图表）

    /// - Parameter styles: 双曲线各自的系列名与颜色（拖动浮层按此过滤显示，传入本图表实际包含的系列）
    @ViewBuilder
    private func monitorSection(
        _ title: String,
        single: [MonitorPoint] = [],
        color: Color = .blue,
        dual: [LoadSeriesPoint] = [],
        styles: KeyValuePairs<String, Color> = [:],
        unit: String
    ) -> some View {
        Section {
            HStack {
                Text(title).font(.headline)
                Spacer()
            }
            .padding(.top, 8)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

            Group {
                if !dual.isEmpty {
                    ContainerMonitorChart(points: dual, styles: styles, unit: unit)
                } else if !single.isEmpty {
                    // 单曲线（CPU）：系列名固定 "CPU"，图例隐藏
                    ContainerMonitorChart(
                        points: single.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: "CPU") },
                        styles: ["CPU": color],
                        unit: unit
                    )
                } else {
                    chartPlaceholder
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 8)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        }
    }

    private var chartPlaceholder: some View {
        Text("暂无数据")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 120)
    }
}

// MARK: - 可拖动查看数值的监控图表

/// 折线图 + 拖动浮层：按住图表横向滑动显示竖排数值（按值降序，颜色与曲线一致），
/// 交互与管理 - 监控的磁盘 I/O / 网络图表相同
struct ContainerMonitorChart: View {
    let points: [LoadSeriesPoint]
    let styles: KeyValuePairs<String, Color>
    let unit: String

    @State private var selectedDate: Date?

    var body: some View {
        let seriesCounts = Dictionary(grouping: points, by: \.kind).mapValues(\.count)
        return Chart(points) { p in
            LineMark(x: .value("时间", p.date), y: .value("值", p.value))
                .foregroundStyle(by: .value("类型", p.kind))
            // 数据点过少时折线画不出来，补圆点让单点也可见
            if (seriesCounts[p.kind] ?? 0) <= 2 {
                PointMark(x: .value("时间", p.date), y: .value("值", p.value))
                    .foregroundStyle(by: .value("类型", p.kind))
                    .symbolSize(30)
            }
            if let sel = selectedDate {
                RuleMark(x: .value("选中", sel))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartForegroundStyleScale(styles)
        // 图表下方不显示系列名图例行（拖动浮层已按颜色标注各系列）
        .chartLegend(.hidden)
        // 固定 0 起点 + 最小值域 1，避免数据恒为 0（如空闲 CPU）时值域退化为 [0,0]、
        // 自动刻度不渲染导致左侧无百分比标签
        .chartYScale(domain: 0...yHeadroom)
        // X 值域两侧留 3% 垫，单点/极短跨度时避免值域退化 [t,t] 不渲染刻度
        .chartXScale(domain: xDomain)
        .chartXAxis {
            // 刻度取图表内部 2~3 个均匀位置（避开左右边缘的标签裁切区），
            // 数量固定不随采样点增多跳变；统一 HH:mm:ss 格式
            AxisMarks(values: xMarkDates) { value in
                AxisGridLine()
                AxisValueLabel(centered: true) {
                    if let d = value.as(Date.self) {
                        Text(Self.timeFormatter.string(from: d))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Self.axisText(v, unit: unit))
                    }
                }
            }
        }
        .frame(height: 120)
        .chartOverlay { proxy in
            GeometryReader { geo in
                // 手势层：触摸 x → 日期
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                guard let plotAnchor = proxy.plotFrame else { return }
                                let plotFrame = geo[plotAnchor]
                                let x = gesture.location.x - plotFrame.minX
                                guard x >= 0, x <= plotFrame.width,
                                      let date: Date = proxy.value(atX: x) else { return }
                                selectedDate = clampDate(date)
                            }
                            .onEnded { _ in selectedDate = nil }
                    )

                // 选中浮层：竖排显示各系列数值（值大的在最上面），颜色与曲线一致
                if let sel = selectedDate {
                    let entries = sortedEntries(at: sel)
                    let x = proxy.position(forX: sel) ?? 0
                    // 靠右边缘时翻转到左侧
                    let flip = x + 128 > geo.size.width
                    tooltip(entries)
                        .offset(x: flip ? x - 128 : x + 12, y: 10)
                }
            }
        }
    }

    /// 选中时间的各系列数值（按值降序，返回已格式化文本）
    private func sortedEntries(at date: Date) -> [(title: String, text: String, color: Color)] {
        var raw: [(String, Double, Color)] = []
        for (kind, color) in styles {
            raw.append((kind, nearestValue(to: date, kind: kind) ?? 0, color))
        }
        return raw.sorted { $0.1 > $1.1 }
            .map { ($0.0, String(format: "%.2f%@", $0.1, unit), $0.2) }
    }

    /// 图内数值浮层（竖排，颜色与曲线一致）
    private func tooltip(_ entries: [(title: String, text: String, color: Color)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(entries, id: \.title) { entry in
                HStack(spacing: 5) {
                    StatusDot(color: entry.color)
                    Text(entry.title).foregroundStyle(entry.color)
                    Spacer(minLength: 4)
                    Text(entry.text).monospacedDigit().foregroundStyle(entry.color)
                }
            }
        }
        .font(.caption2)
        .frame(width: 112, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
    }

    /// 距目标时间最近的指定系列数值
    private func nearestValue(to date: Date, kind: String) -> Double? {
        points.filter { $0.kind == kind }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?
            .value
    }

    /// 把手势日期限制在数据时间范围内
    private func clampDate(_ date: Date) -> Date {
        guard let first = points.map(\.date).min(),
              let last = points.map(\.date).max() else { return date }
        return min(max(date, first), last)
    }

    /// Y 轴上限：数据最大值留 15% 余量，下限至少 1 个单位（全 0/极小值时刻度仍可读）
    private var yHeadroom: Double {
        max((points.map(\.value).max() ?? 0) * 1.15, 1)
    }

    /// X 值域：数据范围两侧各留 3%（至少 2s）垫，保证单点/极短跨度时刻度可渲染
    private var xDomain: ClosedRange<Date> {
        let dates = points.map(\.date)
        guard let first = dates.min(), let last = dates.max(), last >= first else {
            return Date()...Date().addingTimeInterval(1)
        }
        let pad = max(last.timeIntervalSince(first) * 0.03, 2)
        return first.addingTimeInterval(-pad)...last.addingTimeInterval(pad)
    }

    /// X 轴刻度时间：图内部 2~3 个均匀位置（避开边缘裁切），跨度足够时取整到 5s/30s；
    /// 单点时标数据自身时间
    private var xMarkDates: [Date] {
        let dates = points.map(\.date)
        guard let first = dates.min(), let last = dates.max(), last > first else {
            return dates.isEmpty ? [] : [dates[0]]
        }
        let span = last.timeIntervalSince(first)
        // 跨度 ≥40s 显示 3 个，否则 2 个；位置整体内收 18%
        let fractions: [Double] = span >= 40 ? [0.18, 0.5, 0.82] : [0.22, 0.78]
        // 跨度足够时秒数取整更整洁；极短跨度取整会重合，保持原值
        let roundTo: Double = span >= 240 ? 30 : (span >= 20 ? 5 : 1)
        let marks = fractions.map { f -> Date in
            let t = first.addingTimeInterval(span * f).timeIntervalSince1970
            return Date(timeIntervalSince1970: (t / roundTo).rounded() * roundTo)
        }
        let unique = Array(Set(marks)).sorted()
        return unique.count >= 2 ? unique : fractions.map { first.addingTimeInterval(span * $0) }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Y 轴刻度文本：整数直接拼单位（30KB），小数保留一位（0.5KB）
    private static func axisText(_ value: Double, unit: String) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(value))\(unit)"
        }
        return String(format: "%.1f%@", value, unit)
    }
}

