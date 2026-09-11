//
//  GPUMonitorView.swift
//  1PanelClient
//
//  GPU 监控（/api/v2/ai/gpu/*）：实时快照（设备卡：利用率/显存/温度/功耗 + 进程）
//  与历史曲线（利用率/显存/温度/功耗，MonitorHistoryChart 复用）；
//  快照 5 秒轮询，历史服务端 5 分钟落一条、60 秒重拉即可
//

import SwiftUI
import Combine
import Charts

// MARK: - ViewModel

@MainActor
final class GPUMonitorViewModel: ObservableObject {
    /// 历史时间范围（小时）：1 / 6 / 24 / 168
    @Published var hours = 1
    /// 历史曲线对应的设备（多卡时切换）
    @Published var selectedProduct = ""

    @Published var info: GPULoadInfo?
    @Published var history: GPUMonitorData?
    @Published private(set) var isLoading = true
    @Published private(set) var hasLoadedHistory = false
    @Published var errorMessage: String?

    var devices: [GPUDeviceInfo] { info?.allDevices ?? [] }

    private let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient.shared(for: server)
    }

    func loadAll() async {
        await loadInfo()
        await loadHistory()
    }

    /// 实时快照（GET /ai/gpu/load）
    func loadInfo() async {
        do {
            info = try await client.send(
                path: APIEndpoint.aiGpuLoad.path,
                method: APIEndpoint.aiGpuLoad.method,
                as: GPULoadInfo.self)
            errorMessage = nil
            if selectedProduct.isEmpty {
                selectedProduct = devices.first?.productName ?? ""
            }
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// 历史序列（POST /ai/gpu/search，按设备名 + 时间窗）
    func loadHistory() async {
        let end = Date()
        let start = Calendar.current.date(byAdding: .hour, value: -hours, to: end) ?? end
        do {
            history = try await client.send(
                path: APIEndpoint.aiGpuMonitorSearch.path,
                body: GPUMonitorSearchRequest(
                    productName: selectedProduct,
                    startTime: MonitorDate.requestString(start),
                    endTime: MonitorDate.requestString(end)),
                as: GPUMonitorData.self)
        } catch {
            guard !APIError.isCancellation(error) else { return }
            // 未开启监控记录 / 该设备无数据：静默为空图，不整页报错
            history = nil
        }
        hasLoadedHistory = true
    }
}

// MARK: - 页面

struct GPUMonitorView: View {
    @StateObject private var vm: GPUMonitorViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isSceneActive = true

    init(server: ServerConfig) {
        _vm = StateObject(wrappedValue: GPUMonitorViewModel(server: server))
    }

    var body: some View {
        Group {
            if vm.isLoading {
                LoadingStateView()
            } else if vm.devices.isEmpty {
                gpuUnavailable
            } else {
                content
            }
        }
        .navigationTitle(L10n.t("GPU 监控"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.loadAll() }
        .onChange(of: scenePhase) { _, phase in
            isSceneActive = phase == .active
        }
        .onChange(of: vm.hours) { _, _ in
            Task { await vm.loadHistory() }
        }
        .onChange(of: vm.selectedProduct) { _, _ in
            Task { await vm.loadHistory() }
        }
        .task {
            await vm.loadAll()
            // 快照 5 秒一轮；历史 60 秒一轮
            var elapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, isSceneActive else { continue }
                await vm.loadInfo()
                elapsed += 5
                if elapsed >= 60 {
                    elapsed = 0
                    await vm.loadHistory()
                }
            }
        }
    }

    /// 无 GPU / 无驱动：load 接口报错或设备列表为空
    private var gpuUnavailable: some View {
        ContentUnavailableView {
            Label(L10n.t("未检测到 GPU"), systemImage: "memorychip")
        } description: {
            Text(vm.errorMessage ?? L10n.t("需要 NVIDIA 驱动或受支持的加速器（NPU/XPU）"))
        } actions: {
            Button(L10n.t("重试")) { Task { await vm.loadAll() } }
        }
    }

    private var content: some View {
        List {
            rangeSection
            driverSection
            ForEach(vm.devices) { device in
                deviceSection(device)
            }
            processSection
            historySection
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 36)
    }

    // MARK: 时间范围 / 设备选择

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

            // 多卡时选择历史曲线对应的设备
            if vm.devices.count > 1 {
                Picker(L10n.t("显卡"), selection: $vm.selectedProduct) {
                    ForEach(vm.devices) { device in
                        Text(device.displayName).tag(device.productName ?? "")
                    }
                }
            }
        }
    }

    // MARK: 驱动信息

    private var driverSection: some View {
        Section {
            InfoRow(L10n.t("加速器类型"), value: vm.info?.type ?? "-")
            if let cuda = vm.info?.cudaVersion, !cuda.isEmpty {
                InfoRow("CUDA", value: cuda, monospaced: true)
            }
            if let driver = vm.info?.driverVersion, !driver.isEmpty {
                InfoRow(L10n.t("驱动版本"), value: driver, monospaced: true)
            }
        } header: {
            SectionLabel(title: L10n.t("运行环境"), systemImage: "gearshape.2")
        }
    }

    // MARK: 设备卡

    private func deviceSection(_ device: GPUDeviceInfo) -> some View {
        Section {
            // 利用率
            statRow(
                title: L10n.t("利用率"),
                percent: device.utilPercent,
                text: device.gpuUtil ?? "-",
                tint: .blue)

            // 显存
            statRow(
                title: L10n.t("显存"),
                percent: device.memPercent,
                text: memText(device),
                tint: .purple)

            HStack {
                InfoRow(L10n.t("温度"), value: tempText(device))
                InfoRow(L10n.t("功耗"), value: powerText(device))
            }
            HStack {
                if let fan = device.fanSpeed, !fan.isEmpty {
                    InfoRow(L10n.t("风扇"), value: fan)
                }
                if let state = device.performanceState, !state.isEmpty {
                    InfoRow(L10n.t("性能状态"), value: state, monospaced: true)
                }
            }
        } header: {
            SectionLabel(title: device.displayName, systemImage: "memorychip")
        }
    }

    /// 标题 + 数值 + 进度条的统计行
    private func statRow(title: String, percent: Double?, text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(text)
                    .font(.body.monospacedDigit().weight(.medium))
            }
            if let percent {
                ProgressView(value: percent / 100)
                    .tint(tint)
            }
        }
        .padding(.vertical, 4)
    }

    private func memText(_ d: GPUDeviceInfo) -> String {
        switch (d.memUsed, d.memTotal) {
        case let (u?, t?) where !u.isEmpty && !t.isEmpty:
            return "\(u) / \(t)"
        case let (u?, _) where !u.isEmpty:
            return u
        case (_, let t?) where !t.isEmpty:
            return "/ \(t)"
        default:
            return "-"
        }
    }

    private func tempText(_ d: GPUDeviceInfo) -> String {
        d.temperature.flatMap { !$0.isEmpty ? $0 : nil } ?? "-"
    }

    private func powerText(_ d: GPUDeviceInfo) -> String {
        let draw = d.powerDraw.flatMap { !$0.isEmpty ? $0 : nil }
        let max = d.maxPowerW.map { "\(Int($0)) W" }
        switch (draw, max) {
        case let (d?, m?): return "\(d) / \(m)"
        case let (d?, nil): return d
        case let (nil, m?): return "/ \(m)"
        default: return "-"
        }
    }

    // MARK: 进程

    private var processSection: some View {
        Section {
            let all = vm.devices.flatMap { device in
                (device.processes ?? []).map { (device: device, process: $0) }
            }
            if all.isEmpty {
                Text(L10n.t("暂无进程占用"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(all, id: \.process.id) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.process.processName ?? "-")
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                            if vm.devices.count > 1 {
                                Text(item.device.displayName)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("PID \(item.process.pid ?? 0)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if let mem = item.process.usedMemory, !mem.isEmpty {
                                Text(mem)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            SectionLabel(title: L10n.t("GPU 进程"), systemImage: "cpu")
        }
    }

    // MARK: 历史曲线

    @ViewBuilder
    private var historySection: some View {
        Section {
            historyChart(
                title: L10n.t("利用率"),
                points: series(vm.history?.gpuValue, kind: L10n.t("利用率")),
                color: .blue,
                unit: "%",
                fixed: 0...100,
                fill: true)

            historyChart(
                title: L10n.t("显存使用率"),
                points: series(vm.history?.memoryPercent, kind: L10n.t("显存使用率")),
                color: .purple,
                unit: "%",
                fixed: 0...100,
                fill: true)

            historyChart(
                title: L10n.t("温度"),
                points: series(vm.history?.temperatureValue, kind: L10n.t("温度")),
                color: .orange,
                unit: "°C",
                fixed: nil,
                fill: false)

            historyChart(
                title: L10n.t("功耗"),
                points: series(vm.history?.powerUsed, kind: L10n.t("功耗")),
                color: .green,
                unit: "W",
                fixed: nil,
                fill: false)
        } header: {
            SectionLabel(title: L10n.t("历史曲线"), systemImage: "chart.line.uptrend.xyaxis")
        } footer: {
            if vm.hasLoadedHistory, vm.history?.date?.isEmpty != false {
                Text(L10n.t("暂无监控记录，可在面板监控设置中开启 GPU 记录"))
            }
        }
    }

    @ViewBuilder
    private func historyChart(
        title: String,
        points: [LoadSeriesPoint],
        color: Color,
        unit: String,
        fixed: ClosedRange<Double>?,
        fill: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let last = points.last {
                    Text(String(format: "%.1f %@", last.value, unit))
                        .font(.body.monospacedDigit().weight(.medium))
                        .foregroundStyle(color)
                }
            }
            if points.isEmpty {
                chartPlaceholder
            } else {
                MonitorHistoryChart(
                    points: points,
                    styles: [title: color],
                    unit: unit,
                    fixedYDomain: fixed,
                    fixedDecimals: 0,
                    fill: fill,
                    height: 140,
                    labelFormatter: vm.hours >= 168 ? Self.dayFormatter : Self.hourFormatter
                )
            }
        }
        .padding(.vertical, 6)
    }

    private var chartPlaceholder: some View {
        HStack {
            Spacer()
            Text(L10n.t("暂无数据"))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(height: 64)
    }

    // MARK: 数据换算

    /// 历史数组 → 图表点（date 与数值按索引对齐，长窗口降采样）
    private func series(_ values: [Double]?, kind: String) -> [LoadSeriesPoint] {
        guard let dates = vm.history?.date, let values else { return [] }
        let n = min(dates.count, values.count)
        let raw = (0..<n).compactMap { i -> LoadSeriesPoint? in
            guard let date = MonitorDate.parse(dates[i]) else { return nil }
            return LoadSeriesPoint(date: date, value: values[i], kind: kind)
        }
        return Self.decimate(raw)
    }

    /// 降采样：最多约 480 点，末尾点保留（长窗口曲线平滑不卡顿）
    private static func decimate(_ points: [LoadSeriesPoint], cap: Int = 480) -> [LoadSeriesPoint] {
        guard points.count > cap else { return points }
        let step = Int((Double(points.count) / Double(cap)).rounded(.up))
        var result = stride(from: 0, to: points.count, by: step).map { points[$0] }
        if let last = points.last, result.last?.date != last.date {
            result.append(last)
        }
        return result
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
}
