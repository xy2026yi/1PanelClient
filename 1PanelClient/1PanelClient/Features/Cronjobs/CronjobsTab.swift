//
//  CronjobsTab.swift
//  1PanelClient
//
//  计划任务：列表 / 详情 / 创建 / 手动执行 / 删除 / 执行记录 / 日志
//  基于 doc/计划任务.md
//

import SwiftUI
import Combine

struct CronjobsTab: View {
    @ObservedObject var manager: ServerManager
    @StateObject private var vm: CronjobsViewModel
    @State private var showCreate = false
    @State private var searchText = ""
    @State private var isSearching = false
    // 分组管理弹窗入口（筛选条末尾「管理」chip）
    @State private var showGroupManage = false
    // 导入导出（导出走行长按「导出任务」多选；导入并入 + 号半屏菜单）
    @State private var showExport = false
    /// + 号半屏菜单（创建/导入，与其他列表页统一呈现）
    @State private var showAddMenu = false
    @State private var showImport = false
    /// 导出多选的初始勾选（长按菜单「导出任务」= 仅当前任务；nil = 默认全选）
    @State private var exportPreselect: Set<Int>? = nil
    /// 行长按操作菜单（立即执行/停启用/编辑/导出/删除）
    @State private var actionJob: Cronjob?
    // 多选模式（长按菜单「多选」进入；批量启用/停用/删除）
    @State private var isSelecting = false
    @State private var selectedIDs: Set<Int> = []
    @State private var isBatchOperating = false
    @State private var showBatchDelete = false
    /// 点击行编程式推入的详情页目标
    @State private var pushedJob: Cronjob?
    /// 长按菜单「编辑任务」：加载详情后推入编辑表单
    @State private var editingInfo: CronjobInfo?
    @State private var showEditView = false
    @State private var isLoadingEditInfo = false
    /// 分组管理页所需服务器配置（init 时固定）
    private let server: ServerConfig

    init(manager: ServerManager) {
        self.manager = manager
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        self.server = server
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(key: ManageItem.cronjobList.storeKey(server: server)) {
            CronjobsViewModel(server: server)
        })
    }

    var body: some View {
        rootContent
            .task { await PageVMStore.shared.autoRefresh(vm: vm) { await vm.refresh() } }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
        Text(vm.alertMessage)
        }
            .toastOverlay(message: $vm.toastMessage)
    }

    /// 列表根内容（不含 NavigationStack），供 ManageTab 嵌入复用
    var rootContent: some View {
        VStack(spacing: 0) {
            // 分组筛选条放在分支外常驻（末尾「管理」入口点击弹窗管理分组）：
            // 选中分组无任务时仍能切回「全部」
            if !vm.groups.isEmpty {
                GroupFilterBar(groups: vm.groups, selectedID: $vm.selectedGroupID) {
                    showGroupManage = true
                }
            }

            if vm.isLoading && vm.cronjobs.isEmpty {
                LoadingStateView()
            } else if let err = vm.errorMessage, !err.isEmpty, vm.cronjobs.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button(L10n.t("重试")) {
                        Task { await vm.refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if vm.cronjobs.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无计划任务"),
                    systemImage: "clock.badge.checkmark",
                    description: Text(L10n.t("点击右上角创建第一个任务"))
                )
            } else {
                cronjobList
            }
        }
        .searchIconMode(
            text: $searchText,
            isSearching: $isSearching,
            title: L10n.t("计划任务"),
            prompt: L10n.t("搜索脚本名")
        )
        // 长按「编辑任务」拉取详情期间的轻量加载指示
        .overlay {
            if isLoadingEditInfo {
                ProgressView()
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .navigationTitle(L10n.t("计划任务"))
        .navigationBarTitleDisplayMode(.inline)
        // 脚本库入口已上移至 管理-计划任务 Hub；右上角留 搜索 + 创建/导入 两键；
        // 多选时为退出按钮（与网站/文件页一致），多选入口在行长按菜单
        .toolbar {
            if !isSearching {
                ToolbarItem(placement: .topBarTrailing) {
                    if isSelecting {
                        Button {
                            exitSelecting()
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .accessibilityLabel(L10n.t("退出多选"))
                    } else {
                        // 创建/导入合并进 + 号半屏菜单（呈现方式与网站列表统一）
                        Button {
                            showAddMenu = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(L10n.t("创建计划任务"))
                    }
                }
            }
        }
        .sheet(isPresented: $showAddMenu) {
            ActionBottomSheet(title: L10n.t("计划任务"), items: [
                .init(title: L10n.t("创建计划任务"), icon: "plus", color: .blue) {
                    showCreate = true
                },
                .init(title: L10n.t("导入计划任务"), icon: "square.and.arrow.down", color: .blue) {
                    showImport = true
                },
            ]) { showAddMenu = false }
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: 2))])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showExport) {
            CronjobExportView(server: server, cronjobs: vm.cronjobs,
                              preselectedIDs: exportPreselect)
        }
        .sheet(isPresented: $showImport) {
            CronjobImportView(server: server) {
                await vm.refresh()
            }
        }
        .onChange(of: vm.selectedGroupID) { _, _ in
            Task { await vm.refresh() }
        }
        .navigationDestination(for: Cronjob.self) { job in
            CronjobDetailView(job: job, vm: vm, server: manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
        }
        // 行点击进入任务详情（编程式推入；与上方 for 版共存，各自独立触发）
        .navigationDestination(item: $pushedJob) { job in
            CronjobDetailView(job: job, vm: vm, server: manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
        }
        .navigationDestination(isPresented: $showCreate) {
            CreateCronjobView(vm: vm, server: manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
        }
        .navigationDestination(isPresented: $showEditView) {
            if let info = editingInfo {
                CreateCronjobView(vm: vm, server: manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""),
                                  editingJob: info)
            }
        }
        // 行长按操作菜单（与防火墙规则行同款半屏 ActionBottomSheet）
        .sheet(isPresented: Binding(
            get: { actionJob != nil },
            set: { if !$0 { actionJob = nil } }
        )) {
            ActionBottomSheet(title: actionJob?.name ?? L10n.t("计划任务"),
                              items: actionMenuItems) { actionJob = nil }
                .bottomSheetDetents([.height(ActionBottomSheet.height(for: actionMenuItems.count))])
                .presentationDragIndicator(.visible)
        }
        // 批量删除确认（含备份文件/远程备份文件选项）
        .sheet(isPresented: $showBatchDelete) {
            CronjobBatchDeleteSheet(
                count: selectedIDs.count,
                showsBackupOptions: selectedJobs.contains { $0.jobType.producesBackupRecords }
            ) { cleanData, cleanRemoteData in
                await runBatchDelete(cleanData: cleanData, cleanRemoteData: cleanRemoteData)
            }
        }
        .navigationDestination(isPresented: $showGroupManage) {
            GroupManageView(server: server, scope: .cronjob) {
                Task {
                    // 分组管理内的增删改必须强制重查分组：loadGroups 有「非空跳过」
                    // 守卫，普通 refresh 不会刷新筛选条（删除后仍显示已删分组）
                    await vm.loadGroups(force: true)
                    await vm.refresh()
                }
            }
        }
    }

    /// 搜索过滤：按任务名（名称可能为空，按空串处理）
    private var filteredCronjobs: [Cronjob] {
        let keyword = searchText.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return vm.cronjobs }
        return vm.cronjobs.filter { ($0.name ?? "").localizedCaseInsensitiveContains(keyword) }
    }

    /// 长按行菜单项：多选 / 立即执行 / 停用·启用 / 编辑 / 导出 / 删除
    private var actionMenuItems: [ActionMenuItem] {
        guard let job = actionJob else { return [] }
        var items: [ActionMenuItem] = []
        items.append(ActionMenuItem(title: L10n.t("多选"), icon: "checkmark.circle", color: .blue) {
            withAnimation(Motion.standard) {
                isSelecting = true
                selectedIDs = [job.id]
            }
        })
        items.append(ActionMenuItem(title: L10n.t("立即执行"), icon: "play.fill", color: .blue) {
            Task { await vm.handle(job: job) }
        })
        items.append(ActionMenuItem(
            title: job.isEnabled ? L10n.t("停用任务") : L10n.t("启用任务"),
            icon: job.isEnabled ? "pause.fill" : "checkmark.circle.fill", color: .orange) {
            Task { await vm.updateStatus(job: job, enabled: !job.isEnabled) }
        })
        items.append(ActionMenuItem(title: L10n.t("编辑任务"), icon: "pencil", color: .blue) {
            Task { await loadEditInfo(job: job) }
        })
        items.append(ActionMenuItem(title: L10n.t("导出任务"), icon: "square.and.arrow.up", color: .teal) {
            exportPreselect = [job.id]
            showExport = true
        })
        items.append(ActionMenuItem(title: L10n.t("删除任务"), icon: "trash", color: .red,
                                    role: .destructive) {
            Haptic.warning()
            vm.pendingDeleteJob = job
        })
        return items
    }

    /// 加载编辑所需的任务详情，加载成功后跳转到编辑表单
    private func loadEditInfo(job: Cronjob) async {
        isLoadingEditInfo = true
        let info = await vm.loadCronjobInfo(id: job.id)
        isLoadingEditInfo = false
        if let info = info {
            editingInfo = info
            showEditView = true
        }
    }

    private var cronjobList: some View {
        List {
            if filteredCronjobs.isEmpty {
                Section {
                    ContentUnavailableView(
                        L10n.t("该分组暂无任务"),
                        systemImage: "clock.badge.checkmark"
                    )
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(filteredCronjobs) { job in
                    if isSelecting {
                        selectingRow(job)
                    } else {
                        // tap 手势 + 编程式推入（原 NavigationLink(value:) + 长按共存，
                        // 松手仍会误触导航进详情）
                        CronjobRow(job: job)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .rowTapAndLongPress(
                                onTap: { pushedJob = job },
                                onLongPress: { actionJob = job })
                            // VoiceOver 无长按手势：以自定义操作暴露同一菜单
                            .accessibilityAction(named: L10n.t("更多操作")) { actionJob = job }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    Task { await vm.handle(job: job) }
                                } label: {
                                    Label(L10n.t("执行"), systemImage: "play.fill")
                                }
                                .tint(.blue)

                                Button(role: .destructive) {
                                    vm.pendingDeleteJob = job
                                } label: {
                                    Label(L10n.t("删除"), systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await vm.refresh()
        }
        // 多选模式底部批量操作栏（退出在右上角工具栏）
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                CronjobBatchBar(
                    selectedCount: selectedIDs.count,
                    totalCount: filteredCronjobs.count,
                    isOperating: isBatchOperating,
                    onSelectAll: {
                        if selectedIDs.count >= filteredCronjobs.count {
                            selectedIDs.removeAll()
                        } else {
                            selectedIDs = Set(filteredCronjobs.map(\.id))
                        }
                    },
                    onEnable: { Task { await batchUpdateStatus(enabled: true) } },
                    onDisable: { Task { await batchUpdateStatus(enabled: false) } },
                    onDelete: { showBatchDelete = true }
                )
            }
        }
        .sheet(item: $vm.pendingDeleteJob) { job in
            TextInputConfirmSheet(
                title: L10n.t("删除任务"),
                message: L10n.f("此操作不可恢复。请输入任务名称「%@」以确认删除。", job.name ?? ""),
                expectedText: job.name ?? "",
                fieldLabel: L10n.t("确认名称"),
                fieldPlaceholder: L10n.t("任务名称")
            ) {
                Task { await vm.delete(job: job) }
            } options: {
                // 同时删除备份文件仅备份类任务展示（与「备份记录」入口同判据）
                if job.jobType.producesBackupRecords {
                    Section(L10n.t("选项")) {
                        Toggle(L10n.t("同时删除备份文件"), isOn: $vm.deleteCleanData)
                    }
                }
            }
        }
    }

    // MARK: - 批量操作（多选）

    /// 多选行：勾选圈 + 原行内容
    private func selectingRow(_ job: Cronjob) -> some View {
        Button {
            if selectedIDs.contains(job.id) {
                selectedIDs.remove(job.id)
            } else {
                selectedIDs.insert(job.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedIDs.contains(job.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedIDs.contains(job.id) ? Color.accentColor : Color.secondary)
                CronjobRow(job: job)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func exitSelecting() {
        withAnimation(Motion.standard) {
            isSelecting = false
            selectedIDs.removeAll()
        }
    }

    /// 当前筛选下选中的任务（按列表顺序）
    private var selectedJobs: [Cronjob] {
        filteredCronjobs.filter { selectedIDs.contains($0.id) }
    }

    /// 批量启用/停用：选中 N 个依次发 N 条 /cronjobs/status（见 VM）
    private func batchUpdateStatus(enabled: Bool) async {
        let jobs = selectedJobs
        guard !jobs.isEmpty else { return }
        isBatchOperating = true
        defer { isBatchOperating = false }
        if await vm.batchUpdateStatus(jobs: jobs, enabled: enabled) {
            exitSelecting()
        }
    }

    /// 批量删除：一次 /cronjobs/del 提交全部 id（选项来自确认弹窗）
    private func runBatchDelete(cleanData: Bool, cleanRemoteData: Bool) async {
        let jobs = selectedJobs
        guard !jobs.isEmpty else { return }
        isBatchOperating = true
        defer { isBatchOperating = false }
        if await vm.batchDelete(jobs: jobs, cleanData: cleanData, cleanRemoteData: cleanRemoteData) {
            exitSelecting()
        }
    }
}

// MARK: - 批量操作栏（多选模式底部）

/// 全选/计数 + 批量操作菜单（启用/停用/删除），与网站页 WebsiteBatchBar 同款
struct CronjobBatchBar: View {
    let selectedCount: Int
    let totalCount: Int
    let isOperating: Bool
    let onSelectAll: () -> Void
    let onEnable: () -> Void
    let onDisable: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                onSelectAll()
            } label: {
                Label(
                    selectedCount >= totalCount ? L10n.t("取消全选") : L10n.t("全选"),
                    systemImage: selectedCount >= totalCount ? "circle" : "checkmark.circle"
                )
                .font(.subheadline)
            }
            .disabled(totalCount == 0)

            Spacer()

            Text(L10n.f("已选 %ld 项", selectedCount))
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                Button { onEnable() } label: {
                    Label(L10n.t("启用"), systemImage: "checkmark.circle.fill")
                }
                Button { onDisable() } label: {
                    Label(L10n.t("停用"), systemImage: "pause.fill")
                }
                Button(role: .destructive) { onDelete() } label: {
                    Label(L10n.t("删除"), systemImage: "trash")
                }
            } label: {
                Label(L10n.t("批量操作"), systemImage: "ellipsis.circle")
                    .font(.subheadline.bold())
            }
            .disabled(selectedCount == 0 || isOperating)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - 批量删除确认（含备份文件选项）

/// 批量删除确认弹窗：N 个任务无单一任务名可输入确认，以选项 + 明确计数确认；
/// 「删除远程备份文件」仅在「同时删除备份文件」打开时出现（默认开）
struct CronjobBatchDeleteSheet: View {
    let count: Int
    /// 选中含备份类任务才展示备份文件选项（与单个删除同判据）
    let showsBackupOptions: Bool
    /// (cleanData, cleanRemoteData) → 执行删除
    let onDelete: (Bool, Bool) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cleanData = false
    @State private var cleanRemoteData = true
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if showsBackupOptions {
                        Toggle(L10n.t("同时删除备份文件"), isOn: $cleanData)
                        if cleanData {
                            Toggle(L10n.t("删除远程备份文件"), isOn: $cleanRemoteData)
                        }
                    }
                } header: {
                    if showsBackupOptions { Text(L10n.t("选项")) }
                } footer: {
                    Text(L10n.f("将删除选中的 %ld 个任务，该操作不可恢复。", count))
                }
            }
            .navigationTitle(L10n.t("批量删除任务"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("删除"), role: .destructive) {
                        Task {
                            isSubmitting = true
                            await onDelete(cleanData, cleanRemoteData)
                            dismiss()
                        }
                    }
                    .disabled(isSubmitting)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.medium])
        .interactiveDismissDisabled(isSubmitting)
    }
}

// MARK: - 任务列表项

struct CronjobRow: View {
    let job: Cronjob

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: job.jobType.icon, color: job.jobType.color)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.name ?? L10n.t("未命名"))
                    .font(.body.bold())
                    .lineLimit(1)

                HStack(spacing: 6) {
                    StatusBadge(text: job.jobType.displayName, color: job.jobType.color)
                    StatusBadge(text: job.specDisplay, color: .secondary)
                }

                if let last = job.lastRecordStatus, !last.isEmpty {
                    Text(L10n.f("上次：%@", job.lastStatusDisplay))
                        .font(.caption2)
                        .foregroundStyle(job.lastStatusColor)
                }
            }

            Spacer()

            // 启用/禁用徽标
            if !job.isEnabled {
                StatusBadge(text: L10n.t("已停用"), color: .secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

