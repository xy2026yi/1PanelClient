//
//  MonitorSettingsView.swift
//  1PanelClient
//
//  监控设置 + 虚拟内存（logs/推荐实现-计划任务和面板.md 抓包 2026-09-14）：
//  监控开关/保存天数/采集间隔/默认网卡/磁盘（单项 setting/update {key,value}）
//  · 清空监控记录 · Swap 统计与调整（device/update/swap 任务进度）
//

import SwiftUI

struct MonitorSettingsView: View {
    let server: ServerConfig

    @State private var settings = MonitorSettings()
    @State private var isLoading = true
    @State private var netOptions: [String] = []
    @State private var ioOptions: [String] = []
    @State private var toastMessage: String?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showCleanConfirm = false

    /// 采集间隔（分钟；UI 固定单位，提交换算回秒）
    @State private var intervalMinutesText = "5"

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        List {
            monitorSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("监控设置"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadAll() }
        .refreshable { await loadAll() }
        .toastOverlay(message: $toastMessage)
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(L10n.t("清空监控记录"), isPresented: $showCleanConfirm) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("清空"), role: .destructive) {
                Task { await cleanMonitor() }
            }
        } message: {
            Text(L10n.t("将删除全部历史监控数据，该操作无法回滚，是否继续？"))
        }
    }

    // MARK: 监控设置

    private var monitorSection: some View {
        Section {
            Toggle(L10n.t("监控状态"), isOn: Binding(
                get: { settings.monitorStatus },
                set: { on in
                    settings.monitorStatus = on
                    update(key: "MonitorStatus", value: on ? "Enable" : "Disable")
                }))
            OutlinedUnitField(label: L10n.t("保存天数"), unit: L10n.t("天"),
                              text: storeDaysText, range: 1...365)
                .onSubmit {
                    // 回车提交（输入即时钳制在 1...365）
                    update(key: "MonitorStoreDays", value: String(settings.storeDays))
                }
            OutlinedUnitField(label: L10n.t("采集间隔"), unit: L10n.t("分钟"),
                              text: $intervalMinutesText, range: 1...1440)
                .onSubmit { submitInterval() }
            OutlinedPicker(label: L10n.t("默认网卡"),
                           options: netOptions.isEmpty ? [""] : netOptions,
                           selection: Binding(
                               get: { settings.defaultNetwork },
                               set: { settings.defaultNetwork = $0; update(key: "DefaultNetwork", value: $0) }),
                           optionLabels: Self.deviceOptionLabels(netOptions))
            OutlinedPicker(label: L10n.t("默认磁盘"),
                           options: ioOptions.isEmpty ? [""] : ioOptions,
                           selection: Binding(
                               get: { settings.defaultIO },
                               set: { settings.defaultIO = $0; update(key: "DefaultIO", value: $0) }),
                           optionLabels: Self.deviceOptionLabels(ioOptions))
            Button(role: .destructive) {
                showCleanConfirm = true
            } label: {
                Label(L10n.t("清空监控记录"), systemImage: "trash")
            }
        } header: {
            SectionLabel(title: L10n.t("监控设置"), systemImage: "chart.line.uptrend.xyaxis")
        }
    }

    // MARK: 虚拟内存（Swap）已移至 面板 → 设置 → 基础设置（DeviceSwapSection）

    // MARK: 数据加载

    /// 保存天数 Int ↔ String（OutlinedUnitField 用）
    private var storeDaysText: Binding<String> {
        Binding<String>(get: { String(settings.storeDays) },
                        set: { settings.storeDays = Int($0) ?? settings.storeDays })
    }

    /// 网卡/磁盘选项显示名（all → 所有）
    private static func deviceOptionLabels(_ options: [String]) -> [String: String] {
        var labels: [String: String] = [:]
        for option in options { labels[option] = option == "all" ? L10n.t("所有") : option }
        return labels
    }

    private func loadAll() async {
        // GET setting 响应按扁平字典防御性解码（键大小写不敏感）
        if let dict: [String: String] = try? await client.send(
            path: APIEndpoint.hostsMonitorSettingGet.path, method: "GET", as: [String: String].self) {
            let loaded = MonitorSettings.from(dict: dict)
            settings = loaded
            // 秒 → 分钟（不足 1 分钟按 1 计）
            intervalMinutesText = String(max(1, loaded.interval / 60))
        }
        if let nets: [String] = try? await client.send(
            path: APIEndpoint.monitorNetOptions.path, method: "GET", as: [String].self) {
            netOptions = nets
        }
        if let ios: [String] = try? await client.send(
            path: APIEndpoint.monitorIOOptions.path, method: "GET", as: [String].self) {
            ioOptions = ios
        }
        isLoading = false
    }

    private var intervalSeconds: Int {
        (Int(intervalMinutesText) ?? 5) * 60
    }

    private func submitInterval() {
        update(key: "MonitorInterval", value: String(intervalSeconds))
    }

    /// 单项设置提交（{key,value}，抓包确认）
    private func update(key: String, value: String) {
        Task {
            do {
                let _: EmptyResponse = try await client.send(
                    path: APIEndpoint.hostsMonitorSettingUpdate.path,
                    body: MonitorSettingUpdateRequest(key: key, value: value),
                    as: EmptyResponse.self)
            } catch {
                guard !APIError.isCancellation(error) else { return }
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func cleanMonitor() async {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.hostsMonitorClean.path, as: EmptyResponse.self)
            toastMessage = L10n.t("已清空监控记录")
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    static func fmt(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(bytes)
        var idx = 0
        while size >= 1024 && idx < units.count - 1 {
            size /= 1024
            idx += 1
        }
        return String(format: "%.2f %@", size, units[idx])
    }
}

// MARK: - 虚拟内存（Swap）设置页（基础设置入口推入）

/// 自包含 Swap 管理页：加载 device/base、展示统计与明细、提交调整（任务进度）
struct DeviceSwapSettingsView: View {
    let server: ServerConfig

    @State private var device: DeviceBase?
    @State private var errorMessage: String?
    @State private var showError = false
    /// Swap 调整任务
    @State private var swapTask: SwapTaskTarget?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        Form {
            Section {
                if let device {
                    InfoRow(L10n.t("Swap 总数"), value: MonitorSettingsView.fmt(device.swapMemoryTotal ?? 0))
                    InfoRow(L10n.t("Swap 已用"), value: MonitorSettingsView.fmt(device.swapMemoryUsed ?? 0))
                    InfoRow(L10n.t("Swap 空闲"), value: MonitorSettingsView.fmt(device.swapMemoryAvailable ?? 0))
                    ForEach(device.swapDetails ?? []) { detail in
                        SwapDetailRow(
                            detail: detail,
                            maxSizeGB: device.maxSize.map { Double($0) / 1024 / 1024 / 1024 } ?? 8) { path, sizeKB in
                            Task { await updateSwap(path: path, sizeKB: sizeKB) }
                        }
                    }
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 12)
                }
            } header: {
                SectionLabel(title: L10n.t("虚拟内存"), systemImage: "memorychip")
            } footer: {
                Text(L10n.t("调整 Swap 大小需要重建交换分区，期间可能短暂占用磁盘与 CPU"))
            }
        }
        .navigationTitle(L10n.t("虚拟内存"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadDevice() }
        .task { await loadDevice() }
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .navigationDestination(item: $swapTask) { target in
            TaskProgressView(taskID: target.taskID, title: target.title) { isDone in
                if isDone { Task { await loadDevice() } }
                return false
            }
        }
    }

    private func loadDevice() async {
        if let base: DeviceBase = try? await client.send(
            path: APIEndpoint.toolboxDeviceBase.path, as: DeviceBase.self) {
            device = base
        }
    }

    /// 调整 Swap（size KB；used 回传原字符串；任务进度）
    private func updateSwap(path: String, sizeKB: Int) async {
        let taskID = UUID().uuidString
        let used = device?.swapDetails?.first(where: { $0.path == path })?.used ?? "0"
        let isNew = device?.swapDetails?.first(where: { $0.path == path })?.isNew ?? false
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.toolboxDeviceUpdateSwap.path,
                body: SwapUpdateRequest(path: path, size: sizeKB, used: used, isNew: isNew, taskID: taskID),
                as: EmptyResponse.self)
            swapTask = SwapTaskTarget(taskID: taskID, title: L10n.f("设置 Swap %@", path))
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

/// Swap 任务目标
struct SwapTaskTarget: Identifiable, Hashable {
    let taskID: String
    let title: String
    var id: String { taskID }
}

/// 单个 Swap 行：路径 + 大小(GB)编辑 + 已用 + 保存
private struct SwapDetailRow: View {
    let detail: SwapDetail
    let maxSizeGB: Double
    let onSave: (String, Int) -> Void

    @State private var sizeGBText: String = ""
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(detail.path)
                    .font(.dataMonospaced)
                Spacer()
                Text(L10n.t("已用") + " " + MonitorSettingsView.fmt(Int64(detail.usedKB) * 1024))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(L10n.t("大小"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("2", text: $sizeGBText)
                    .keyboardType(.numberPad)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                Text("GB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.t("保存")) {
                    let gb = Double(sizeGBText) ?? 0
                    let kb = Int((gb * 1024 * 1024).rounded())
                    onSave(detail.path, kb)
                }
                .buttonStyle(.bordered)
                .disabled(sizeGBText.isEmpty)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            guard !appeared else { return }
            appeared = true
            sizeGBText = String(format: "%.1f", detail.sizeGB)
        }
    }
}
