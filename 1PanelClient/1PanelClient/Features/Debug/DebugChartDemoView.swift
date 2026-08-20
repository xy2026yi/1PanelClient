//
//  DebugChartDemoView.swift
//  1PanelClient
//
//  DEBUG 专用：监控图表坐标域/轴标签示例页（依据 logs/分析.md 的 fl_chart 思路，用 Swift Charts 等价复现）。
//  启动方式：模拟器带启动参数 -chartDemo 拉起（见 _PanelClientApp.swift），Release 构建整体排除。
//
//  落地的分析要点：
//  1. 固定采样间隔 → 用「点索引」作 x 值，而不是时间戳；
//  2. x 域右端 = n-1（最后一个点的索引），不写成 n，否则右侧出现空白；
//  3. 网格与时间标签：固定 12 位采样窗口，中间 10 条等距虚线；
//     5 个时间标签正对采样位居中（位 0/3/6/9/11），自绘于图表下方；
//  4. CPU / 内存固定 y 轴 0...100；网络 / 磁盘 I/O 用独立的动态 y 轴（按峰值取整洁上限）；
//  5. 直线插值、不平滑（曲线过冲会误导监控读数）；正常态不画数据点；
//  6. 样本不足 3 个时不画折线、补圆点，且绝不用 0 填充起始段；
//  7. 时间以 Date（UTC 基准）存储，Formatter 默认本地时区显示，即完成 UTC→本地转换。
//

#if DEBUG
import SwiftUI
import Combine
import Charts

// MARK: - 数据模型

/// 单曲线样本（x = 数组索引，date 仅用于时间标签）
struct DebugDemoSample: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

/// 双曲线样本（kind 区分系列，x = 数组索引）
struct DebugDemoDualPoint: Identifiable {
    let date: Date
    let value: Double
    let kind: String
    var id: String { "\(kind)#\(date.timeIntervalSince1970)" }
}

// MARK: - 演示数据源

/// 模拟固定间隔采样的监控数据：4 组指标各自随机游走，窗口满后旧样本从左侧推出
@MainActor
final class DebugChartDemoViewModel: ObservableObject {
    /// 窗口容量：12 位采样窗口（两端边缘位不画虚线，中间 10 条等距虚线）
    static let windowSize = 12
    /// 采样间隔（秒）——固定间隔是「点索引作 x」成立的前提
    static let sampleInterval: TimeInterval = 1

    @Published var cpuSamples: [DebugDemoSample] = []       // CPU %
    @Published var memSamples: [DebugDemoSample] = []       // 内存 MB
    @Published var netPoints: [DebugDemoDualPoint] = []     // 上行/下行 KB/s
    @Published var ioPoints: [DebugDemoDualPoint] = []      // 读取/写入 MB/s
    @Published var isPaused = false

    /// 各指标随机游走的当前值（生成下一样本用）
    private var cpu: Double = 0
    private var mem: Double = 0
    private var netUp: Double = 0
    private var netDown: Double = 0
    private var ioRead: Double = 0
    private var ioWrite: Double = 0
    /// CPU 高载时段剩余采样数（>0 期间维持 78...98%，演示封顶后下限抬高的值域如 75...100%）
    private var cpuHighRemaining = 0

    init() {
        prefill()
    }

    /// 预填满整个窗口（倒推时间戳），打开页面即可看到完整曲线；
    /// 预填先处于高载时段，首屏即可看到「封顶 100% + 下限抬高」的值域效果
    private func prefill() {
        cpuSamples = []; memSamples = []; netPoints = []; ioPoints = []
        cpu = 88; mem = 1_200; netUp = 120; netDown = 640; ioRead = 1.2; ioWrite = 0.6
        cpuHighRemaining = 6
        let now = Date()
        for i in (0..<Self.windowSize).reversed() {
            appendSample(date: now.addingTimeInterval(-Double(i) * Self.sampleInterval))
        }
    }

    /// 从 2 个真实样本重新生长（演示「不足 3 点补圆点、不用 0 填充」的初始阶段）
    func replayFromScratch() {
        cpuSamples = []; memSamples = []; netPoints = []; ioPoints = []
        cpu = 3; mem = 900; netUp = 80; netDown = 300; ioRead = 0.4; ioWrite = 0.2
        let now = Date()
        appendSample(date: now.addingTimeInterval(-Self.sampleInterval))
        appendSample(date: now)
    }

    /// 采样一步：追加各指标新样本并把窗口外的旧样本推出
    func sample() {
        appendSample(date: Date())
    }

    private func appendSample(date: Date) {
        // CPU 低载/高载交替：低载 0.05~15%，偶发进入 5~10 秒高载（78~98%）——
        // 低载演示 0...动态上限，高载演示封顶 100% 后下限抬高（如 75...100%）；
        // 内存为 MB 用量，网络/IO 偶发尖峰
        if cpuHighRemaining > 0 {
            cpuHighRemaining -= 1
            cpu = clamp(cpu + .random(in: -4...4), 78, 98)
        } else if Double.random(in: 0...1) < 0.06 {
            cpuHighRemaining = Int.random(in: 5...10)
            cpu = 88
        } else {
            cpu = clamp(cpu + .random(in: -2.5...2.5), 0.05, 15)
        }
        mem = clamp(mem + .random(in: -60...60), 200, 8_192)
        netUp = clamp(netUp + .random(in: -50...50) + spike(120, p: 0.12), 5, 2_000)
        netDown = clamp(netDown + .random(in: -120...120) + spike(400, p: 0.12), 10, 5_000)
        ioRead = clamp(ioRead + .random(in: -0.5...0.5) + spike(4, p: 0.1), 0.05, 30)
        ioWrite = clamp(ioWrite + .random(in: -0.3...0.3) + spike(2.5, p: 0.1), 0.02, 20)

        push(DebugDemoSample(date: date, value: cpu), into: &cpuSamples)
        push(DebugDemoSample(date: date, value: mem), into: &memSamples)
        push(DebugDemoDualPoint(date: date, value: netUp, kind: "上行"), into: &netPoints)
        push(DebugDemoDualPoint(date: date, value: netDown, kind: "下行"), into: &netPoints)
        push(DebugDemoDualPoint(date: date, value: ioRead, kind: "读取"), into: &ioPoints)
        push(DebugDemoDualPoint(date: date, value: ioWrite, kind: "写入"), into: &ioPoints)
    }

    private func spike(_ amount: Double, p: Double) -> Double {
        Double.random(in: 0...1) < p ? amount : 0
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }

    private func push<T>(_ point: T, into array: inout [T]) {
        array.append(point)
        if array.count > Self.windowSize {
            array.removeFirst(array.count - Self.windowSize)
        }
    }
}

// MARK: - 坐标域工具

enum DebugChartAxis {
    /// 动态 y 轴上限：按峰值取 1/1.2/1.5/2/2.5/3/4/5/6/8/10 × 10^k 的整洁值，
    /// 让各量纲曲线的刻度始终可读
    static func niceCeiling(_ peak: Double) -> Double {
        guard peak > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(peak)))
        let normalized = peak / magnitude
        let nice: Double
        switch normalized {
        case ..<1: nice = 1
        case ..<1.2: nice = 1.2
        case ..<1.5: nice = 1.5
        case ..<2: nice = 2
        case ..<2.5: nice = 2.5
        case ..<3: nice = 3
        case ..<4: nice = 4
        case ..<5: nice = 5
        case ..<6: nice = 6
        case ..<8: nice = 8
        default: nice = 10
        }
        return nice * magnitude
    }

    /// 动态下限：向下取 ladder（1/1.2/1.5/2/2.5/3/4/5/6/8/10 × 10^k）中不超过 x 的最大值
    static func niceFloor(_ x: Double) -> Double {
        guard x > 0 else { return 0 }
        let magnitude = pow(10, floor(log10(x)))
        let normalized = x / magnitude
        let ladder: [Double] = [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]
        let nice = ladder.last { $0 <= normalized + 0.0001 } ?? 1
        return nice * magnitude
    }
}

// MARK: - 页面

struct DebugChartDemoView: View {
    @StateObject private var vm = DebugChartDemoViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var isSceneActive = true

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"   // Date 为 UTC 基准，Formatter 默认本地时区 → 显示即本地时间
        return f
    }()

    var body: some View {
        NavigationStack {
            List {
                introSection
                singleSection("CPU", samples: vm.cpuSamples, color: .blue, unit: "%", fixedYCeiling: 100)
                singleSection("内存", samples: vm.memSamples, color: .purple, unit: "MB")
                dualSection("网络", points: vm.netPoints,
                            styles: ["上行": .green, "下行": .purple], unit: "KB/s")
                dualSection("磁盘 I/O", points: vm.ioPoints,
                            styles: ["读取": .blue, "写入": .orange], unit: "MB/s")
                domainComparisonSection
            }
            .navigationTitle("图表 Debug 示例")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(vm.isPaused ? "继续" : "暂停") { vm.isPaused.toggle() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("从 2 点重播") { vm.replayFromScratch() }
                }
            }
            .onChange(of: scenePhase) { _, phase in isSceneActive = phase == .active }
            // 固定间隔轮询（仅前台活跃且未暂停时采样）
            .task {
                while !Task.isCancelled {
                    if isSceneActive, !vm.isPaused {
                        vm.sample()
                    }
                    try? await Task.sleep(for: .seconds(DebugChartDemoViewModel.sampleInterval))
                }
            }
        }
    }

    // MARK: 分区

    private var introSection: some View {
        Section {
                Text("按 logs/分析.md 复现 fl_chart 的坐标域思路：点索引作 x、固定 12 位窗口（右端 n-1 防右侧空白）、10 条等距虚线、5 个时间标签正对采样位居中（0/3/6/9/11）、CPU/内存固定 y 0...100、网络/IO 动态 y、直线不平滑；点按/滑动图表可查看数值；1s 采样模拟。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// 单曲线指标：CPU 用 %（上限封顶 100%、值域自适应）、内存用 MB（标题在卡片内左上角）
    private func singleSection(_ title: String, samples: [DebugDemoSample],
                               color: Color, unit: String, fixedYCeiling: Double? = nil) -> some View {
        Section {
            DemoLineChart(title: title, samples: samples, styles: [title: color],
                          unit: unit, fixedYCeiling: fixedYCeiling)
                .listRowSeparator(.hidden)
        }
    }

    /// 网络 / 磁盘 I/O：双曲线 + 动态 y 轴（标题在卡片内左上角）
    private func dualSection(_ title: String, points: [DebugDemoDualPoint],
                             styles: KeyValuePairs<String, Color>, unit: String) -> some View {
        Section {
            DemoLineChart(title: title, points: points, styles: styles, unit: unit)
                .listRowSeparator(.hidden)
        }
    }

    /// 要点 2 的直观对比：同一份数据，x 域右端分别取 n-1（正确）与 n（右侧空白）
    private var domainComparisonSection: some View {
        Section("x 域右端对比：n-1 vs n") {
            VStack(alignment: .leading, spacing: 4) {
                Text("正确：domain 0…n-1，末点贴右缘")
                    .font(.caption).foregroundStyle(.secondary)
                DemoLineChart(samples: vm.cpuSamples, styles: ["CPU": .blue], unit: "%",
                              xDomainUpperOffset: 0, height: 90)
            }
            .listRowSeparator(.hidden)
            VStack(alignment: .leading, spacing: 4) {
                Text("错误：domain 0…n（末点悬空，右侧一段空白）")
                    .font(.caption).foregroundStyle(.secondary)
                DemoLineChart(samples: vm.cpuSamples, styles: ["CPU": .red], unit: "%",
                              xDomainUpperOffset: 1, height: 90)
            }
            .listRowSeparator(.hidden)
        }
    }
}

// MARK: - 通用监控折线图

/// 图表内的一个系列（按系列名拆分后的样本）
private struct DemoSeries: Identifiable {
    let kind: String
    let samples: [DebugDemoSample]
    var id: String { kind }
}

/// 摊平后的数据点（系列名 + 采样索引），id 唯一（kind+index），供单 ForEach 绘制
private struct DemoFlatPoint: Identifiable {
    let kind: String
    let index: Int
    let value: Double
    var id: String { "\(kind)#\(index)" }
}

/// 单/双曲线监控折线图（固定采样位窗口 x 轴，y 值域自适应 + 顶部气泡预留）。
/// - y 上限：峰值 + 气泡预留 → 整洁上限；设 `fixedYCeiling`（如 CPU 100%）时为封顶，
///   数据整体高位时下限相应抬起（如 80~98% → 75...100%）。
/// - `xDomainUpperOffset`：0 = 右端取 n-1（正确）；1 = 右端取 n（错误示范，右侧留空一档）。
struct DemoLineChart: View {
    /// 画竖向虚线的采样位：10 条、等距（两端边缘采样位 0 与 11 不画）
    private static let gridSlots = Array(1...(DebugChartDemoViewModel.windowSize - 2))
    /// 时间标签的采样位：5 个、正对采样位居中（0/3/6/9/11，首尾在窗口两端）
    private static let labelSlots = [0, 3, 6, 9, DebugChartDemoViewModel.windowSize - 1]

    let samples: [DebugDemoSample]
    let points: [DebugDemoDualPoint]
    let styles: KeyValuePairs<String, Color>
    let unit: String
    var title: String?
    /// 固定 y 上限（如 CPU 传 100：y 轴恒 0...100%，不随峰值/气泡预留放大）；
    /// nil = 动态轴（峰值 + 气泡预留 → 整洁上限）
    var fixedYCeiling: Double?
    var xDomainUpperOffset: Int = 0
    var height: CGFloat = 150

    /// 图表绘图区（相对图表整体 frame），自绘时间轴/气泡据此与数据区对齐
    @State private var plotRect: CGRect = .zero
    /// 点按/滑动选中的采样位（nil = 未选中）
    @State private var selectedSlot: Int?
    /// 本次手势开始前已选中的采样位（松手时判断「点击已选位 → 取消」）
    @State private var slotAtGestureStart: Int?
    /// 气泡实际尺寸（position 按中心定位，计算与最高圆点的间距用）
    @State private var bubbleSize: CGSize = .zero

    init(title: String? = nil, samples: [DebugDemoSample], styles: KeyValuePairs<String, Color>,
         unit: String, fixedYCeiling: Double? = nil, xDomainUpperOffset: Int = 0, height: CGFloat = 150) {
        self.title = title
        self.samples = samples
        self.points = []
        self.styles = styles
        self.unit = unit
        self.fixedYCeiling = fixedYCeiling
        self.xDomainUpperOffset = xDomainUpperOffset
        self.height = height
    }

    init(title: String? = nil, points: [DebugDemoDualPoint], styles: KeyValuePairs<String, Color>,
         unit: String, fixedYCeiling: Double? = nil, xDomainUpperOffset: Int = 0, height: CGFloat = 150) {
        self.title = title
        self.samples = []
        self.points = points
        self.styles = styles
        self.unit = unit
        self.fixedYCeiling = fixedYCeiling
        self.xDomainUpperOffset = xDomainUpperOffset
        self.height = height
    }

    /// 双曲线输入按 kind 拆分后的各系列（单曲线输入则只有一个系列）
    private var seriesList: [DemoSeries] {
        if !samples.isEmpty {
            return [DemoSeries(kind: styles.first?.key ?? "", samples: samples)]
        }
        let dates = orderedDates
        return styles.map { kind, _ in
            DemoSeries(kind: kind, samples: dates.compactMap { d in
                points.first { $0.kind == kind && $0.date == d }
                    .map { DebugDemoSample(date: $0.date, value: $0.value) }
            })
        }
    }

    /// 各系列共用的时间轴（按出现顺序去重）
    private var orderedDates: [Date] {
        var seen = Set<Date>()
        return points.compactMap { seen.insert($0.date).inserted ? $0.date : nil }
    }

    /// 摊平后的全部数据点（供单 ForEach 绘制，系列靠 foregroundStyle(by:) 区分）
    private var flatPoints: [DemoFlatPoint] {
        seriesList.flatMap { series in
            series.samples.enumerated().map { i, s in
                DemoFlatPoint(kind: series.kind, index: i, value: s.value)
            }
        }
    }

    /// 各系列当前点数（起始生长阶段 <3 时补圆点）
    private var seriesCounts: [String: Int] {
        Dictionary(grouping: flatPoints, by: \.kind).mapValues(\.count)
    }

    /// 当前窗口点数 n（各系列一致）
    private var count: Int {
        samples.isEmpty ? orderedDates.count : samples.count
    }

    var body: some View {
        if count == 0 {
            Text("暂无数据")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: height)
        } else {
            VStack(spacing: 2) {
                // 标题置于卡片内左上角，与图表拉开间距
                if let title {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 10)
                }
                chart
                timeAxis
            }
            // 右侧留出边距，绘图区不顶到行右缘
            .padding(.trailing, 10)
        }
    }

    // 拆成小成员：整段链式表达式会让类型检查超时

    private var chart: some View {
        chartMarks
            .chartForegroundStyleScale(styles)
            .chartLegend(.hidden)
            // 固定采样窗口（点索引 x）：右端 = 窗口末位 n-1 + offset；offset=1 即「写成 n」的错误示范。
            // 域固定不随样本数变化 → 虚线/标签位置恒定，初始阶段曲线由左至右逐位填充
            .chartXScale(domain: 0...xUpper)
            // y 值域自适应：上限整洁（可封顶，如 CPU ≤100%），数据高位时下限抬起
            .chartYScale(domain: yDomain)
            // 时间标签自绘（见 timeAxis）：系统轴标签位置/碰撞裁切不可控，无法保证「正对虚线居中」
            .chartXAxis(.hidden)
            .chartYAxis {
                // 自算刻度值（首尾必含）：系统自动刻度在值域切换后会丢端点
                //（如 0...100 只画 25/50/75/100，缺 0%）
                AxisMarks(position: .leading, values: yTickValues) { value in
                    AxisGridLine()
                    AxisValueLabel { yLabelView(value) }
                }
            }
            .frame(height: height)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    let plotFrame = proxy.plotFrame.map { geo[$0] } ?? .zero

                    // 手势层：触摸/拖动 x → 就近吸附到采样位（虚线跟手）
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { g in
                                    guard plotFrame.width > 0 else { return }
                                    if slotAtGestureStart == nil {
                                        slotAtGestureStart = selectedSlot
                                    }
                                    let x = g.location.x - plotFrame.minX
                                    guard x >= 0, x <= plotFrame.width else { return }
                                    selectedSlot = snapSlot(atX: x, plotWidth: plotFrame.width)
                                }
                                .onEnded { _ in
                                    // 再次点击已选中的采样位取消；拖到别的位松手则保持新选中
                                    if selectedSlot != nil, selectedSlot == slotAtGestureStart {
                                        selectedSlot = nil
                                    }
                                    slotAtGestureStart = nil
                                }
                        )

                    // 布局期间同步绘图区位置，供自绘时间轴/气泡与数据区对齐
                    Color.clear
                        .onAppear { plotRect = plotFrame }
                        .onChange(of: plotFrame) { _, new in plotRect = new }

                    // 数值气泡：水平居中于选中位（贴边收回），悬于最高圆点正上方
                    if let sel = selectedSlot {
                        bubbleView(sel, plotFrame: plotFrame, geoSize: geo.size)
                    }
                }
            }
    }

    private var chartMarks: some View {
        Chart {
            // 固定网格虚线（画在最底层）：10 条等距，两端边缘采样位不画
            ForEach(Self.gridSlots, id: \.self) { slot in
                RuleMark(x: .value("网格", Double(slot)))
                    .foregroundStyle(Color.secondary.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            // 全部数据点摊平进一个 ForEach（与生产 ContainerMonitorChart 同构）：
            // 系列由 foregroundStyle(by: 类型) 划分。不能每系列一个 ForEach——
            // 两系列点的 id（日期）跨系列相同，会让两条线粘连成阶梯状
            ForEach(flatPoints) { p in
                LineMark(x: .value("采样位", Double(p.index)), y: .value("值", p.value))
                    .foregroundStyle(by: .value("类型", p.kind))
                    // 直线插值：监控曲线平滑过冲会制造不存在的峰谷
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                // 样本不足 3 个：折线画不出趋势，补圆点保证可见（且起始段从真实样本生长，不填 0）
                if (seriesCounts[p.kind] ?? 0) < 3 {
                    PointMark(x: .value("采样位", Double(p.index)), y: .value("值", p.value))
                        .foregroundStyle(by: .value("类型", p.kind))
                        .symbolSize(60)
                }
            }

            // 选中采样位：深色虚线跟手 + 各系列同色圆点
            if let sel = selectedSlot {
                RuleMark(x: .value("选中", Double(sel)))
                    .foregroundStyle(Color.primary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                ForEach(seriesList) { series in
                    if let v = value(at: sel, in: series) {
                        PointMark(x: .value("选中", Double(sel)), y: .value("值", v))
                            .foregroundStyle(color(for: series.kind))
                            .symbolSize(60)
                    }
                }
            }
        }
    }

    /// x 域右端：固定窗口末位 (windowSize-1) + offset，不随当前样本数变化
    private var xUpper: Double {
        Double(DebugChartDemoViewModel.windowSize - 1 + xDomainUpperOffset)
    }

    // MARK: 点选交互

    /// 触摸 x → 就近吸附的采样位（仅限已有数据的位）
    private func snapSlot(atX x: CGFloat, plotWidth: CGFloat) -> Int {
        let fraction = Double(x / plotWidth)
        let slot = Int((fraction * xUpper).rounded())
        let maxSlot = min(count, DebugChartDemoViewModel.windowSize) - 1
        return min(max(slot, 0), maxSlot)
    }

    /// 指定系列在采样位上的值（x = 数组索引）
    private func value(at slot: Int, in series: DemoSeries) -> Double? {
        series.samples.indices.contains(slot) ? series.samples[slot].value : nil
    }

    /// 系列名对应的曲线颜色
    private func color(for kind: String) -> Color {
        for (k, c) in styles where k == kind { return c }
        return .blue
    }

    /// 气泡定位：默认水平居中于选中位（贴边收回边界内）、悬于最高圆点正上方；
    /// 值超过固定上限的 90%（如 CPU 封顶 100% 时的 90+%）或上方放不下时，
    /// 改放圆点侧面——圆点在图表左半边时气泡放右侧、右半边放左侧，垂直与圆点对齐
    @ViewBuilder
    private func bubbleView(_ sel: Int, plotFrame: CGRect, geoSize: CGSize) -> some View {
        if plotFrame.width > 0,
           let topValue = seriesList.compactMap({ value(at: sel, in: $0) }).max() {
            let xCenter = plotFrame.minX + plotFrame.width * (Double(sel) / xUpper)
            let span = max(yDomain.upperBound - yDomain.lowerBound, .ulpOfOne)
            let yTop = plotFrame.minY + plotFrame.height * ((yDomain.upperBound - topValue) / span)
            let pos = bubblePosition(topValue: topValue, xCenter: xCenter, yTop: yTop,
                                     halfW: bubbleSize.width / 2, halfH: bubbleSize.height / 2,
                                     geoWidth: geoSize.width, geoHeight: geoSize.height)
            bubble(sel)
                .background(bubbleTracker)
                .position(x: pos.x, y: pos.y)
        }
    }

    private func bubblePosition(topValue: Double, xCenter: CGFloat, yTop: CGFloat,
                                halfW: CGFloat, halfH: CGFloat,
                                geoWidth: CGFloat, geoHeight: CGFloat) -> (x: CGFloat, y: CGFloat) {
        let nearCap = fixedYCeiling.map { topValue > $0 * 0.9 } ?? false
        let noRoomAbove = yTop < 12 + 2 * halfH
        if nearCap || noRoomAbove {
            // 侧面：圆点在左半边 → 气泡放右侧，右半边 → 放左侧；垂直与圆点对齐并收回边界内
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

    /// 选中位数值气泡：每系列一行「同色圆点 + 系列名 数值」
    private func bubble(_ slot: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(seriesList) { series in
                if let v = value(at: slot, in: series) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(color(for: series.kind))
                            .frame(width: 6, height: 6)
                        Text("\(series.kind) \(String(format: "%.\(valueDecimals)f%@", v, unit))")
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
            }
        }
        .font(.caption2)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
    }

    /// 测量气泡实际尺寸（position 按中心定位，计算与最高圆点的间距用）
    private var bubbleTracker: some View {
        GeometryReader { g in
            Color.clear
                .onAppear { bubbleSize = g.size }
                .onChange(of: g.size) { _, new in bubbleSize = new }
        }
    }

    // MARK: 自绘时间轴

    /// 图表下方的时间标签行：严格正对各自采样位居中（位 0/3/6/9/11），
    /// 显示该采样位的本地时间；初始阶段数据填到哪个标签位，该标签才出现。
    /// 不做贴边收回——首尾标签（位 0 与 11）允许悬出行边界，保证与采样位精确对齐
    private var timeAxis: some View {
        GeometryReader { geo in
            ForEach(Self.labelSlots, id: \.self) { slot in
                if slot < count, let s = sample(at: slot) {
                    Text(Self.timeFormatter.string(from: s.date))
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: slotX(slot), y: geo.size.height / 2)
                }
            }
        }
        .frame(height: 20)
    }

    /// 标签水平位置：正对采样位精确居中（半宽悬出也不拉回）
    private func slotX(_ slot: Int) -> CGFloat {
        plotRect.minX + plotRect.width * (Double(slot) / xUpper)
    }

    /// y 轴刻度文本：小数位随值域自适应（值域 <1 时两位，可显示 0.0x%）；
    /// trailing 内边距把文字与绘图区左缘拉开距离（如刻度不贴住曲线区）
    @ViewBuilder
    private func yLabelView(_ value: AxisValue) -> some View {
        if let v = value.as(Double.self) {
            Text(Self.axisText(v, unit: unit, decimals: valueDecimals))
                .font(.caption2)
                .monospacedDigit()
                .fixedSize()
                .padding(.trailing, 12)
        }
    }

    private func sample(at index: Int) -> DebugDemoSample? {
        if !samples.isEmpty {
            return samples.indices.contains(index) ? samples[index] : nil
        }
        let dates = orderedDates
        guard dates.indices.contains(index) else { return nil }
        let date = dates[index]
        for (kind, _) in styles {
            if let p = points.first(where: { $0.kind == kind && $0.date == date }) {
                return DebugDemoSample(date: date, value: p.value)
            }
        }
        return nil
    }

    /// y 上限：窗口峰值先为顶部气泡预留空间（按系列数估算气泡高度 + 间距，
    /// 保证选中最高点时气泡仍完整悬于圆点上方），再取整洁上限；下限至少 1，全 0 时刻度仍可读。
    /// 预留不依赖气泡实测尺寸——气泡只在选中后才被测量，那样 y 轴会在首次选中时跳变
    /// 基准 Y 值域（未做等距对齐；取整与「6 值 6 线」由 yDomain 的等距对齐层统一完成）：
    /// - 上限：峰值 × 1.15 的紧凑头寸（顶部不预留气泡位——放不下自动转圆点侧面），
    ///   设有封顶（CPU 100%）时不超过它；
    /// - 下限：封顶轴上限被钉住时抬到窗口最小值下方一个步长（步长 = cap/20，如 100 → 5%）；
    ///   动态轴数据带高位（最小值过半峰值）时收紧贴数据带；其余为 0（全 0 时刻度仍可读）
    private var yBaseDomain: ClosedRange<Double> {
        let values = seriesList.flatMap(\.samples).map(\.value)
        let peak = values.max() ?? 0
        let low = values.min() ?? 0
        if let cap = fixedYCeiling, cap > 0 {
            if max(peak, 0.1) * 1.15 >= cap {
                // 上限钉在封顶值：下限抬到窗口最小值下方一个步长（如 80~98% → 75...100%）
                let step = cap / 20
                let lower = max(0, ((low - step) / step).rounded(.down) * step)
                return lower...max(cap, lower + step)
            }
            return 0...max(peak, 0.1) * 1.15
        }
        if peak > 0, low > peak * 0.5 {
            // 动态轴高位窄带：上下限同时收紧贴数据（如内存 1140~1260MB → 1000...1500）
            let upper = peak * 1.15
            let lower = min(DebugChartAxis.niceFloor(low * 0.9), upper * 0.9)
            return lower...upper
        }
        return 0...max(peak * 1.15, 1)
    }

    /// Y 轴值域：在基准值域上做等距对齐——跨度固定为 5 × 刻度步长
    ///（封顶轴锚定上限、下限向下回退；其余锚定下限、上限向上补齐），
    /// 保证恰好 6 值 6 线、等距且首尾都落在网格上；
    /// 数值恒为 0 时跨度取 2 × 步长（仅 3 个刻度）
    private var yDomain: ClosedRange<Double> {
        let base = yBaseDomain
        let lower = base.lowerBound
        let upper = base.upperBound
        let step = yTickStep
        guard upper > lower, step > 0 else { return base }
        let span = Double(isAllZero ? 2 : 5) * step
        if let cap = fixedYCeiling, cap > 0, upper >= cap {
            return max(0, cap - span)...cap
        }
        return lower...(lower + span)
    }

    /// 窗口数值是否恒为 0——此时刻度不加密
    private var isAllZero: Bool {
        let values = seriesList.flatMap(\.samples).map(\.value)
        return !values.isEmpty && values.allSatisfy { $0 == 0 }
    }

    /// y 轴刻度步长：按基准跨度/5 向上归整到 1/2/2.5/4/5/10 × 10^k——
    /// 配合 yDomain 的「跨度 = 5 × 步长」恒得 6 值 6 线；
    /// 数值恒为 0 时不加密（跨度/2、无 4 档，仅保留 3 个刻度）
    private var yTickStep: Double {
        let span = yBaseDomain.upperBound - yBaseDomain.lowerBound
        guard span > 0 else { return 1 }
        let dense = !isAllZero
        let raw = span / (dense ? 5 : 2)
        let magnitude = pow(10, floor(log10(raw)))
        let normalized = raw / magnitude
        let ladder = dense ? [1.0, 2, 2.5, 4, 5, 10] : [1.0, 2, 2.5, 5, 10]
        let nice = ladder.first { $0 >= normalized - 0.0001 } ?? 10
        return nice * magnitude
    }

    /// y 轴刻度值：下限起步按步进到上限——值域已等距对齐（跨度 = 步长整数倍），
    /// 横线等距且首尾必在列
    private var yTickValues: [Double] {
        let lower = yDomain.lowerBound
        let upper = yDomain.upperBound
        let step = yTickStep
        guard upper > lower, step > 0 else { return [lower] }
        let n = max(1, Int(((upper - lower) / step).rounded()))
        return (0...n).map { lower + Double($0) * step }
    }

    /// 数值小数位：由刻度步长决定（步长 0.0x → 两位、0.x/2.5 → 一位、整数 → 取整），
    /// 刻度与气泡数值保持一致
    private var valueDecimals: Int {
        let step = yTickStep
        if step.truncatingRemainder(dividingBy: 1) == 0 { return 0 }
        if (step * 10).truncatingRemainder(dividingBy: 1) == 0 { return 1 }
        return 2
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// y 轴刻度文本：按小数位格式化后拼单位（如 30KB/s、0.5%、0.05%）
    private static func axisText(_ value: Double, unit: String, decimals: Int) -> String {
        String(format: "%.\(decimals)f%@", value, unit)
    }
}
#endif
