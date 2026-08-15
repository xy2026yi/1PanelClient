//
//  MonitorView.swift
//  1PanelClient
//
//  历史监控：平均负载 / CPU / 内存 / 磁盘I/O / 网络 曲线图（Swift Charts）
//  数据来自 POST /api/v2/hosts/monitor/search，支持时间范围切换
//

import SwiftUI
import Combine
import Charts

// MARK: - 图表数据点

struct MonitorPoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

/// 带类型标签的图表点（多系列折线用：foregroundStyle(by:) 按类型分系列）
struct LoadSeriesPoint: Identifiable {
    let date: Date
    let value: Double
    let kind: String   // "1分钟" / "5分钟" / "15分钟"
    var id: String { "\(kind)-\(date.timeIntervalSince1970)" }
}

// MARK: - ViewModel

@MainActor
final class MonitorViewModel: ObservableObject {
    /// 时间范围（小时）
    @Published var hours: Int = 1
    @Published var isLoading = false
    @Published var errorMessage: String?

    // 曲线数据
    @Published var loadPoints: [MonitorPoint] = []      // 负载使用率 %（圆环用）
    @Published var load1Points: [MonitorPoint] = []     // 1 分钟负载曲线
    @Published var load5Points: [MonitorPoint] = []     // 5 分钟负载曲线
    @Published var load15Points: [MonitorPoint] = []    // 15 分钟负载曲线
    @Published var cpuPoints: [MonitorPoint] = []       // CPU %
    @Published var memPoints: [MonitorPoint] = []       // 内存 %
    @Published var ioReadPoints: [MonitorPoint] = []    // 磁盘读取 KB/s
    @Published var ioWritePoints: [MonitorPoint] = []   // 磁盘写入 KB/s
    @Published var netUpPoints: [MonitorPoint] = []     // 上行 KB/s
    @Published var netDownPoints: [MonitorPoint] = []   // 下行 KB/s

    // 最新快照（负载 1/5/15 + Top 进程）
    @Published var latestLoad1: Double?
    @Published var latestLoad5: Double?
    @Published var latestLoad15: Double?
    @Published var topCPU: [MonitorTopItem] = []
    @Published var topMem: [MonitorTopItem] = []

    private let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    /// 可选时间范围（小时）
    static let rangeOptions: [(title: String, hours: Int)] = [
        ("近1小时", 1), ("近6小时", 6), ("近24小时", 24), ("近3天", 72), ("近7天", 168),
    ]

    /// 负载图表 Y 轴上限：取「1/5/15 分钟三条曲线历史峰值、最新负载值」中的
    /// 最大值，留 20% 余量后向上取整到 1/2/5×10ⁿ 的整齐刻度（不固定 100）
    var loadAxisMax: Double {
        let seriesMax = [load1Points, load5Points, load15Points]
            .compactMap { $0.map(\.value).max() }
            .max() ?? 0
        let rawMax = [seriesMax, latestLoad1 ?? 0, latestLoad5 ?? 0, latestLoad15 ?? 0].max() ?? 0
        guard rawMax > 0 else { return 10 }
        return Self.niceCeil(rawMax * 1.2)
    }

    /// 向上取整到 1 / 2 / 5 × 10ⁿ 的"好看"刻度值
    private static func niceCeil(_ value: Double) -> Double {
        guard value > 0 else { return 1 }
        let exponent = floor(log10(value))
        let base = pow(10, exponent)
        let fraction = value / base
        let nice: Double
        switch fraction {
        case ...1:  nice = 1
        case ...2:  nice = 2
        case ...5:  nice = 5
        default:    nice = 10
        }
        return nice * base
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let end = Date()
        let start = Calendar.current.date(byAdding: .hour, value: -hours, to: end) ?? end
        let startTime = MonitorDate.requestString(start)
        let endTime = MonitorDate.requestString(end)

        // 五个指标并行请求
        async let loadSeries: [MonitorSeries]? = fetch(param: "load", start: startTime, end: endTime)
        async let cpuSeries: [MonitorSeries]? = fetch(param: "cpu", start: startTime, end: endTime)
        async let memSeries: [MonitorSeries]? = fetch(param: "memory", start: startTime, end: endTime)
        async let ioSeries: [MonitorSeries]? = fetch(param: "io", start: startTime, end: endTime)
        async let netSeries: [MonitorSeries]? = fetch(param: "network", start: startTime, end: endTime)

        let baseLoad = await loadSeries ?? []
        let baseCPU = await cpuSeries ?? []
        let baseMem = await memSeries ?? []
        let io = await ioSeries ?? []
        let net = await netSeries ?? []

        // base 形态（负载/CPU/内存共用记录结构）
        loadPoints = points(from: baseLoad) { $0.loadUsage ?? 0 }
        load1Points = points(from: baseLoad) { $0.cpuLoad1 ?? 0 }
        load5Points = points(from: baseLoad) { $0.cpuLoad5 ?? 0 }
        load15Points = points(from: baseLoad) { $0.cpuLoad15 ?? 0 }
        cpuPoints = points(from: baseCPU) { $0.cpu ?? 0 }
        memPoints = points(from: baseMem) { $0.memory ?? 0 }

        // io / network 形态
        ioReadPoints = points(from: io) { $0.read ?? 0 }
        ioWritePoints = points(from: io) { $0.write ?? 0 }
        netUpPoints = points(from: net) { $0.up ?? 0 }
        netDownPoints = points(from: net) { $0.down ?? 0 }

        // 最新快照（优先用负载序列的最后一条）
        let snapshotSeries = [baseLoad, baseCPU, baseMem].first { series in
            series.flatMap { $0.value ?? [] }.contains { $0.topCPUItems != nil || $0.topMemItems != nil }
        }
        if let last = snapshotSeries?.compactMap({ $0.value ?? [] }).last?.last {
            latestLoad1 = last.cpuLoad1
            latestLoad5 = last.cpuLoad5
            latestLoad15 = last.cpuLoad15
            topCPU = (last.topCPUItems ?? []).sorted { ($0.percent ?? 0) > ($1.percent ?? 0) }
            topMem = (last.topMemItems ?? []).sorted { ($0.percent ?? 0) > ($1.percent ?? 0) }
        }
    }

    private func fetch(param: String, start: String, end: String) async -> [MonitorSeries]? {
        do {
            return try await client.send(
                path: APIEndpoint.hostsMonitorSearch.path,
                body: MonitorSearchRequest(param: param, startTime: start, endTime: end),
                as: [MonitorSeries].self
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// date[i] 与 value[i] 按索引配对生成图表点
    private func points(from series: [MonitorSeries], value: @escaping (MonitorRecord) -> Double) -> [MonitorPoint] {
        var result: [MonitorPoint] = []
        for s in series {
            let dates = s.date ?? []
            let values = s.value ?? []
            for (d, v) in zip(dates, values) {
                if let date = MonitorDate.parse(d) {
                    result.append(MonitorPoint(date: date, value: value(v)))
                }
            }
        }
        return result.sorted { $0.date < $1.date }
    }
}

// MARK: - 监控视图

struct MonitorView: View {
    let server: ServerConfig
    @StateObject private var vm: MonitorViewModel
    /// 平均负载图表展开状态（默认收起，点右侧下拉展开）
    @State private var showLoadChart = false
    /// 负载图表手指选中的时间点（nil = 显示最新值）
    @State private var selectedLoadDate: Date?

    init(server: ServerConfig) {
        self.server = server
        _vm = StateObject(wrappedValue: MonitorViewModel(server: server))
    }

    var body: some View {
        List {
            // 时间范围
            Section {
                Picker("时间范围", selection: $vm.hours) {
                    ForEach(MonitorViewModel.rangeOptions, id: \.hours) { opt in
                        Text(opt.title).tag(opt.hours)
                    }
                }
                .pickerStyle(.menu)
            }

            if vm.isLoading && vm.cpuPoints.isEmpty {
                Section {
                    HStack { Spacer(); ProgressView("加载监控数据…"); Spacer() }
                        .padding(.vertical, 30)
                }
            } else if let err = vm.errorMessage, vm.cpuPoints.isEmpty {
                Section {
                    ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(err))
                }
            } else {
                loadSection
                cpuSection
                memorySection
                ioSection
                networkSection
                topProcessSections
            }
        }
        .navigationTitle("监控")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await vm.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(vm.isLoading)
            }
        }
        .refreshable { await vm.load() }
        .task(id: vm.hours) { await vm.load() }
    }

    // MARK: 平均负载（标题+数值+图表一体化，右侧下拉展开图表）

    private var loadSection: some View {
        Section {
            // 标题行 + 下拉按钮
            HStack {
                Text("平均负载")
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showLoadChart.toggle()
                    }
                } label: {
                    Image(systemName: showLoadChart ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showLoadChart ? "收起图表" : "展开图表")
            }

            // 1/5/15 分钟负载（上标签下数值）+ 右侧小型使用率圆环
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 0) {
                    loadColumn("1分钟", vm.latestLoad1)
                    loadColumn("5分钟", vm.latestLoad5)
                    loadColumn("15分钟", vm.latestLoad15)
                }
                .frame(maxWidth: .infinity)

                miniRing(percent: vm.loadPoints.last?.value ?? 0)
            }

            // 图表（下拉展开时显示：1/5/15 分钟三条曲线，支持拖动查看）
            if showLoadChart {
                loadChart
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// 负载三曲线图表（1/5/15 分钟），拖动时图表内竖排浮层显示数值（按值降序）
    private var loadChart: some View {
        return Chart(loadAllPoints) { p in
            LineMark(x: .value("时间", p.date), y: .value("负载", p.value))
                .foregroundStyle(by: .value("类型", p.kind))
            if let sel = selectedLoadDate {
                RuleMark(x: .value("选中", sel))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartForegroundStyleScale([
            "1分钟": .blue, "5分钟": .orange, "15分钟": .purple,
        ])
        .chartYScale(domain: 0...max(vm.loadAxisMax, 1))
        .chartYAxis { AxisMarks(position: .leading) }
        .frame(height: 160)
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
                                selectedLoadDate = clampToLoadDomain(date)
                            }
                            .onEnded { _ in selectedLoadDate = nil }
                    )

                // 选中浮层：竖排显示三条曲线数值（值大的在最上面），颜色与曲线一致
                if let sel = selectedLoadDate {
                    let entries: [(title: String, value: Double?, color: Color)] = [
                        ("1分钟", selectedLoadValue(from: vm.load1Points), .blue),
                        ("5分钟", selectedLoadValue(from: vm.load5Points), .orange),
                        ("15分钟", selectedLoadValue(from: vm.load15Points), .purple),
                    ].sorted { ($0.value ?? 0) > ($1.value ?? 0) }

                    let x = proxy.position(forX: sel) ?? 0
                    let panelWidth: CGFloat = 112
                    // 靠右边缘时翻转到左侧
                    let flip = x + panelWidth + 16 > geo.size.width

                    loadTooltip(entries)
                        .offset(x: flip ? x - panelWidth - 12 : x + 12, y: 10)
                }
            }
        }
    }

    /// 三条曲线的扁平数据（按「类型」分组形成独立系列）
    private var loadAllPoints: [LoadSeriesPoint] {
        vm.load1Points.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: "1分钟") }
            + vm.load5Points.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: "5分钟") }
            + vm.load15Points.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: "15分钟") }
    }

    /// 拖动选中时的竖排数值浮层
    private func loadTooltip(_ entries: [(title: String, value: Double?, color: Color)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(entries, id: \.title) { entry in
                HStack(spacing: 5) {
                    Circle().fill(entry.color).frame(width: 6, height: 6)
                    Text(entry.title)
                        .foregroundStyle(entry.color)
                    Spacer(minLength: 4)
                    Text(entry.value.map { String(format: "%.2f", $0) } ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(entry.color)
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

    /// 选中时间（或最新）在曲线上的数值
    private func selectedLoadValue(from points: [MonitorPoint]) -> Double? {
        guard let sel = selectedLoadDate else { return points.last?.value }
        return points.min {
            abs($0.date.timeIntervalSince(sel)) < abs($1.date.timeIntervalSince(sel))
        }?.value
    }

    /// 把手势换算出的日期限制在曲线数据范围内
    private func clampToLoadDomain(_ date: Date) -> Date {
        let all = vm.load1Points + vm.load5Points + vm.load15Points
        guard let first = all.map(\.date).min(), let last = all.map(\.date).max() else {
            return date
        }
        return min(max(date, first), last)
    }

    /// 负载列：上方标签、下方数值（不加粗）
    private func loadColumn(_ title: String, _ value: Double?) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value.map { String(format: "%.2f", $0) } ?? "—")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
    }

    /// 小型使用率圆环（44pt，高度不超过三列负载文本），圆心仅显示数值
    private func miniRing(percent: Double) -> some View {
        ZStack {
            Circle()
                .stroke(Color.teal.opacity(0.15), lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(0.001, min(percent, 100)) / 100)
                .stroke(Color.teal, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(String(format: "%.0f%%", percent))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .frame(width: 44, height: 44)
    }

    private var cpuSection: some View {
        Section {
            percentChart(vm.cpuPoints, color: .blue)
        } header: {
            Text("CPU 使用率")
        } footer: {
            if let last = vm.cpuPoints.last {
                Text("当前 \(String(format: "%.1f%%", last.value))")
            }
        }
    }

    private var memorySection: some View {
        Section {
            percentChart(vm.memPoints, color: .purple)
        } header: {
            Text("内存使用率")
        } footer: {
            if let last = vm.memPoints.last {
                Text("当前 \(String(format: "%.1f%%", last.value))")
            }
        }
    }

    // MARK: 磁盘 I/O

    private var ioSection: some View {
        Section {
            dualChart(read: vm.ioReadPoints, write: vm.ioWritePoints)
            legend(color: .blue, label: "读取", color2: .orange, label2: "写入")
        } header: {
            Text("磁盘 I/O（KB/s）")
        }
    }

    // MARK: 网络

    private var networkSection: some View {
        Section {
            dualChart(read: vm.netUpPoints, write: vm.netDownPoints)
            legend(color: .green, label: "上行", color2: .purple, label2: "下行")
        } header: {
            Text("网络（KB/s）")
        }
    }

    // MARK: Top 进程

    @ViewBuilder
    private var topProcessSections: some View {
        if !vm.topCPU.isEmpty {
            Section("Top 进程（CPU）") {
                ForEach(vm.topCPU.prefix(5)) { item in
                    topRow(item, memoryBytes: false)
                }
            }
        }
        if !vm.topMem.isEmpty {
            Section("Top 进程（内存）") {
                ForEach(vm.topMem.prefix(5)) { item in
                    topRow(item, memoryBytes: true)
                }
            }
        }
    }

    // MARK: 图表组件

    /// 百分比单曲线：面积 + 折线（yMax 默认 100，负载图传入自适应上限）
    private func percentChart(_ points: [MonitorPoint], color: Color, yMax: Double = 100) -> some View {
        Chart(points) { p in
            AreaMark(
                x: .value("时间", p.date),
                y: .value("数值", p.value)
            )
            .foregroundStyle(color.opacity(0.12))
            LineMark(
                x: .value("时间", p.date),
                y: .value("数值", p.value)
            )
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartYScale(domain: 0...max(yMax, 1))
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .frame(height: 160)
    }

    /// 双曲线（读/写、上/下行），Y 轴自适应
    private func dualChart(read: [MonitorPoint], write: [MonitorPoint]) -> some View {
        Chart {
            ForEach(read) { p in
                LineMark(
                    x: .value("时间", p.date),
                    y: .value("数值", p.value)
                )
                .foregroundStyle(.blue)
            }
            ForEach(write) { p in
                LineMark(
                    x: .value("时间", p.date),
                    y: .value("数值", p.value)
                )
                .foregroundStyle(.orange)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .frame(height: 160)
    }

    private func legend(color: Color, label: String, color2: Color, label2: String) -> some View {
        HStack(spacing: 20) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label)
            }
            HStack(spacing: 6) {
                Circle().fill(color2).frame(width: 8, height: 8)
                Text(label2)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func loadLabel(_ title: String, _ value: Double?) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Text(value.map { String(format: "%.2f", $0) } ?? "—")
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }

    private func topRow(_ item: MonitorTopItem, memoryBytes: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape")
                .foregroundStyle(.secondary)
                .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name ?? "—")
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    if let user = item.user, user != "undefined" {
                        Text(user)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let cmd = item.cmd, !cmd.isEmpty {
                    Text(cmd)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.1f%%", item.percent ?? 0))
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(memoryBytes ? .purple : .blue)
                if memoryBytes, let mem = item.memory, mem > 0 {
                    Text(formatBytes(mem))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var size = Double(bytes)
        var idx = 0
        while size >= 1024 && idx < units.count - 1 {
            size /= 1024
            idx += 1
        }
        return String(format: "%.1f %@", size, units[idx])
    }
}
