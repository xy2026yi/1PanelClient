//
//  KVMSnapshotListView.swift
//  1PanelClient
//
//  虚拟机快照页（入口在虚拟机卡片「快照」按钮）：POST /xpack/vms/snapshots/list 列表、
//  右上角创建（默认名 snap-yyyyMMddHHmmss，任务式）、长按恢复（仅关机态，
//  二次确认后任务式）。原详情页内嵌快照区迁至此独立页。
//

import SwiftUI

struct KVMSnapshotListView: View {
    @ObservedObject var vm: KVMViewModel
    /// 进入时的快照；展示时优先取列表里的实时对象
    let initial: KVMVirtualMachine

    @State private var snapshots: [KVMSnapshot] = []
    @State private var snapshotsLoaded = false
    @State private var snapshotError: String?
    @State private var showCreateSnapshot = false
    @State private var recoverTarget: KVMSnapshot?

    init(vm: KVMViewModel, machine: KVMVirtualMachine) {
        self.vm = vm
        self.initial = machine
    }

    private var machine: KVMVirtualMachine {
        vm.vms.first { $0.id == initial.id } ?? initial
    }

    var body: some View {
        List {
            Section {
                if snapshots.isEmpty {
                    if !snapshotsLoaded {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .padding(.vertical, 20)
                    } else if let snapshotError {
                        ContentUnavailableView {
                            Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(snapshotError)
                        } actions: {
                            Button(L10n.t("重试")) { Task { await loadSnapshots() } }
                        }
                        .listRowBackground(Color.clear)
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
            } footer: {
                Text(L10n.t("恢复快照需先关机；长按快照行执行恢复。"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("快照"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 创建快照移至右上角
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreateSnapshot = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("创建快照"))
            }
        }
        .refreshable { await loadSnapshots() }
        .task(id: machine.id) { await loadSnapshots() }
        .alert(
            L10n.t("恢复快照"),
            isPresented: Binding(get: { recoverTarget != nil }, set: { if !$0 { recoverTarget = nil } })
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
    }

    // MARK: 行 / 数据

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
            snapshotError = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
        snapshotsLoaded = true
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
