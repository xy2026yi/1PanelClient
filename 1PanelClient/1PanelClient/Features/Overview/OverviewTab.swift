//
//  OverviewTab.swift
//  1PanelClient
//

import SwiftUI
import Combine

struct OverviewTab: View {
    @ObservedObject var manager: ServerManager
    @Binding var selectedTab: AppTab
    /// 向 MainTabView 同步导航深度：true=根页面（显示底部 Tab 栏），false=子页面
    @Binding var atRoot: Bool
    @StateObject private var vm: OverviewViewModel
    @State private var showServers = false
    @State private var showUpgradeLog = false

    /// 卡片点击回调：传递具体 ManageItem，由 MainTabView 跨 Tab 跳转到管理详情
    var onSelectManageItem: ((ManageItem) -> Void)? = nil

    init(
        manager: ServerManager,
        selectedTab: Binding<AppTab> = .constant(.overview),
        atRoot: Binding<Bool> = .constant(true),
        onSelectManageItem: ((ManageItem) -> Void)? = nil
    ) {
        self.manager = manager
        self._selectedTab = selectedTab
        self._atRoot = atRoot
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
            }
            // TabBar 上方留白：与管理页 contentMargins 同一机制、同一数值
            .contentMargins(.bottom, 60, for: .scrollContent)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await vm.refresh()
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button {
                        showServers = true
                    } label: {
                        VStack(spacing: 1) {
                            Text(manager.current?.name ?? "未连接")
                                .font(.headline)
                            HStack(spacing: 3) {
                                Text(manager.current?.normalizedBaseURL ?? "")
                                    .font(.caption2)
                                    .lineLimit(1)
                                ServerSwitchIcon()
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationDestination(isPresented: $showServers) {
                ServersView(manager: manager)
            }
            .navigationDestination(isPresented: $showUpgradeLog) {
                if let server = manager.current {
                    PanelUpgradeView(server: server, currentVersion: vm.settingInfo?.systemVersion, upgradeInfo: vm.upgradeInfo)
                }
            }
            .onChange(of: showServers) { _, show in
                atRoot = !show
            }
            .onChange(of: showUpgradeLog) { _, show in
                atRoot = !show
            }
        }
        .task { await vm.refresh() }
        // 实时监控独立轮询：页面可见时每 5 秒刷新一次 current 数据（仅当前 Tab 活跃时）
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !Task.isCancelled && selectedTab == .overview {
                    await vm.refreshCurrent()
                }
            }
        }
        // 服务器切换时（服务器页添加、切换）自动重建 ViewModel 并刷新
        .onChange(of: manager.currentServerID) {
            if let new = manager.current {
                vm.switchServer(new)
                Task { await vm.refresh() }
            }
        }
        // 当前服务器 API Key 变化时（冷启动 Keychain 补齐、编辑保存）同样重建，避免沿用旧 Key
        .onChange(of: manager.current?.apiKey ?? "") {
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
                    StatusBadge(text: "有更新", color: .orange)
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
            if let currentInfo = vm.currentInfo ?? b.currentInfo {
                if let startupTime = currentInfo.timeSinceUptime, !startupTime.isEmpty {
                    InfoRow(key: "启动时间", value: startupTime)
                }
                if let runningTime = currentInfo.runningTime {
                    InfoRow(key: "运行时间", value: runningTime.displayText)
                }
            }
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
                // 跳转 管理-监控（onSelectManageItem 机制）；chevron 表达「进入」语义
                Button {
                    onSelectManageItem?(.monitor)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("查看监控")
            }

            // 负载 / CPU / 内存 固定一排（点击圆环区域与右上角箭头一样跳转监控）
            HStack(alignment: .top, spacing: 4) {
                RingStatView(
                    percent: min(cur.loadUsagePercent ?? 0, 100),
                    color: .teal,
                    topText: String(format: "%.2f%%", cur.loadUsagePercent ?? 0),
                    bottomText: "负载",
                    footer: format2(cur.load1),
                    compact: true
                )

                RingStatView(
                    percent: min(cur.cpuUsedPercent ?? 0, 100),
                    color: .blue,
                    topText: String(format: "%.2f%%", cur.cpuUsedPercent ?? 0),
                    bottomText: "CPU",
                    footer: "\(format2(cur.cpuUsed)) / \(cur.cpuTotal ?? 0) 核",
                    compact: true
                )

                RingStatView(
                    percent: min(cur.memoryUsedPercent ?? 0, 100),
                    color: .purple,
                    topText: String(format: "%.2f%%", cur.memoryUsedPercent ?? 0),
                    bottomText: "内存",
                    footer: formatUsedOverTotal(cur.memoryUsed, cur.memoryTotal),
                    compact: true
                )
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .onTapGesture { tapManage(.monitor) }

            // 各存储挂载点：网格平铺（3 列），无需横滑即可见
            if !disks.isEmpty {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 4),
                    GridItem(.flexible(), spacing: 4),
                    GridItem(.flexible(), spacing: 4)
                ], spacing: 12) {
                    ForEach(Array(disks.enumerated()), id: \.offset) { _, disk in
                        let pct = disk.usedPercent ?? 0
                        RingStatView(
                            percent: min(pct, 100),
                            color: .orange,
                            topText: String(format: "%.2f%%", pct),
                            bottomText: disk.path?.isEmpty == false ? disk.path! : "存储",
                            footer: formatUsedOverTotal(disk.used, disk.total),
                            compact: true
                        )
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 4)
                .contentShape(Rectangle())
                .onTapGesture { tapManage(.monitor) }
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
            .buttonStyle(PressableCardStyle())

            Button { tapManage(.apps) } label: {
                StatCard(title: "应用", count: b.appInstalledNumber, icon: "app.badge", color: .blue, updateCount: vm.appUpdateCount)
            }
            .buttonStyle(PressableCardStyle())

            Button { tapManage(.database) } label: {
                StatCard(title: "数据库", count: b.databaseNumber, icon: "cylinder.split.1x2", color: .purple)
            }
            .buttonStyle(PressableCardStyle())

            Button { tapManage(.containers) } label: {
                StatCard(title: "容器", count: vm.containerCount, icon: "shippingbox", color: .indigo)
            }
            .buttonStyle(PressableCardStyle())
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
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.2f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
    }

    /// 字节数拆成 (数值, 单位)：≥1GB 用 GB、≥1MB 用 MB、≥1KB 用 KB；GB/MB 保留两位小数
    private func byteParts(_ bytes: Int64?) -> (value: String, unit: String) {
        let b = bytes ?? 0
        if b >= 1024 * 1024 * 1024 {
            return (String(format: "%.2f", Double(b) / 1_073_741_824), "GB")
        }
        if b >= 1024 * 1024 {
            return (String(format: "%.2f", Double(b) / 1_048_576), "MB")
        }
        if b >= 1024 {
            return (String(format: "%.1f", Double(b) / 1024), "KB")
        }
        return ("\(b)", "B")
    }

    /// 已用/总量：同单位时单位只出现一次（6.83 / 58.90 GB），不足 GB 的已用单独标注（1.02 MB / 3.86 GB）
    private func formatUsedOverTotal(_ used: Int64?, _ total: Int64?) -> String {
        let u = byteParts(used)
        let t = byteParts(total)
        if u.unit == t.unit {
            return "\(u.value) / \(t.value) \(t.unit)"
        }
        return "\(u.value) \(u.unit) / \(t.value) \(t.unit)"
    }

    private func format2(_ v: Double?) -> String {
        String(format: "%.2f", v ?? 0)
    }
}

// MARK: - 子视图

/// 首页顶栏「切换服务器」图标：圆形底 + 上下两条平行反向箭头（左右交换语义）
struct ServerSwitchIcon: View {
    var body: some View {
        Image(systemName: "arrow.left.arrow.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
            .background(
                Circle()
                    .fill(Color.primary.opacity(0.08))
            )
    }
}

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
        // 两位小数百分比（58.81%）较长，字号收紧 + 允许自动缩小避免圆环内溢出
        let topFont: Font = compact
            ? .system(size: 10, weight: .semibold, design: .rounded)
            : .system(size: 13, weight: .semibold, design: .rounded)

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
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(bottomText)
                        .font(.system(size: compact ? 9.5 : 12))
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
                    HStack(spacing: 4) {
                        // 可点入口的视觉暗示：标题旁的导航箭头
                        Text(title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.up.forward")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
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
    @Published var containerCount: Int?               // 容器总数（dashboard/base 无此字段，独立请求）
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
        containerCount = nil
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
        async let containers: ContainerListResponse? = try? await client.send(
            path: APIEndpoint.containersSearch.path,
            body: ContainerSearchRequest(page: 1, pageSize: 1, name: "", state: "all", orderBy: "createdAt", order: "null"),
            as: ContainerListResponse.self
        )
        async let upgrade: PanelUpgradeInfo? = try? await client.send(
            path: APIEndpoint.settingsUpgradeCheck.path,
            method: APIEndpoint.settingsUpgradeCheck.method,
            as: PanelUpgradeInfo.self
        )

        let (b, o, d, s, c, au, ct, up) = await (baseResp, os, dev, settings, current, appUpdates, containers, upgrade)
        if let b { self.base = b }
        if let o { self.osInfo = o }
        if let d { self.deviceInfo = d }
        if let s { self.settingInfo = s }
        if let c { self.currentInfo = c }
        self.appUpdateCount = au?.total ?? 0
        self.containerCount = ct?.total
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
                    StatusBadge(text: "新增 \(newCount)", color: .green)
                }
                if let optCount = release.optimizationCount, optCount > 0 {
                    StatusBadge(text: "优化 \(optCount)", color: .blue)
                }
                if let fixCount = release.fixCount, fixCount > 0 {
                    StatusBadge(text: "修复 \(fixCount)", color: .orange)
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
