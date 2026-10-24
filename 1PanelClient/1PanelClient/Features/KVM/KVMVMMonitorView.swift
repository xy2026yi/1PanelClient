//
//  KVMVMMonitorView.swift
//  1PanelClient
//
//  虚拟机实时监控图表页（POST /xpack/vms/stats，入口在虚拟机卡片「监控」按钮，仅运行态）：
//  与容器监控（ContainerMonitorView）同款四张曲线图——CPU 使用率 / 内存(已用 MB) /
//  磁盘 I/O(读·写 MB/s) / 网络(接收·发送 KB/s)。stats 为累计型计数（cpuTime 纳秒、
//  磁盘与网络字节），CPU% 与速率由相邻两次采样求差得出，3 秒一采（首个样本无差值，
//  从第二次采样起进图）；内存已用 = actual - unused。图表复用 ContainerMonitorChart
//  （固定 12 采样位窗口 + 点选数值气泡）。
//

import SwiftUI

struct KVMVMMonitorView: View {
    @ObservedObject var vm: KVMViewModel
    /// 进入时的快照；状态实时取列表对象
    let initial: KVMVirtualMachine

    @Environment(\.scenePhase) private var scenePhase
    @State private var isSceneActive = true

    // 采样曲线
    @State private var cpuPoints: [MonitorPoint] = []        // CPU %
    @State private var memPoints: [MonitorPoint] = []        // 已用内存 MB
    @State private var ioReadPoints: [MonitorPoint] = []     // 读取 MB/s
    @State private var ioWritePoints: [MonitorPoint] = []    // 写入 MB/s
    @State private var netRxPoints: [MonitorPoint] = []      // 接收 KB/s
    @State private var netTxPoints: [MonitorPoint] = []      // 发送 KB/s
    /// 上一次采样（供下一次求差）
    @State private var lastStats: KVMStats?
    @State private var hasData = false
    @State private var loadError: String?
    /// 已有数据后连续失败计数（到阈值轻提示一次，不中断图表）
    @State private var consecutiveFailures = 0
    @State private var toastMessage: String?

    init(vm: KVMViewModel, machine: KVMVirtualMachine) {
        self.vm = vm
        self.initial = machine
    }

    private var machine: KVMVirtualMachine {
        vm.vms.first { $0.id == initial.id } ?? initial
    }

    var body: some View {
        Group {
            if !machine.isRunning {
                ContentUnavailableView(
                    L10n.t("虚拟机未运行"),
                    systemImage: "desktopcomputer",
                    description: Text(L10n.t("虚拟机运行后才有实时监控数据"))
                )
            } else if let loadError, !hasData {
                ContentUnavailableView(
                    L10n.t("获取监控数据失败"),
                    systemImage: "exclamationmark.triangle.fill",
                    description: Text(loadError)
                )
            } else {
                chartList
            }
        }
        .navigationTitle(L10n.t("监控"))
        .navigationBarTitleDisplayMode(.inline)
        .toastOverlay(message: $toastMessage,
                      systemImage: "exclamationmark.triangle.fill",
                      iconColor: .orange)
        .onChange(of: scenePhase) { _, phase in
            isSceneActive = phase == .active
        }
        // 3 秒轮询（App 前台活跃时；关机 / 暂停态接口无意义，body 切占位页自然停采）
        .task(id: machine.id) {
            while !Task.isCancelled {
                if isSceneActive, machine.isRunning {
                    await sample()
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var chartList: some View {
        List {
            monitorSection("CPU", icon: "cpu", single: cpuPoints, color: .blue, unit: "%", yCap: 100)
            monitorSection(L10n.t("内存"), icon: "memorychip", single: memPoints, color: .purple, unit: "MB")
            monitorSection(L10n.t("磁盘 I/O"), icon: "macpro.gen2", dual: ioSeries,
                           styles: [L10n.t("读取"): .blue, L10n.t("写入"): .orange], unit: "MB/s")
            monitorSection(L10n.t("网络"), icon: "wifi.router", dual: netSeries,
                           styles: [L10n.t("接收"): .green, L10n.t("发送"): .purple], unit: "KB/s")
        }
        .environment(\.defaultMinListRowHeight, 32)
    }

    private var ioSeries: [LoadSeriesPoint] {
        ioReadPoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: L10n.t("读取")) }
            + ioWritePoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: L10n.t("写入")) }
    }

    private var netSeries: [LoadSeriesPoint] {
        netRxPoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: L10n.t("接收")) }
            + netTxPoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: L10n.t("发送")) }
    }

    // MARK: 图表区（标题 + 图表，与容器监控同构）

    @ViewBuilder
    private func monitorSection(
        _ title: String,
        icon: String,
        single: [MonitorPoint] = [],
        color: Color = .blue,
        dual: [LoadSeriesPoint] = [],
        styles: KeyValuePairs<String, Color> = [:],
        unit: String,
        yCap: Double? = nil
    ) -> some View {
        Section {
            HStack {
                Label(title, systemImage: icon)
                    .font(.headline)
                Spacer()
            }
            .padding(.top, 8)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

            Group {
                if !dual.isEmpty {
                    ContainerMonitorChart(points: dual, styles: styles, unit: unit, yCap: yCap)
                } else if !single.isEmpty {
                    ContainerMonitorChart(
                        points: single.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: title) },
                        styles: [title: color],
                        unit: unit,
                        yCap: yCap
                    )
                } else {
                    ChartEmptyPlaceholder(text: L10n.t("暂无数据"), height: 120)
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 8)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        }
    }

    // MARK: 采样

    private func sample() async {
        do {
            let current = try await vm.stats(machine)
            loadError = nil
            consecutiveFailures = 0
            // 求差得到 CPU% 与速率；首个样本无前值，仅记内存与累计基线
            let date = Date()
            if let cpu = KVMStats.cpuPercent(previous: lastStats, current: current) {
                push(.init(date: date, value: cpu), into: &cpuPoints)
            }
            if let usedKiB = current.memory?.usedKiB {
                push(.init(date: date, value: Double(usedKiB) / 1024), into: &memPoints)
            }
            if let read = KVMStats.rate(previous: lastStats.map { ($0.disk?.readBytes, $0.timestamp) },
                                        current: (current.disk?.readBytes, current.timestamp)) {
                push(.init(date: date, value: read / 1024 / 1024), into: &ioReadPoints)
            }
            if let write = KVMStats.rate(previous: lastStats.map { ($0.disk?.writeBytes, $0.timestamp) },
                                         current: (current.disk?.writeBytes, current.timestamp)) {
                push(.init(date: date, value: write / 1024 / 1024), into: &ioWritePoints)
            }
            if let rx = KVMStats.rate(previous: lastStats.map { ($0.network?.rxBytes, $0.timestamp) },
                                      current: (current.network?.rxBytes, current.timestamp)) {
                push(.init(date: date, value: rx / 1024), into: &netRxPoints)
            }
            if let tx = KVMStats.rate(previous: lastStats.map { ($0.network?.txBytes, $0.timestamp) },
                                      current: (current.network?.txBytes, current.timestamp)) {
                push(.init(date: date, value: tx / 1024), into: &netTxPoints)
            }
            lastStats = current
            hasData = true
        } catch {
            guard !APIError.isCancellation(error) else { return }
            if !hasData {
                loadError = error.localizedDescription
            } else {
                consecutiveFailures += 1
                if consecutiveFailures == 3 {
                    toastMessage = L10n.t("监控数据获取失败，图表显示为最近数据")
                    consecutiveFailures = 0
                }
            }
        }
    }

    private func push(_ point: MonitorPoint, into points: inout [MonitorPoint]) {
        points.append(point)
        if points.count > MonitorSlotWindow.slotCount {
            points.removeFirst(points.count - MonitorSlotWindow.slotCount)
        }
    }
}
