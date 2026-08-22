//
//  WAFMonitorViews.swift
//  1PanelClient
//
//  WAF 监控：概览 / 拦截记录 / 封锁记录
//

import SwiftUI
import Charts

// MARK: - 概览

/// WAF 监控入口页（管理-高级功能）：概览 / 拦截记录 / 封锁记录
struct WAFMonitorView: View {
    let server: ServerConfig

    var body: some View {
        List {
            Section {
                NavigationLink {
                    WAFOverviewView(server: server)
                } label: {
                    entryRow(icon: "chart.bar.xaxis", color: .blue, title: L10n.t("概览"))
                }
                NavigationLink {
                    WAFInterceptLogsView(server: server)
                } label: {
                    entryRow(icon: "exclamationmark.triangle.fill", color: .orange, title: L10n.t("拦截记录"))
                }
                NavigationLink {
                    WAFBlockRecordsView(server: server)
                } label: {
                    entryRow(icon: "lock.shield", color: .red, title: L10n.t("封锁记录"))
                }
            }
        }
        .navigationTitle(L10n.t("WAF 监控"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func entryRow(icon: String, color: Color, title: String) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemName: icon, color: color, size: 34, cornerRadius: 8)
            Text(title)
        }
    }
}

struct WAFOverviewView: View {
    let server: ServerConfig

    @State private var today: WAFStatToday?
    @State private var days: [WAFStatDayItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient(server: server)
    }

    var body: some View {
        Group {
            if isLoading && today == nil && days.isEmpty {
                LoadingStateView()
            } else if let errorMessage, today == nil && days.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button(L10n.t("重试")) { Task { await load() } }
                }
            } else {
                content
            }
        }
        .navigationTitle(L10n.t("概览"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 今日状态
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(title: L10n.t("今日状态"), systemImage: "calendar")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        StatCard(title: L10n.t("请求"), count: today?.reqCount, icon: "arrow.down.circle", color: .blue)
                        StatCard(title: L10n.t("拦截"), count: today?.attackCount, icon: "shield.slash", color: .red)
                        StatCard(title: L10n.t("4xx 数量"), count: today?.count4xx, icon: "exclamationmark.circle", color: .orange)
                        StatCard(title: L10n.t("5xx 数量"), count: today?.count5xx, icon: "xmark.octagon", color: .purple)
                    }
                }

                // 请求趋势(7日)
                trendSection(title: L10n.t("请求趋势（7日）"), values: days.map { ($0.shortDay, $0.reqCount ?? 0) }, color: .blue)

                // 拦截趋势(7日)
                trendSection(title: L10n.t("拦截趋势（7日）"), values: days.map { ($0.shortDay, $0.attackCount ?? 0) }, color: .red)
            }
            .padding()
        }
    }

    private func trendSection(title: String, values: [(day: String, value: Int)], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: title, systemImage: "chart.bar")
            WAFDayBarChart(values: values, color: color)
                .frame(height: 160)
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    /// 单项请求独立容错：今日统计或 7 日趋势一项失败不拖垮另一项
    private func fetch<T: Decodable>(_ path: String, as type: T.Type) async -> Result<T, Error> {
        do {
            return .success(try await client.send(path: path, method: "GET", as: type))
        } catch {
            return .failure(error)
        }
    }

    private func load() async {
        isLoading = true
        async let t = fetch(APIEndpoint.wafStat.path, as: WAFStatToday.self)
        async let d = fetch(APIEndpoint.wafStatDays.path, as: [WAFStatDayItem].self)
        let (tr, dr) = await (t, d)
        isLoading = false
        var firstError: String?
        switch tr {
        case .success(let x): today = x
        case .failure(let e): firstError = e.localizedDescription
        }
        switch dr {
        case .success(let x): days = x
        case .failure(let e): firstError = firstError ?? e.localizedDescription
        }
        errorMessage = firstError
    }
}

// MARK: - 7日柱状图

struct WAFDayBarChart: View {
    let values: [(day: String, value: Int)]
    let color: Color

    @State private var selectedIndex: Int?
    @State private var bubbleSize: CGSize = .zero

    /// 与监控折线图共用的 Y 轴数学：峰值向上对齐整洁刻度
    ///（如 5493 → 值域上扩，6000 一档必在刻度列），全 0 时退 0...1
    private var axis: MonitorYAxis {
        let peak = Double(values.map(\.value).max() ?? 0)
        return MonitorYAxis.dynamic(peak: peak, low: 0, allZero: peak <= 0)
    }

    var body: some View {
        Chart(values, id: \.day) { item in
            BarMark(
                x: .value("日期", item.day),
                y: .value("数量", item.value)
            )
            .foregroundStyle(color.gradient)
            .cornerRadius(3)
        }
        .chartYScale(domain: axis.domain)
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .font(.caption2)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: axis.ticks) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(String(format: "%.\(axis.decimals)f", v))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotFrame.map { geo[$0] } ?? .zero

                Rectangle().fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                guard plot.width > 0, !values.isEmpty else { return }
                                let x = g.location.x - plot.minX
                                guard x >= 0, x <= plot.width else { return }
                                let idx = min(Int(x / plot.width * CGFloat(values.count)), values.count - 1)
                                selectedIndex = idx
                            }
                            // 手指移开即取消选中
                            .onEnded { _ in selectedIndex = nil }
                    )

                // 数值气泡：悬于选中柱正上方，贴边收回、上方放不下时转柱侧
                if let idx = selectedIndex, plot.width > 0 {
                    let item = values[idx]
                    let barWidth = plot.width / CGFloat(values.count)
                    let xCenter = plot.minX + barWidth * (CGFloat(idx) + 0.5)
                    let span = max(axis.domain.upperBound - axis.domain.lowerBound, .ulpOfOne)
                    let yTop = plot.minY
                        + plot.height * CGFloat((axis.domain.upperBound - Double(item.value)) / span)
                    let pos = MonitorBubbleLayout.position(
                        nearCap: false,
                        xCenter: xCenter, yTop: yTop,
                        halfW: bubbleSize.width / 2, halfH: bubbleSize.height / 2,
                        geoWidth: geo.size.width, geoHeight: geo.size.height
                    )
                    bubble(item)
                        .background(bubbleTracker)
                        .position(x: pos.x, y: pos.y)
                }
            }
        }
    }

    private func bubble(_ item: (day: String, value: Int)) -> some View {
        Text("\(item.value)")
            .font(.caption.bold())
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
    }

    private var bubbleTracker: some View {
        GeometryReader { g in
            Color.clear
                .onAppear { bubbleSize = g.size }
                .onChange(of: g.size) { _, new in bubbleSize = new }
        }
    }
}

// MARK: - 拦截记录

struct WAFInterceptLogsView: View {
    let server: ServerConfig

    @State private var items: [WAFLogItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient(server: server)
    }

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                LoadingStateView()
            } else if let errorMessage, items.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button(L10n.t("重试")) { Task { await load() } }
                }
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("暂无数据"), systemImage: "tray")
                }
            } else {
                List(items) { item in
                    NavigationLink {
                        WAFInterceptLogDetailView(client: client, logID: item.logID ?? 0)
                    } label: {
                        logRow(item)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(L10n.t("拦截记录"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func logRow(_ item: WAFLogItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.ip ?? "-")
                    .font(.callout.bold())
                    .monospaced()
                Spacer()
                if let loc = item.ipLocation, !loc.isEmpty {
                    Text(loc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                if let uri = item.uri, !uri.isEmpty {
                    Text(uri)
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(WAFTime.short(item.localtime) ?? "-")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let req = WAFLogSearchRequest(
            page: 1, pageSize: 100,
            ip: "", ipLocation: "", host: "", url: "", websiteKey: "",
            execRules: [], action: "all"
        )
        do {
            let resp: PageResponse<WAFLogItem> = try await client.send(
                path: APIEndpoint.wafLogSearch.path, body: req,
                as: PageResponse<WAFLogItem>.self
            )
            items = resp.items ?? []
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 拦截记录详情

struct WAFInterceptLogDetailView: View {
    let client: APIClient
    let logID: Int

    @State private var detail: WAFLogItem?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading && detail == nil {
                LoadingStateView()
            } else if let errorMessage, detail == nil {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button(L10n.t("重试")) { Task { await load() } }
                }
            } else if let d = detail {
                Form {
                    Section {
                        InfoRow(L10n.t("攻击IP"), value: d.ip ?? "-")
                        InfoRow(L10n.t("日期"), value: WAFTime.short(d.localtime) ?? d.localtime ?? "-")
                        InfoRow(L10n.t("操作"), value: actionLabel(d.action))
                        InfoRow(L10n.t("命中规则"), value: nonEmpty(d.execRule))
                    }

                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("HTTP")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let log = d.nginxLog, !log.isEmpty {
                                Text(log)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text("-")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle(L10n.t("拦截记录"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func nonEmpty(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "-" }
        return s
    }

    private func actionLabel(_ action: String?) -> String {
        switch action {
        case "deny": return L10n.t("拒绝")
        case "allow", "white": return L10n.t("放行")
        default: return action ?? "-"
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let path = APIEndpoint.wafLogDetail.path.replacingOccurrences(of: ":id", with: String(logID))
        do {
            detail = try await client.send(path: path, method: "GET", as: WAFLogItem.self)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 封锁记录

struct WAFBlockRecordsView: View {
    let server: ServerConfig

    @State private var items: [WAFBlockItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient(server: server)
    }

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                LoadingStateView()
            } else if let errorMessage, items.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button(L10n.t("重试")) { Task { await load() } }
                }
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("暂无数据"), systemImage: "tray")
                }
            } else {
                List(items) { item in
                    blockRow(item)
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(L10n.t("封锁记录"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func blockRow(_ item: WAFBlockItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.ip ?? "-")
                    .font(.callout.bold())
                    .monospaced()
                Spacer()
                if let loc = item.ipLocation, !loc.isEmpty {
                    Text(loc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                if let count = item.count {
                    Text("\(L10n.t("封锁次数")): \(count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let until = WAFTime.short(item.untilTime) {
                    Text("\(L10n.t("封锁至")): \(until)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let req = WAFBlockSearchRequest(page: 1, pageSize: 100, total: 0, ip: "")
        do {
            let resp: PageResponse<WAFBlockItem> = try await client.send(
                path: APIEndpoint.wafBlockSearch.path, body: req,
                as: PageResponse<WAFBlockItem>.self
            )
            items = resp.items ?? []
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
