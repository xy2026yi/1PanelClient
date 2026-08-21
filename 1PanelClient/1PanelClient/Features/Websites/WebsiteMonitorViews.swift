//
//  WebsiteMonitorViews.swift
//  1PanelClient
//
//  网站监控：概览（QPS/今日状态/访客趋势/访客地图）、访问统计、请求日志
//

import SwiftUI
import Charts

// MARK: - 网站监控主页（网站选择 + 三个板块）

struct WebsiteMonitorView: View {
    let server: ServerConfig
    let website: Website?

    private let client: APIClient

    private enum Tab: String, CaseIterable, Identifiable {
        case overview, stats, logs
        var id: String { rawValue }
        var label: String {
            switch self {
            case .overview: return L10n.t("概览")
            case .stats: return L10n.t("访问统计")
            case .logs: return L10n.t("请求日志")
            }
        }
    }

    @State private var websites: [Website] = []
    @State private var selectedID: Int
    @State private var tab: Tab = .overview
    @State private var isLoadingWebsites = true

    init(server: ServerConfig, website: Website? = nil) {
        self.server = server
        self.website = website
        self.client = APIClient(server: server)
        _selectedID = State(initialValue: website?.id ?? 0)
    }

    var body: some View {
        List {
            Section {
                if isLoadingWebsites && websites.isEmpty {
                    HStack { ProgressView(); Text(L10n.t("加载中…")) }
                } else {
                    Picker(L10n.t("网站"), selection: $selectedID) {
                        ForEach(websites) { site in
                            Text(site.displayName).tag(site.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            Section {
                Picker(L10n.t("板块"), selection: $tab) {
                    ForEach(Tab.allCases) { t in
                        Text(t.label).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .segmentedPickerRow()
            }

            if selectedID != 0 {
                switch tab {
                case .overview:
                    WebsiteMonitorOverviewSection(client: client, websiteID: selectedID)
                        .id("overview-\(selectedID)")
                case .stats:
                    WebsiteMonitorStatsSection(client: client, websiteID: selectedID)
                        .id("stats-\(selectedID)")
                case .logs:
                    WebsiteMonitorLogsSection(client: client, websiteID: selectedID)
                        .id("logs-\(selectedID)")
                }
            } else if !isLoadingWebsites {
                Section {
                    ContentUnavailableView {
                        Label(L10n.t("暂无数据"), systemImage: "tray")
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(L10n.t("网站监控"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadWebsites() }
    }

    private func loadWebsites() async {
        do {
            let req = WebsiteSearchRequest(
                name: "", page: 1, pageSize: 200,
                orderBy: "favorite", order: "descending",
                websiteGroupId: 0, type: ""
            )
            let resp: WebsiteListResponse = try await client.send(
                path: APIEndpoint.websitesSearch.path, body: req,
                as: WebsiteListResponse.self
            )
            var list = resp.items ?? []
            // 兜底：入口网站不在列表里时置顶补入，避免选择器空选中
            if let website, !list.contains(where: { $0.id == website.id }) {
                list.insert(website, at: 0)
            }
            websites = list
        } catch {
            websites = website.map { [$0] } ?? []
        }
        // 无入口网站（如 OpenResty 卡片进入）时默认选第一个
        if selectedID == 0, let first = websites.first {
            selectedID = first.id
        }
        isLoadingWebsites = false
    }
}

// MARK: - 监控统计卡片（无图标、标题居左、紧凑高度）

struct MonitorStatCard: View {
    let title: String
    var count: Int? = nil
    var text: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if count == nil && text == nil {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(text ?? count.map { "\($0)" } ?? "—")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - 概览

struct WebsiteMonitorOverviewSection: View {
    let client: APIClient
    let websiteID: Int

    @State private var range: WebsiteMonitorRange = .today
    @State private var qpsInfo: MonitorQpsInfo?
    @State private var stat: WebsiteMonitorStat?
    @State private var visitors: [VisitorTrendPoint] = []
    @State private var locs: [VisitorLocItem] = []
    @State private var locError: String?
    @State private var worldMap: [String: String] = [:]
    @State private var errorMessage: String?
    @State private var isLoading = true
    /// 加载令牌：range 快速切换时，旧请求慢返回不覆盖新一次的结果
    @State private var loadToken = 0

    var body: some View {
        Group {
            if isLoading && qpsInfo == nil && stat == nil {
                Section { HStack { ProgressView(); Text(L10n.t("加载中…")) } }
            } else if let errorMessage, stat == nil && qpsInfo == nil {
                Section {
                    ContentUnavailableView {
                        Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button(L10n.t("重试")) { Task { await load() } }
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                content
            }
        }
        .task { await load() }
        .onChange(of: range) { _, _ in Task { await load() } }
        .refreshable { await load() }
    }

    @ViewBuilder
    private var content: some View {
        // 当前(1分钟)
        Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                MonitorStatCard(title: L10n.t("请求数"), count: qpsInfo?.qps)
                MonitorStatCard(title: L10n.t("流量"), text: qpsInfo?.flow.map(formatBytes))
            }
        } header: {
            SectionLabel(title: L10n.t("当前(1分钟)"), systemImage: "clock")
        }

        // 今日状态
        Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                MonitorStatCard(title: L10n.t("浏览数"), count: stat?.pv)
                MonitorStatCard(title: L10n.t("访客"), count: stat?.uv)
                MonitorStatCard(title: L10n.t("独立IP"), count: stat?.ip)
                MonitorStatCard(title: L10n.t("流量"), text: stat?.flow.map(formatBytes))
                MonitorStatCard(title: L10n.t("蜘蛛"), count: stat?.spider)
                MonitorStatCard(title: L10n.t("请求数"), count: stat?.req)
                MonitorStatCard(title: L10n.t("4xx 数量"), count: stat?.count4xx)
                MonitorStatCard(title: L10n.t("5xx 数量"), count: stat?.count5xx)
            }
        } header: {
            SectionLabel(title: L10n.t("今日状态"), systemImage: "calendar")
        }

        // 访客趋势
        Section {
            Picker(L10n.t("时间范围"), selection: $range) {
                ForEach(WebsiteMonitorRange.allCases) { r in
                    Text(r.label).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .segmentedPickerRow()

            if visitors.isEmpty {
                Text(L10n.t("暂无数据"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                WebsiteVisitorsChart(points: visitors)
                    .frame(height: 180)
            }
        } header: {
            SectionLabel(title: L10n.t("访客趋势"), systemImage: "chart.xyaxis.line")
        }

        // 访客地图(30日)：仅显示有值地区
        Section {
            let active = locs
                .filter { ($0.value ?? 0) > 0 }
                .sorted { ($0.value ?? 0) > ($1.value ?? 0) }
            if let locError {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("加载失败"))
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text(locError)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Button(L10n.t("重试")) { Task { await load() } }
                        .font(.caption)
                }
            } else if active.isEmpty {
                Text(L10n.t("暂无数据"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(active) { item in
                    HStack {
                        Text(displayName(item))
                        Spacer()
                        Text("\(Int(item.value ?? 0))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            SectionLabel(title: L10n.t("访客地图（30日）"), systemImage: "map")
        }
    }

    private func formatBytes(_ bytes: Int64?) -> String {
        guard let bytes, bytes >= 0 else { return "-" }
        var size = Double(bytes)
        let units = ["B", "KB", "MB", "GB", "TB"]
        var idx = 0
        while size >= 1024 && idx < units.count - 1 {
            size /= 1024
            idx += 1
        }
        return String(format: "%.1f %@", size, units[idx])
    }

    /// 单项请求独立容错：访客地图等单项失败不拖垮其他板块
    private func fetch<T: Decodable>(_ path: String, body: (any Encodable)?, as type: T.Type) async -> Result<T, Error> {
        do {
            return .success(try await client.send(path: path, body: body, as: type))
        } catch {
            return .failure(error)
        }
    }

    /// 访客地图数据可能带非法 UTF-8 的地区名（GeoIP 库脏数据），
    /// Swift 严格 JSON 解码会整体失败；先严格解码，失败退 JSONSerialization
    /// 容错解析（无效字节以替换字符呈现），与网页端行为一致
    private func fetchLocs() async -> Result<[VisitorLocItem], Error> {
        let body = MonitorLocRequest(websiteID: websiteID, resource: "world")
        // 面板按 Accept-Language 精确匹配语言资源:仅认识 "zh"/"en" 等,
        // URLSession 自动带的 "zh-Hans-CN" 或复合格式会导致地区名与计数全空
        let langHeader = ["Accept-Language": L10n.shared.isEnglishEffective ? "en" : "zh"]
        do {
            let data = try await client.sendRaw(
                path: APIEndpoint.monitorVisitorsLoc.path,
                body: body,
                extraHeaders: langHeader
            )
            if let wrapped = try? JSONDecoder().decode(APIResponse<[VisitorLocItem]>.self, from: data) {
                if wrapped.isSuccess {
                    return .success(wrapped.data ?? [])
                }
                return .failure(APIError.businessError(wrapped.code, wrapped.message ?? ""))
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (obj["code"] as? Int) == 200,
               let arr = obj["data"] as? [[String: Any]] {
                let items = arr.compactMap { d -> VisitorLocItem? in
                    VisitorLocItem(
                        value: Self.locValue(d["value"]),
                        name: d["name"] as? String
                    )
                }
                return .success(items)
            }
            return .failure(APIError.decodingError("visitors/loc"))
        } catch {
            return .failure(error)
        }
    }

    /// value 可能是数字或数字字符串，统一取 Double
    private static func locValue(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// 中文界面时拉取面板的「英文名→中文」映射表(与网页地图同源),
    /// 用于把地区名翻译成中文;英文界面直接用原始英文名
    private func fetchWorldMap() async -> [String: String] {
        guard !L10n.shared.isEnglishEffective else { return [:] }
        do {
            let data = try await client.sendRaw(
                path: APIEndpoint.wafLocationsWorld.path,
                method: "GET",
                extraHeaders: ["Accept-Language": "zh"]
            )
            if let wrapped = try? JSONDecoder().decode(APIResponse<[String: String]>.self, from: data),
               wrapped.isSuccess, let map = wrapped.data {
                return map
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let map = obj["data"] as? [String: String] {
                return map
            }
        } catch {}
        return [:]
    }

    /// 地区显示名:中文界面查映射表翻译,查不到(或已是中文)原样显示
    private func displayName(_ item: VisitorLocItem) -> String {
        guard let raw = item.name, !raw.isEmpty else { return "-" }
        return worldMap[raw, default: raw]
    }

    private func load() async {
        loadToken += 1
        let token = loadToken
        isLoading = true
        async let q = fetch(APIEndpoint.monitorQps.path,
                            body: MonitorQpsRequest(websiteID: websiteID), as: MonitorQpsInfo.self)
        async let s = fetch(APIEndpoint.monitorStat.path,
                            body: MonitorStatRequest(websiteID: websiteID, dayRange: "today"), as: WebsiteMonitorStat.self)
        async let v = fetch(APIEndpoint.monitorVisitors.path,
                            body: MonitorVisitorsRequest(websiteID: websiteID, dayRange: range.rawValue), as: [VisitorTrendPoint].self)
        async let l = fetchLocs()
        async let w = fetchWorldMap()
        let (qr, sr, vr, lr) = await (q, s, v, l)
        let world = await w
        guard token == loadToken else { return }
        isLoading = false
        worldMap = world
        var firstError: String?
        switch qr {
        case .success(let x): qpsInfo = x
        case .failure(let e): firstError = e.localizedDescription
        }
        switch sr {
        case .success(let x): stat = x
        case .failure(let e): firstError = firstError ?? e.localizedDescription
        }
        switch vr {
        case .success(let x): visitors = x
        case .failure(let e): firstError = firstError ?? e.localizedDescription
        }
        switch lr {
        case .success(let x):
            locs = x
            locError = nil
        case .failure(let e):
            locs = []
            locError = e.localizedDescription
        }
        errorMessage = firstError
    }
}

// MARK: - 访客趋势折线图（浏览数/访客双系列，可按压查看数值）

struct WebsiteVisitorsChart: View {
    let points: [VisitorTrendPoint]

    @State private var selectedIndex: Int?
    @State private var bubbleSize: CGSize = .zero

    private static let pvColor: Color = .blue
    private static let uvColor: Color = .green

    private var axis: MonitorYAxis {
        let peak = Double(points.map { max($0.pv ?? 0, $0.uv ?? 0) }.max() ?? 0)
        return MonitorYAxis.dynamic(peak: peak, low: 0, allZero: peak <= 0)
    }

    /// X 轴刻度采样位：今日 24 点取 0/4/8/12/16/20/23，
    /// 近30日 30 点取 0/5/10/15/20/25/29，其余（近7天等）全部显示
    private var tickIndices: [Int] {
        let n = points.count
        guard n > 0 else { return [] }
        switch n {
        case 24: return [0, 4, 8, 12, 16, 20, 23]
        case 30: return [0, 5, 10, 15, 20, 25, 29]
        default:
            guard n > 8 else { return Array(0..<n) }
            var idxs = Array(stride(from: 0, to: n, by: max(1, n / 7)))
            if idxs.last != n - 1 { idxs.append(n - 1) }
            return idxs
        }
    }

    var body: some View {
        Chart(Array(points.enumerated()), id: \.offset) { pair in
            LineMark(x: .value(L10n.t("时间"), Double(pair.offset)), y: .value(L10n.t("浏览数"), pair.element.pv ?? 0))
                .foregroundStyle(by: .value(L10n.t("系列"), L10n.t("浏览数")))
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            LineMark(x: .value(L10n.t("时间"), Double(pair.offset)), y: .value(L10n.t("浏览数"), pair.element.uv ?? 0))
                .foregroundStyle(by: .value(L10n.t("系列"), L10n.t("访客")))
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 1.5))

            if let sel = selectedIndex {
                RuleMark(x: .value(L10n.t("选中"), Double(sel)))
                    .foregroundStyle(Color.primary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                PointMark(x: .value(L10n.t("选中"), Double(sel)), y: .value(L10n.t("浏览数"), points[sel].pv ?? 0))
                    .foregroundStyle(Self.pvColor)
                    .symbolSize(60)
                PointMark(x: .value(L10n.t("选中"), Double(sel)), y: .value(L10n.t("浏览数"), points[sel].uv ?? 0))
                    .foregroundStyle(Self.uvColor)
                    .symbolSize(60)
            }
        }
        .chartForegroundStyleScale([
            L10n.t("浏览数"): Self.pvColor,
            L10n.t("访客"): Self.uvColor,
        ])
        .chartXScale(domain: 0...Double(max(1, points.count - 1)))
        .chartYScale(domain: axis.domain)
        .chartXAxis {
            AxisMarks(values: tickIndices.map(Double.init)) { value in
                AxisValueLabel {
                    if let i = value.as(Int.self), i >= 0, i < points.count {
                        Text(points[i].shortLabel)
                            .font(.caption2)
                    }
                }
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
                                guard plot.width > 0, points.count > 1 else { return }
                                let x = g.location.x - plot.minX
                                guard x >= 0, x <= plot.width else { return }
                                let frac = Double(x / plot.width) * Double(points.count - 1)
                                selectedIndex = min(max(Int(frac.rounded()), 0), points.count - 1)
                            }
                            // 手指移开即取消选中
                            .onEnded { _ in selectedIndex = nil }
                    )

                // 数值气泡：悬于选中位最高点正上方
                if let sel = selectedIndex, plot.width > 0 {
                    let p = points[sel]
                    let xCenter = points.count > 1
                        ? plot.minX + plot.width * (CGFloat(sel) / CGFloat(points.count - 1))
                        : plot.midX
                    let span = max(axis.domain.upperBound - axis.domain.lowerBound, .ulpOfOne)
                    let topValue = Double(max(p.pv ?? 0, p.uv ?? 0))
                    let yTop = plot.minY
                        + plot.height * CGFloat((axis.domain.upperBound - topValue) / span)
                    let pos = MonitorBubbleLayout.position(
                        nearCap: false,
                        xCenter: xCenter, yTop: yTop,
                        halfW: bubbleSize.width / 2, halfH: bubbleSize.height / 2,
                        geoWidth: geo.size.width, geoHeight: geo.size.height
                    )
                    bubble(p)
                        .background(bubbleTracker)
                        .position(x: pos.x, y: pos.y)
                }
            }
        }
    }

    /// 气泡：浏览数/访客各一行「同色圆点 + 名称 数值」
    private func bubble(_ p: VisitorTrendPoint) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Circle().fill(Self.pvColor).frame(width: 6, height: 6)
                Text("\(L10n.t("浏览数")) \(p.pv ?? 0)")
            }
            HStack(spacing: 4) {
                Circle().fill(Self.uvColor).frame(width: 6, height: 6)
                Text("\(L10n.t("访客")) \(p.uv ?? 0)")
            }
        }
        .font(.caption2)
        .monospacedDigit()
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
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

// MARK: - 访问统计

struct WebsiteMonitorStatsSection: View {
    let client: APIClient
    let websiteID: Int

    /// (接口 type, 展示名)——实例计算属性而非 static 缓存：
    /// static 会把 L10n.t 结果常驻进程，语言热切换（根视图 .id 重建）后标题停留旧语言
    private var types: [(String, String)] {
        [
            ("uri", "URL"),
            ("referer", L10n.t("来源")),
            ("ip", "IP"),
            ("browser", L10n.t("浏览器")),
            ("os", L10n.t("操作系统")),
            ("device", L10n.t("设备")),
            ("status_code", L10n.t("状态码")),
        ]
    }

    /// 预览仅显示 5 条、可跳转完整列表的类型
    private static let expandableTypes: Set<String> = ["uri", "referer", "ip", "browser"]
    private static let previewCount = 5

    @State private var range: WebsiteMonitorRange = .today
    @State private var ranks: [String: [MonitorRankItem]] = [:]
    @State private var errorMessage: String?
    @State private var isLoading = true
    /// 加载令牌：range 快速切换时，旧请求慢返回不覆盖新一次的结果
    @State private var loadToken = 0

    var body: some View {
        Group {
            if isLoading && ranks.isEmpty {
                Section { HStack { ProgressView(); Text(L10n.t("加载中…")) } }
            } else if let errorMessage, ranks.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button(L10n.t("重试")) { Task { await load() } }
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                content
            }
        }
        .task { await load() }
        .onChange(of: range) { _, _ in Task { await load() } }
        .refreshable { await load() }
    }

    @ViewBuilder
    private var content: some View {
        Section {
            Picker(L10n.t("时间范围"), selection: $range) {
                ForEach(WebsiteMonitorRange.allCases) { r in
                    Text(r.label).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .segmentedPickerRow()
        }

        ForEach(types, id: \.0) { type in
            Section {
                let items = ranks[type.0] ?? []
                let expandable = Self.expandableTypes.contains(type.0)
                let shown = expandable ? Array(items.prefix(Self.previewCount)) : items
                if items.isEmpty {
                    Text(L10n.t("暂无数据"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(shown) { item in
                        MonitorRankRow(item: item, monospaced: type.0 == "uri" || type.0 == "ip")
                    }
                    if expandable, items.count > Self.previewCount {
                        NavigationLink {
                            WebsiteMonitorRankListView(
                                client: client, websiteID: websiteID,
                                type: type, range: range
                            )
                        } label: {
                            Text(L10n.t("查看更多"))
                                .font(.callout)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            } header: {
                SectionLabel(title: type.1, systemImage: Self.icon(for: type.0))
            }
        }
    }

    static func icon(for type: String) -> String {
        switch type {
        case "uri": return "link"
        case "referer": return "arrow.uturn.left"
        case "ip": return "number"
        case "browser": return "globe"
        case "os": return "desktopcomputer"
        case "device": return "iphone"
        case "status_code": return "hash"
        default: return "number"
        }
    }

    private func load() async {
        loadToken += 1
        let token = loadToken
        isLoading = true
        let pair = range.dayPair()
        var merged: [String: [MonitorRankItem]] = [:]
        var firstError: String?
        await withTaskGroup(of: (String, [MonitorRankItem]?, String?).self) { group in
            for type in types {
                group.addTask {
                    do {
                        let resp: [MonitorRankItem] = try await self.client.send(
                            path: APIEndpoint.monitorRank.path,
                            body: MonitorRankRequest(websiteID: self.websiteID, type: type.0, dayRange: pair, limit: 10),
                            as: [MonitorRankItem].self
                        )
                        return (type.0, resp, nil)
                    } catch {
                        return (type.0, nil, error.localizedDescription)
                    }
                }
            }
            for await (type, items, err) in group {
                if let items { merged[type] = items }
                if firstError == nil, let err { firstError = err }
            }
        }
        guard token == loadToken else { return }
        isLoading = false
        ranks = merged
        errorMessage = firstError
    }
}

// MARK: - 排行行与完整列表页

struct MonitorRankRow: View {
    let item: MonitorRankItem
    let monospaced: Bool

    var body: some View {
        HStack {
            Text(item.name ?? "-")
                .font(monospaced ? .callout.monospaced() : .callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("\(item.count ?? 0)")
                .font(.callout.bold())
                .monospacedDigit()
            if let percent = item.percent {
                Text(String(format: "%.1f%%", percent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
    }
}

struct WebsiteMonitorRankListView: View {
    let client: APIClient
    let websiteID: Int
    /// (接口 type, 展示名)
    let type: (String, String)
    let range: WebsiteMonitorRange

    @State private var items: [MonitorRankItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                ProgressView(L10n.t("加载中…"))
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
                    MonitorRankRow(item: item, monospaced: type.0 == "uri" || type.0 == "ip")
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("\(type.1) · \(range.label)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let req = MonitorRankRequest(websiteID: websiteID, type: type.0, dayRange: range.dayPair(), limit: 10)
        do {
            items = try await client.send(path: APIEndpoint.monitorRank.path, body: req, as: [MonitorRankItem].self)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 请求日志

struct WebsiteMonitorLogsSection: View {
    let client: APIClient
    let websiteID: Int

    @State private var range: WebsiteMonitorRange = .today
    @State private var items: [MonitorLogItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// 加载令牌：range 快速切换时，旧请求慢返回不覆盖新一次的结果
    @State private var loadToken = 0

    var body: some View {
        Group {
            Section {
                Picker(L10n.t("时间范围"), selection: $range) {
                    ForEach(WebsiteMonitorRange.allCases) { r in
                        Text(r.label).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .segmentedPickerRow()
            }

            if isLoading && items.isEmpty {
                Section { HStack { ProgressView(); Text(L10n.t("加载中…")) } }
            } else if let errorMessage, items.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button(L10n.t("重试")) { Task { await load() } }
                    }
                    .frame(maxWidth: .infinity)
                }
            } else if items.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label(L10n.t("暂无数据"), systemImage: "tray")
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                Section {
                    ForEach(items) { item in
                        NavigationLink {
                            WebsiteMonitorLogDetailView(
                                client: client,
                                logID: item.logID ?? 0,
                                websiteID: websiteID
                            )
                        } label: {
                            logRow(item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task { await load() }
        .onChange(of: range) { _, _ in Task { await load() } }
        .refreshable { await load() }
    }

    private func logRow(_ item: MonitorLogItem) -> some View {
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
        loadToken += 1
        let token = loadToken
        isLoading = true
        let window = range.logWindow()
        let req = MonitorLogSearchRequest(
            page: 1, pageSize: 100, total: 0,
            ip: "", ipLocation: "", url: "",
            websiteID: websiteID, method: "", spider: "",
            orderBy: "time", order: "descending",
            startTime: MonitorDate.requestString(window.start),
            endTime: MonitorDate.requestString(window.end)
        )
        do {
            let resp: PageResponse<MonitorLogItem> = try await client.send(
                path: APIEndpoint.monitorLogsSearch.path, body: req,
                as: PageResponse<MonitorLogItem>.self
            )
            guard token == loadToken else { return }
            isLoading = false
            items = resp.items ?? []
            errorMessage = nil
        } catch {
            guard token == loadToken else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 请求日志详情

struct WebsiteMonitorLogDetailView: View {
    let client: APIClient
    let logID: Int
    let websiteID: Int

    @State private var detail: MonitorLogDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading && detail == nil {
                ProgressView(L10n.t("加载中…"))
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
                        InfoRow("IP", value: d.ip ?? "-")
                        InfoRow(L10n.t("日期"), value: WAFTime.short(d.localtime) ?? d.localtime ?? "-")
                        InfoRow(L10n.t("响应流量"), value: formatBytes(d.sendBytes))
                        InfoRow(L10n.t("响应时间"), value: d.requestTime.map { "\($0)ms" } ?? "-")
                        InfoRow(L10n.t("来源"), value: nonEmpty(d.referer))
                        InfoRow(L10n.t("请求类型"), value: nonEmpty(d.method))
                        InfoRow(L10n.t("状态码"), value: d.statusCode.map(String.init) ?? "-")
                    }
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("User-Agent")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(nonEmpty(d.userAgent))
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("URL")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(nonEmpty(d.uri))
                                .font(.callout.monospaced())
                                .lineLimit(3)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle(L10n.t("请求日志"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func nonEmpty(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "-" }
        return s
    }

    private func formatBytes(_ bytes: Int64?) -> String {
        guard let bytes, bytes >= 0 else { return "-" }
        var size = Double(bytes)
        let units = ["B", "KB", "MB", "GB", "TB"]
        var idx = 0
        while size >= 1024 && idx < units.count - 1 {
            size /= 1024
            idx += 1
        }
        return String(format: "%.1f %@", size, units[idx])
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let req = MonitorLogDetailRequest(id: logID, websiteID: websiteID)
        do {
            detail = try await client.send(path: APIEndpoint.monitorLogsDetail.path, body: req, as: MonitorLogDetail.self)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
