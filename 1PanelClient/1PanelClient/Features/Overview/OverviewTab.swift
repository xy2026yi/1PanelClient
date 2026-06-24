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
                        if let new = manager.current {
                            vm.switchServer(new)
                            Task { await vm.refresh() }
                        }
                    }
                }
                Button("添加服务器") { showAddSheet = true }
                Button("取消", role: .cancel) {}
            }
            .sheet(isPresented: $showAddSheet) {
                ServerEditView(manager: manager)
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
            InfoRow(key: "版本", value: vm.settingInfo?.systemVersion.flatMap { $0.isEmpty ? nil : $0 } ?? "未知")
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
        return VStack(spacing: 12) {
            HStack {
                Image(systemName: "chart.xyaxis.line")
                    .foregroundStyle(.tint)
                Text("状态")
                    .font(.headline)
                Spacer()
                if let uptime = cur.timeSinceUptime, !uptime.isEmpty {
                    Text("运行 \(uptime)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 负载 / CPU / 内存 一排
            HStack(spacing: 4) {
                RingStatView(
                    percent: min(cur.loadUsagePercent ?? 0, 100),
                    color: .teal,
                    topText: String(format: "%.0f%%", cur.loadUsagePercent ?? 0),
                    bottomText: "负载",
                    footer: format2(cur.load1),
                    compact: true
                )
                RingStatView(
                    percent: min(cur.cpuUsedPercent ?? 0, 100),
                    color: .blue,
                    topText: String(format: "%.0f%%", cur.cpuUsedPercent ?? 0),
                    bottomText: "CPU",
                    footer: "\(cur.cpuTotal ?? 0) 核",
                    compact: true
                )
                RingStatView(
                    percent: min(cur.memoryUsedPercent ?? 0, 100),
                    color: .purple,
                    topText: String(format: "%.0f%%", cur.memoryUsedPercent ?? 0),
                    bottomText: "内存",
                    footer: formatBytes(cur.memoryTotal),
                    compact: true
                )
            }

            // 存储：按挂载点单独区分，横向滑动
            if let disks = cur.diskData, !disks.isEmpty {
                Divider().padding(.vertical, 2)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
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
                }
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
                StatCard(title: "应用", count: b.appInstalledNumber, icon: "app.badge", color: .blue)
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
        let ringSize: CGFloat = compact ? 62 : 88
        let ringWidth: CGFloat = compact ? 7 : 10
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Spacer()
                if count == nil {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            Text(count.map { "\($0)" } ?? "—")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
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

        let (b, o, d, s, c) = await (baseResp, os, dev, settings, current)
        self.base = b
        self.osInfo = o
        self.deviceInfo = d
        self.settingInfo = s
        self.currentInfo = c

        if b == nil && o == nil && d == nil {
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
