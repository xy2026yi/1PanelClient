//
//  ContainerMonitorView.swift
//  1PanelClient
//

import SwiftUI
import Combine
import Charts

// MARK: - 容器监控页

/// 单容器实时监控：每 1 秒轮询 /containers/stats/:id，
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
    /// 轻提示（自动消失）：已有数据后采样持续失败时提示一次
    @Published var toastMessage: String?

    /// 连续失败计数：达到阈值后轻提示（错误页仅在完全没有数据时显示）
    private var consecutiveFailures = 0
    private static let failureToastThreshold = 3
    private var toastTask: Task<Void, Never>?

    /// 每系列最多保留采样点数：与图表窗口采样位保持同源
    /// （满后旧样本从左侧推出）
    private let maxPoints = MonitorSlotWindow.slotCount
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
            consecutiveFailures = 0
            // X 网格取本地采样时刻：服务器 shotTime 受缓存/抖动影响且可能出现重复值，
            // 直接采用会让时间标签间隔忽大忽小（12s/13s/15s 混杂）
            let date = Date()
            push(.init(date: date, value: stats.cpuPercent ?? 0), into: &cpuPoints)
            push(.init(date: date, value: stats.memory ?? 0), into: &memPoints)
            push(.init(date: date, value: stats.cache ?? 0), into: &cachePoints)
            push(.init(date: date, value: stats.ioRead ?? 0), into: &ioReadPoints)
            push(.init(date: date, value: stats.ioWrite ?? 0), into: &ioWritePoints)
            push(.init(date: date, value: stats.networkTX ?? 0), into: &netTXPoints)
            push(.init(date: date, value: stats.networkRX ?? 0), into: &netRXPoints)
        } catch {
            errorMessage = error.localizedDescription
            // 已有数据时不打断图表，连续失败到阈值后轻提示一次
            if !cpuPoints.isEmpty {
                consecutiveFailures += 1
                if consecutiveFailures == Self.failureToastThreshold {
                    showToast(L10n.t("监控数据获取失败，图表显示为最近数据"))
                }
            }
        }
    }

    /// 显示自动消失的轻提示（2 秒）
    private func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { self?.toastMessage = nil }
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
            if let err = vm.errorMessage, vm.cpuPoints.isEmpty {
                Section {
                    ContentUnavailableView(
                        L10n.t("获取监控数据失败"), systemImage: "exclamationmark.triangle.fill", description: Text(err)
                    )
                }
            } else {
                monitorSection("CPU", single: vm.cpuPoints, color: .blue, unit: "%", yCap: 100)
                monitorSection(L10n.t("内存"), dual: memorySeries, styles: [L10n.t("内存"): .purple, L10n.t("缓存"): .orange], unit: "MB")
                monitorSection(L10n.t("磁盘 I/O"), dual: ioSeries, styles: [L10n.t("读取"): .blue, L10n.t("写入"): .orange], unit: "MB")
                monitorSection(L10n.t("网络"), dual: networkSeries, styles: [L10n.t("上行"): .green, L10n.t("下行"): .purple], unit: "KB")
            }
        }
        .environment(\.defaultMinListRowHeight, 32)
        .navigationTitle(L10n.t("监控"))
        .navigationBarTitleDisplayMode(.inline)
        .toastOverlay(message: $vm.toastMessage,
                      systemImage: "exclamationmark.triangle.fill",
                      iconColor: .orange)
        .onChange(of: scenePhase) { _, phase in
            isSceneActive = phase == .active
        }
        // 每 1 秒轮询一次（仅页面存活且 App 前台活跃时采样）
        .task {
            while !Task.isCancelled {
                if isSceneActive {
                    await vm.sample(containerID: container.containerID)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: 数据系列

    private var memorySeries: [LoadSeriesPoint] {
        vm.memPoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: L10n.t("内存")) }
            + vm.cachePoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: L10n.t("缓存")) }
    }

    private var ioSeries: [LoadSeriesPoint] {
        vm.ioReadPoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: L10n.t("读取")) }
            + vm.ioWritePoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: L10n.t("写入")) }
    }

    private var networkSeries: [LoadSeriesPoint] {
        vm.netTXPoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: L10n.t("上行")) }
            + vm.netRXPoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: L10n.t("下行")) }
    }

    // MARK: 图表区（标题 + 图表）

    /// - Parameter styles: 双曲线各自的系列名与颜色（数值气泡按此过滤显示，传入本图表实际包含的系列）
    /// - Parameter yCap: y 轴上限封顶（CPU 百分比传 100；其余量纲传 nil 走纯动态）
    @ViewBuilder
    private func monitorSection(
        _ title: String,
        single: [MonitorPoint] = [],
        color: Color = .blue,
        dual: [LoadSeriesPoint] = [],
        styles: KeyValuePairs<String, Color> = [:],
        unit: String,
        yCap: Double? = nil
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
                    ContainerMonitorChart(points: dual, styles: styles, unit: unit, yCap: yCap)
                } else if !single.isEmpty {
                    // 单曲线（CPU）：系列名固定 "CPU"，图例隐藏
                    ContainerMonitorChart(
                        points: single.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: "CPU") },
                        styles: ["CPU": color],
                        unit: unit,
                        yCap: yCap
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
        Text(L10n.t("暂无数据"))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 120)
    }
}

// MARK: - 固定采样网格的监控图表

/// 折线图 + 固定采样网格 + 点选查看数值：
/// X 轴为固定 12 个采样位的窗口（0...11，首尾数据点贴绘图区两缘），
/// 中间 10 个采样位（1...10）各画一条等距竖向虚线，两端边缘采样位不画；
/// 时间标签固定 5 个，严格正对采样位居中显示（采样位 0、3、6、9、11），
/// 首尾在窗口两端、允许悬出行边界（不做贴边收回），相邻标签之间隔 2 条虚线；
/// 初始样本由左至右逐位填充（时间标签随之从左至右出现），
/// 窗口满后保留最近 12 个样本、曲线向左推进；
/// Y 轴形态由共享的 MonitorYAxis 计算：峰值×1.15 紧凑头寸，设 yCap（CPU 100%）时封顶、
/// 数据带高位时抬起下限，峰值超封顶（多核 CPU% 按核累加）时放弃封顶退纯动态轴，
/// 刻度自算且首尾必在列；
/// 点击/拖动选中采样位：每条曲线在该位显示同色圆点，
/// 数值气泡默认悬浮于最高一条曲线上方，值贴近封顶（>90%）或上方放不下时改放圆点左/右侧
///（再次点击同一位取消选中）。
struct ContainerMonitorChart: View {
    /// 图表高度
    private static let plotHeight: CGFloat = 150
    /// 画竖向虚线的采样位（内部 10 个、等距；两端边缘采样位不画）
    private static let dashSlots = Array(1...10)
    /// 时间标签的采样位（严格正对采样位居中；首尾为窗口两端、允许悬出）。
    /// 相邻间隔 3 个采样位（中间隔 2 条虚线），末段 9→11 隔 1 条
    private static let labelSlots = [0, 3, 6, 9, 11]

    let points: [LoadSeriesPoint]
    let styles: KeyValuePairs<String, Color>
    let unit: String
    /// y 轴上限封顶（如 CPU 百分比传 100）：动态上限不超过它，数据高位时下限相应抬起；
    /// 峰值超封顶时放弃封顶退纯动态轴（见 MonitorYAxis.dynamic）
    var yCap: Double? = nil

    @State private var selectedSlot: Int?
    /// 本次手势开始前已选中的采样位（松手时判断「点击已选位 → 取消」）
    @State private var slotAtGestureStart: Int?
    /// 图表绘图区（相对图表整体 frame），自绘时间轴与气泡据此与数据区对齐
    @State private var plotRect: CGRect = .zero
    /// 数值气泡实际尺寸（position 按中心定位，计算与最高线的间距用）
    @State private var bubbleSize: CGSize = .zero

    var body: some View {
        let window = MonitorSlotWindow(points: points)
        let plotted = window.inWindow(points)
        let slots = window.slotByDate
        let seriesCounts = Dictionary(grouping: plotted, by: \.kind).mapValues(\.count)
        // Y 轴形态（值域/刻度/小数位）一次算好：轴刻度、气泡数值与「贴近封顶」判断共用
        let values = plotted.map(\.value)
        let axis = MonitorYAxis.dynamic(
            peak: values.max() ?? 0,
            low: values.min() ?? 0,
            cap: yCap,
            allZero: !values.isEmpty && values.allSatisfy { $0 == 0 }
        )
        return VStack(spacing: 2) {
            Chart {
                // 固定网格虚线（画在最底层）：内部 10 个采样位，等距；
                // 两端边缘采样位（0 和 11）也绘数据点但不画虚线
                ForEach(Self.dashSlots, id: \.self) { slot in
                    RuleMark(x: .value(L10n.t("网格"), Double(slot)))
                        .foregroundStyle(Color.secondary.opacity(0.3))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }

                ForEach(plotted) { p in
                    LineMark(x: .value(L10n.t("采样位"), Double(slots[p.date] ?? 0)),
                             y: .value(L10n.t("值"), p.value))
                        .foregroundStyle(by: .value(L10n.t("类型"), p.kind))
                    // 数据点过少时折线画不出来，补圆点让单点也可见
                    if (seriesCounts[p.kind] ?? 0) <= 2 {
                        PointMark(x: .value(L10n.t("采样位"), Double(slots[p.date] ?? 0)),
                                  y: .value(L10n.t("值"), p.value))
                            .foregroundStyle(by: .value(L10n.t("类型"), p.kind))
                            .symbolSize(30)
                    }
                }

                // 选中采样位：深色虚线 + 每条曲线一个同色圆点
                if let sel = selectedSlot {
                    RuleMark(x: .value(L10n.t("选中"), Double(sel)))
                        .foregroundStyle(Color.primary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    ForEach(Array(styles), id: \.key) { kind, color in
                        if let v = value(atSlot: sel, kind: kind) {
                            PointMark(x: .value(L10n.t("选中"), Double(sel)), y: .value(L10n.t("值"), v))
                                .foregroundStyle(color)
                                .symbolSize(90)
                        }
                    }
                }
            }
            .chartForegroundStyleScale(styles)
            // 图表下方不显示系列名图例行（气泡/圆点已按颜色标注各系列）
            .chartLegend(.hidden)
            // Y 轴形态见上方 axis（MonitorYAxis）：上限可封顶、数据高位时抬下限
            .chartYScale(domain: axis.domain)
            // 固定采样窗口（首尾采样位贴绘图区两缘），虚线/标签位置恒定不动
            .chartXScale(domain: MonitorSlotWindow.xDomain)
            // 时间标签自绘（见 timeAxis）：系统轴的自动碰撞会丢弃/裁切标签，位置无法稳定控制
            .chartXAxis(.hidden)
            .chartYAxis {
                // 自算刻度值（首尾必含）：系统自动刻度在值域切换后会丢端点
                //（如 0...100 只画 25/50/75/100，缺 0%）
                AxisMarks(position: .leading, values: axis.ticks) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(Self.axisText(v, unit: unit, decimals: axis.decimals))
                                .font(.caption2)
                                .monospacedDigit()
                                .fixedSize()
                                // 与绘图区左缘拉开距离（同 debug 示例：刻度不贴住曲线区）
                                .padding(.trailing, 12)
                        }
                    }
                }
            }
            .frame(height: Self.plotHeight)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    let plotFrame = proxy.plotFrame.map { geo[$0] } ?? .zero

                    // 手势层：触摸 x → 就近吸附到采样位
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { gesture in
                                    guard plotFrame.width > 0, !window.dates.isEmpty else { return }
                                    if slotAtGestureStart == nil {
                                        slotAtGestureStart = selectedSlot
                                    }
                                    let x = gesture.location.x - plotFrame.minX
                                    guard x >= 0, x <= plotFrame.width else { return }
                                    selectedSlot = window.slot(atX: x, plotWidth: plotFrame.width)
                                }
                                .onEnded { _ in
                                    // 再次点击已选中的采样位取消；拖到别的位松手则保持新选中
                                    if selectedSlot != nil, selectedSlot == slotAtGestureStart {
                                        selectedSlot = nil
                                    }
                                    slotAtGestureStart = nil
                                }
                        )

                    // 布局期间同步绘图区位置，供自绘时间轴/气泡对齐数据区
                    // （不能只靠手势回调更新——用户不触摸时 plotRect 永远是 .zero）
                    Color.clear
                        .onAppear { plotRect = plotFrame }
                        .onChange(of: plotFrame) { _, new in plotRect = new }

                    // 数值气泡：默认水平居中于选中位置（贴边收回）、悬于最高一条曲线上方——
                    // y 按值域直接换算，不走 proxy.position(forY:)（其返回值不稳，会导致气泡贴顶）；
                    // 值贴近封顶（>90%，按实际生效的封顶——被放弃时为 nil 不触发）
                    // 或上方放不下时改放圆点左/右侧（见 MonitorBubbleLayout.position）
                    if let sel = selectedSlot, plotFrame.width > 0 {
                        let entries = entries(atSlot: sel, decimals: axis.decimals)
                        if let topValue = entries.map(\.value).max() {
                            let xCenter = plotFrame.minX
                                + plotFrame.width * MonitorSlotWindow.xFraction(Double(sel))
                            let span = max(axis.domain.upperBound - axis.domain.lowerBound, .ulpOfOne)
                            let yTop = plotFrame.minY
                                + plotFrame.height * ((axis.domain.upperBound - topValue) / span)
                            let pos = MonitorBubbleLayout.position(
                                nearCap: axis.cap.map { topValue > $0 * 0.9 } ?? false,
                                xCenter: xCenter, yTop: yTop,
                                halfW: bubbleSize.width / 2,
                                halfH: bubbleSize.height / 2,
                                geoWidth: geo.size.width,
                                geoHeight: geo.size.height
                            )
                            tooltip(entries)
                                .background(bubbleTracker)
                                .position(x: pos.x, y: pos.y)
                        }
                    }
                }
            }

            timeAxis
        }
        // 右侧留出边距，绘图区不顶到行右缘（同 debug 示例）
        .padding(.trailing, 10)
        // VoiceOver：图表整体作为一个元素朗读摘要（折线内容无法逐点访问）
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: 自绘时间轴

    /// 图表下方的时间标签行：严格正对各自采样位居中（0、3、6、9、11），
    /// 显示该采样位的实际时间；初始阶段数据填到哪个标签位，该标签才出现
    /// （由左至右逐个出现，末位标签在窗口填满时出现）。
    /// 不做贴边收回——首尾标签（位 0 与 11）允许悬出行边界，保证与采样位精确对齐
    private var timeAxis: some View {
        let window = MonitorSlotWindow(points: points)
        return GeometryReader { geo in
            ForEach(Self.labelSlots, id: \.self) { slot in
                if slot < window.dates.count {
                    Text(Self.timeFormatter.string(from: window.dates[slot]))
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    .fixedSize()
                    .position(
                        x: slotX(slot),
                        y: geo.size.height / 2
                    )
                }
            }
        }
        .frame(height: 22)   // 与 Y 轴底部刻度文字拉开距离，避免最左时间标签贴住 Y 轴文本
    }

    /// 标签水平位置：正对采样位精确居中（半宽悬出也不拉回）
    private func slotX(_ slot: Int) -> CGFloat {
        plotRect.minX + plotRect.width * MonitorSlotWindow.xFraction(Double(slot))
    }

    /// 测量气泡实际尺寸（position 按中心定位，计算与最高线的间距用）
    private var bubbleTracker: some View {
        GeometryReader { g in
            Color.clear
                .onAppear { bubbleSize = g.size }
                .onChange(of: g.size) { _, new in bubbleSize = new }
        }
    }

    /// 选中采样位上指定系列的数值
    private func value(atSlot slot: Int, kind: String) -> Double? {
        let dates = MonitorSlotWindow(points: points).dates
        guard slot < dates.count else { return nil }
        let date = dates[slot]
        return points.first { $0.kind == kind && $0.date == date }?.value
    }

    /// 选中采样位各系列数值（按值降序，最高一条线的数值排最上；
    /// 小数位随 Y 轴形态，刻度与气泡数值保持一致）
    private func entries(atSlot slot: Int, decimals: Int) -> [(title: String, text: String, color: Color, value: Double)] {
        var raw: [(String, Double, Color)] = []
        for (kind, color) in styles {
            if let v = value(atSlot: slot, kind: kind) {
                raw.append((kind, v, color))
            }
        }
        return raw.sorted { $0.1 > $1.1 }
            .map { ($0.0, String(format: "%.\(decimals)f%@", $0.1, unit), $0.2, $0.1) }
    }

    /// 数值气泡（竖排，系列名与数值间一个空格，颜色与曲线一致；
    /// 气泡宽度固定，文本过长时整体轻微缩放而不是加宽）
    private func tooltip(_ entries: [(title: String, text: String, color: Color, value: Double)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(entries, id: \.title) { entry in
                Text("\(entry.title) \(entry.text)")
                    .monospacedDigit()
                    .foregroundStyle(entry.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .font(.caption2)
        .frame(width: 74)
        .padding(.vertical, 4)
        .padding(.horizontal, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
    }

    /// 无障碍摘要：折线内容 VoiceOver 无法读取，以各系列最新采样值代替
    private var accessibilitySummary: String {
        let parts = Array(styles).compactMap { kind, _ -> String? in
            guard let latest = points.filter({ $0.kind == kind }).max(by: { $0.date < $1.date }) else {
                return nil
            }
            return L10n.f("%@最新%@", kind, String(format: "%.2f%@", latest.value, unit))
        }
        return parts.isEmpty ? L10n.t("监控折线图，暂无数据") : L10n.t("监控折线图：") + parts.joined(separator: "，")
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Y 轴刻度文本：按小数位格式化后拼单位（如 30KB、0.5%、0.05%）
    private static func axisText(_ value: Double, unit: String, decimals: Int) -> String {
        String(format: "%.\(decimals)f%@", value, unit)
    }
}
