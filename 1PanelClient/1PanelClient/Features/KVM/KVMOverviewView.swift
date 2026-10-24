//
//  KVMOverviewView.swift
//  1PanelClient
//
//  虚拟机管理·概览段（网页端同源数据，抓包 2026-10-24 逐项核对）：
//  状态计数 / 资源分配 / 风险提醒 / 存储池概况 四张卡。
//  - 状态计数：vms/search 全量（pageSize 10000）按桶计数（running/shutoff/过渡/
//    异常 + 挂起——挂起为主动 suspend，>0 时追加一格，不并入异常）；
//  - 资源分配：Σvm.cpu ÷ dashboardCurrent.cpuTotal、Σvm.memory(MB) ÷
//    dashboardCurrent.memoryTotal（抓包 12.95% 精确一致）、存储 Σ(池容量-可用)；
//  - 风险提醒：无专用 API（网页端同为前端推导）——异常 VM / 池未启用 / 池
//    使用率>90% / 池报错 / CPU·内存超分配；
//  - 存储池概况：storages/list 逐池行，点击跳存储池段；
//  - 工具栏右上角：孤立数据清理入口（KVMOrphansView，原虚拟机段菜单迁入）。
//

import SwiftUI

struct KVMOverviewView: View {
    @ObservedObject var vm: KVMViewModel

    @State private var showOrphans = false

    var body: some View {
        List {
            if vm.isLoading && vm.overview == nil {
                LoadingStateView()
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .listRowBackground(Color.clear)
            } else if vm.overview == nil, let error = vm.overviewError {
                Section {
                    ContentUnavailableView {
                        Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button(L10n.t("重试")) { Task { await vm.loadOverview() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                }
            } else if let overview = vm.overview {
                statusSection(overview)
                resourceSection(overview)
                riskSection(overview)
                storageSection
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await vm.loadOverview() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showOrphans = true
                } label: {
                    Image(systemName: "trash.slash")
                }
                .accessibilityLabel(L10n.t("孤立数据清理"))
            }
        }
        .navigationDestination(isPresented: $showOrphans) {
            KVMOrphansView(vm: vm)
        }
    }

    // MARK: 虚拟机状态

    private func statusSection(_ overview: KVMOverview) -> some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                statusChip(icon: "play.circle.fill", count: overview.runningCount,
                           label: L10n.t("已启动"), color: .green)
                statusChip(icon: "stop.circle", count: overview.stoppedCount,
                           label: L10n.t("已停止"), color: .secondary)
                statusChip(icon: "hourglass", count: overview.creatingCount,
                           label: L10n.t("创建中"), color: .blue)
                statusChip(icon: "exclamationmark.triangle.fill", count: overview.errorCount,
                           label: L10n.t("异常"), color: .orange)
                // 挂起为主动操作（不并入异常），有挂起时追加一格
                if overview.pausedCount > 0 {
                    statusChip(icon: "pause.circle", count: overview.pausedCount,
                               label: L10n.t("挂起"), color: .purple)
                }
            }
            .padding(.vertical, 4)
        } header: {
            SectionLabel(title: L10n.f("虚拟机状态（%ld）", overview.totalCount),
                         systemImage: "desktopcomputer")
        }
    }

    private func statusChip(icon: String, count: Int, label: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color == .secondary ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(color))
            Text("\(count)")
                .font(.title2.bold())
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: 资源分配

    private func resourceSection(_ overview: KVMOverview) -> some View {
        Section {
            // CPU：已分配核数 ÷ 宿主机核数（dashboardCurrent.cpuTotal）
            resourceRow(
                title: L10n.t("CPU 已分配"),
                valueText: L10n.f("%ld/%ld 核", overview.allocatedCPU, overview.hostCPUCount ?? 0),
                percent: overview.cpuPercent)
            // 内存：Σ vm.memory ÷ dashboardCurrent.memoryTotal（抓包 12.95% 精确一致）
            if overview.hostMemoryBytes != nil {
                resourceRow(
                    title: L10n.t("内存已分配"),
                    valueText: memoryText(overview.allocatedMemoryMB, host: overview.hostMemoryBytes!),
                    percent: overview.memoryPercent)
            } else {
                resourceRow(title: L10n.t("内存已分配"),
                            valueText: memoryText(overview.allocatedMemoryMB, host: nil),
                            percent: nil)
            }
            // 存储：Σ(池容量-可用) ÷ Σ池容量（storages/list）
            let (storageUsed, storageTotal) = storageTotals
            if storageTotal > 0 {
                resourceRow(
                    title: L10n.t("存储已使用"),
                    valueText: bytesText(storageUsed) + "/" + bytesText(storageTotal),
                    percent: Double(storageUsed) / Double(storageTotal) * 100)
            } else {
                resourceRow(title: L10n.t("存储已使用"), valueText: "-", percent: nil)
            }
        } header: {
            SectionLabel(title: L10n.t("资源分配"), systemImage: "gauge.with.dots.needle.50percent")
        }
    }

    private func resourceRow(title: String, valueText: String, percent: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.callout)
                Spacer()
                if let percent {
                    Text("\(valueText) \(String(format: "%.1f%%", percent))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(valueText)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let percent {
                ProgressView(value: min(max(percent / 100, 0), 1))
                    .tint(percent > 90 ? .red : .blue)
            }
        }
        .padding(.vertical, 2)
    }

    private func memoryText(_ mb: Int, host: Int64?) -> String {
        let used = bytesText(Int64(mb) * 1024 * 1024)
        guard let host else { return used }
        return used + "/" + bytesText(host)
    }

    private func bytesText(_ bytes: Int64) -> String {
        let parts = MetricFormat.byteParts(bytes)
        return "\(parts.value) \(parts.unit)"
    }

    /// Σ(容量-可用) / Σ容量（负值防御按 0 计）
    private var storageTotals: (used: Int64, total: Int64) {
        var used: Int64 = 0
        var total: Int64 = 0
        for pool in vm.storages {
            let capacity = max(pool.capacity ?? 0, 0)
            let available = min(max(pool.available ?? 0, 0), capacity)
            total += capacity
            used += capacity - available
        }
        return (used, total)
    }

    // MARK: 风险提醒

    private func riskSection(_ overview: KVMOverview) -> some View {
        let risks = KVMOverviewRisks.compute(overview: overview, pools: vm.storages)
        return Section {
            if risks.isEmpty {
                Label(L10n.t("暂无风险"), systemImage: "checkmark.seal.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                ForEach(risks) { risk in
                    Label(risk.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            SectionLabel(title: L10n.t("风险提醒"), systemImage: "shield.lefthalf.filled")
        }
    }

    // MARK: 存储池概况

    private var storageSection: some View {
        Section {
            if vm.storages.isEmpty {
                Text(L10n.t("暂无存储池"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vm.storages) { pool in
                    Button {
                        vm.segment = .storages   // 跳存储池段看操作入口
                    } label: {
                        poolRow(pool)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            SectionLabel(title: L10n.t("存储池概况"), systemImage: "internaldrive")
        }
    }

    private func poolRow(_ pool: KVMStoragePool) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "internaldrive", color: .gray)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(pool.displayName)
                        .font(.body.bold())
                        .lineLimit(1)
                    StatusBadge(text: pool.isActive ? L10n.t("已启用") : L10n.t("未启用"),
                                color: pool.isActive ? .statusRunning : .secondary)
                }
                HStack(spacing: 8) {
                    if let available = pool.available, available >= 0 {
                        Text(L10n.f("可用 %@", bytesText(available)))
                    }
                    if let percent = pool.usedPercent {
                        Text(L10n.f("使用率 %.1f%%", percent))
                    }
                    Text(L10n.f("%ld 台虚拟机", pool.vmCount ?? 0))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
