//
//  AIVllmMonitorView.swift
//  1PanelClient
//
//  vLLM 实例监控（v2.4.0 新增，logs/2.4.0新增vllm.md 抓包 2026-10-23）：
//  实时指标（POST ai/vllm/monitor/current，5 秒轮询）/ 历史曲线（POST monitor/search，
//  时间范围 1/6/24 小时与 7 天 × 分组 概览/延迟分析/请求分析 × 聚合 平均/最大，60 秒轮询）/
//  清空该实例监控记录（POST monitor/clean）。图表复用 MonitorHistoryChart（与主机/GPU 监控同构）。
//  抓包机无 GPU：全部指标 null、status=unavailable——页面以「—」与不可用脚注兜底；
//  单位口径按服务端 utils/ai_tools/vllm 计算逻辑（百分比 / 每秒速率 / 秒）。
//  分布直方图（promptDistribution/generationDistribution 桶 → req/s）暂不展示，完成原因按行列出。
//

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class AIVllmMonitorViewModel: ObservableObject {
    /// 历史时间范围（小时）：1 / 6 / 24 / 168
    @Published var hours = 1
    @Published var group: VllmMonitorGroup = .overview
    @Published var aggregation: VllmMonitorAggregation = .avg

    @Published private(set) var current: VllmMonitorPoint?
    @Published private(set) var history: VllmMonitorHistory?
    @Published private(set) var isLoading = true
    @Published private(set) var hasLoadedHistory = false
    @Published var errorMessage: String?
    @Published var toastMessage: String?

    let appInstallID: Int
    private let client: APIClient
    private var historyGeneration = 0

    init(server: ServerConfig, appInstallID: Int) {
        self.appInstallID = appInstallID
        self.client = APIClient.shared(for: server)
    }

    func loadAll() async {
        async let current: () = loadCurrent()
        async let history: () = loadHistory()
        _ = await (current, history)
        isLoading = false
    }

    /// 实时指标：服务端即时拉实例 /metrics 计算，实例未运行时 status=unavailable 仍返回 200
    func loadCurrent() async {
        do {
            current = try await client.send(
                path: APIEndpoint.vllmMonitorCurrent.path,
                body: VllmMonitorTargetRequest(appInstallID: appInstallID),
                as: VllmMonitorPoint.self)
            errorMessage = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            if current == nil { errorMessage = error.localizedDescription }
        }
    }

    /// 历史曲线：范围 / 分组 / 聚合任一变化即重拉；慢返回的旧响应不覆盖新结果
    func loadHistory() async {
        historyGeneration += 1
        let generation = historyGeneration
        let end = Date()
        let start = Calendar.current.date(byAdding: .hour, value: -hours, to: end) ?? end
        do {
            let resp: VllmMonitorHistory = try await client.send(
                path: APIEndpoint.vllmMonitorSearch.path,
                body: VllmMonitorSearchRequest(
                    appInstallID: appInstallID,
                    startTime: MonitorDate.requestString(start),
                    endTime: MonitorDate.requestString(end),
                    aggregation: aggregation.rawValue,
                    group: group.rawValue),
                as: VllmMonitorHistory.self)
            guard generation == historyGeneration else { return }
            history = resp
            errorMessage = nil
        } catch {
            guard !APIError.isCancellation(error), generation == historyGeneration else { return }
            if history == nil { errorMessage = error.localizedDescription }
        }
        hasLoadedHistory = true
    }

    /// 清空该实例监控记录；成功后清空本地历史并重拉
    func clean() async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.vllmMonitorClean.path,
                body: VllmMonitorTargetRequest(appInstallID: appInstallID),
                as: EmptyResponse.self)
            toastMessage = L10n.t("已清空监控记录")
            history = nil
            await loadHistory()
            return true
        } catch {
            guard !APIError.isCancellation(error) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: 派生

    /// 历史采样点按时间升序（服务端已排序，防御性再排一次）
    var historyPoints: [(date: Date, point: VllmMonitorPoint)] {
        (history?.points ?? []).compactMap { point in
            guard let raw = point.createdAt, let date = MonitorDate.parse(raw) else { return nil }
            return (date, point)
        }
        .sorted { $0.date < $1.date }
    }

    /// 某指标曲线（nil 值跳过形成断点；长窗口降采样）
    func series(_ metric: VllmMonitorMetric, kind: String) -> [LoadSeriesPoint] {
        series(kind: kind) { metric.value(in: $0) }
    }

    func series(kind: String, value: (VllmMonitorPoint) -> Double?) -> [LoadSeriesPoint] {
        let raw = historyPoints.compactMap { item -> LoadSeriesPoint? in
            guard let v = value(item.point) else { return nil }
            return LoadSeriesPoint(date: item.date, value: v, kind: kind)
        }
        return Self.decimate(raw)
    }

    /// 降采样：最多约 480 点，末尾点保留（与 GPU 监控同款）
    private static func decimate(_ points: [LoadSeriesPoint], cap: Int = 480) -> [LoadSeriesPoint] {
        guard points.count > cap else { return points }
        let step = Int((Double(points.count) / Double(cap)).rounded(.up))
        var result = stride(from: 0, to: points.count, by: step).map { points[$0] }
        if let last = points.last, result.last?.date != last.date {
            result.append(last)
        }
        return result
    }
}

// MARK: - 页面

struct AIVllmMonitorView: View {
    let instance: VllmInstance
    @StateObject private var vm: AIVllmMonitorViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isSceneActive = true
    @State private var showCleanConfirm = false
    @State private var showError = false

    init(server: ServerConfig, instance: VllmInstance, appInstallID: Int) {
        self.instance = instance
        _vm = StateObject(wrappedValue: AIVllmMonitorViewModel(server: server, appInstallID: appInstallID))
    }

    var body: some View {
        statefulContent
            .navigationTitle(L10n.f("监控 · %@", instance.displayName))
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await vm.loadAll() }
            .toastOverlay(message: $vm.toastMessage)
    }

    /// body 整条修饰符链在 Xcode 26.6（CI 低一档工具链）下类型检查超时，
    /// 拆为三段计算属性各自独立检查（rootContent / 状态交互组 / 导航刷新组）
    private var statefulContent: some View {
        rootContent
            .alert(L10n.t("清空监控记录"), isPresented: $showCleanConfirm) {
                Button(L10n.t("取消"), role: .cancel) {}
                Button(L10n.t("清空"), role: .destructive) {
                    Haptic.warning()
                    Task {
                        if !(await vm.clean()) { showError = true }
                    }
                }
            } message: {
                Text(L10n.f("将删除实例「%@」的全部历史监控数据，该操作无法回滚，是否继续？", instance.displayName))
            }
            .alert(L10n.t("提示"), isPresented: $showError) {
                Button(L10n.t("好的"), role: .cancel) {}
            } message: {
                Text(vm.errorMessage ?? "")
            }
            .onChange(of: scenePhase) { _, phase in
                isSceneActive = phase == .active
            }
            .onChange(of: vm.hours) { _, _ in Task { await vm.loadHistory() } }
            .onChange(of: vm.group) { _, _ in Task { await vm.loadHistory() } }
            .onChange(of: vm.aggregation) { _, _ in Task { await vm.loadHistory() } }
            // 实时 5 秒一轮（服务端按需即时采集）；历史按面板采集间隔落库，60 秒一轮足够
            .task { await pollLoop() }
    }

    private var rootContent: some View {
        Group {
            if vm.isLoading && vm.current == nil && vm.history == nil {
                LoadingStateView()
            } else if let err = vm.errorMessage, vm.current == nil, vm.history == nil {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button(L10n.t("重试")) { Task { await vm.loadAll() } }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                content
            }
        }
    }

    /// 轮询循环提取为独立方法——Xcode 26.6（CI 低一档工具链）对 .task 闭包内联的
    /// while + Duration 字面量整体类型检查超时（CI 实证 211 行），拆开后豁免
    private func pollLoop() async {
        await vm.loadAll()
        var elapsed: Int = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, isSceneActive else { continue }
            await vm.loadCurrent()
            elapsed += 5
            if elapsed >= 60 {
                elapsed = 0
                await vm.loadHistory()
            }
        }
    }

    private var content: some View {
        List {
            rangeSection
            currentSection
            historySection
            cleanSection
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 36)
    }

    // MARK: 范围 / 分组 / 聚合

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

            Picker(L10n.t("分组"), selection: $vm.group) {
                ForEach(VllmMonitorGroup.allCases) { group in
                    Text(group.displayName).tag(group)
                }
            }
            .pickerStyle(.segmented)
            .segmentedPickerRow()
            .listRowSeparator(.hidden)

            Picker(L10n.t("聚合方式"), selection: $vm.aggregation) {
                ForEach(VllmMonitorAggregation.allCases) { aggregation in
                    Text(aggregation.displayName).tag(aggregation)
                }
            }
        } footer: {
            Text(L10n.t("聚合方式作用于历史曲线：采样点过多时服务端按时间桶合并，取桶内平均值或最大值。"))
        }
    }

    // MARK: 实时指标

    private var metrics: [VllmMonitorMetric] { VllmMonitorMetric.metrics(in: vm.group) }

    private var currentSection: some View {
        Section {
            HStack {
                Text(L10n.t("采集状态"))
                Spacer()
                if let point = vm.current {
                    StatusBadge(text: point.isAvailable ? L10n.t("正常") : L10n.t("不可用"),
                                color: point.isAvailable ? .statusRunning : .secondary)
                    if let raw = point.createdAt, let date = MonitorDate.parse(raw) {
                        Text(Self.timeFormatter.string(from: date))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }

            ForEach(metrics) { metric in
                metricRow(metric)
            }

            // 请求分析：完成原因（stop / length / abort …）→ 每秒请求数
            if vm.group == .requests, let reasons = vm.current?.finishReasons, !reasons.isEmpty {
                ForEach(reasons.keys.sorted(), id: \.self) { reason in
                    InfoRow(L10n.f("完成原因 · %@", reason),
                            value: String(format: "%.2f req/s", reasons[reason] ?? 0),
                            monospaced: true)
                }
            }
        } header: {
            SectionLabel(title: L10n.t("实时指标"), systemImage: "waveform.path.ecg")
        } footer: {
            if let point = vm.current, !point.isAvailable {
                Text(L10n.t("无法读取 vLLM /metrics：实例未运行、无 GPU 或首次采样无前值可算速率。"))
            }
        }
    }

    /// 单指标行：标题 + 当前值；延迟三项另起一行列出 P50/P90/P95/P99
    @ViewBuilder
    private func metricRow(_ metric: VllmMonitorMetric) -> some View {
        let value = vm.current.flatMap { metric.value(in: $0) }
        InfoRow(metric.title, value: metric.text(value), monospaced: true)
        if metric.hasPercentiles, let point = vm.current {
            let percentiles = metric.percentiles(in: point)
            HStack(spacing: 0) {
                ForEach(percentiles.indices, id: \.self) { i in
                    VStack(spacing: 2) {
                        Text(percentiles[i].label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(metric.text(percentiles[i].value))
                            .font(.caption.monospacedDigit())
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 2)
            .listRowSeparator(.hidden, edges: .top)
        }
    }

    // MARK: 历史曲线

    private static let palette: [Color] = [.blue, .purple, .orange, .green, .teal, .pink]

    private var historySection: some View {
        Section {
            ForEach(Array(metrics.enumerated()), id: \.element) { index, metric in
                historyChart(metric, color: Self.palette[index % Self.palette.count])
            }
        } header: {
            SectionLabel(title: L10n.t("历史曲线"), systemImage: "chart.line.uptrend.xyaxis")
        } footer: {
            if vm.hasLoadedHistory, vm.historyPoints.isEmpty {
                Text(L10n.t("暂无监控记录：需实例运行且面板已开启 vLLM 监控采集。"))
            } else if let bucket = vm.history?.bucketSeconds, bucket > 0 {
                Text(L10n.f("采样点较多，已按 %ld 秒分桶聚合。", bucket))
            }
        }
    }

    /// 单指标曲线卡：标题 + 最新值；延迟三项叠加 P50/P90/P99 分位曲线
    @ViewBuilder
    private func historyChart(_ metric: VllmMonitorMetric, color: Color) -> some View {
        let meanKind = metric.hasPercentiles ? L10n.t("平均") : metric.title
        let mean = vm.series(metric, kind: meanKind)
        let quantiles: [LoadSeriesPoint] = metric.hasPercentiles
            ? ["P50", "P90", "P99"].flatMap { label in
                vm.series(kind: label) { metric.percentile(label, in: $0) }
            }
            : []
        let all = mean + quantiles
        let labelFormatter = vm.hours >= 168 ? Self.dayFormatter : Self.hourFormatter

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(metric.title).font(.headline)
                Spacer()
                if let last = mean.last {
                    Text(metric.text(last.value))
                        .font(.body.monospacedDigit().weight(.medium))
                        .foregroundStyle(color)
                }
            }
            if all.isEmpty {
                ChartEmptyPlaceholder(text: L10n.t("暂无数据"), height: 64, compact: true)
            } else if metric.hasPercentiles {
                MonitorHistoryChart(
                    points: all,
                    styles: [meanKind: color, "P50": .green, "P90": .orange, "P99": .red],
                    unit: "",
                    fixedYDomain: nil,
                    fixedDecimals: metric.decimals,
                    fill: false,
                    height: 140,
                    labelFormatter: labelFormatter)
            } else {
                MonitorHistoryChart(
                    points: all,
                    styles: [meanKind: color],
                    unit: metric.unit == "%" ? "%" : "",
                    fixedYDomain: metric.fixedYDomain,
                    fixedDecimals: 0,
                    fill: metric.fixedYDomain != nil,
                    height: 140,
                    labelFormatter: labelFormatter)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: 清空

    private var cleanSection: some View {
        Section {
            Button(role: .destructive) {
                showCleanConfirm = true
            } label: {
                Label(L10n.t("清空监控记录"), systemImage: "trash")
            }
        } footer: {
            Text(L10n.t("仅删除该实例的历史监控数据，不影响实例运行。"))
        }
    }

    // MARK: 格式

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = "MM-dd"
        return f
    }()
}
