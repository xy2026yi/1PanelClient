//
//  OverviewTab.swift
//  1PanelClient
//

import SwiftUI
import Combine

struct OverviewTab: View {
    @ObservedObject var manager: ServerManager
    @Binding var selectedTab: AppTab
    @StateObject private var vm: OverviewViewModel
    @State private var showServerPicker = false
    @State private var showAddSheet = false
    @State private var showUpgradeLog = false

    /// 卡片点击回调：传递具体 ManageItem，由 MainTabView 跨 Tab 跳转到管理详情
    var onSelectManageItem: ((ManageItem) -> Void)? = nil

    init(
        manager: ServerManager,
        selectedTab: Binding<AppTab> = .constant(.overview),
        onSelectManageItem: ((ManageItem) -> Void)? = nil
    ) {
        self.manager = manager
        self._selectedTab = selectedTab
        self.onSelectManageItem = onSelectManageItem
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: OverviewViewModel(server: server))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if vm.isLoading && !vm.hasData {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else if let base = vm.base, base.hostname != nil {
                        fullDashboard(base)
                    } else {
                        fallbackView
                    }
                }
                .padding()
                .padding(.bottom, 44)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await vm.refresh()
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button {
                        showServerPicker = true
                    } label: {
                        VStack(spacing: 1) {
                            Text(manager.current?.name ?? "未连接")
                                .font(.headline)
                            HStack(spacing: 3) {
                                Text(manager.current?.normalizedBaseURL ?? "")
                                    .font(.caption2)
                                    .lineLimit(1)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .confirmationDialog("选择服务器", isPresented: $showServerPicker, titleVisibility: .visible) {
                ForEach(manager.servers) { s in
                    Button(s.name) {
                        manager.select(s)
                    }
                }
                Button("添加服务器") { showAddSheet = true }
                Button("取消", role: .cancel) {}
            }
            .sheet(isPresented: $showAddSheet) {
                ServerEditView(manager: manager)
            }
            .navigationDestination(isPresented: $showUpgradeLog) {
                if let server = manager.current {
                    PanelUpgradeView(server: server, currentVersion: vm.settingInfo?.systemVersion, upgradeInfo: vm.upgradeInfo)
                }
            }
        }
        .task { await vm.refresh() }
        // 实时监控独立轮询：页面可见时每 5 秒刷新一次 current 数据
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !Task.isCancelled {
                    await vm.refreshCurrent()
                }
            }
        }
        // 服务器切换时（设置页添加/切换、首页下拉选择）自动重建 ViewModel 并刷新
        .onChange(of: manager.currentServerID) { _ in
            if let new = manager.current {
                vm.switchServer(new)
                Task { await vm.refresh() }
            }
        }
    }

    // 完整仪表盘（dashboard/base/all/all 可用时）
    // 顺序对齐 1Panel 官方：资源卡片 → 实时监控 → 面板信息 → 系统信息
    @ViewBuilder
    private func fullDashboard(_ base: DashboardBase) -> some View {
        resourceStatsGrid(base)
        // 实时监控使用独立的 current 接口数据（优先），回退到 base.currentInfo
        if let cur = vm.currentInfo ?? base.currentInfo {
            monitorCards(cur: cur)
        }
        panelInfoCard
        systemCard(base)
    }
    // MARK: - 面板信息卡片（版本号等）
    @ViewBuilder
    private var panelInfoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "info.circle")
                    .foregroundStyle(.tint)
                Text("面板信息")
                    .font(.headline)
            }
            Divider()
            // 版本号行：可点击跳转版本更新日志
            HStack {
                Text("版本")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(vm.settingInfo?.systemVersion.flatMap { $0.isEmpty ? nil : $0 } ?? "未知")
                    .foregroundStyle(.primary)
                if vm.upgradeInfo?.hasUpdate(comparedTo: vm.settingInfo?.systemVersion) == true {
                    Text("有更新")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange, in: Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                showUpgradeLog = true
            }
            if let ip = vm.settingInfo?.systemIP, !ip.isEmpty {
                InfoRow(key: "面板 IP", value: ip)
            }
            if let tz = vm.settingInfo?.timeZone, !tz.isEmpty {
                InfoRow(key: "时区", value: tz)
            }
            if let local = vm.settingInfo?.localTime, !local.isEmpty {
                InfoRow(key: "本地时间", value: local)
            }
            if let monitor = vm.settingInfo?.monitorStatus, !monitor.isEmpty {
                InfoRow(key: "监控", value: monitor == "enable" ? "已启用" : "已停用")
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // 回退视图（dashboard/base/all/all 失败时）
    @ViewBuilder
    private var fallbackView: some View {
        if let dev = vm.deviceInfo {
            deviceCard(dev)
        }
        if let os = vm.osInfo {
            osCard(os)
        }
        if let err = vm.errorMessage, vm.deviceInfo == nil && vm.osInfo == nil {
            ErrorBanner(message: err) { Task { await vm.refresh() } }
        }
    }

    // MARK: - 完整模式卡片

    private func systemCard(_ b: DashboardBase) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(.tint)
                Text("系统信息")
                    .font(.headline)
            }
            Divider()
            InfoRow(key: "主机名", value: b.hostname ?? "-")
            InfoRow(key: "版本", value: b.prettyDistro ?? "-")
            InfoRow(key: "内核版本", value: b.kernelVersion ?? "-")
            InfoRow(key: "系统类型", value: b.kernelArch ?? "-")
            InfoRow(key: "主机地址", value: b.ipV4Addr ?? "-")
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func monitorCards(cur: DashboardCurrent) -> some View {
        let disks = cur.diskData ?? []

        return VStack(spacing: 12) {
            HStack {
                Image(systemName: "chart.xyaxis.line")
                    .foregroundStyle(.tint)
                Text("状态")
                    .font(.headline)
                Spacer()
            }

            // 负载 / CPU / 内存 / 各存储挂载点 全部一排，超出可左右滑动
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 4) {
                    RingStatView(
                        percent: min(cur.loadUsagePercent ?? 0, 100),
                        color: .teal,
                        topText: String(format: "%.0f%%", cur.loadUsagePercent ?? 0),
                        bottomText: "负载",
                        footer: format2(cur.load1),
                        compact: true
                    )
                    .frame(width: 76)

                    RingStatView(
                        percent: min(cur.cpuUsedPercent ?? 0, 100),
                        color: .blue,
                        topText: String(format: "%.0f%%", cur.cpuUsedPercent ?? 0),
                        bottomText: "CPU",
                        footer: "\(cur.cpuTotal ?? 0) 核",
                        compact: true
                    )
                    .frame(width: 76)

                    RingStatView(
                        percent: min(cur.memoryUsedPercent ?? 0, 100),
                        color: .purple,
                        topText: String(format: "%.0f%%", cur.memoryUsedPercent ?? 0),
                        bottomText: "内存",
                        footer: formatBytes(cur.memoryTotal),
                        compact: true
                    )
                    .frame(width: 76)

                    ForEach(Array(disks.enumerated()), id: \.offset) { _, disk in
                        let pct = disk.usedPercent ?? 0
                        RingStatView(
                            percent: min(pct, 100),
                            color: .orange,
                            topText: String(format: "%.0f%%", pct),
                            bottomText: disk.path?.isEmpty == false ? disk.path! : "存储",
                            footer: formatBytes(disk.total),
                            compact: true
                        )
                        .frame(width: 76)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 2)
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func resourceStatsGrid(_ b: DashboardBase) -> some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ], spacing: 12) {
            Button { tapManage(.websites) } label: {
                StatCard(title: "网站", count: b.websiteNumber, icon: "globe", color: .green)
            }
            .buttonStyle(.plain)

            Button { tapManage(.apps) } label: {
                StatCard(title: "应用", count: b.appInstalledNumber, icon: "app.badge", color: .blue, updateCount: vm.appUpdateCount)
            }
            .buttonStyle(.plain)

            Button { tapManage(.database) } label: {
                StatCard(title: "数据库", count: b.databaseNumber, icon: "cylinder.split.1x2", color: .purple)
            }
            .buttonStyle(.plain)

            Button { tapManage(.containers) } label: {
                StatCard(title: "容器", count: b.appInstalledNumber, icon: "shippingbox", color: .indigo)
            }
            .buttonStyle(.plain)
        }
    }

    /// 点击资源卡片：优先用 onSelectManageItem 跨 Tab 打开管理详情；
    /// 回退方案：仅切到管理 Tab
    private func tapManage(_ item: ManageItem) {
        if let onSelectManageItem {
            onSelectManageItem(item)
        } else {
            selectedTab = .manage
        }
    }

    // MARK: - 回退模式卡片

    private func deviceCard(_ d: DeviceInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(.tint)
                Text("服务器信息")
                    .font(.headline)
            }
            Divider()
            InfoRow(key: "主机名", value: d.hostname)
            InfoRow(key: "时区", value: d.timeZone)
            InfoRow(key: "本地时间", value: d.localTime)
            InfoRow(key: "NTP", value: d.ntp ?? "-")
            InfoRow(key: "DNS", value: d.dns.joined(separator: ", "))
            InfoRow(key: "Hosts", value: "\(d.hosts.count) 条")
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func osCard(_ os: OsInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "info.bubble")
                    .foregroundStyle(.tint)
                Text("系统详情")
                    .font(.headline)
            }
            Divider()
            if let distro = os.prettyDistro, !distro.isEmpty {
                InfoRow(key: "发行版", value: distro)
            }
            if let p = os.platform, !p.isEmpty {
                InfoRow(key: "平台", value: "\(p) \(os.platformVersion ?? "")")
            }
            InfoRow(key: "内核", value: "\(os.kernelVersion ?? "-") (\(os.kernelArch ?? "-"))")
            if let size = os.diskSize {
                InfoRow(key: "磁盘总量", value: formatBytes(size))
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func formatBytes(_ bytes: Int64?) -> String {
        let bytes = bytes ?? 0
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
    }

    private func format2(_ v: Double?) -> String {
        String(format: "%.2f", v ?? 0)
    }
}

// MARK: - 子视图

/// 圆形进度指标：外圈圆环体现使用率，圆心上方显示百分比，下方显示标签，圆环正下方显示详情
struct RingStatView: View {
    let percent: Double
    let color: Color
    let topText: String      // 圆心上：百分比文本
    let bottomText: String   // 圆心下：标签（负载/CPU/内存/存储）
    let footer: String       // 圆环下方：具体使用情况/总数
    var compact: Bool = false // 紧凑模式（一排显示）

    var body: some View {
        let ringSize: CGFloat = compact ? 54 : 88
        let ringWidth: CGFloat = compact ? 6 : 10
        let topFont: Font = compact
            ? .system(size: 13, weight: .bold, design: .rounded)
            : .system(size: 16, weight: .bold, design: .rounded)

        return VStack(spacing: compact ? 4 : 8) {
            ZStack {
                // 背景圆环
                Circle()
                    .stroke(color.opacity(0.15), lineWidth: ringWidth)
                // 进度圆环
                Circle()
                    .trim(from: 0, to: max(0.001, min(percent, 100) / 100))
                    .stroke(color,
                            style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: percent)
                // 圆心文字：上（%）+ 下（标签）
                VStack(spacing: compact ? 0 : 2) {
                    Text(topText)
                        .font(topFont)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text(bottomText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: ringSize, height: ringSize)

            // 圆环正下方：具体使用情况/总数
            Text(footer)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: compact ? 14 : 28)
        }
        .frame(maxWidth: .infinity)
    }
}

struct StatCard: View {
    let title: String
    let count: Int?
    let icon: String
    let color: Color
    var updateCount: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.title3)
                Spacer()
                if count == nil {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            HStack(alignment: .firstTextBaseline) {
                Text(count.map { "\($0)" } ?? "—")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                if let updates = updateCount, updates > 0 {
                    Text("\(updates)个更新")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - ViewModel

@MainActor
final class OverviewViewModel: ObservableObject {
    @Published var base: DashboardBase?
    @Published var osInfo: OsInfo?
    @Published var deviceInfo: DeviceInfo?
    @Published var settingInfo: SettingInfo?
    @Published var currentInfo: DashboardCurrent?   // 实时监控（独立接口）
    @Published var appUpdateCount: Int?              // 可更新应用数
    @Published var upgradeInfo: PanelUpgradeInfo?     // 面板版本更新信息
    @Published var isLoading = false
    @Published var errorMessage: String?

    private(set) var client: APIClient

    var hasData: Bool { base != nil || osInfo != nil || deviceInfo != nil }

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    func switchServer(_ server: ServerConfig) {
        client = APIClient(server: server)
        base = nil
        osInfo = nil
        deviceInfo = nil
        settingInfo = nil
        currentInfo = nil
        appUpdateCount = nil
        upgradeInfo = nil
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // 并行：完整 dashboard + OS 信息 + 设备信息 + 面板设置 + 实时监控
        async let baseResp: DashboardBase? = try? await client.send(
            path: APIEndpoint.dashboardBase.path,
            method: APIEndpoint.dashboardBase.method,
            as: DashboardBase.self
        )
        async let os: OsInfo? = try? await client.send(
            path: APIEndpoint.dashboardOS.path,
            method: APIEndpoint.dashboardOS.method,
            as: OsInfo.self
        )
        async let dev: DeviceInfo? = try? await client.send(
            path: APIEndpoint.deviceBase.path,
            as: DeviceInfo.self
        )
        async let settings: SettingInfo? = try? await client.send(
            path: APIEndpoint.settingsSearch.path,
            as: SettingInfo.self
        )
        async let current: DashboardCurrent? = try? await client.send(
            path: APIEndpoint.dashboardCurrent.path,
            method: APIEndpoint.dashboardCurrent.method,
            as: DashboardCurrent.self
        )
        async let appUpdates: AppInstalledListResponse? = try? await client.send(
            path: APIEndpoint.appsInstalledSearch.path,
            body: AppInstalledSearchRequest(page: 1, pageSize: 1, name: "", type: "", tags: [], update: true, all: false, unused: false, sync: false),
            as: AppInstalledListResponse.self
        )
        async let upgrade: PanelUpgradeInfo? = try? await client.send(
            path: APIEndpoint.settingsUpgradeCheck.path,
            method: APIEndpoint.settingsUpgradeCheck.method,
            as: PanelUpgradeInfo.self
        )

        let (b, o, d, s, c, au, up) = await (baseResp, os, dev, settings, current, appUpdates, upgrade)
        if let b { self.base = b }
        if let o { self.osInfo = o }
        if let d { self.deviceInfo = d }
        if let s { self.settingInfo = s }
        if let c { self.currentInfo = c }
        self.appUpdateCount = au?.total ?? 0
        self.upgradeInfo = up

        // 仅在完全无数据时才显示错误（刷新失败时保留旧数据）
        if base == nil && osInfo == nil && deviceInfo == nil {
            self.errorMessage = "无法获取服务器信息，请检查 API Key 和网络"
        }
    }

    /// 仅刷新实时监控数据（供定时轮询调用，避免全量刷新）
    func refreshCurrent() async {
        if let c: DashboardCurrent = try? await client.send(
            path: APIEndpoint.dashboardCurrent.path,
            method: APIEndpoint.dashboardCurrent.method,
            as: DashboardCurrent.self
        ) {
            self.currentInfo = c
        }
    }
}

// MARK: - 面板版本更新日志

struct PanelUpgradeView: View {
    let server: ServerConfig
    let initialCurrentVersion: String?
    let initialUpgradeInfo: PanelUpgradeInfo?

    @State private var releases: [PanelRelease] = []
    @State private var latestSettingInfo: SettingInfo?
    @State private var latestUpgradeInfo: PanelUpgradeInfo?
    @State private var isLoading = false
    @State private var isUpgrading = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private let client: APIClient

    private var currentVersion: String? {
        latestSettingInfo?.systemVersion ?? initialCurrentVersion
    }

    private var upgradeInfo: PanelUpgradeInfo? {
        latestUpgradeInfo ?? initialUpgradeInfo
    }

    init(server: ServerConfig, currentVersion: String?, upgradeInfo: PanelUpgradeInfo?) {
        self.server = server
        self.initialCurrentVersion = currentVersion
        self.initialUpgradeInfo = upgradeInfo
        self.client = APIClient(server: server)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if isLoading && releases.isEmpty {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if releases.isEmpty {
                    ContentUnavailableView("暂无更新日志", systemImage: "doc.text.magnifyingglass")
                } else {
                    if upgradeInfo?.hasUpdate(comparedTo: currentVersion) == true, let latest = upgradeInfo?.latestVersion {
                        updateBanner(latestVersion: latest)
                    }

                    ForEach(Array(releases.enumerated()), id: \.element.id) { index, release in
                        releaseCard(release, isExpanded: index == 0)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("版本更新日志")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadReleases() }
        .alert("提示", isPresented: Binding(
            get: { successMessage != nil || errorMessage != nil },
            set: { _ in successMessage = nil; errorMessage = nil }
        )) {
            Button("好的") { successMessage = nil; errorMessage = nil }
        } message: {
            Text(errorMessage ?? successMessage ?? "")
        }
    }

    @ViewBuilder
    private func updateBanner(latestVersion: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("发现新版本")
                        .font(.headline)
                    Text("当前 \(currentVersion ?? "未知") → 最新 \(latestVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await upgrade(to: latestVersion) }
                } label: {
                    Label(isUpgrading ? "更新中…" : "更新", systemImage: "arrow.down.circle.fill")
                        .font(.callout)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(isUpgrading)
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.blue.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func releaseCard(_ release: PanelRelease, isExpanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(release.version)
                        .font(.headline)
                    if let date = release.createdAt {
                        Text(date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let newCount = release.newCount, newCount > 0 {
                    ReleaseTag(text: "新增 \(newCount)", color: .green)
                }
                if let optCount = release.optimizationCount, optCount > 0 {
                    ReleaseTag(text: "优化 \(optCount)", color: .blue)
                }
                if let fixCount = release.fixCount, fixCount > 0 {
                    ReleaseTag(text: "修复 \(fixCount)", color: .orange)
                }
            }

            if isExpanded, let content = release.content {
                Text(stripHTML(content))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
            } else if !isExpanded {
                Text("点击查看详情")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func loadReleases() async {
        isLoading = true
        do {
            async let releasesResponse: [PanelRelease] = client.send(
                path: APIEndpoint.settingsUpgradeReleases.path,
                method: APIEndpoint.settingsUpgradeReleases.method,
                as: [PanelRelease].self
            )
            async let settingsResponse: SettingInfo? = try? await client.send(
                path: APIEndpoint.settingsSearch.path,
                as: SettingInfo.self
            )
            async let upgradeResponse: PanelUpgradeInfo? = try? await client.send(
                path: APIEndpoint.settingsUpgradeCheck.path,
                method: APIEndpoint.settingsUpgradeCheck.method,
                as: PanelUpgradeInfo.self
            )

            releases = try await releasesResponse
            latestSettingInfo = await settingsResponse
            latestUpgradeInfo = await upgradeResponse
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func upgrade(to version: String) async {
        isUpgrading = true
        let req = PanelUpgradeRequest(version: version)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.settingsUpgrade.path, body: req, as: EmptyResponse.self)
            successMessage = "更新任务已提交，请稍后查看面板状态"
        } catch {
            errorMessage = error.localizedDescription
        }
        isUpgrading = false
    }

    private func stripHTML(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<p>", with: "", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<li>", with: "• ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "</li>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<ul>", with: "", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "</ul>", with: "", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        let lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.joined(separator: "\n")
    }
}

private struct ReleaseTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}
