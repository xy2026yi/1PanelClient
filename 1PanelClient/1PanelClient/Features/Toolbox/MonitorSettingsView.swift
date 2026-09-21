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

    /// 采集间隔：数值 + 单位（s/m/h，提交换算回秒）
    @State private var intervalValueText = "5"
    @State private var intervalUnit = "m"
    private let intervalUnitOptions = ["s", "m", "h"]
    /// 加载时的原值（脏检查：失焦/回车仅在改动后提交，避免每次聚焦都发请求）
    @State private var loadedStoreDays = 0
    @State private var loadedIntervalSeconds = 0

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
            // numberPad 无回车键：失焦（onCommit）为主提交时机，onSubmit 兜底外接键盘
            OutlinedUnitField(label: L10n.t("保存天数"), unit: L10n.t("天"),
                              text: storeDaysText, range: 1...365,
                              onCommit: { Task { await commitStoreDays() } })
                .onSubmit { Task { await commitStoreDays() } }
            OutlinedUnitField(label: L10n.t("采集间隔"), unit: "",
                              text: $intervalValueText, range: intervalRange,
                              onCommit: { Task { await commitInterval() } })
                .onSubmit { Task { await commitInterval() } }
            OutlinedPicker(label: L10n.t("间隔单位"),
                           options: intervalUnitOptions, selection: $intervalUnit,
                           optionLabels: ["s": L10n.t("秒"),
                                          "m": L10n.t("分钟"),
                                          "h": L10n.t("小时")])
                // 单位单独切换也提交（该页无保存按钮，切单位后不再碰数值框时不丢改动）
                .onChange(of: intervalUnit) { _, _ in Task { await commitInterval() } }
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
            // 秒 → 数值+单位（整除取大单位，原值可整除时往返无损）
            if loaded.interval % 3600 == 0, loaded.interval >= 3600 {
                intervalUnit = "h"
                intervalValueText = String(max(1, loaded.interval / 3600))
            } else if loaded.interval % 60 == 0 {
                intervalUnit = "m"
                intervalValueText = String(max(1, loaded.interval / 60))
            } else {
                intervalUnit = "s"
                intervalValueText = String(max(1, loaded.interval))
            }
            loadedStoreDays = loaded.storeDays
            loadedIntervalSeconds = loaded.interval
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

    /// 单位 → 秒
    private static func intervalUnitSeconds(_ unit: String) -> Int {
        switch unit {
        case "s": return 1
        case "h": return 3600
        default:  return 60
        }
    }

    /// 数值范围随单位缩放（总量上限 24 小时 = 原 1440 分钟上限）
    private var intervalRange: ClosedRange<Int> {
        switch intervalUnit {
        case "h": return 1...24
        case "m": return 1...1440
        default:  return 1...86400
        }
    }

    private var intervalSeconds: Int {
        // 切换单位不换算数值，组合可能超上限（如 90 切到「小时」），按 24h 钳制
        min(max((Int(intervalValueText) ?? 5) * Self.intervalUnitSeconds(intervalUnit), 1), 86400)
    }

    private func submitInterval() {
        update(key: "MonitorInterval", value: String(intervalSeconds))
    }

    /// 保存天数脏检查提交（失焦/回车共用；成功后才更新基线，失败可原值重试）
    private func commitStoreDays() async {
        guard settings.storeDays != loadedStoreDays else { return }
        let newValue = settings.storeDays
        if await updateSetting(key: "MonitorStoreDays", value: String(newValue)) {
            loadedStoreDays = newValue
        }
    }

    /// 采集间隔脏检查提交（失焦/回车/单位切换共用；数值或单位变化都算脏）
    private func commitInterval() async {
        guard intervalSeconds != loadedIntervalSeconds else { return }
        let newValue = intervalSeconds
        if await updateSetting(key: "MonitorInterval", value: String(newValue)) {
            loadedIntervalSeconds = newValue
        }
    }

    /// 单项设置提交（{key,value}，抓包确认）；返回是否成功
    @discardableResult
    private func updateSetting(key: String, value: String) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.hostsMonitorSettingUpdate.path,
                body: MonitorSettingUpdateRequest(key: key, value: value),
                as: EmptyResponse.self)
            return true
        } catch {
            guard !APIError.isCancellation(error) else { return false }
            errorMessage = error.localizedDescription
            showError = true
            return false
        }
    }

    /// 单项设置提交（fire-and-forget，开关/网卡/磁盘等无需回执的调用方）
    private func update(key: String, value: String) {
        Task { await updateSetting(key: key, value: value) }
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
                    ForEach(swapDetailsForDisplay) { detail in
                        NavigationLink {
                            SwapEditView(detail: detail) { path, sizeKB in
                                Task { await updateSwap(path: path, sizeKB: sizeKB) }
                            }
                        } label: {
                            SwapDetailRow(detail: detail)
                        }
                        .buttonStyle(.plain)
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

    /// 展示用明细：网页端固定展示默认交换文件 /opt/.1panel_swap（0MB），
    /// 接口未返回该条时补一条合成行（与网页端一致；点入编辑即创建）
    private var swapDetailsForDisplay: [SwapDetail] {
        var list = device?.swapDetails ?? []
        let defaultPath = "/opt/.1panel_swap"
        if !list.contains(where: { $0.path == defaultPath }) {
            list.append(SwapDetail(path: defaultPath, size: 0, used: "0",
                                   isNew: nil, taskID: nil))
        }
        return list
    }

    /// 调整 Swap（size KB；used 回传原字符串；任务进度）
    private func updateSwap(path: String, sizeKB: Int) async {
        let taskID = UUID().uuidString
        let detail = device?.swapDetails?.first(where: { $0.path == path })
        let used = detail?.used ?? "0"
        // 接口未返回该路径（如网页端默认 /opt/.1panel_swap）按新建提交
        let isNew = detail?.isNew ?? true
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

/// 单个 Swap 行（点击进入修改总数）：
/// 上=路径（高度居中于两行内容），下=总数（2 位小数）+ 已用
private struct SwapDetailRow: View {
    let detail: SwapDetail

    /// KB → GB（2 位小数显示；1.9 → 1.87 类还原真实容量）
    private var sizeGBText2: String {
        String(format: "%.2f", detail.sizeGB)
    }

    var body: some View {
        HStack(alignment: .center) {
            Text(detail.path)
                .font(.dataMonospaced)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(L10n.t("总数") + " " + sizeGBText2 + " GB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.t("已用") + " " + MonitorSettingsView.fmt(Int64(detail.usedKB) * 1024))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// Swap 总数编辑页（形态 1）：路径只读 + 总数（MB，能被 4 整除换算 KB，
/// 0=关闭该 Swap；服务端最小 40KB）
struct SwapEditView: View {
    let detail: SwapDetail
    let onSave: (String, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sizeValueText: String = ""
    /// 总数单位（K/M/G，提交换算回 KB）
    @State private var sizeUnit = "M"
    private let sizeUnitOptions = ["K", "M", "G"]
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var isSaving = false

    var body: some View {
        Form {
            Section {
                OutlinedShape(label: L10n.t("路径"), isFocused: false,
                              hasValue: !detail.path.isEmpty,
                              trailing: { EmptyView() }) {
                    Text(detail.path)
                        .font(.dataMonospacedBody)
                        .lineLimit(1)
                }
                OutlinedUnitField(label: L10n.t("总数"), unit: "",
                                  text: $sizeValueText)
                OutlinedPicker(label: L10n.t("单位"),
                               options: sizeUnitOptions, selection: $sizeUnit,
                               optionLabels: ["K": "KB", "M": "MB", "G": "GB"])
            } footer: {
                Text(L10n.t("分区大小最小值为 40 KB，设置成 0 则关闭 Swap 分区。"))
            }
        }
        .navigationTitle(L10n.t("修改 Swap"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    save()
                } label: {
                    if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                }
                .disabled(sizeValueText.isEmpty || isSaving)
            }
        }
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            // KB → 数值+单位：整除取大单位（原值可整除时往返无损）
            if detail.size % (1024 * 1024) == 0, detail.size >= 1024 * 1024 {
                sizeUnit = "G"
                sizeValueText = String(detail.size / 1024 / 1024)
            } else if detail.size % 1024 == 0 {
                sizeUnit = "M"
                sizeValueText = String(detail.size / 1024)
            } else {
                sizeUnit = "K"
                sizeValueText = String(detail.size)
            }
        }
    }

    /// 单位 → KB
    private static func sizeUnitKB(_ unit: String) -> Int {
        switch unit {
        case "K": return 1
        case "G": return 1024 * 1024
        default:  return 1024
        }
    }

    private func save() {
        guard let value = Int(sizeValueText), value >= 0 else {
            errorMessage = L10n.t("请输入有效的数值")
            showError = true
            return
        }
        let kb = value * Self.sizeUnitKB(sizeUnit)
        if kb != 0 && kb < 40 {
            errorMessage = L10n.t("分区大小最小值为 40 KB，设置成 0 则关闭 Swap 分区。")
            showError = true
            return
        }
        if kb % 4 != 0 {
            errorMessage = L10n.t("大小需要能被 4 整除")
            showError = true
            return
        }
        isSaving = true
        onSave(detail.path, kb)
        dismiss()
    }
}
