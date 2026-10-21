//
//  FirewallView.swift
//  1PanelClient
//
//  防火墙 v2.3.0（上游 2026-09 整体重构后的 API，doc/references/v2.3.0-upstream-diff.md）：
//  状态卡（系统子系统生命周期 + 基础链初始化/绑定）+ 四段内容——
//  规则（统一规则清单）/ 转发（forward 子域）/ Docker 端口守护 / 设置（三组后端）。
//  旧 v2.2.5 端口/IP/链规则三段模型已被上游「rules 统一命名空间 + states 五态」取代。
//

import SwiftUI
import Combine

// MARK: - 主视图

struct FirewallView: View {
    @StateObject private var vm: FirewallViewModel
    let server: ServerConfig

    @State private var statusExpanded = false
    /// 内容段：0=规则 1=转发 2=容器端口防护 3=设置（与 Web 端四页一一对应）
    @State private var segment = 0
    // 规则段交互
    @State private var showAddRule = false
    // 规则搜索（右上角搜索态；服务端过滤，提交/取消时同步 VM 并重载）
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var editingRule: FirewallRule?
    /// 编辑中规则的操作目标键（v2.4.0：scope+instanceKey，弃 uuid）
    @State private var editingRuleTarget: FirewallRuleOperationTarget?
    /// 编辑中规则的链内优先级（observed.locator.position；表单回显当前值）
    @State private var editingRulePosition: Int?
    @State private var pendingDeleteItem: FirewallInventoryItem?
    @State private var pendingLifeOp: String?
    // 转发段交互
    @State private var showAddForward = false
    @State private var editingForward: FirewallForwardRule?
    @State private var pendingDeleteForward: FirewallForwardRule?
    // 重置 / Docker 策略
    @State private var showRulesReset = false
    /// 重置方式（确认弹窗文案随动）：true = 备份规则后重置，false = 仅重置
    @State private var resetWithBackup = true
    @State private var showDockerReset = false
    @State private var showForwardReset = false
    @State private var editingPolicy: DockerGuardEndpoint?
    /// 点击容器行编程式推入的端口规则页目标
    @State private var pushedContainer: DockerGuardContainer?
    // 规则低频操作
    @State private var showImport = false
    @State private var rawDetail: RawDetailPayload?
    @State private var showForwardImport = false
    @State private var showDockerImport = false
    /// 长按弹出的规则操作目标
    @State private var actionItem: FirewallInventoryItem?
    /// 初始化方式菜单（未初始化占位卡入口：仅初始化 / 初始化并恢复规则）
    @State private var showInitMenu = false
    /// 初始化并恢复规则的备份选择 sheet
    @State private var showRestorePicker = false
    /// 重置方式菜单（备份规则后重置 / 仅重置）
    @State private var showResetMenu = false
    /// 孤立策略长按菜单目标 / 删除确认目标（与规则/转发同款交互）
    @State private var actionOrphan: DockerGuardEndpoint?
    @State private var pendingDeleteOrphan: DockerGuardEndpoint?
    /// 长按弹出的转发操作目标
    @State private var actionForward: FirewallForwardRule?
    /// 规则导出多选页
    @State private var showExportPicker = false
    /// 转发导出多选页
    @State private var showForwardExportPicker = false
    /// Docker 导出多选页
    @State private var showDockerExportPicker = false
    /// 长按「导出规则」的预选（与计划任务语义一致：仅预选长按对象，nil = 默认全选）
    @State private var ruleExportPreselect: Set<String>? = nil
    @State private var forwardExportPreselect: Int? = nil
    @State private var dockerExportPreselect: Set<Int>? = nil
    struct RawDetailPayload: Identifiable {
        let title: String
        let text: String
        var id: String { title }
    }

    init(server: ServerConfig) {
        self.server = server
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(
            key: ManageItem.firewall.storeKey(server: server)) {
            FirewallViewModel(server: server)
        })
    }

    // body 修饰链过长会触发「unable to type-check in reasonable time」：
    // 按职责拆成 列表 → 导航层 → 弹层 三段组合

    var body: some View {
        sheetLayer(
            destinationLayer(
                chromeLayer(firewallList)
            )
        )
    }

    private var firewallList: some View {
        List {
            if vm.unsupportedPanel {
                unsupportedSection
            } else {
                statusSection
                Picker("", selection: $segment) {
                    Text(L10n.t("规则")).tag(0)
                    Text(L10n.t("转发")).tag(1)
                    Text("Docker").tag(2)
                    Text(L10n.t("设置")).tag(3)
                }
                .pickerStyle(.segmented)
                .segmentedPickerRow()
                .listRowBackground(Color.clear)

                switch segment {
                case 0: rulesSection
                case 1: forwardSection
                case 2: dockerSection
                default: FirewallSettingsContent(vm: vm)
                }
            }
        }
    }

    /// 页面外观层：搜索 / 工具栏 / 刷新 / 加载态 / toast / 错误弹窗
    private func chromeLayer(_ content: some View) -> some View {
        content
            .searchIconMode(
                text: $searchText,
                isSearching: $isSearching,
                title: L10n.t("防火墙"),
                prompt: L10n.t("搜索端口 / 地址"),
                onSubmit: { commitSearch() },
                // 搜索只作用于规则段（服务端过滤）：其他段提交会改不可见的
                // 规则数据；切段时自动收起并经取消回调恢复全量
                searchAvailable: segment == 0
            )
            .onChange(of: isSearching) { _, active in
                // 取消搜索（文本已被 searchIconMode 清空）：同步回 VM 恢复全量列表
                if !active && vm.ruleSearchText != searchText { commitSearch() }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !vm.unsupportedPanel {
                        // + 按段条件渲染（未初始化段不显示；导入/导出/同步/重置均已收进
                        // 状态抽屉，规则与转发都只剩创建，直接点击不经菜单）
                        if segment == 0 && !needsRulesInit && !isRulesUnbound {
                            Button { showAddRule = true } label: {
                                Image(systemName: "plus")
                            }
                            .accessibilityLabel(L10n.t("创建规则"))
                            .id(segment)
                        } else if segment == 1 && !needsForwardInit {
                            Button { showAddForward = true } label: {
                                Image(systemName: "plus")
                            }
                            .accessibilityLabel(L10n.t("创建转发"))
                            .id(segment)
                        }
                    }
                }
            }
            .refreshable { await vm.refresh() }
            .overlay {
                if vm.isLoading && vm.systemStatus == nil && !vm.unsupportedPanel {
                    LoadingStateView()
                } else if let err = vm.errorMessage, vm.systemStatus == nil, !vm.unsupportedPanel {
                    // 整页加载失败：统一 LoadErrorStateView（ErrorBanner 仅限首页概览降级场景）
                    LoadErrorStateView(message: err) {
                        Task { await vm.refresh() }
                    }
                }
            }
            .toastOverlay(message: $vm.toastMessage)
            .alert(L10n.t("提示"), isPresented: Binding(
                get: { vm.errorMessage != nil && vm.systemStatus != nil },
                set: { if !$0 {
                    // 自动刷新成功清 errorMessage 时，alert 随绑定转 false 会在
                    // 视图更新内同步回调 set——直接写 @Published 触发
                    // "Publishing changes from within view updates"，推迟到下一周期；
                    // 比较后清除：推迟窗口内新到的错误不被误抹
                    let cleared = vm.errorMessage
                    DispatchQueue.main.async {
                        if vm.errorMessage == cleared { vm.errorMessage = nil }
                    }
                } }
            )) {
                Button(L10n.t("好的"), role: .cancel) { vm.errorMessage = nil }
            } message: {
                Text(vm.errorMessage ?? "")
            }
            .task { await PageVMStore.shared.autoRefresh(vm: vm) { await vm.refresh() } }
    }

    /// 导航层：规则/转发/容器的推入目标 + 任务进度页 + 删除/生命周期确认
    private func destinationLayer(_ content: some View) -> some View {
        content
            // 规则：创建 / 编辑
            .navigationDestination(isPresented: $showAddRule) {
                FirewallRuleFormView(vm: vm, editing: nil, editingTarget: nil)
            }
            .navigationDestination(isPresented: Binding(
                get: { editingRule != nil },
                set: { if !$0 { editingRule = nil; editingRuleTarget = nil; editingRulePosition = nil } }
            )) {
                if let rule = editingRule {
                    FirewallRuleFormView(vm: vm, editing: rule, editingTarget: editingRuleTarget,
                                         editingPosition: editingRulePosition)
                }
            }
            .alert(L10n.t("删除规则"), isPresented: Binding(
                get: { pendingDeleteItem != nil },
                set: { if !$0 { pendingDeleteItem = nil } }
            )) {
                Button(L10n.t("取消"), role: .cancel) { pendingDeleteItem = nil }
                Button(L10n.t("删除"), role: .destructive) {
                    Haptic.warning()
                    if let item = pendingDeleteItem {
                        pendingDeleteItem = nil
                        Task { await vm.deleteRule(item) }
                    }
                }
            } message: {
                if let item = pendingDeleteItem {
                    Text(L10n.f("确定删除规则「%@」吗？删除后不可恢复。", item.rule?.destinationPort ?? item.rule?.sourceAddress ?? ""))
                }
            }
            // 转发：创建 / 编辑 / 删除
            .navigationDestination(isPresented: $showAddForward) {
                FirewallForwardFormView(vm: vm, editing: nil)
            }
            .navigationDestination(isPresented: Binding(
                get: { editingForward != nil },
                set: { if !$0 { editingForward = nil } }
            )) {
                if let rule = editingForward {
                    FirewallForwardFormView(vm: vm, editing: rule)
                }
            }
            .alert(L10n.t("删除端口转发"), isPresented: Binding(
                get: { pendingDeleteForward != nil },
                set: { if !$0 { pendingDeleteForward = nil } }
            )) {
                Button(L10n.t("取消"), role: .cancel) { pendingDeleteForward = nil }
                Button(L10n.t("删除"), role: .destructive) {
                    Haptic.warning()
                    deleteForward()
                }
            } message: {
                if let rule = pendingDeleteForward {
                    Text(L10n.f("确定删除端口转发「%@」吗？", rule.port ?? ""))
                }
            }
            // 生命周期确认（start/stop/restart 大操作保留确认；ping 开关直接执行）
            .alert(L10n.t("提示"), isPresented: Binding(
                get: { pendingLifeOp != nil },
                set: { if !$0 { pendingLifeOp = nil } }
            )) {
                Button(L10n.t("取消"), role: .cancel) { pendingLifeOp = nil }
                Button(L10n.t("确认"), role: .destructive) {
                    guard let op = pendingLifeOp else { return }
                    pendingLifeOp = nil
                    Task { await vm.operateFirewall(op) }
                }
            } message: {
                Text(L10n.f("将对防火墙执行「%@」，操作期间服务可能短暂中断，是否继续？",
                            pendingLifeOp.flatMap(Self.lifeOpName) ?? ""))
            }
            // 容器行点击进入端口规则页（编程式推入）
            .navigationDestination(item: $pushedContainer) { container in
                DockerGuardEndpointsView(container: container) { endpoint in
                    if endpoint.managementTarget == "host_firewall" {
                        vm.toastMessage = L10n.t("该端点由主机防火墙规则管理，请在规则段调整")
                    } else {
                        editingPolicy = endpoint
                    }
                }
            }
            // 任务式操作进度页（初始化/启用转发/白名单/Docker 操作/IPv6 开关）
            .navigationDestination(item: $vm.activeTask) { target in
                TaskProgressView(taskID: target.taskID, title: target.title) { _ in
                    // IPv6 开关等整页校准型任务：完成返回时重拉
                    if target.refreshAfterDone {
                        Task { await vm.refresh() }
                    }
                    return false
                }
            }
    }

    /// 弹层：半屏操作菜单 / 导入导出 / 策略表单 / 初始化与重置方式菜单 / 重置确认 / 备份恢复 / 原文查看
    private func sheetLayer(_ content: some View) -> some View {
        content
            // Docker 端点防护策略表单
            .sheet(item: $editingPolicy) { endpoint in
                DockerPolicyFormView(vm: vm, endpoint: endpoint)
                    .bottomSheetDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            // 规则导入（文件解析 + 勾选 + sourceKind imported）
            .sheet(isPresented: $showImport) {
                FirewallImportView(vm: vm)
            }
            // 转发导入（文件解析 + 勾选 + forward/operate 批量 add）
            .sheet(isPresented: $showForwardImport) {
                FirewallForwardImportView(vm: vm)
            }
            // Docker 防护策略导入（文件解析 + 勾选 + docker/policies/batch）
            .sheet(isPresented: $showDockerImport) {
                FirewallDockerImportView(vm: vm)
            }
            // 原文查看（observed.raw 或 native/detail）
            .sheet(item: $rawDetail) { payload in
                FirewallRawDetailView(title: payload.title, text: payload.text)
                    .bottomSheetDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            // 长按规则：半屏操作弹窗（编辑/删除/上移下移/导出规则/查看原文，或纳管）
            .sheet(isPresented: Binding(
                get: { actionItem != nil },
                set: { if !$0 { actionItem = nil } }
            )) {
                ActionBottomSheet(
                    title: actionItem?.rule?.destinationPort ?? actionItem?.rule?.sourceAddress ?? L10n.t("规则"),
                    items: ruleActionItems,
                    onDismiss: { actionItem = nil }
                )
                .bottomSheetDetents([.height(ActionBottomSheet.height(for: ruleActionItems.count))])
                .presentationDragIndicator(.visible)
            }
            // 规则导出多选（长按菜单「导出规则」进入：仅预选长按的这条）
            .sheet(isPresented: $showExportPicker) {
                FirewallExportPickerView(vm: vm, preselectedIDs: ruleExportPreselect)
            }
            // 长按转发：半屏操作弹窗（编辑/删除/导出规则）。
            // 菜单项在构建时捕获目标值：ActionBottomSheet 按钮是「先收抽屉、动作
            // 延迟执行」，闭包内回读 actionForward 恒为 nil，动作会静默丢失
            .sheet(isPresented: Binding(
                get: { actionForward != nil },
                set: { if !$0 { actionForward = nil } }
            )) {
                let rule = actionForward
                return ActionBottomSheet(
                    title: rule?.port ?? L10n.t("转发"),
                    items: [
                        ActionMenuItem(title: L10n.t("编辑"), icon: "pencil", color: .blue) {
                            if let rule { editingForward = rule }
                        },
                        ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red,
                                       role: .destructive) {
                            Haptic.warning()
                            if let rule { pendingDeleteForward = rule }
                        },
                        ActionMenuItem(title: L10n.t("导出规则"), icon: "square.and.arrow.down",
                                       color: .teal) {
                            // 仅预选长按的这条转发（与计划任务「导出任务」语义一致）
                            if let rule {
                                forwardExportPreselect = vm.forwards.firstIndex {
                                    $0.port == rule.port && $0.protocolField == rule.protocolField
                                        && $0.family == rule.family && $0.targetIP == rule.targetIP
                                        && $0.targetPort == rule.targetPort && $0.interface == rule.interface
                                }
                            }
                            showForwardExportPicker = true
                        },
                    ],
                    onDismiss: { actionForward = nil }
                )
                .bottomSheetDetents([.height(ActionBottomSheet.height(for: 3))])
                .presentationDragIndicator(.visible)
            }
            // 转发导出多选（长按菜单「导出规则」进入）
            .sheet(isPresented: $showForwardExportPicker) {
                FirewallForwardExportPickerView(vm: vm, preselectedIndex: forwardExportPreselect)
            }
            // Docker 导出多选（容器行长按「导出规则」进入：仅预选该容器的策略）
            .sheet(isPresented: $showDockerExportPicker) {
                FirewallDockerExportPickerView(vm: vm, preselectedIndices: dockerExportPreselect)
            }
            // 孤立策略长按菜单（与规则/转发同款；构建时捕获目标值）
            .sheet(isPresented: Binding(
                get: { actionOrphan != nil },
                set: { if !$0 { actionOrphan = nil } }
            )) {
                let orphan = actionOrphan
                return ActionBottomSheet(
                    title: orphan.map(orphanTitle) ?? L10n.t("孤立策略"),
                    items: [
                        ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red,
                                       role: .destructive) {
                            if let orphan { pendingDeleteOrphan = orphan }
                        },
                    ],
                    onDismiss: { actionOrphan = nil }
                )
                .bottomSheetDetents([.height(ActionBottomSheet.height(for: 1))])
                .presentationDragIndicator(.visible)
            }
            .alert(L10n.t("删除孤立策略"), isPresented: Binding(
                get: { pendingDeleteOrphan != nil },
                set: { if !$0 { pendingDeleteOrphan = nil } }
            )) {
                Button(L10n.t("取消"), role: .cancel) { pendingDeleteOrphan = nil }
                Button(L10n.t("删除"), role: .destructive) {
                    Haptic.warning()
                    let target = pendingDeleteOrphan
                    pendingDeleteOrphan = nil
                    if let target { Task { await vm.deleteDockerPolicy(target) } }
                }
            } message: {
                Text(L10n.t("确定删除该端口的防护策略吗？删除后不可恢复。"))
            }
            // 规则重置（先选方式：备份规则后重置 / 仅重置；R1 均需输入后端名确认，
            // 对齐 Web 端「请手动输入 iptables」；抓包 2026-10-21）
            .sheet(isPresented: $showRulesReset) {
                TextInputConfirmSheet(
                    title: L10n.t("重置防火墙规则"),
                    message: resetConfirmMessage,
                    expectedText: vm.systemStatus?.backend ?? "",
                    fieldLabel: L10n.t("确认输入"),
                    fieldPlaceholder: vm.systemStatus?.backend,
                    confirmTitle: L10n.t("重置")
                ) {
                    Task { await vm.resetRules(backup: resetWithBackup) }
                }
            }
            // Docker 守护重置（R1：同款输入后端名确认；settings/operate cleanup）
            .sheet(isPresented: $showDockerReset) {
                TextInputConfirmSheet(
                    title: L10n.t("重置 Docker 端口防护"),
                    message: L10n.f("将删除 %@ 中的 1Panel Docker 端口防护运行时规则：删除全部相关规则及规则链，仅保留数据库数据。请输入后端名「%@」以确认。", vm.dockerGuard?.base?.backend ?? "", vm.dockerGuard?.base?.backend ?? ""),
                    expectedText: vm.dockerGuard?.base?.backend ?? "",
                    fieldLabel: L10n.t("确认输入"),
                    fieldPlaceholder: vm.dockerGuard?.base?.backend,
                    confirmTitle: L10n.t("重置")
                ) {
                    Task { await vm.resetDockerGuard() }
                }
            }
            // 转发运行时规则重置（R1：同款输入后端名确认；settings/operate cleanup）
            .sheet(isPresented: $showForwardReset) {
                TextInputConfirmSheet(
                    title: L10n.t("重置端口转发规则"),
                    message: L10n.f("将删除 %@ 中的 1Panel 端口转发运行时规则：删除全部相关规则及规则链，仅保留数据库数据。请输入后端名「%@」以确认。", vm.forwardStatus?.backend ?? vm.systemStatus?.backend ?? "", vm.forwardStatus?.backend ?? vm.systemStatus?.backend ?? ""),
                    expectedText: vm.forwardStatus?.backend ?? vm.systemStatus?.backend ?? "",
                    fieldLabel: L10n.t("确认输入"),
                    fieldPlaceholder: vm.forwardStatus?.backend ?? vm.systemStatus?.backend,
                    confirmTitle: L10n.t("重置")
                ) {
                    Task { await vm.resetForwarding() }
                }
            }
            // 初始化方式菜单（未初始化占位卡入口；对齐 Web 端下拉二选一）
            .sheet(isPresented: $showInitMenu) {
                ActionBottomSheet(
                    title: L10n.t("初始化"),
                    items: [
                        ActionMenuItem(title: L10n.t("仅初始化"), icon: "wand.and.stars",
                                       color: .blue) {
                            Task { await vm.operateFilterChain("init-base") }
                        },
                        ActionMenuItem(title: L10n.t("初始化并恢复规则"),
                                       icon: "arrow.counterclockwise.circle",
                                       color: .teal) {
                            showRestorePicker = true
                        },
                    ],
                    onDismiss: { showInitMenu = false }
                )
                .bottomSheetDetents([.height(ActionBottomSheet.height(for: 2))])
                .presentationDragIndicator(.visible)
            }
            // 初始化并恢复规则：备份选择（rules/backups → POST rules initialize）
            .sheet(isPresented: $showRestorePicker) {
                FirewallRestoreBackupView(vm: vm)
            }
            // 重置方式菜单（备份规则后重置 / 仅重置，随后进输入后端名确认）
            .sheet(isPresented: $showResetMenu) {
                ActionBottomSheet(
                    title: L10n.t("重置防火墙规则"),
                    items: [
                        ActionMenuItem(title: L10n.t("备份规则后重置"),
                                       icon: "externaldrive.badge.timemachine",
                                       color: .orange) {
                            resetWithBackup = true
                            showRulesReset = true
                        },
                        ActionMenuItem(title: L10n.t("仅重置"), icon: "trash",
                                       color: .statusError, role: .destructive) {
                            resetWithBackup = false
                            showRulesReset = true
                        },
                    ],
                    onDismiss: { showResetMenu = false }
                )
                .bottomSheetDetents([.height(ActionBottomSheet.height(for: 2))])
                .presentationDragIndicator(.visible)
            }
            // 备份后重置完成：弹窗提醒服务器保存路径（对齐 Web 端；抓包 2026-10-21）
            .alert(L10n.t("重置完成"), isPresented: Binding(
                get: { vm.lastResetResult != nil },
                set: { if !$0 { vm.lastResetResult = nil } }
            )) {
                Button(L10n.t("好的"), role: .cancel) { vm.lastResetResult = nil }
            } message: {
                if let result = vm.lastResetResult {
                    Text(L10n.f("已移除 %ld 条规则，规则备份已保存至：", result.removed ?? 0)
                         + "\n" + (result.backupPath ?? ""))
                }
            }
    }

    /// 重置确认弹窗文案（随方式变化；v2.4.0 上游已移除同步，提示只提重新初始化）
    private var resetConfirmMessage: String {
        let backend = vm.systemStatus?.backend ?? ""
        if resetWithBackup {
            return L10n.f("将删除 %@ 中的全部 1Panel 运行时规则及规则链，仅保留数据库策略；重置前将自动备份当前规则并显示保存路径。请输入后端名「%@」以确认。", backend, backend)
        }
        return L10n.f("将删除 %@ 中的全部 1Panel 运行时规则及规则链，仅保留数据库策略，且不生成备份。请输入后端名「%@」以确认。", backend, backend)
    }

    private func deleteForward() {
        guard let rule = pendingDeleteForward else { return }
        pendingDeleteForward = nil
        Task {
            _ = await vm.submitForward([.remove(rule)])
        }
    }

    // MARK: 段初始化判定（未初始化：隐藏 + / 列表 / 筛选，仅显示初始化入口）

    /// iptables/nftables 有基础链初始化概念；ufw/firewalld 与状态未加载完成按已初始化处理（防闪烁）
    private var needsRulesInit: Bool {
        guard let s = vm.systemStatus else { return false }
        return (s.backend == "iptables" || s.backend == "nftables") && s.isInit != true
    }

    private var needsForwardInit: Bool {
        vm.forwardStatus?.isInit != true && vm.forwardStatus != nil
    }

    /// 规则段解绑态（基础链已摘除；ufw/firewalld 无绑定概念，isBind 缺失按已绑定处理）
    private var isRulesUnbound: Bool {
        vm.systemStatus?.isBind == false
    }

    /// 解绑态占位：说明绑定入口在上方操作行（隐藏 +、列表与同步/导入）
    private var unboundPlaceholder: some View {
        Section {
            VStack(spacing: 14) {
                Image(systemName: "link.badge.plus")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text(L10n.t("当前防火墙未绑定，请先绑定！"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
            .listRowBackground(Color.clear)
        }
    }

    private var needsDockerInit: Bool {
        guard let base = vm.dockerGuard?.base else { return false }
        return base.isExist == true && base.initialized != true
    }

    /// 段未初始化时的占位：说明 + 初始化按钮（隐藏 +、列表与筛选）
    private func uninitializedPlaceholder(message: String, buttonTitle: String,
                                          action: @escaping () -> Void) -> some View {
        Section {
            VStack(spacing: 14) {
                Image(systemName: "wand.and.stars")
                    .font(.title)
                    .foregroundStyle(.tint)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(action: action) {
                    // 图标/文字显式白色：主题 tint 下 Label 内容可能与按钮底色
                    // 同色导致图标不可见（borderedProminent 不保证内容对比度）
                    Label(buttonTitle, systemImage: "wand.and.stars")
                        .foregroundStyle(.white)
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .disabled(vm.isOperating)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
            .listRowBackground(Color.clear)
        }
    }

    private static func lifeOpName(_ op: String) -> String {
        switch op {
        case "start": return L10n.t("启动")
        case "stop": return L10n.t("停止")
        case "restart": return L10n.t("重启")
        default: return op
        }
    }

    // MARK: 旧面板门禁（L2）

    private var unsupportedSection: some View {
        Section {
            ContentUnavailableView {
                Label(L10n.t("面板版本过低"), systemImage: "exclamationmark.arrow.triangle.2.circlepath")
            } description: {
                Text(L10n.t("防火墙新管理界面需要 1Panel v2.3.0 及以上版本。请升级面板后使用；旧版端口/转发管理已随 v2.3.0 重构下线。"))
            }
        }
    }

    // MARK: 状态卡

    private var statusSection: some View {
        Section {
            Button {
                withAnimation(Motion.standard) { statusExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    IconBadge(systemName: "flame.fill",
                              color: (vm.systemStatus?.isActive == true) ? .orange : .gray)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(vm.systemStatus?.backend?.uppercased() ?? "—")
                                .font(.subheadline.bold())
                            if let v = vm.systemStatus?.version, !v.isEmpty {
                                Text("v\(v)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(lifeStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let conflict = vm.systemStatus?.conflictBackend, !conflict.isEmpty {
                        StatusBadge(text: L10n.t("后端冲突"), color: .semanticWarning)
                    }
                    Image(systemName: statusExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if statusExpanded {
                if let conflict = vm.systemStatus?.conflictBackend, !conflict.isEmpty {
                    Label(L10n.f("检测到冲突后端 %@，可能互相干扰规则，建议在设置段清理未用后端。", conflict),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.semanticWarning)
                }
                // 地址族待办（v2.4.0 family/operate）：如「IPv6 · 1PANEL_BASIC 链 · 未初始化」
                if !familyAttentions.isEmpty {
                    familyAttentionRows
                        .padding(.top, 4)
                }
                operationsRow
                    .padding(.top, 4)
            }
        }
    }

    /// 生命周期状态文案：停止（不论是否初始化）→ 已停止；
    /// 运行中未初始化（iptables/nftables）→ 未初始化；运行中已初始化 → 运行中。
    /// 转发/Docker 段按各自子系统状态显示（转发 isActive 恒 false 用 isInit 判据）
    private var lifeStatusText: String {
        switch segment {
        case 1:
            guard let fs = vm.forwardStatus else { return "—" }
            return fs.isInit == true ? L10n.t("运行中") : L10n.t("未初始化")
        case 2:
            guard let base = vm.dockerGuard?.base, base.isExist == true else { return "—" }
            return base.initialized == true ? L10n.t("运行中") : L10n.t("未初始化")
        default:
            guard let s = vm.systemStatus else { return "—" }
            if s.isActive != true { return L10n.t("已停止") }
            if s.isInit != true, s.backend == "iptables" || s.backend == "nftables" {
                return L10n.t("未初始化")
            }
            return L10n.t("运行中")
        }
    }

    /// 地址族待办（派生逻辑在 VM.familyAttention，纯函数可单测）：
    /// available 且 partial → 修复；未初始化 → 初始化；已初始化未绑定 → 绑定
    private var familyAttentions: [FirewallFamilyAttention] {
        FirewallViewModel.familyAttention(vm.systemStatus)
    }

    /// 待办行：族名 · 1PANEL_BASIC 链 · 状态文案 + 右侧动作按钮（任务式，进进度页）
    private var familyAttentionRows: some View {
        VStack(spacing: 8) {
            ForEach(familyAttentions.indices, id: \.self) { idx in
                let item = familyAttentions[idx]
                HStack(spacing: 10) {
                    if item.operation == "repair" {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.semanticWarning)
                    }
                    Text("\(item.family.uppercased()) · \(L10n.t("1PANEL_BASIC 链")) · \(familyStateText(item.operation))")
                        .font(.footnote)
                        .foregroundStyle(item.operation == "repair" ? Color.semanticWarning : .primary)
                    Spacer()
                    Button {
                        Task { await vm.operateFamily(item.family, operation: item.operation) }
                    } label: {
                        Text(FirewallViewModel.familyActionName(item.operation))
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(vm.isOperating)
                }
            }
        }
    }

    private func familyStateText(_ operation: String) -> String {
        switch operation {
        case "initialize": return L10n.t("未初始化")
        case "bind": return L10n.t("未绑定")
        case "repair": return L10n.t("状态不完整")
        default: return operation
        }
    }

    private var operationsRow: some View {
        VStack(spacing: 8) {
            // iptables/nftables 无服务生命周期概念 → 整行隐藏（否则按钮孤行）
            if vm.systemStatus?.backend != "iptables", vm.systemStatus?.backend != "nftables" {
                HStack(spacing: 8) {
                    CardActionButton(
                        title: vm.systemStatus?.isActive == true ? L10n.t("停止") : L10n.t("启动"),
                        icon: vm.systemStatus?.isActive == true ? "stop.fill" : "play.fill",
                        color: .blue,
                        busy: vm.isOperating
                    ) {
                        pendingLifeOp = (vm.systemStatus?.isActive == true) ? "stop" : "start"
                    }
                    CardActionButton(title: L10n.t("重启"), icon: "arrow.triangle.2.circlepath",
                                     color: .orange, busy: vm.isOperating) {
                        pendingLifeOp = "restart"
                    }
                }
            }
            // 随段变化的上下文操作：同名按钮（解绑/绑定、重置）按段传对应参数
            contextOperationsRow
        }
    }

    @ViewBuilder
    private var contextOperationsRow: some View {
        switch segment {
        case 0:
            // 规则段：基础链解绑/绑定 + 重置 + 导入/导出（未初始化段不提供；
            // 解绑态下导入不可用——基础链已摘除，规则清单不展示）。
            // v2.4.0 上游移除 rules/sync 全家，「同步规则」按钮随之取消
            if !needsRulesInit {
                HStack(spacing: 8) {
                    filterChainBindButton
                    CardActionButton(title: L10n.t("重置"), icon: "trash",
                                     color: .statusError, busy: vm.isOperating) {
                        showResetMenu = true
                    }
                    CardActionButton(title: L10n.t("导入"), icon: "square.and.arrow.down",
                                     color: .teal, busy: false,
                                     disabled: isRulesUnbound) {
                        showImport = true
                    }
                }
            }
        case 1:
            // 转发段：重置 + 导入（导出走长按菜单，子系统无绑定概念）
            if !needsForwardInit {
                HStack(spacing: 8) {
                    CardActionButton(title: L10n.t("重置"), icon: "trash",
                                     color: .statusError, busy: vm.isOperating) {
                        showForwardReset = true
                    }
                    CardActionButton(title: L10n.t("导入"), icon: "square.and.arrow.down",
                                     color: .teal, busy: false) {
                        showForwardImport = true
                    }
                }
            }
        case 2:
            // Docker 段：端口守护解绑/绑定 + 重置 + 导入/导出（未初始化/不可用不提供；
            // 解绑态下导入不可用——守护链已摘除，容器列表不展示）
            if let base = vm.dockerGuard?.base,
               base.isExist == true, base.initialized == true {
                HStack(spacing: 8) {
                    CardActionButton(
                        title: base.bound == true ? L10n.t("解绑") : L10n.t("绑定"),
                        icon: base.bound == true ? "link.badge.plus" : "link",
                        color: base.bound == true ? .secondary : .green,
                        busy: vm.isOperating
                    ) {
                        Task { await vm.dockerOperate(base.bound == true ? "unbind" : "bind") }
                    }
                    CardActionButton(title: L10n.t("重置"), icon: "trash",
                                     color: .statusError, busy: vm.isOperating) {
                        showDockerReset = true
                    }
                    CardActionButton(title: L10n.t("导入"), icon: "square.and.arrow.down",
                                     color: .teal, busy: false,
                                     disabled: base.bound != true) {
                        showDockerImport = true
                    }
                }
            }
        default:
            // 设置段：无段级操作（配置项都在段内容里）
            EmptyView()
        }
    }

    /// 规则段基础链解绑/绑定（iptables/nftables；未初始化时不提供绑定）
    @ViewBuilder
    private var filterChainBindButton: some View {
        if vm.systemStatus?.backend == "iptables" || vm.systemStatus?.backend == "nftables" {
            if vm.systemStatus?.isBind == true {
                CardActionButton(title: L10n.t("解绑"), icon: "link.badge.plus",
                                 color: .secondary, busy: vm.isOperating) {
                    Task { await vm.operateFilterChain("unbind-base") }
                }
            } else if vm.systemStatus?.isInit == true {
                CardActionButton(title: L10n.t("绑定"), icon: "link",
                                 color: .green, busy: vm.isOperating) {
                    Task { await vm.operateFilterChain("bind-base") }
                }
            }
        }
    }

    // MARK: 规则段

    private var rulesSection: some View {
        Group {
            if needsRulesInit {
                uninitializedPlaceholder(
                    message: L10n.t("初始化后将创建 1Panel 基础链并接管规则管理；完成前不可创建规则。"),
                    buttonTitle: L10n.t("初始化")
                ) {
                    // 初始化方式（仅初始化 / 初始化并恢复规则）经菜单二选一
                    showInitMenu = true
                }
            } else if isRulesUnbound {
                unboundPlaceholder
            } else {
                rulesListContent
            }
        }
    }

    /// 长按规则弹窗（半屏）菜单项：可操作且非白名单保护 → 编辑/删除/上移下移；
    /// 末尾固定 导出规则 + 查看原文（v2.4.0 上游移除纳管，外部规则即普通规则）
    private var ruleActionItems: [ActionMenuItem] {
        guard let item = actionItem else { return [] }
        var items: [ActionMenuItem] = []
        if let target = item.operationTarget, let rule = item.rule {
            // 白名单保护规则（isWhitelist）不可编辑/删除；其余常规规则可
            if !item.isProtected {
                items.append(ActionMenuItem(title: L10n.t("编辑"), icon: "pencil", color: .blue) {
                    editingRuleTarget = target
                    editingRulePosition = item.observed?.locator?.position
                    editingRule = rule
                })
                items.append(ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red,
                                            role: .destructive) {
                    Haptic.warning()
                    pendingDeleteItem = item
                })
            }
            // 上移/下移按 ipvxRange 边界裁剪：已是链首（min）不可上移，
            // 已是链尾（max）不可下移；范围未知时不设限
            if let position = item.observed?.locator?.position {
                let range = vm.positionRange(family: rule.scope?.family)
                let minPos = range?.min ?? 1
                let maxPos = range?.max ?? Int.max
                if position > minPos {
                    items.append(ActionMenuItem(title: L10n.t("上移"), icon: "arrow.up", color: .orange) {
                        Task { await vm.reorderRule(target: target, to: Int64(max(minPos, position - 1))) }
                    })
                }
                if position < maxPos {
                    items.append(ActionMenuItem(title: L10n.t("下移"), icon: "arrow.down", color: .orange) {
                        Task { await vm.reorderRule(target: target, to: Int64(min(maxPos, position + 1))) }
                    })
                }
            }
        }
        // 导出入口仅对可导出规则展示（与导出页 exportable 过滤一致）：
        // 白名单保护规则在导出页被过滤，预选 id 落在列表外会
        // 出现「已选 1 条」却无勾选行、点导出必弹「暂无可导出的规则」
        if item.operationTarget != nil && !item.isProtected {
            items.append(ActionMenuItem(title: L10n.t("导出规则"),
                                        icon: "square.and.arrow.down", color: .teal) {
                // 仅预选长按的这条规则（与计划任务「导出任务」语义一致）
                ruleExportPreselect = [item.id]
                showExportPicker = true
            })
        }
        items.append(ActionMenuItem(title: L10n.t("查看原文"),
                                    icon: "doc.text.magnifyingglass", color: .gray) {
            Task {
                let text = await vm.loadNativeDetail(for: item)
                rawDetail = RawDetailPayload(
                    title: item.rule?.destinationPort ?? item.rule?.sourceAddress ?? "",
                    text: text)
            }
        })
        return items
    }

    private var rulesListContent: some View {
        // 单一 Section：头部 = 计数 + 筛选漏斗 Menu；空态与列表共用同一头部，
        // 保证筛空后（如某状态 0 条）筛选入口仍在，可一键切回
        Section {
            if vm.inventory.isEmpty && !vm.isRulesLoadingMore {
                ContentUnavailableView(L10n.t("暂无规则"), systemImage: "shield")
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(vm.inventory) { item in
                    FirewallRuleRowView(item: item,
                                        processName: processName(for: item),
                                        priority: item.observed?.locator?.position)
                        .rowTapAndLongPress(
                            onTap: {
                                // 白名单保护规则与不可操作规则：点击不进编辑
                                guard item.operationTarget != nil, !item.isProtected else { return }
                                if let target = item.operationTarget, let rule = item.rule {
                                    editingRuleTarget = target
                                    editingRulePosition = item.observed?.locator?.position
                                    editingRule = rule
                                }
                            },
                            onLongPress: { actionItem = item })
                        // VoiceOver 无长按手势：以自定义操作暴露同一菜单
                        .accessibilityAction(named: L10n.t("更多操作")) {
                            actionItem = item
                        }
                        .onAppear {
                            if item.id == vm.inventory.last?.id,
                               vm.inventory.count < vm.rulesResultTotal {
                                Task { await vm.loadRules(replacing: false) }
                            }
                        }
                }
                // 加载指示行仅在仍有更多页时出现（已加载全量时不再多占一行）
                if vm.isRulesLoadingMore && vm.inventory.count < vm.rulesResultTotal {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
        } header: {
            rulesHeader
        }
    }

    /// 规则段头部：筛选结果计数 + 筛选入口（Apple Notes「x 个备忘录 + ⋯」同款
    /// 模式）。计数本来就是筛选后的结果数，筛选值直接并入文案，图标做激活态提示
    private var rulesHeader: some View {
        HStack {
            Text(rulesHeaderText)
            Spacer()
            rulesFilterMenu
        }
    }

    private var rulesHeaderText: String {
        // v2.4.0 上游移除状态维度（state/managedTotal），仅剩地址族筛选。
        // 筛选/搜索生效时计数取结果总数（rulesResultTotal），与下方列表一致
        if let family = vm.ruleFamilyFilter {
            return L10n.f("共 %ld 条 · %@", vm.rulesResultTotal, family.uppercased())
        }
        if !vm.ruleSearchText.isEmpty {
            return L10n.f("共 %ld 条", vm.rulesResultTotal)
        }
        return L10n.f("共 %ld 条", vm.rulesAllTotal)
    }

    /// 地址族筛选漏斗菜单；筛选生效时图标实心高亮
    private var rulesFilterMenu: some View {
        Menu {
            familyMenuButton(nil, L10n.t("全部族"))
            familyMenuButton("ipv4", "IPv4")
            familyMenuButton("ipv6", "IPv6")
        } label: {
            Image(systemName: filterActive
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(filterActive ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(L10n.t("地址族筛选"))
    }

    private var filterActive: Bool {
        vm.ruleFamilyFilter != nil
    }

    private func familyMenuButton(_ family: String?, _ label: String) -> some View {
        Button {
            guard vm.ruleFamilyFilter != family else { return }
            vm.ruleFamilyFilter = family
            reloadRules()
        } label: {
            if vm.ruleFamilyFilter == family {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    private func reloadRules() {
        Task { await vm.loadRules(replacing: true) }
    }

    /// 搜索提交/取消：同步搜索词到 VM 并整段重载（服务端过滤）
    private func commitSearch() {
        guard !vm.unsupportedPanel else { return }
        vm.ruleSearchText = searchText
        reloadRules()
    }

    private func processName(for item: FirewallInventoryItem) -> String? {
        let rule = item.rule
        return vm.processName(port: rule?.destinationPort, proto: rule?.protocolField)
    }

    // MARK: 转发段

    private var forwardSection: some View {
        Group {
            if needsForwardInit {
                uninitializedPlaceholder(
                    message: L10n.t("启用端口转发子系统后将创建转发规则链；完成前不可创建转发。"),
                    buttonTitle: L10n.t("初始化")
                ) {
                    Task { await vm.enableForwarding() }
                }
            } else {
                forwardListContent
            }
        }
    }

    private var forwardListContent: some View {
        Group {
            // 转发子系统状态分组已移除（初始化状态并入头部，操作收进右上角菜单）
            if vm.forwards.isEmpty {
                Section {
                    ContentUnavailableView(L10n.t("暂无转发规则"), systemImage: "arrow.triangle.branch")
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(vm.forwards) { rule in
                        FirewallForwardRowView(rule: rule)
                            .rowTapAndLongPress(
                                onTap: { editingForward = rule },
                                onLongPress: { actionForward = rule })
                            // VoiceOver 无长按手势：以自定义操作暴露同一菜单
                            .accessibilityAction(named: L10n.t("更多操作")) { actionForward = rule }
                            .onAppear {
                                if rule.id == vm.forwards.last?.id,
                                   vm.forwards.count < vm.forwardsTotal {
                                    Task { await vm.loadForwards(replacing: false) }
                                }
                            }
                    }
                    if vm.isForwardsLoadingMore {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                } header: {
                    Text(L10n.f("共 %ld 条", vm.forwardsTotal))
                }
            }
        }
    }

    // MARK: Docker 守护段

    private var dockerSection: some View {
        Group {
            if let guard_ = vm.dockerGuard, let base = guard_.base, base.isExist == true {
                if needsDockerInit {
                    uninitializedPlaceholder(
                        message: L10n.t("初始化容器端口防护后将接管已发布端口的访问控制；完成前不可配置策略。"),
                        buttonTitle: L10n.t("初始化")
                    ) {
                        Task { await vm.dockerOperate("initialize") }
                    }
                } else if base.bound == false {
                    // 解绑态：守护链已摘除，容器列表不展示（绑定入口在操作行）
                    unboundPlaceholder
                } else {
                    dockerListContent(guard_, base)
                }
            } else {
                Section {
                    ContentUnavailableView(
                        L10n.t("Docker 守护不可用"),
                        systemImage: "shippingbox",
                        description: Text(L10n.t("未检测到 Docker 或守护链不可用；安装 Docker 后下拉刷新。"))
                    )
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .listRowBackground(Color.clear)
                }
            }
        }
    }

    /// 孤立策略菜单标题：主机 IP:端口（与行首展示一致）
    private func orphanTitle(_ e: DockerGuardEndpoint) -> String {
        e.hostLabel
    }

    /// 可删除的孤立策略行：长按弹半屏菜单（闭包构建时捕获 endpoint，
    /// 经 ActionBottomSheet「先收抽屉再延迟执行」契约安全送达）
    private func orphanRow(_ endpoint: DockerGuardEndpoint) -> some View {
        DockerGuardEndpointRow(endpoint: endpoint)
            .contentShape(Rectangle())
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    Haptic.selection()
                    actionOrphan = endpoint
                }
            )
            .accessibilityAction(named: L10n.t("更多操作")) {
                actionOrphan = endpoint
            }
    }

    /// Docker 段主内容（已初始化）：容器入口行 + 孤立策略
    private func dockerListContent(_ guard_: DockerGuardList, _ base: DockerGuardBase) -> some View {
        Group {
                ForEach(guard_.containers ?? []) { container in
                    DockerGuardContainerSection(
                        container: container,
                        onEditPolicy: { endpoint in
                            if endpoint.managementTarget == "host_firewall" {
                                vm.toastMessage = L10n.t("该端点由主机防火墙规则管理，请在规则段调整")
                            } else {
                                editingPolicy = endpoint
                            }
                        },
                        onExport: {
                            // 仅预选该容器的策略（与计划任务「导出任务」语义一致）
                            dockerExportPreselect = vm.dockerExportableIndices(containerID: container.id)
                            showDockerExportPicker = true
                        },
                        onOpen: { pushedContainer = container }
                    )
                }

                if let orphans = guard_.orphanPolicies, !orphans.isEmpty {
                    Section {
                        ForEach(orphans) { endpoint in
                            // 可删除的孤立策略：长按弹半屏菜单（与规则/转发行一致，
                            // 替代原右划删除）；无策略 id 的行不可删（VM 侧会
                            // 静默 return），不挂菜单以免确认后零反馈。
                            // v2.4.0 上游移除 readOnly 字段，不再有只读孤立策略
                            if let uuid = endpoint.policyUUID, !uuid.isEmpty {
                                orphanRow(endpoint)
                            } else {
                                DockerGuardEndpointRow(endpoint: endpoint)
                            }
                        }
                    } header: {
                        SectionLabel(title: L10n.t("孤立策略"), systemImage: "questionmark.circle")
                    } footer: {
                        Text(L10n.t("长按策略可删除；删除后该端口的访问控制将被移除。"))
                    }
                }
        }
    }
}

