//
//  KVMOrphansView.swift
//  1PanelClient
//
//  孤立数据清理（/xpack/vms/orphans/scan|clean 抓包 2026-10-24）：
//  扫描未被虚拟机 / 快照 / 已登记模版引用的候选文件，多选后提交清理（不可恢复）。
//  入口在虚拟机段工具栏菜单；清理请求体直接复用扫描结果项（字段同构），
//  响应为清理后的候选列表，直接刷新本地结果。
//  布局三层：摘要卡（扫描状态 + 扫描主按钮，加载态收于此）→ 候选列表（header 内联
//  全选切换，默认全选——候选本就未被引用，逐项排除更省）→ 底部清理栏（破坏性操作）。
//

import SwiftUI

struct KVMOrphansView: View {
    @ObservedObject var vm: KVMViewModel

    @State private var selected: Set<KVMOrphanItem.ID> = []
    @State private var showCleanConfirm = false

    private var allSelected: Bool {
        !vm.orphans.isEmpty && selected.count == vm.orphans.count
    }

    private var selectedItems: [KVMOrphanItem] {
        vm.orphans.filter { selected.contains($0.id) }
    }

    /// 勾选项总大小（底部栏显示）
    private var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + max($1.size ?? 0, 0) }
    }

    private var isBusy: Bool { vm.isScanningOrphans || vm.isCleaningOrphans }

    var body: some View {
        List {
            summarySection
            candidatesSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("孤立数据清理"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !vm.orphans.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    cleanBar
                }
            }
        }
        .refreshable { await rescan() }
        .task {
            if !vm.hasScannedOrphans {
                await rescan()
            }
        }
        .alert(L10n.t("确认清理"), isPresented: $showCleanConfirm) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("清理"), role: .destructive) {
                let items = selectedItems
                guard !items.isEmpty else { return }
                Task {
                    // 清理成功（含内部重扫）后全不选——连按误删面最小化；
                    // 失败保持原勾选便于重试
                    if await vm.cleanOrphans(items) {
                        selected.removeAll()
                    }
                }
            }
        } message: {
            Text(L10n.f("将删除 %ld 个文件，清理操作不可恢复。请确认文件不再使用。", selected.count))
        }
    }

    /// 扫描 + 默认全选（候选文件本就未被引用，逐项排除比逐项勾选更省）
    private func rescan() async {
        await vm.scanOrphans()
        selected = Set(vm.orphans.map(\.id))
    }

    // MARK: 摘要卡（状态 + 扫描主按钮）

    private var summarySection: some View {
        Section {
            HStack(spacing: 12) {
                IconBadge(systemName: "trash.slash", color: .orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("孤立数据"))
                        .font(.body.bold())
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button {
                    Task { await rescan() }
                } label: {
                    if vm.isScanningOrphans {
                        ProgressView()
                            .frame(width: 16, height: 16)
                    } else {
                        Label(vm.hasScannedOrphans ? L10n.t("重新扫描") : L10n.t("扫描"),
                              systemImage: "arrow.clockwise")
                            .font(.callout)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)
            }
            .padding(.vertical, 4)
        } footer: {
            Text(L10n.t("仅展示未被虚拟机、快照或已登记模板引用的候选文件。请确认文件不再使用后再清理，清理操作不可恢复。"))
        }
    }

    private var summaryText: String {
        if vm.isScanningOrphans {
            return L10n.t("正在扫描…")
        }
        if !vm.hasScannedOrphans {
            return L10n.t("尚未扫描")
        }
        if vm.orphans.isEmpty {
            return L10n.t("未发现未被引用的候选文件")
        }
        let total = vm.orphans.reduce(Int64(0)) { $0 + max($1.size ?? 0, 0) }
        let parts = MetricFormat.byteParts(total)
        return L10n.f("候选 %ld 项 · 共 %@ %@", vm.orphans.count, parts.value, parts.unit)
    }

    // MARK: 候选列表（header 内联全选切换）

    @ViewBuilder
    private var candidatesSection: some View {
        if vm.isScanningOrphans && !vm.hasScannedOrphans {
            // 首次扫描：列表区居中小转圈（重扫时保留上次结果，转圈在摘要卡）
            Section {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 24)
                .listRowBackground(Color.clear)
            }
        } else if vm.hasScannedOrphans && vm.orphans.isEmpty {
            Section {
                ContentUnavailableView(
                    L10n.t("无孤立数据"),
                    systemImage: "checkmark.seal",
                    description: Text(L10n.t("所有文件均被虚拟机、快照或模板引用"))
                )
                .listRowBackground(Color.clear)
            }
        } else if !vm.orphans.isEmpty {
            Section {
                ForEach(vm.orphans) { item in
                    orphanRow(item)
                }
            } header: {
                HStack {
                    SectionLabel(title: L10n.f("候选文件（%ld）", vm.orphans.count), systemImage: "tray.full")
                    Spacer()
                    Button(allSelected ? L10n.t("取消全选") : L10n.t("全选")) {
                        if allSelected {
                            selected.removeAll()
                        } else {
                            selected = Set(vm.orphans.map(\.id))
                        }
                    }
                    .font(.caption)
                    .textCase(nil)
                    .disabled(isBusy)
                }
            }
        }
    }

    private func orphanRow(_ item: KVMOrphanItem) -> some View {
        Button {
            if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected.contains(item.id) ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    StatusBadge(text: item.typeDisplayName, color: .orange)
                    Text(item.path)
                        .font(.dataMonospacedFootnote)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.leading)
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = item.path
                                Haptic.selection()
                            } label: {
                                Label(L10n.t("复制路径"), systemImage: "doc.on.doc")
                            }
                        }
                    HStack(spacing: 8) {
                        if let size = item.size, size >= 0 {
                            let parts = MetricFormat.byteParts(size)
                            Text("\(parts.value) \(parts.unit)")
                        }
                        if let time = item.modifiedAtText {
                            Text(time)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    // MARK: 底部清理栏

    private var cleanBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.f("已选 %ld 项", selected.count))
                    .font(.footnote.weight(.medium))
                if selectedBytes > 0 {
                    let parts = MetricFormat.byteParts(selectedBytes)
                    Text(L10n.f("共 %@ %@", parts.value, parts.unit))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            Spacer()
            Button(role: .destructive) {
                showCleanConfirm = true
            } label: {
                if vm.isCleaningOrphans {
                    ProgressView()
                        .frame(width: 16, height: 16)
                } else {
                    Label(L10n.t("清理所选"), systemImage: "trash")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(selected.isEmpty || isBusy)
        }
    }
}
