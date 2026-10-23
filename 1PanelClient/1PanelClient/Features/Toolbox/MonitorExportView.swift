//
//  MonitorExportView.swift
//  1PanelClient
//
//  监控导出（v2.4.0 新增，logs/2.4.0新增监控导出.md 抓包 2026-10-23）：
//  时间范围 / 导出指标多选（CPU·内存·平均负载·磁盘I/O·网络）/ 磁盘与网卡
//  设备选择（每个设备明细 · 合计 · 单设备，选项来自 iooptions/netoptions）/
//  导出格式（CSV·JSON·Excel）。数据经 POST /hosts/monitor/search 拉取后本地组表，
//  文件生成走 MonitorExportFileBuilder、落盘走 LocalDownloads(.exports)。
//  对齐网页端 host/monitor/export 页（CPU/内存/负载合并一张 base 表；
//  磁盘 I/O 上送 io="" 为逐设备明细、"all" 为合计、设备名为单设备，网卡同理）。
//

import SwiftUI

struct MonitorExportView: View {
    let server: ServerConfig

    /// 「每个设备（逐设备明细）」哨兵值：请求时上送空串（网页端同款约定）
    private static let allDevices = "*"

    @State private var metrics: Set<String> = ["cpu", "memory", "load"]
    @State private var ioChoice = MonitorExportView.allDevices
    @State private var netChoice = MonitorExportView.allDevices
    @State private var format: MonitorExportFormat = .csv
    /// 默认时间范围：今天 00:00 → 现在（对齐网页端）
    @State private var startTime = Calendar.current.startOfDay(for: Date())
    @State private var endTime = Date()

    @State private var ioOptions: [String] = []
    @State private var netOptions: [String] = []
    @State private var isExporting = false

    /// 导出结果：落盘位置与告警（无数据表 / 超行数截断），持续显示在表单尾部
    @State private var savedTo: LocalDownloads.Saved?
    @State private var emptyTables: [String] = []
    @State private var truncatedTables: [String] = []

    @State private var toastMessage: String?
    @State private var errorMessage: String?
    @State private var showError = false

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        Form {
            rangeSection
            metricsSection
            if metrics.contains("io") { diskSection }
            if metrics.contains("network") { interfaceSection }
            formatSection
            submitSection
        }
        .navigationTitle(L10n.t("导出"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadOptions() }
        .toastOverlay(message: $toastMessage)
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: 时间范围

    private var rangeSection: some View {
        Section {
            DatePicker(L10n.t("开始时间"), selection: $startTime, in: ...endTime)
            DatePicker(L10n.t("结束时间"), selection: $endTime, in: startTime...)
        } header: {
            SectionLabel(title: L10n.t("时间范围"), systemImage: "calendar")
        }
    }

    // MARK: 导出指标

    /// 指标多选（key 与服务端 param 对应：cpu/memory/load/io/network）
    private var metricOptions: [(key: String, title: String)] {
        [
            ("cpu", "CPU"),
            ("memory", L10n.t("内存")),
            ("load", L10n.t("平均负载")),
            ("io", L10n.t("磁盘 I/O")),
            ("network", L10n.t("网络")),
        ]
    }

    private var metricsSection: some View {
        Section {
            ForEach(metricOptions, id: \.key) { option in
                Button {
                    if metrics.contains(option.key) {
                        metrics.remove(option.key)
                    } else {
                        metrics.insert(option.key)
                    }
                } label: {
                    HStack {
                        Image(systemName: metrics.contains(option.key)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(metrics.contains(option.key)
                                             ? Color.accentColor : Color.secondary)
                        Text(option.title)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            SectionLabel(title: L10n.t("导出指标"), systemImage: "checklist")
        } footer: {
            Text(L10n.t("CPU、内存与负载指标将合并到同一张表。"))
        }
    }

    // MARK: 磁盘 / 网卡设备选择

    private var diskSection: some View {
        Section {
            OutlinedPicker(label: L10n.t("磁盘"), options: devicePickerOptions(ioOptions),
                           selection: $ioChoice, optionLabels: devicePickerLabels(ioOptions, disk: true))
        } footer: {
            Text(L10n.t("「每个设备」为逐设备明细；「合计」为所有设备求和的汇总行。"))
        }
    }

    private var interfaceSection: some View {
        Section {
            OutlinedPicker(label: L10n.t("网卡"), options: devicePickerOptions(netOptions),
                           selection: $netChoice, optionLabels: devicePickerLabels(netOptions, disk: false))
        } footer: {
            Text(L10n.t("「每个接口」为逐接口明细；「合计」为所有接口求和的汇总行。"))
        }
    }

    /// 下拉选项 = 每个设备/接口 明细哨兵 + 服务端选项列表（含 all 合计）
    private func devicePickerOptions(_ options: [String]) -> [String] {
        [Self.allDevices] + options
    }

    private func devicePickerLabels(_ options: [String], disk: Bool) -> [String: String] {
        var labels: [String: String] = [
            Self.allDevices: disk ? L10n.t("每个设备（逐设备明细）") : L10n.t("每个接口（逐接口明细）"),
        ]
        for option in options where option != Self.allDevices {
            labels[option] = option == "all" ? L10n.t("合计（所有设备求和）") : option
        }
        return labels
    }

    // MARK: 导出格式

    private var formatSection: some View {
        Section {
            OutlinedPicker(label: L10n.t("导出格式"), options: MonitorExportFormat.allCases,
                           selection: $format) { $0.displayName }
        } footer: {
            Text(formatHelper)
        }
    }

    private var formatHelper: String {
        switch format {
        case .json: return L10n.t("导出为单个结构化 JSON 文件。")
        case .xlsx: return L10n.t("每个指标生成一个独立工作表。")
        case .csv:  return L10n.t("选择多个指标时将分别生成 CSV 文件并打包为 ZIP。")
        }
    }

    // MARK: 提交与结果

    private var submitSection: some View {
        Section {
            Button {
                Task { await export() }
            } label: {
                HStack {
                    if isExporting { ProgressView() } else { Text(L10n.t("导出")) }
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(isExporting)
            resultFooter
        }
    }

    /// 导出结果常驻展示：落盘路径 + 无数据/截断告警（避免弹窗连发）
    @ViewBuilder
    private var resultFooter: some View {
        if let savedTo {
            Label(savedTo.successMessage, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        if !emptyTables.isEmpty {
            Label(L10n.f("以下指标在所选时间段内没有数据：%@", emptyTables.joined(separator: "、")),
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        if !truncatedTables.isEmpty {
            Label(L10n.f("以下数据集已超出 Excel 行数上限被截断：%@", truncatedTables.joined(separator: "、")),
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    // MARK: 数据获取与组表

    private func loadOptions() async {
        if ioOptions.isEmpty {
            ioOptions = (try? await client.send(
                path: APIEndpoint.monitorIOOptions.path, method: "GET",
                as: [String].self)) ?? []
        }
        if netOptions.isEmpty {
            netOptions = (try? await client.send(
                path: APIEndpoint.monitorNetOptions.path, method: "GET",
                as: [String].self)) ?? []
        }
    }

    private func export() async {
        guard !metrics.isEmpty else { return fail(L10n.t("请至少选择一个导出指标")) }
        guard endTime > startTime else { return fail(L10n.t("结束时间需晚于开始时间")) }
        isExporting = true
        defer { isExporting = false }

        // 组请求（与网页端一致）：任一 base 指标 → 单个 load 请求；
        // io/network 各一个请求，明细哨兵上送空串、合计上送 all、单设备上送设备名
        let needsBase = metrics.contains(where: ["cpu", "memory", "load"].contains)
        var requests: [(param: String, io: String, network: String)] = []
        if needsBase { requests.append(("load", "all", "all")) }
        if metrics.contains("io") {
            requests.append(("io", ioChoice == Self.allDevices ? "" : ioChoice, "all"))
        }
        if metrics.contains("network") {
            requests.append(("network", "all", netChoice == Self.allDevices ? "" : netChoice))
        }

        var datasets: [MonitorSeries] = []
        // 并发拉取（async let 需要静态数量，用 TaskGroup 覆盖 1–3 个请求）；
        // group 闭包只捕获 Sendable 局部量（视图结构体自身不可捕获）
        let apiClient = client
        let start = MonitorDate.requestString(startTime)
        let end = MonitorDate.requestString(endTime)
        datasets = await withTaskGroup(of: [MonitorSeries].self) { group in
            for request in requests {
                group.addTask {
                    (try? await Self.fetchSeries(client: apiClient, param: request.param,
                                                 io: request.io, network: request.network,
                                                 start: start, end: end)) ?? []
                }
            }
            var all: [MonitorSeries] = []
            for await series in group { all += series }
            return all
        }

        let tables = buildTables(datasets: datasets, needsBase: needsBase)
        if tables.allSatisfy({ $0.rows.isEmpty }) {
            return fail(L10n.t("暂无数据"))
        }
        emptyTables = tables.filter { $0.rows.isEmpty }.map { tableDisplayName($0.name) }
        do {
            let file = MonitorExportFileBuilder.build(tables: tables, format: format)
            truncatedTables = file.truncatedTables.map { tableDisplayName($0) }
            let saved = try LocalDownloads.save(data: file.data,
                                                fileName: file.fileName,
                                                category: .exports)
            savedTo = saved
            Haptic.success()
            toastMessage = saved.successMessage
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func fetchSeries(client: APIClient, param: String, io: String, network: String,
                                    start: String, end: String) async throws -> [MonitorSeries] {
        try await client.send(
            path: APIEndpoint.hostsMonitorSearch.path,
            body: MonitorSearchRequest(param: param, io: io, network: network,
                                       startTime: start, endTime: end),
            as: [MonitorSeries].self)
    }

    // MARK: 组表（对齐网页端 buildBaseTable/buildIOTable/buildNetworkTable）

    /// base 表列随所选指标拼装：时间 + CPU% + 内存% + 负载%（负载另带 1/5/15 分钟原始值）
    private func buildTables(datasets: [MonitorSeries], needsBase: Bool) -> [MonitorExportTable] {
        var tables: [MonitorExportTable] = []
        if needsBase {
            tables.append(baseTable(from: datasets))
        }
        if metrics.contains("io") {
            tables.append(ioTable(from: datasets))
        }
        if metrics.contains("network") {
            tables.append(networkTable(from: datasets))
        }
        return tables
    }

    private func baseTable(from datasets: [MonitorSeries]) -> MonitorExportTable {
        var fields = ["time"]
        var headers = [L10n.t("日期")]
        // 列取值器；负载一条指标展开 4 列（使用率 + 1/5/15 分钟原始值）
        var pickers: [(MonitorRecord) -> MonitorExportCell] = []
        if metrics.contains("cpu") {
            fields.append("cpu")
            headers.append("CPU (%)")
            pickers.append { .numberCell($0.cpu) }
        }
        if metrics.contains("memory") {
            fields.append("memory")
            headers.append(L10n.f("%@ (%%)", L10n.t("内存")))
            pickers.append { .numberCell($0.memory) }
        }
        if metrics.contains("load") {
            fields.append(contentsOf: ["loadUsage", "load1", "load5", "load15"])
            headers.append(contentsOf: [
                L10n.f("%@ (%%)", L10n.t("平均负载")), "Load 1m", "Load 5m", "Load 15m",
            ])
            pickers.append(contentsOf: [
                { .numberCell($0.loadUsage) },
                { .numberCell($0.cpuLoad1) },
                { .numberCell($0.cpuLoad5) },
                { .numberCell($0.cpuLoad15) },
            ])
        }
        let records = datasets.filter { $0.param == "base" }.flatMap { $0.value ?? [] }
        let rows: [[MonitorExportCell]] = records.compactMap { record in
            guard let createdAt = record.createdAt,
                  let date = MonitorDate.parse(createdAt) else { return nil }
            return [.date(date)] + pickers.map { pick in pick(record) }
        }
        return MonitorExportTable(name: "base", fields: fields, headers: headers, rows: rows)
    }

    /// io 表：明细模式剔除 name=="all" 汇总行；按时间升序
    private func ioTable(from datasets: [MonitorSeries]) -> MonitorExportTable {
        let rows: [[MonitorExportCell]] = deviceRows(from: datasets, param: "io", deviceChoice: ioChoice)
            .map { row in
                [.date(row.date), .text(row.name), .numberCell(row.read), .numberCell(row.write),
                 .numberCell(row.count), .numberCell(row.time)]
            }
        return MonitorExportTable(
            name: "io",
            fields: ["time", "device", "read", "write", "count", "ioTime"],
            headers: [
                L10n.t("日期"), L10n.t("磁盘"),
                L10n.f("%@ (B/s)", L10n.t("读取")), L10n.f("%@ (B/s)", L10n.t("写入")),
                L10n.t("读写次数"), L10n.f("%@ (ms)", L10n.t("读写延迟")),
            ],
            rows: rows)
    }

    private func networkTable(from datasets: [MonitorSeries]) -> MonitorExportTable {
        let rows: [[MonitorExportCell]] = deviceRows(from: datasets, param: "network", deviceChoice: netChoice)
            .map { row in [.date(row.date), .text(row.name), .numberCell(row.up), .numberCell(row.down)] }
        return MonitorExportTable(
            name: "network",
            fields: ["time", "interface", "up", "down"],
            headers: [
                L10n.t("日期"), L10n.t("网卡"),
                L10n.f("%@ (KB/s)", L10n.t("上行")), L10n.f("%@ (KB/s)", L10n.t("下行")),
            ],
            rows: rows)
    }

    /// io/network 记录统一整理：明细模式剔除汇总行、解析时间、按时间升序
    private func deviceRows(from datasets: [MonitorSeries], param: String,
                            deviceChoice: String) -> [(date: Date, name: String, read: Double?,
                                                       write: Double?, count: Double?,
                                                       time: Double?, up: Double?, down: Double?)] {
        let records = datasets.filter { $0.param == param }.flatMap { $0.value ?? [] }
        return records.compactMap { record in
            guard deviceChoice != Self.allDevices || record.name != "all" else { return nil }
            guard let createdAt = record.createdAt, let date = MonitorDate.parse(createdAt) else {
                return nil
            }
            return (date, record.name ?? "", record.read, record.write, record.count,
                    record.time, record.up, record.down)
        }
        .sorted { $0.date < $1.date }
    }

    /// 告警里显示的表名：base 按所选指标展开（CPU / 内存 / 平均负载），其余用指标名
    private func tableDisplayName(_ name: String) -> String {
        switch name {
        case "base":
            return ["cpu", "memory", "load"]
                .filter { metrics.contains($0) }
                .map { key in metricOptions.first { $0.key == key }?.title ?? key }
                .joined(separator: " / ")
        case "io": return L10n.t("磁盘 I/O")
        case "network": return L10n.t("网络")
        default: return name
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        showError = true
    }
}

// MARK: - 单元格取值辅助

private extension MonitorExportCell {
    /// 可空数值列（服务端缺字段 → JSON null / CSV 空串）
    static func numberCell(_ value: Double?) -> MonitorExportCell {
        value.map { .number($0) } ?? .empty
    }
}
