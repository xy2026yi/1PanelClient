//
//  MonitorView.swift
//  1PanelClient
//
//  历史监控：平均负载 / CPU / 内存 / 磁盘I/O / 网络 曲线图（Swift Charts）
//  历史曲线来自 POST /api/v2/hosts/monitor/search（时间范围可切换：1/6/24 小时与 7 天），
//  实时数值来自 GET /api/v2/dashboard/current/all/all（3 秒轮询）；
//  图表为 MonitorHistoryChart：采样位索引域 x + 固定 12 段网格外观（与容器监控同构）——
//  记录存在时间缺口时点距仍均等，虚线/时间标签映射到实际数据点上；
//  负载 Y 自 0...1 起步、峰值超 1 自动上扩（2 位小数）、CPU/内存 Y 固定 0...100
//  （各 11 条等距横线，CPU/内存带线下面积），
//  磁盘 I/O/网络动态（6 值 6 线），点按/拖动吸附数据点显示同色圆点与数值气泡
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
    /// 时间范围（小时）：1 / 6 / 24 / 168（7 天）
    @Published var hours: Int = 1
    @Published var isLoading = false
    /// 首次历史加载是否已完成（避免后台刷新时闪"加载中"占位）
    @Published private(set) var hasLoadedOnce = false
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

    // 最新负载 1/5/15（取自 dashboard/current 实时接口，随 3 秒轮询更新）
    @Published var latestLoad1: Double?
    @Published var latestLoad5: Double?
    @Published var latestLoad15: Double?
    /// 实时数值（GET dashboard/current：CPU 核心/已用/可用、内存等）
    @Published var current: DashboardCurrent?

    private let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    /// 首次进入/下拉刷新：历史曲线 + 实时数值并发拉取
    func loadAll() async {
        async let history: () = loadHistory()
        async let current: () = loadCurrent()
        _ = await (history, current)
    }

    /// 历史曲线（POST /hosts/monitor/search，按 hours 圈定时间窗）。
    /// 服务端每 5 分钟才落一条记录，无需高频轮询。
    func loadHistory() async {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoadedOnce = true
        }

        let end = Date()
        let start = Calendar.current.date(byAdding: .hour, value: -hours, to: end) ?? end
        let startTime = MonitorDate.requestString(start)
        let endTime = MonitorDate.requestString(end)

        // 一个请求获取全部监控序列（param=all 返回 base/io/network 三组）
        guard let series = await fetch(param: "all", start: startTime, end: endTime) else { return }

        // 按返回的 param 拆分
        let base = series.filter { $0.param == "base" }
        let io = series.filter { $0.param == "io" }
        let net = series.filter { $0.param == "network" }

        // base 形态（负载/CPU/内存共用记录结构）
        loadPoints = Self.decimate(points(from: base) { $0.loadUsage ?? 0 })
        load1Points = Self.decimate(points(from: base) { $0.cpuLoad1 ?? 0 })
        load5Points = Self.decimate(points(from: base) { $0.cpuLoad5 ?? 0 })
        load15Points = Self.decimate(points(from: base) { $0.cpuLoad15 ?? 0 })
        cpuPoints = Self.decimate(points(from: base) { $0.cpu ?? 0 })
        memPoints = Self.decimate(points(from: base) { $0.memory ?? 0 })

        // io / network 形态（磁盘 I/O 原始值为字节，除以 1000 换算为 KB）
        ioReadPoints = Self.decimate(points(from: io) { ($0.read ?? 0) / 1000 })
        ioWritePoints = Self.decimate(points(from: io) { ($0.write ?? 0) / 1000 })
        netUpPoints = Self.decimate(points(from: net) { $0.up ?? 0 })
        netDownPoints = Self.decimate(points(from: net) { $0.down ?? 0 })
    }

    /// 实时数值（GET /dashboard/current/all/all）：CPU/内存/SWAP 与负载 1/5/15
    func loadCurrent() async {
        current = await fetchCurrent()
        latestLoad1 = current?.load1
        latestLoad5 = current?.load5
        latestLoad15 = current?.load15
    }

    /// 长时间范围降采样：每条曲线最多保留约 cap 个点，末尾点始终保留。
    /// 7 天全量约 2000 点/条，降采样后曲线在 160pt 高度内足够平滑且不卡顿。
    private static func decimate(_ points: [MonitorPoint], cap: Int = 480) -> [MonitorPoint] {
        guard points.count > cap else { return points }
        let step = Int((Double(points.count) / Double(cap)).rounded(.up))
        var result = stride(from: 0, to: points.count, by: step).map { points[$0] }
        if let last = points.last, result.last?.date != last.date {
            result.append(last)
        }
        return result
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

    /// 实时数值（GET /api/v2/dashboard/current/all/all）
    private func fetchCurrent() async -> DashboardCurrent? {
        do {
            return try await client.send(
                path: APIEndpoint.dashboardCurrent.path,
                method: APIEndpoint.dashboardCurrent.method,
                as: DashboardCurrent.self
            )
        } catch {
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
    /// 平均负载图表展开状态（默认收起，点右侧下拉展开图表）
    @State private var showLoadChart = false
    /// CPU 图表展开状态
    @State private var showCPUChart = false
    /// 内存图表展开状态
    @State private var showMemChart = false
    /// App 是否处于前台活跃（后台时暂停轮询）
    @Environment(\.scenePhase) private var scenePhase
    @State private var isSceneActive = true

    init(server: ServerConfig) {
        self.server = server
        _vm = StateObject(wrappedValue: MonitorViewModel(server: server))
    }

    var body: some View {
        List {
            if vm.isLoading && !vm.hasLoadedOnce {
                Section {
                    HStack { Spacer(); ProgressView(L10n.t("加载监控数据…")); Spacer() }
                        .padding(.vertical, 30)
                }
            } else if let err = vm.errorMessage, vm.cpuPoints.isEmpty, !vm.isLoading {
                Section {
                    ContentUnavailableView {
                        Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(err)
                    } actions: {
                        Button(L10n.t("重试")) { Task { await vm.loadAll() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                rangeSection
                loadSection
                cpuSection
                memorySection
                ioSection
                networkSection
            }
        }
        // 卡片内更紧凑的行距
        .environment(\.defaultMinListRowHeight, 32)
        .navigationTitle(L10n.t("监控"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.loadAll() }
        // App 前后台切换时同步轮询开关
        .onChange(of: scenePhase) { _, phase in
            isSceneActive = phase == .active
        }
        // 切换时间范围后立即重拉历史曲线
        .onChange(of: vm.hours) { _, _ in
            Task { await vm.loadHistory() }
        }
        // 自动刷新（仅页面存活且 App 前台活跃时）：
        // 实时数值 3 秒一轮；历史曲线服务端 5 分钟才记一条，60 秒一轮足够
        .task {
            await vm.loadAll()
            var elapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, isSceneActive else { continue }
                await vm.loadCurrent()
                elapsed += 3
                if elapsed >= 60 {
                    elapsed = 0
                    await vm.loadHistory()
                }
            }
        }
    }

    // MARK: 时间范围

    /// 历史曲线时间范围切换（近 1 小时 / 6 小时 / 24 小时 / 7 天）
    private var rangeSection: some View {
        Section {
            Picker(L10n.t("时间范围"), selection: $vm.hours) {
                Text(L10n.t("1小时")).tag(1)
                Text(L10n.t("6小时")).tag(6)
                Text(L10n.t("24小时")).tag(24)
                Text(L10n.t("7天")).tag(168)
            }
            .pickerStyle(.segmented)
            .segmentedPickerRow()
            .listRowSeparator(.hidden)
        }
    }

    // MARK: 平均负载（标题+数值+图表一体化，右侧下拉展开图表）

    private var loadSection: some View {
        Section {
            // 标题行 + 下拉按钮
            HStack {
                Text(L10n.t("平均负载"))
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
                .accessibilityLabel(showLoadChart ? L10n.t("收起图表") : L10n.t("展开图表"))
            }
            .padding(.top, 8)
            .listRowSeparator(.hidden)
            .monitorRowInsets()

            // 1/5/15 分钟负载（上标签下数值）+ 右侧小型使用率圆环
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 0) {
                    loadColumn(L10n.t("1分钟"), vm.latestLoad1)
                    loadColumn(L10n.t("5分钟"), vm.latestLoad5)
                    loadColumn(L10n.t("15分钟"), vm.latestLoad15)
                }
                .frame(maxWidth: .infinity)

                miniRing(percent: vm.current?.loadUsagePercent ?? vm.loadPoints.last?.value ?? 0)
            }
            .padding(.vertical, 6)
            .listRowSeparator(.hidden)
            .monitorRowInsets()

            // 图表（下拉展开时显示：1/5/15 分钟三条曲线，支持拖动查看）
            if showLoadChart {
                Group {
                    if loadAllPoints.isEmpty {
                        chartPlaceholder()
                    } else {
                        loadChart
                    }
                }
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .listRowSeparator(.hidden)
            .monitorRowInsets()
            }
        }
    }

    /// 负载三曲线图表（1/5/15 分钟）：Y 自 0...1 起步、峰值超 1 自动上扩（11 条等距横线），无填充
    private var loadChart: some View {
        MonitorHistoryChart(
            points: loadAllPoints,
            styles: [L10n.t("1分钟"): .blue, L10n.t("5分钟"): .orange, L10n.t("15分钟"): .purple],
            unit: "",
            fixedYDomain: loadYDomain,
            fixedDecimals: 2,
            fill: false,
            labelFormatter: timeLabelFormatter
        )
    }

    /// 负载 Y 值域：负载可超 1（核心数多或过载时），峰值超 1 时自 0...1 向上扩展
    ///（留 10% 余量并向上取整到 0.5 的倍数，保持 11 条等距横线的刻度可读）
    private var loadYDomain: ClosedRange<Double> {
        let peak = loadAllPoints.map(\.value).max() ?? 0
        guard peak > 1 else { return 0...1 }
        let upper = ((peak * 1.1 * 2).rounded(.up)) / 2
        return 0...upper
    }

    /// 时间标签格式：小时级范围用 HH:mm，7 天用 MM-dd
    private var timeLabelFormatter: DateFormatter {
        vm.hours >= 168 ? Self.dayFormatter : Self.hourFormatter
    }

    private static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f
    }()

    /// 三条曲线的扁平数据（按「类型」分组形成独立系列）
    private var loadAllPoints: [LoadSeriesPoint] {
        vm.load1Points.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: L10n.t("1分钟")) }
            + vm.load5Points.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: L10n.t("5分钟")) }
            + vm.load15Points.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: L10n.t("15分钟")) }
    }

    /// 图表空数据占位：与图表同高，避免空白坐标轴让用户误以为图表坏了
    private func chartPlaceholder(hint: String? = nil) -> some View {
        VStack(spacing: 6) {
            Text(L10n.t("暂无监控数据"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 160)
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

    /// 小型使用率圆环（44pt，高度不超过三列数值文本），圆心仅显示数值
    private func miniRing(percent: Double, color: Color = .teal) -> some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.15), lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(0.001, min(percent, 100)) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(String(format: "%.0f%%", percent))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .frame(width: 44, height: 44)
    }

    // MARK: CPU（样式与平均负载一致：标题+下拉、三列数值+使用率圆环、拖动浮层）

    private var cpuSection: some View {
        Section {
            // 标题行 + 下拉按钮
            HStack {
                Text("CPU")
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showCPUChart.toggle()
                    }
                } label: {
                    Image(systemName: showCPUChart ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showCPUChart ? L10n.t("收起图表") : L10n.t("展开图表"))
            }
            .padding(.top, 8)
            .listRowSeparator(.hidden)
            .monitorRowInsets()

            // 核心 / 已用 / 可用 三列 + 右侧使用率圆环
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 0) {
                    statColumn(L10n.t("核心"), vm.current?.cpuTotal.map(String.init) ?? "—")
                    statColumn(L10n.t("已用"), vm.current?.cpuUsed.map { String(format: "%.2f", $0) } ?? "—")
                    statColumn(L10n.t("可用"), vm.current.map { cur in
                        let total = Double(cur.cpuTotal ?? 0)
                        let used = cur.cpuUsed ?? 0
                        return String(format: "%.2f", max(total - used, 0))
                    } ?? "—")
                }
                .frame(maxWidth: .infinity)

                miniRing(percent: vm.current?.cpuUsedPercent ?? 0, color: .blue)
            }
            .padding(.vertical, 6)
            .listRowSeparator(.hidden)
            .monitorRowInsets()

            // 图表（下拉展开时显示，Y 轴自适应）
            if showCPUChart {
                Group {
                    if vm.cpuPoints.isEmpty {
                        chartPlaceholder()
                    } else {
                        MonitorHistoryChart(
                            points: vm.cpuPoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: "CPU") },
                            styles: ["CPU": .blue],
                            unit: "%",
                            fixedYDomain: 0...100,
                            fixedDecimals: 0,
                            fill: true,
                            labelFormatter: timeLabelFormatter
                        )
                    }
                }
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .listRowSeparator(.hidden)
            .monitorRowInsets()
            }
        }
    }

    /// 通用数值列：上方标签、下方数值（与负载列样式一致）
    private func statColumn(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 内存 + SWAP（同栏显示，图表仅针对内存）

    private var memorySection: some View {
        Section {
            // 标题行 + 下拉按钮
            HStack {
                Text(L10n.t("内存"))
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showMemChart.toggle()
                    }
                } label: {
                    Image(systemName: showMemChart ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showMemChart ? L10n.t("收起图表") : L10n.t("展开图表"))
            }
            .padding(.top, 8)
            .listRowSeparator(.hidden)
            .monitorRowInsets()

            // 内存：总计 / 已用 / 可用 三列 + 右侧使用率圆环
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 0) {
                    statColumn(L10n.t("总计"), bytesText(vm.current?.memoryTotal))
                    statColumn(L10n.t("已用"), bytesText(vm.current?.memoryUsed))
                    statColumn(L10n.t("可用"), bytesText(vm.current?.memoryAvailable))
                }
                .frame(maxWidth: .infinity)

                miniRing(percent: vm.current?.memoryUsedPercent ?? 0, color: .purple)
            }
            .padding(.vertical, 6)
            .listRowSeparator(.hidden)
            .monitorRowInsets()

            // SWAP 子标签
            HStack {
                Text("SWAP")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 2)
            .listRowSeparator(.hidden)
            .monitorRowInsets()

            // SWAP：总计 / 已用 / 可用 三列 + 右侧使用率圆环（无图表）
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 0) {
                    statColumn(L10n.t("总计"), bytesText(vm.current?.swapMemoryTotal))
                    statColumn(L10n.t("已用"), bytesText(vm.current?.swapMemoryUsed))
                    statColumn(L10n.t("可用"), bytesText(vm.current?.swapMemoryAvailable))
                }
                .frame(maxWidth: .infinity)

                miniRing(percent: vm.current?.swapMemoryUsedPercent ?? 0, color: .orange)
            }
            .padding(.vertical, 6)
            .listRowSeparator(.hidden)
            .monitorRowInsets()

            // 内存图表（下拉展开时显示，置于两块数值之下，Y 轴自适应）
            if showMemChart {
                Group {
                    if vm.memPoints.isEmpty {
                        chartPlaceholder()
                    } else {
                        MonitorHistoryChart(
                            points: vm.memPoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: L10n.t("内存")) },
                            styles: [L10n.t("内存"): .purple],
                            unit: "%",
                            fixedYDomain: 0...100,
                            fixedDecimals: 0,
                            fill: true,
                            labelFormatter: timeLabelFormatter
                        )
                    }
                }
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .listRowSeparator(.hidden)
            .monitorRowInsets()
            }
        }
    }

    /// 字节数值格式化（nil 显示 —）
    private func bytesText(_ bytes: Int64?) -> String {
        bytes.map { formatBytes($0) } ?? "—"
    }

    // MARK: 磁盘 I/O（标题与图表同卡片）

    private var ioSection: some View {
        Section {
            HStack {
                Text(L10n.t("磁盘 I/O"))
                    .font(.headline)
                Spacer()
            }
            .padding(.top, 8)
            .listRowSeparator(.hidden)
            .monitorRowInsets()

            Group {
                if ioSeriesPoints.isEmpty {
                    chartPlaceholder(hint: L10n.t("若刚开启监控，磁盘 I/O 与网络数据约 5 分钟后开始记录"))
                } else {
                    MonitorHistoryChart(
                        points: ioSeriesPoints,
                        styles: [L10n.t("读取"): .blue, L10n.t("写入"): .orange],
                        unit: "KB",
                        labelFormatter: timeLabelFormatter
                    )
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 8)
            .listRowSeparator(.hidden)
            .monitorRowInsets()
        }
    }

    // MARK: 网络（标题与图表同卡片）

    private var networkSection: some View {
        Section {
            HStack {
                Text(L10n.t("网络"))
                    .font(.headline)
                Spacer()
            }
            .padding(.top, 8)
            .listRowSeparator(.hidden)
            .monitorRowInsets()

            Group {
                if networkSeriesPoints.isEmpty {
                    chartPlaceholder(hint: L10n.t("若刚开启监控，磁盘 I/O 与网络数据约 5 分钟后开始记录"))
                } else {
                    MonitorHistoryChart(
                        points: networkSeriesPoints,
                        styles: [L10n.t("上行"): .green, L10n.t("下行"): .purple],
                        unit: "KB",
                        labelFormatter: timeLabelFormatter
                    )
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 8)
            .listRowSeparator(.hidden)
            .monitorRowInsets()
        }
    }

    /// 磁盘 I/O 扁平双系列数据
    private var ioSeriesPoints: [LoadSeriesPoint] {
        vm.ioReadPoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: L10n.t("读取")) }
            + vm.ioWritePoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: L10n.t("写入")) }
    }

    /// 网络扁平双系列数据
    private var networkSeriesPoints: [LoadSeriesPoint] {
        vm.netUpPoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: L10n.t("上行")) }
            + vm.netDownPoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: L10n.t("下行")) }
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

// MARK: - 历史监控图表（采样位索引域 + 固定 12 段网格外观，与容器监控同构）

/// 历史曲线图表：
/// - X 为采样位索引域（0...N-1，全部系列并集去重升序）：点距均等，
///   与容器监控同构——监控记录存在时间缺口时点距也不会被拉开；
///   叠加固定 12 段网格外观——中间 10 条竖向虚线、时间标签 5 个（段位 0/3/6/9/11），
///   均映射到实际采样位（虚线/标签/圆点严格落在数据点上，偏差不超过半个点距）；
/// - Y 轴形态由共享的 MonitorYAxis 计算：fixedYDomain（负载 0...1 起步超 1 上扩、
///   CPU/内存 0...100）→ 跨度 10 等分共 11 条等距横线；nil → 动态（峰值×1.15 紧凑头寸
///   → 等距对齐，恰好 6 值 6 线；恒 0 时 3 个刻度）；
/// - 点按/拖动：跟手虚线逐采样位步进吸附、各系列同色圆点，
///   气泡悬于最高圆点上方（值过固定值域 90% 或上方放不下时改放圆点侧面）；
/// - fill：单系列（CPU/内存）线下面积填充；双系列不填充；
/// - 派生数据（时间轴/系列摊平/Y 轴形态）由 body 构建一次经 Model 逐层传递——
///   拖动选中期间 body 每帧求值，避免计算属性在单帧内重复构建字典/数组
struct MonitorHistoryChart: View {
    let points: [LoadSeriesPoint]
    let styles: KeyValuePairs<String, Color>
    let unit: String
    /// 固定 Y 值域（负载 0...1 起步超 1 上扩、CPU/内存 0...100；nil = 动态）
    var fixedYDomain: ClosedRange<Double>? = nil
    /// 固定值域的刻度小数位（负载 2 → 0.15；百分比 0 → 30%）
    var fixedDecimals: Int = 0
    /// 线条至底部的颜色填充（单系列面积）
    var fill: Bool = false
    var height: CGFloat = 160
    /// 时间标签格式（随时间范围：小时级 HH:mm、7 天 MM-dd）
    var labelFormatter: DateFormatter

    /// 选中采样位（nil = 未选中；再次点击同一位取消）
    @State private var selectedSlot: Int?
    /// 本次手势开始前已选中的采样位（松手时判断「点击已选位 → 取消」）
    @State private var slotAtGestureStart: Int?
    /// 绘图区（相对图表整体 frame），自绘时间轴/气泡据此对齐
    @State private var plotRect: CGRect = .zero
    /// 气泡实际尺寸（position 按中心定位，计算与最高圆点的间距用）
    @State private var bubbleSize: CGSize = .zero

    // MARK: 渲染派生数据

    /// 摊平后的数据点（单 ForEach 绘制，系列靠 foregroundStyle(by:) 区分，
    /// 避免分系列双 ForEach 同日期 id 冲突导致曲线粘连）
    private struct FlatPoint: Identifiable {
        let kind: String
        let index: Int
        let value: Double
        var id: String { "\(kind)#\(index)" }
    }

    /// 单次渲染的派生数据：body 求值时构建一次、逐层传递
    ///（历史数据最多约 480 点/系列 × 3 系列，拖动期间每帧求值不重复构建）
    private struct Model {
        /// 画竖向虚线的段位（10 条；两端边缘段位不画）
        private static let gridSegments = Array(1...10)
        /// 时间标签的段位（5 个，相邻隔 2 条虚线；首尾为窗口两端）
        private static let labelSegments = [0, 3, 6, 9, 11]

        /// 升序去重时间轴（全部系列并集），即 x 采样位序列：dates[i] 位于 x = i
        let dates: [Date]
        /// 日期 → 采样位索引
        let dateIndex: [Date: Int]
        /// 按系列名拆分的样本
        let series: [(kind: String, points: [MonitorPoint])]
        /// 摊平后的全部数据点
        let flat: [FlatPoint]
        /// 各系列当前点数（≤2 时补圆点）
        let counts: [String: Int]
        /// 虚线采样位（段位 1...10 映射去重——点数少时段位可能重合到同一位）
        let grid: [Int]
        /// 时间标签采样位（段位 0/3/6/9/11 映射去重）
        let labels: [Int]
        /// Y 轴形态（固定/动态，见 MonitorYAxis）
        let axis: MonitorYAxis

        init(points: [LoadSeriesPoint], styles: KeyValuePairs<String, Color>,
             fixedYDomain: ClosedRange<Double>?, fixedDecimals: Int) {
            // 全程用局部量构建（闭包内不能引用 self 的未初始化属性），最后统一赋值
            var seen = Set<Date>()
            let dates = points.compactMap { seen.insert($0.date).inserted ? $0.date : nil }.sorted()
            let indexByDate = Dictionary(dates.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            let series: [(kind: String, points: [MonitorPoint])] = styles.map { kind, _ in
                (kind, points.filter { $0.kind == kind }.map { MonitorPoint(date: $0.date, value: $0.value) })
            }
            let flat = series.flatMap { s in
                s.points.compactMap { p in
                    indexByDate[p.date].map { FlatPoint(kind: s.kind, index: $0, value: p.value) }
                }
            }

            // 段位（0...11）→ 采样位索引：12 段均分到实际点数并四舍五入，
            // 使虚线/标签严格落在数据点上（偏差不超过半个点距）
            let last = max(dates.count - 1, 0)
            func slotIndex(_ seg: Int) -> Int {
                min(max(Int((Double(seg) * Double(last) / 11).rounded()), 0), last)
            }
            var gridSeen = Set<Int>()
            let grid = Self.gridSegments.compactMap { seg in
                let idx = slotIndex(seg)
                return gridSeen.insert(idx).inserted ? idx : nil
            }
            var labelSeen = Set<Int>()
            let labels = Self.labelSegments.compactMap { seg in
                let idx = slotIndex(seg)
                return labelSeen.insert(idx).inserted ? idx : nil
            }

            let values = flat.map(\.value)
            let axis: MonitorYAxis
            if let fixed = fixedYDomain {
                axis = .fixed(fixed, decimals: fixedDecimals)
            } else {
                axis = .dynamic(
                    peak: values.max() ?? 0,
                    low: values.min() ?? 0,
                    allZero: !values.isEmpty && values.allSatisfy { $0 == 0 }
                )
            }

            self.dates = dates
            self.dateIndex = indexByDate
            self.series = series
            self.flat = flat
            self.counts = Dictionary(grouping: flat, by: \.kind).mapValues(\.count)
            self.grid = grid
            self.labels = labels
            self.axis = axis
        }

        /// x 值域右端（末位采样位索引；dates.count ≥ 2 由 body 占位保证）
        var xUpper: Double { Double(max(dates.count - 1, 1)) }

        /// 指定系列在采样位上的数值（该系列可能缺这个时刻的样本 → 就近取）
        func value(at slot: Int, in series: (kind: String, points: [MonitorPoint])) -> Double? {
            guard dates.indices.contains(slot) else { return nil }
            let date = dates[slot]
            return series.points.min {
                abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
            }?.value
        }
    }

    /// 系列名对应的曲线颜色
    private func color(for kind: String) -> Color {
        for (k, c) in styles where k == kind { return c }
        return .blue
    }

    // MARK: 视图

    var body: some View {
        let m = Model(points: points, styles: styles,
                      fixedYDomain: fixedYDomain, fixedDecimals: fixedDecimals)
        if m.dates.count < 2 {
            Text(L10n.t("暂无监控数据"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: height)
        } else {
            VStack(spacing: 2) {
                chart(m)
                timeAxis(m)
            }
            // 右侧留出边距，绘图区不顶到行右缘（同容器监控）
            .padding(.trailing, 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary(m))
        }
    }

    private func chart(_ m: Model) -> some View {
        Chart {
            // 固定网格虚线（画在最底层）：段位映射到实际采样位，虚线压在数据点上
            ForEach(m.grid, id: \.self) { idx in
                RuleMark(x: .value(L10n.t("网格"), Double(idx)))
                    .foregroundStyle(Color.secondary.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            fillMarks(m)
            lineMarks(m)
            selectionMarks(m)
        }
        .chartForegroundStyleScale(styles)
        .chartLegend(.hidden)
        .chartXScale(domain: 0...m.xUpper)
        .chartYScale(domain: m.axis.domain)
        // 时间标签自绘（见 timeAxis）：系统轴无法保证「正对段位居中」
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: m.axis.ticks) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(String(format: "%.\(m.axis.decimals)f%@", v, unit))
                            .font(.caption2)
                            .monospacedDigit()
                            .fixedSize()
                            // 与绘图区左缘拉开距离（同容器监控）
                            .padding(.trailing, 12)
                    }
                }
            }
        }
        .frame(height: height)
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plotFrame = proxy.plotFrame.map { geo[$0] } ?? .zero

                // 手势层：触摸 x → 采样位（虚线跟手，逐位步进、不跳位）
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
                                let fraction = Double(x / plotFrame.width)
                                selectedSlot = min(max(Int((fraction * m.xUpper).rounded()), 0),
                                                   m.dates.count - 1)
                            }
                            .onEnded { _ in
                                // 再次点击已选中的位取消；拖到别的位松手则保持新选中
                                if selectedSlot != nil, selectedSlot == slotAtGestureStart {
                                    selectedSlot = nil
                                }
                                slotAtGestureStart = nil
                            }
                    )

                // 布局期间同步绘图区位置，供自绘时间轴/气泡对齐数据区
                Color.clear
                    .onAppear { plotRect = plotFrame }
                    .onChange(of: plotFrame) { _, new in plotRect = new }

                // 数值气泡：默认悬于最高圆点正上方（水平居中于选中位、贴边收回），
                // 值过固定值域 90% 或上方放不下时改放圆点左/右侧
                if let sel = selectedSlot {
                    bubbleView(m, sel, plotFrame: plotFrame, geoSize: geo.size)
                }
            }
        }
    }

    // MARK: 图层

    /// 线条至底部的颜色填充（仅单系列：CPU/内存线下面积；双系列不填充）。
    /// 用 foregroundStyle(by: 类型)（与折线共用色彩 scale）保证面积与折线同色
    @ChartContentBuilder
    private func fillMarks(_ m: Model) -> some ChartContent {
        if fill, m.series.count == 1, let only = m.series.first {
            ForEach(only.points.compactMap { p -> (idx: Int, value: Double)? in
                guard let idx = m.dateIndex[p.date] else { return nil }
                return (idx, p.value)
            }, id: \.idx) { item in
                AreaMark(x: .value(L10n.t("采样位"), Double(item.idx)),
                         yStart: .value(L10n.t("值"), 0),
                         yEnd: .value(L10n.t("值"), item.value))
                    .foregroundStyle(by: .value(L10n.t("类型"), only.kind))
                    .opacity(0.12)
            }
        }
    }

    /// 全部系列摊平进一个 ForEach（与容器监控同构）
    @ChartContentBuilder
    private func lineMarks(_ m: Model) -> some ChartContent {
        ForEach(m.flat) { p in
            LineMark(x: .value(L10n.t("采样位"), Double(p.index)), y: .value(L10n.t("值"), p.value))
                .foregroundStyle(by: .value(L10n.t("类型"), p.kind))
                // 直线插值：监控曲线平滑过冲会制造不存在的峰谷
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            // 系列点数 ≤2 时折线画不出趋势，补圆点保证可见
            if (m.counts[p.kind] ?? 0) <= 2 {
                PointMark(x: .value(L10n.t("采样位"), Double(p.index)), y: .value(L10n.t("值"), p.value))
                    .foregroundStyle(by: .value(L10n.t("类型"), p.kind))
                    .symbolSize(60)
            }
        }
    }

    /// 选中采样位：深色虚线跟手 + 各系列同色圆点
    @ChartContentBuilder
    private func selectionMarks(_ m: Model) -> some ChartContent {
        if let sel = selectedSlot {
            RuleMark(x: .value(L10n.t("选中"), Double(sel)))
                .foregroundStyle(Color.primary.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            ForEach(m.series, id: \.kind) { series in
                if let v = m.value(at: sel, in: series) {
                    PointMark(x: .value(L10n.t("选中"), Double(sel)), y: .value(L10n.t("值"), v))
                        .foregroundStyle(color(for: series.kind))
                        .symbolSize(60)
                }
            }
        }
    }

    // MARK: 自绘时间轴

    /// 图表下方的时间标签行：正对各自采样位居中，显示该采样位的实际时间；
    /// 首尾允许悬出行边界
    private func timeAxis(_ m: Model) -> some View {
        GeometryReader { geo in
            ForEach(m.labels, id: \.self) { idx in
                Text(labelFormatter.string(from: m.dates[idx]))
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .position(x: slotX(idx, xUpper: m.xUpper), y: geo.size.height / 2)
            }
        }
        .frame(height: 22)
    }

    /// 采样位 → 标签水平位置（正对采样位精确居中，半宽悬出也不拉回）
    private func slotX(_ slot: Int, xUpper: Double) -> CGFloat {
        plotRect.minX + plotRect.width * (Double(slot) / xUpper)
    }

    // MARK: 交互与气泡

    /// 气泡定位与内容：每系列一行「同色圆点 + 系列名 数值」按值降序，
    /// 悬于最高圆点正上方（贴边收回）；值过固定值域 90% 或上方放不下时
    /// 改放圆点侧面（左半边放右侧、右半边放左侧，垂直与圆点对齐）
    @ViewBuilder
    private func bubbleView(_ m: Model, _ sel: Int, plotFrame: CGRect, geoSize: CGSize) -> some View {
        let entries = entries(m, at: sel)
        if plotFrame.width > 0, let topValue = entries.map(\.value).max() {
            let xCenter = plotFrame.minX + plotFrame.width * (Double(sel) / m.xUpper)
            let span = max(m.axis.domain.upperBound - m.axis.domain.lowerBound, .ulpOfOne)
            let yTop = plotFrame.minY
                + plotFrame.height * CGFloat((m.axis.domain.upperBound - topValue) / span)
            let pos = MonitorBubbleLayout.position(
                nearCap: fixedYDomain.map {
                    topValue > $0.lowerBound + ($0.upperBound - $0.lowerBound) * 0.9
                } ?? false,
                xCenter: xCenter, yTop: yTop,
                halfW: bubbleSize.width / 2, halfH: bubbleSize.height / 2,
                geoWidth: geoSize.width, geoHeight: geoSize.height
            )
            bubble(entries)
                .background(bubbleTracker)
                .position(x: pos.x, y: pos.y)
        }
    }

    /// 选中采样位各系列数值（按值降序；小数位随 Y 轴形态，刻度与气泡数值保持一致）
    private func entries(_ m: Model, at slot: Int) -> [(title: String, text: String, color: Color, value: Double)] {
        var raw: [(String, Double, Color)] = []
        for series in m.series {
            if let v = m.value(at: slot, in: series) {
                raw.append((series.kind, v, color(for: series.kind)))
            }
        }
        return raw.sorted { $0.1 > $1.1 }
            .map { ($0.0, String(format: "%.\(m.axis.decimals)f%@", $0.1, unit), $0.2, $0.1) }
    }

    /// 数值气泡：每系列一行「同色圆点 + 系列名 数值」
    private func bubble(_ entries: [(title: String, text: String, color: Color, value: Double)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(entries, id: \.title) { entry in
                HStack(spacing: 4) {
                    Circle()
                        .fill(entry.color)
                        .frame(width: 6, height: 6)
                    Text("\(entry.title) \(entry.text)")
                        .monospacedDigit()
                        .lineLimit(1)
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

    /// 无障碍摘要：折线内容 VoiceOver 无法读取，以各系列最新采样值代替
    private func accessibilitySummary(_ m: Model) -> String {
        let parts = m.series.compactMap { series -> String? in
            guard let latest = series.points.last else { return nil }
            return L10n.f("%@最新%@", series.kind,
                          String(format: "%.\(m.axis.decimals)f%@", latest.value, unit))
        }
        return parts.isEmpty ? L10n.t("监控折线图，暂无数据") : L10n.t("监控折线图：") + parts.joined(separator: "，")
    }
}
