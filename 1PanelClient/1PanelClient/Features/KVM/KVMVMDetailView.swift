//
//  KVMVMDetailView.swift
//  1PanelClient
//
//  虚拟机详情（logs/高级功能-KVM.md 抓包 2026-10-23）：状态 / 基本信息 /
//  磁盘与网卡。工具栏：电源菜单。控制台与健康检查入口在虚拟机卡片快捷按钮
//  （KVMVMListView），监控 / 快照 / 磁盘管理为独立页。
//

import SwiftUI

struct KVMVMDetailView: View {
    @ObservedObject var vm: KVMViewModel
    /// 进入时的快照；展示时优先取列表里的实时对象（电源操作后状态随刷新变化）
    let initial: KVMVirtualMachine

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
    }

    // MARK: 状态

    private var statusSection: some View {
        Section {
            HStack {
                Text(L10n.t("状态"))
                Spacer()
                KVMStatusBadge(status: machine.status)
            }
        } footer: {
            Text(L10n.t("控制台与健康检查入口在虚拟机列表卡片上。"))
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
                        HStack(spacing: 8) {
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
