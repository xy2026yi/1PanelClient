//
//  KVMVMDetailView.swift
//  1PanelClient
//
//  虚拟机详情（logs/高级功能-KVM.md 抓包 2026-10-23）：状态与控制台信息 / 基本信息 /
//  磁盘与网卡 / 快照（列表·创建·恢复，恢复仅关机态）/ 健康检查（POST health/check，
//  按 PASS/WARN/FAIL 列项）。工具栏菜单提供电源操作。实时监控已独立为图表页
//  KVMVMMonitorView（入口在虚拟机列表长按菜单），详情页不再内嵌数值监控。
//  VNC 控制台（二进制 RFB over WS）暂不实现，仅展示 type/port/listen。
//

import SwiftUI

struct KVMVMDetailView: View {
    @ObservedObject var vm: KVMViewModel
    /// 进入时的快照；展示时优先取列表里的实时对象（电源操作后状态随刷新变化）
    let initial: KVMVirtualMachine

    // 快照
    @State private var snapshots: [KVMSnapshot] = []
    @State private var snapshotsLoaded = false
    @State private var snapshotError: String?
    @State private var showCreateSnapshot = false
    @State private var recoverTarget: KVMSnapshot?

    // 健康检查
    @State private var healthReport: KVMHealthReport?
    @State private var isCheckingHealth = false
    @State private var showHealth = false

    // 电源操作
    @State private var pendingOperate: KVMOperate?

    init(vm: KVMViewModel, machine: KVMVirtualMachine) {
        self.vm = vm
        self.initial = machine
    }

    private var machine: KVMVirtualMachine {
        vm.vms.first { $0.id == initial.id } ?? initial
    }

    var body: some View {
        List {
            statusSection
            infoSection
            devicesSection
            snapshotSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(machine.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(KVMOperate.available(for: machine)) { operate in
                        Button(role: operate == .destroy ? .destructive : nil) {
                            if operate == .start || operate == .resume {
                                Task { await vm.operate(machine, operate) }
                            } else {
                                pendingOperate = operate
                            }
                        } label: {
                            Label(operate.displayName, systemImage: operate.icon)
                        }
                    }
                } label: {
                    if vm.operatingIDs.contains(machine.id) {
                        ProgressView()
                    } else {
                        Image(systemName: "power.circle")
                    }
                }
                .accessibilityLabel(L10n.t("电源操作"))
            }
        }
        .refreshable {
            await vm.loadVMs()
            await loadSnapshots()
        }
        .task(id: machine.id) {
            await loadSnapshots()
        }
        .alert(
            pendingOperate?.displayName ?? "",
            isPresented: Binding(get: { pendingOperate != nil }, set: { if !$0 { pendingOperate = nil } })
        ) {
            Button(L10n.t("取消"), role: .cancel) { pendingOperate = nil }
            Button(L10n.t("确认"), role: .destructive) {
                Haptic.warning()
                if let operate = pendingOperate {
                    Task { await vm.operate(machine, operate) }
                }
                pendingOperate = nil
            }
        } message: {
            if let operate = pendingOperate {
                Text(L10n.f("将对虚拟机「%@」执行 %@ 操作，是否继续？", machine.displayName, operate.displayName))
            }
        }
        .alert(L10n.t("恢复快照"), isPresented: Binding(
            get: { recoverTarget != nil }, set: { if !$0 { recoverTarget = nil } })
        ) {
            Button(L10n.t("取消"), role: .cancel) { recoverTarget = nil }
            Button(L10n.t("恢复"), role: .destructive) {
                Haptic.warning()
                if let snapshot = recoverTarget {
                    Task { await vm.recoverSnapshot(machine, snapshotName: snapshot.name ?? "") }
                }
                recoverTarget = nil
            }
        } message: {
            if let snapshot = recoverTarget {
                Text(L10n.f("将把虚拟机「%@」的磁盘恢复到快照「%@」，当前磁盘内容会被覆盖，是否继续？",
                            machine.displayName, snapshot.name ?? "-"))
            }
        }
        .sheet(isPresented: $showCreateSnapshot) {
            KVMSnapshotCreateSheet(machine: machine) { snapshotName, description in
                await vm.createSnapshot(machine, snapshotName: snapshotName, description: description) != nil
            }
        }
        .sheet(isPresented: $showHealth) {
            if let report = healthReport {
                KVMHealthReportSheet(machine: machine, report: report)
            }
        }
    }

    // MARK: 状态 / 控制台 / 健康检查

    private var statusSection: some View {
        Section {
            HStack {
                Text(L10n.t("状态"))
                Spacer()
                KVMStatusBadge(status: machine.status)
            }
            if let graphics = machine.graphics {
                InfoRow(L10n.t("控制台"),
                        value: "\((graphics.type ?? "vnc").uppercased()) \(graphics.listen ?? "-"):\(graphics.port ?? "-")",
                        monospaced: true)
            }
            Button {
                Task { await runHealthCheck() }
            } label: {
                HStack {
                    Label(L10n.t("健康检查"), systemImage: "stethoscope")
                    Spacer()
                    if isCheckingHealth {
                        ProgressView()
                    } else if let report = healthReport {
                        healthSummary(report)
                    }
                }
            }
            .disabled(isCheckingHealth)
        } footer: {
            Text(L10n.t("VNC 控制台请在面板网页端打开；此处仅展示监听地址与端口。"))
        }
    }

    private func healthSummary(_ report: KVMHealthReport) -> some View {
        HStack(spacing: 6) {
            if (report.fail ?? 0) > 0 {
                StatusBadge(text: L10n.f("%ld 失败", report.fail ?? 0), color: .statusError)
            }
            if (report.warn ?? 0) > 0 {
                StatusBadge(text: L10n.f("%ld 警告", report.warn ?? 0), color: .orange)
            }
            StatusBadge(text: L10n.f("%ld 通过", report.pass ?? 0), color: .statusRunning)
        }
    }

    // MARK: 基本信息

    private var infoSection: some View {
        Section {
            InfoRow("UUID", value: machine.uuid ?? "-", monospaced: true)
            InfoRow("CPU", value: L10n.f("%ld 核", machine.cpu ?? 0))
            InfoRow(L10n.t("内存"), value: "\(machine.memory ?? 0) MB")
            InfoRow(L10n.t("磁盘容量"), value: "\(machine.diskSize ?? 0) GB")
            InfoRow(L10n.t("磁盘总线"), value: KVMDiskBus(rawValue: machine.diskBus ?? "")?.displayName ?? (machine.diskBus ?? "-"))
            if let path = machine.diskPath, !path.isEmpty {
                InfoRow(L10n.t("磁盘路径"), value: path, monospaced: true)
            }
            InfoRow(L10n.t("存储池"), value: machine.storagePool ?? "-")
            InfoRow(L10n.t("网络"), value: machine.network ?? "-")
            InfoRow(L10n.t("启动项"), value: KVMBootOrder(rawValue: machine.bootOrder ?? "")?.displayName ?? (machine.bootOrder ?? "-"))
            if let isos = machine.isoPaths, !isos.isEmpty {
                InfoRow(L10n.t("镜像"), value: isos.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "),
                        monospaced: true)
            }
            InfoRow(L10n.t("开机自启"), value: machine.autoStart == true ? L10n.t("开启") : L10n.t("关闭"))
            if let description = machine.description, !description.isEmpty {
                InfoRow(L10n.t("描述"), value: description)
            }
        } header: {
            SectionLabel(title: L10n.t("基本信息"), systemImage: "info.circle")
        }
    }

    // MARK: 磁盘 / 网卡

    @ViewBuilder
    private var devicesSection: some View {
        if let disks = machine.disks, !disks.isEmpty {
            Section {
                ForEach(Array(disks.enumerated()), id: \.offset) { _, disk in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: disk.device == "cdrom" ? "opticaldisc" : "internaldrive")
                                .foregroundStyle(.secondary)
                            Text("\(disk.target ?? "-") · \(disk.bus ?? "-") · \(disk.format ?? "-")")
                                .font(.subheadline.weight(.medium))
                            if disk.readOnly == true {
                                StatusBadge(text: L10n.t("只读"), color: .secondary)
                            }
                        }
                        Text(disk.source ?? "-")
                            .font(.dataMonospacedFootnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                SectionLabel(title: L10n.t("磁盘"), systemImage: "internaldrive")
            }
        }
        if let interfaces = machine.interfaces, !interfaces.isEmpty {
            Section {
                ForEach(Array(interfaces.enumerated()), id: \.offset) { _, iface in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(iface.source ?? "-") · \(iface.model ?? "-")")
                            .font(.subheadline.weight(.medium))
                        HStack(spacing: 8) {
                            Text(iface.mac ?? "-")
                            if let ip = iface.ip, !ip.isEmpty {
                                Text(ip)
                            }
                        }
                        .font(.dataMonospacedFootnote)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                SectionLabel(title: L10n.t("网卡"), systemImage: "network")
            }
        }
    }

    // MARK: 快照

    private var snapshotSection: some View {
        Section {
            if snapshots.isEmpty {
                if !snapshotsLoaded {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let snapshotError {
                    Text(snapshotError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.t("暂无快照"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(snapshots) { snapshot in
                    snapshotRow(snapshot)
                }
            }
            Button {
                showCreateSnapshot = true
            } label: {
                Label(L10n.t("创建快照"), systemImage: "camera.badge.clock")
            }
        } header: {
            SectionLabel(title: L10n.t("快照"), systemImage: "camera.on.rectangle")
        } footer: {
            Text(L10n.t("恢复快照需先关机；长按快照行执行恢复。"))
        }
    }

    private func snapshotRow(_ snapshot: KVMSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(snapshot.name ?? "-")
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if snapshot.current == true {
                    StatusBadge(text: L10n.t("当前"), color: .statusRunning)
                }
                Spacer()
                if let size = snapshot.size {
                    Text(bytesText(size))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                if let date = snapshot.createdDate {
                    Text(Self.dateFormatter.string(from: date))
                }
                if let state = snapshot.state, !state.isEmpty {
                    Text(state)
                }
                if let children = snapshot.children, children > 0 {
                    Text(L10n.f("%ld 个子快照", children))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let description = snapshot.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.5) {
            Haptic.selection()
            requestRecover(snapshot)
        }
        .accessibilityAction(named: L10n.t("恢复快照")) {
            requestRecover(snapshot)
        }
    }

    /// 恢复仅关机态可用：运行中长按给出提示而非静默
    private func requestRecover(_ snapshot: KVMSnapshot) {
        guard machine.isShutOff else {
            vm.alertMessage = L10n.t("恢复快照需先关闭虚拟机")
            vm.showAlert = true
            return
        }
        recoverTarget = snapshot
    }

    private func loadSnapshots() async {
        do {
            snapshots = try await vm.listSnapshots(machine)
            snapshotError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            snapshotError = error.localizedDescription
        }
        snapshotsLoaded = true
    }

    private func runHealthCheck() async {
        isCheckingHealth = true
        defer { isCheckingHealth = false }
        do {
            healthReport = try await vm.healthCheck(machine)
            showHealth = true
        } catch {
            guard !APIError.isCancellation(error) else { return }
            vm.alertMessage = L10n.f("健康检查失败：%@", error.localizedDescription)
            vm.showAlert = true
        }
    }

    private func bytesText(_ bytes: Int64) -> String {
        let parts = MetricFormat.byteParts(bytes)
        return "\(parts.value) \(parts.unit)"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

// MARK: - 创建快照

/// 快照名默认 snap-yyyyMMddHHmmss（对齐网页端自动填充）
struct KVMSnapshotCreateSheet: View {
    let machine: KVMVirtualMachine
    let onSubmit: (String, String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var snapshotName = KVMSnapshotNaming.defaultName()
    @State private var description = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    OutlinedTextField(label: L10n.t("快照名称"), text: $snapshotName)
                    OutlinedMultiLineField(label: L10n.t("描述"), lines: 3, text: $description)
                } footer: {
                    Text(L10n.f("为虚拟机「%@」创建磁盘快照；运行中创建会包含当前内存状态外的磁盘内容。", machine.displayName))
                }
            }
            .navigationTitle(L10n.t("创建快照"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            isSubmitting = true
                            defer { isSubmitting = false }
                            if await onSubmit(snapshotName.trimmingCharacters(in: .whitespaces), description) {
                                dismiss()
                            }
                        }
                    } label: {
                        if isSubmitting { ProgressView() } else { Text(L10n.t("创建")).bold() }
                    }
                    .disabled(snapshotName.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.medium])
    }
}

// MARK: - 健康检查报告

struct KVMHealthReportSheet: View {
    let machine: KVMVirtualMachine
    let report: KVMHealthReport

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        summaryColumn(L10n.t("通过"), report.pass ?? 0, .statusRunning)
                        summaryColumn(L10n.t("警告"), report.warn ?? 0, .orange)
                        summaryColumn(L10n.t("失败"), report.fail ?? 0, .statusError)
                    }
                    .padding(.vertical, 6)
                }
                Section {
                    ForEach(Array((report.items ?? []).enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: levelIcon(item.level))
                                .foregroundStyle(levelColor(item.level))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.checkDisplay)
                                if let subject = item.subject, !subject.isEmpty {
                                    Text(subject)
                                        .font(.dataMonospacedFootnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    SectionLabel(title: L10n.t("检查项"), systemImage: "checklist")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.f("健康检查 · %@", machine.displayName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("关闭")) { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func summaryColumn(_ title: String, _ count: Int, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(String(count))
                .font(.title2.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func levelIcon(_ level: String?) -> String {
        switch (level ?? "").uppercased() {
        case "PASS": return "checkmark.circle.fill"
        case "WARN": return "exclamationmark.triangle.fill"
        case "FAIL": return "xmark.circle.fill"
        default: return "questionmark.circle"
        }
    }

    private func levelColor(_ level: String?) -> Color {
        switch (level ?? "").uppercased() {
        case "PASS": return .statusRunning
        case "WARN": return .orange
        case "FAIL": return .statusError
        default: return .secondary
        }
    }
}
