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

    init(manager: ServerManager, selectedTab: Binding<AppTab> = .constant(.overview)) {
        self.manager = manager
        self._selectedTab = selectedTab
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
            .navigationTitle(manager.current?.name ?? "1Panel")
            .navigationBarTitleDisplayMode(.large)
            .refreshable {
                await vm.refresh()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showServerPicker = true
                    } label: { Image(systemName: "server.rack") }
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
    }

    // 完整仪表盘（dashboard/base/all/all 可用时）
    @ViewBuilder
    private func fullDashboard(_ base: DashboardBase) -> some View {
        systemCard(base)
        if let cur = base.currentInfo {
            monitorCards(cur: cur)
        }
        resourceStatsGrid(base)
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
            if let distro = b.prettyDistro, !distro.isEmpty {
                InfoRow(key: "发行版", value: distro)
            } else if let os = b.os {
                InfoRow(key: "系统", value: "\(os) \(b.platformVersion ?? "")")
            }
            InfoRow(key: "内核", value: "\(b.kernelVersion ?? "-") (\(b.kernelArch ?? "-"))")
            if let ip = b.ipV4Addr, !ip.isEmpty {
                InfoRow(key: "IP", value: ip)
            }
            if let cpuModel = b.cpuModelName, !cpuModel.isEmpty {
                InfoRow(key: "CPU", value: cpuModel)
                InfoRow(key: "核心数", value: "\(b.cpuCores ?? 0) 物理核 / \(b.cpuLogicalCores ?? 0) 逻辑核")
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func monitorCards(cur: DashboardCurrent) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "chart.xyaxis.line")
                    .foregroundStyle(.tint)
                Text("实时监控")
                    .font(.headline)
                Spacer()
                if let uptime = cur.timeSinceUptime, !uptime.isEmpty {
                    Text("运行 \(uptime)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                GaugeCard(title: "CPU",
                          percent: cur.cpuUsedPercent ?? 0,
                          color: .blue,
                          detail: "\(formatCores(cur.cpuUsed)) / \(cur.cpuTotal ?? 0) 核",
                          loadInfo: "负载 \(format2(cur.load1)) / \(format2(cur.load5)) / \(format2(cur.load15))")
                GaugeCard(title: "内存",
                          percent: cur.memoryUsedPercent ?? 0,
                          color: .purple,
                          detail: "\(formatBytes(cur.memoryUsed)) / \(formatBytes(cur.memoryTotal))",
                          loadInfo: "Swap \(formatBytes(cur.swapMemoryUsed)) / \(formatBytes(cur.swapMemoryTotal))")
            }

            HStack(spacing: 12) {
                MiniStatCard(title: "磁盘读", icon: "arrow.down.circle",
                             value: formatBytes(cur.ioReadBytes), color: .green)
                MiniStatCard(title: "磁盘写", icon: "arrow.up.circle",
                             value: formatBytes(cur.ioWriteBytes), color: .orange)
            }
            HStack(spacing: 12) {
                MiniStatCard(title: "网络接收", icon: "arrow.down.to.line",
                             value: formatBytes(cur.netBytesRecv), color: .blue)
                MiniStatCard(title: "网络发送", icon: "arrow.up.to.line",
                             value: formatBytes(cur.netBytesSent), color: .pink)
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
            Button { selectedTab = .websites } label: {
                StatCard(title: "网站", count: b.websiteNumber, icon: "globe", color: .green)
            }
            .buttonStyle(.plain)

            Button { selectedTab = .apps } label: {
                StatCard(title: "应用", count: b.appInstalledNumber, icon: "shippingbox", color: .blue)
            }
            .buttonStyle(.plain)

            StatCard(title: "数据库", count: b.databaseNumber, icon: "cylinder.split.1x2", color: .purple)
            StatCard(title: "计划任务", count: b.cronjobNumber, icon: "clock.arrow.circlepath", color: .orange)
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

    private func formatCores(_ v: Double?) -> String {
        String(format: "%.1f", v ?? 0)
    }
}

// MARK: - 子视图

struct GaugeCard: View {
    let title: String
    let percent: Double
    let color: Color
    let detail: String
    let loadInfo: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(String(format: "%.1f", percent))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ProgressView(value: min(percent, 100), total: 100)
                .tint(color)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(loadInfo)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct MiniStatCard: View {
    let title: String
    let icon: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.bold())
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(10)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // 并行：尝试完整 dashboard + OS 信息 + 设备信息
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

        let (b, o, d) = await (baseResp, os, dev)
        self.base = b
        self.osInfo = o
        self.deviceInfo = d

        if b == nil && o == nil && d == nil {
            self.errorMessage = "无法获取服务器信息，请检查 API Key 和网络"
        }
    }
}
