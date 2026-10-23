//
//  KVMDiskManageView.swift
//  1PanelClient
//
//  虚拟机磁盘管理（关机态，入口在虚拟机列表长按菜单）：
//  进页 POST /xpack/vms/info {name, checkDisks:true} 取逐盘可扩容判定——
//  disks[].resizeBlocked 非空（如 "backing" 挂在快照链上）即不可扩容。
//  磁盘列表展示 设备 / 总线 / 格式 / 容量 / 源路径 + 不可扩容标记；
//  扩容表单：设备（仅可选可扩容磁盘）/ 磁盘容量（当前）/ 扩容后总容量，
//  提交 POST /xpack/vms/disks/resize {name, target, sizeGiB, taskID} →
//  页内推入任务进度（operateNode=local），完成后重拉 info 与虚拟机列表。
//

import SwiftUI

struct KVMDiskManageView: View {
    @ObservedObject var vm: KVMViewModel
    /// 进入时的快照；展示时优先取列表里的实时对象
    let initial: KVMVirtualMachine

    @Environment(\.dismiss) private var dismiss

    /// info(checkDisks) 结果（磁盘含 resizeBlocked 判定）
    @State private var info: KVMVirtualMachine?
    @State private var isLoading = false
    @State private var loadError: String?

    // 扩容表单
    @State private var target = ""
    @State private var sizeText = ""
    @State private var isSubmitting = false
    @State private var showProgress = false
    @State private var activeTaskID = ""

    init(vm: KVMViewModel, machine: KVMVirtualMachine) {
        self.vm = vm
        self.initial = machine
    }

    private var machine: KVMVirtualMachine {
        vm.vms.first { $0.id == initial.id } ?? initial
    }

    private var disks: [KVMDisk] { info?.disks ?? machine.disks ?? [] }

    /// 可扩容磁盘（非 cdrom 且 resizeBlocked 为空）
    private var resizableDisks: [KVMDisk] {
        disks.filter(\.isResizable)
    }

    private var selectedDisk: KVMDisk? {
        resizableDisks.first { $0.target == target }
    }

    /// 当前磁盘容量 GiB（字节换算取整）
    private var currentGiB: Int? {
        selectedDisk?.capacityGiB ?? selectedDisk.map { _ in 0 }
    }

    var body: some View {
        List {
            diskSection
            resizeSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("磁盘管理"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadInfo() }
        .task {
            // info 未返回前先用列表数据回填默认设备（search 响应同含 disks/resizeBlocked）
            if target.isEmpty, let first = disks.first(where: \.isResizable) {
                target = first.target ?? ""
            }
            await loadInfo()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text(L10n.t("扩容")).bold()
                    }
                }
                .disabled(!isValid || isSubmitting)
            }
        }
        .navigationDestination(isPresented: $showProgress) {
            TaskProgressView(taskID: activeTaskID,
                             title: L10n.f("扩容磁盘 %@", target),
                             node: "local") { _ in
                Task {
                    await vm.loadVMs()
                    await loadInfo()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    dismiss()
                }
                return false
            }
        }
    }

    // MARK: 磁盘列表

    private var diskSection: some View {
        Section {
            if isLoading, disks.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding(.vertical, 20)
            } else if let loadError, disks.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(loadError)
                } actions: {
                    Button(L10n.t("重试")) { Task { await loadInfo() } }
                }
                .listRowBackground(Color.clear)
            } else if disks.isEmpty {
                Text(L10n.t("未检测到磁盘"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(disks.enumerated()), id: \.offset) { _, disk in
                    diskRow(disk)
                }
            }
        } header: {
            SectionLabel(title: L10n.t("磁盘"), systemImage: "internaldrive")
        } footer: {
            Text(L10n.t("仅关机状态可扩容；挂有快照链（backing 文件）或只读磁盘不可扩容。"))
        }
    }

    private func diskRow(_ disk: KVMDisk) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: disk.device == "cdrom" ? "opticaldisc" : "internaldrive")
                    .foregroundStyle(.secondary)
                Text("\(disk.target ?? "-") · \(disk.bus ?? "-") · \(disk.format ?? "-")")
                    .font(.subheadline.weight(.medium))
                if let giB = disk.capacityGiB {
                    Text(L10n.f("%ld GB", giB))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if disk.device == "cdrom" {
                    StatusBadge(text: L10n.t("光驱"), color: .secondary)
                } else if !disk.isResizable {
                    StatusBadge(text: L10n.t("不可扩容"), color: .statusError)
                }
            }
            Text(disk.source ?? "-")
                .font(.dataMonospacedFootnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !disk.isResizable, disk.device != "cdrom", !disk.resizeBlockedDisplay.isEmpty {
                Text(L10n.f("原因：%@", disk.resizeBlockedDisplay))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: 扩容表单

    @ViewBuilder
    private var resizeSection: some View {
        if !resizableDisks.isEmpty {
            Section {
                OutlinedPicker(label: L10n.t("设备"),
                               options: resizableDisks.compactMap(\.target),
                               selection: $target)
                OutlinedShape(label: L10n.t("磁盘容量"), isFocused: false, hasValue: true,
                              trailing: { EmptyView() }) {
                    Text(L10n.f("%ld GB", currentGiB ?? 0))
                        .font(.dataMonospacedBody)
                }
                OutlinedUnitField(label: L10n.t("扩容后总容量"), unit: "GB", text: $sizeText, range: 1...65_536)
            } header: {
                SectionLabel(title: L10n.t("扩容"), systemImage: "arrow.up.left.and.arrow.down.right.square")
            } footer: {
                Text(L10n.t("扩容后总容量需大于当前容量；扩容只增大不缩小，提交后由后台任务执行。"))
            }
            .onChange(of: target) { _, _ in
                // 切换设备时回填当前容量，用户在其基础上调大
                if let giB = currentGiB { sizeText = String(giB) }
            }
        }
    }

    // MARK: 数据与提交

    private func loadInfo() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await vm.info(machine, checkDisks: true)
            info = fresh
            loadError = nil
            if target.isEmpty, let first = fresh.disks?.first(where: \.isResizable) {
                target = first.target ?? ""
            }
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    private var isValid: Bool {
        guard let disk = selectedDisk, let size = Int(sizeText), size >= 1 else { return false }
        return currentGiB.map { size > $0 } ?? true
    }

    private func submit() async {
        guard let disk = selectedDisk, let size = Int(sizeText) else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        if let taskID = await vm.resizeDisk(machine, target: disk.target ?? "", sizeGiB: size, present: false) {
            if taskID.isEmpty {
                dismiss()
            } else {
                activeTaskID = taskID
                showProgress = true
            }
        }
    }
}
