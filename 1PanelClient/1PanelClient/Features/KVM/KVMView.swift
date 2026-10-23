//
//  KVMView.swift
//  1PanelClient
//
//  虚拟机管理根页（高级功能分组，/xpack/vms/*，专业版门禁；logs/高级功能-KVM.md 抓包 2026-10-23）：
//  进页先 GET environment 检测依赖（架构 / 辅助程序 / KVM 设备 / libvirt / 存储目录），
//  未就绪只显检测卡 + 重新检测；就绪后分段 虚拟机 / 镜像 / 模版 / 网络 / 存储池。
//  虚拟机段：卡片列表（每台一卡：点击卡进详情、长按弹操作菜单——电源 / 编辑 / 重命名 / 删除，
//  卡上常驻 监控·快照·磁盘管理·转为模版 四个快捷按钮，按状态可用），工具栏 创建 + 同步。
//  任务式操作进度由根页 navigationDestination(item: activeTask) 推入 TaskProgressView
//  （operateNode=local），完成后重拉当前段。VNC 控制台为二进制 RFB over WebSocket，
//  客户端暂不实现，仅详情展示连接信息。
//

import SwiftUI
import Combine

// MARK: - 根页

struct KVMView: View {
    let server: ServerConfig
    @StateObject private var vm: KVMViewModel

    init(server: ServerConfig) {
        self.server = server
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(key: ManageItem.kvm.storeKey(server: server)) {
            KVMViewModel(server: server)
        })
    }

    var body: some View {
        Group {
            if vm.isCheckingEnvironment && vm.environment == nil {
                LoadingStateView()
            } else if let env = vm.environment, !env.isReady {
                KVMEnvironmentView(environment: env, isChecking: vm.isCheckingEnvironment) {
                    await vm.checkEnvironment()
                    if vm.environment?.isReady == true { await vm.loadSegment() }
                }
            } else if vm.environment == nil, let err = vm.environmentError {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button(L10n.t("重试")) { Task { await vm.load() } }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                content
            }
        }
        .navigationTitle(L10n.t("虚拟机管理"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await PageVMStore.shared.autoRefresh(vm: vm) { await vm.load() } }
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        // 任务式操作进度（创建/编辑由表单自行 push；其余列表级操作在此推入）
        .navigationDestination(item: $vm.activeTask) { target in
            TaskProgressView(taskID: target.taskID, title: target.title, node: "local") { isDone in
                if isDone { Task { await vm.loadSegment() } }
                return false
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Picker(L10n.t("分段"), selection: $vm.segment) {
                ForEach(KVMViewModel.Segment.allCases) { segment in
                    Text(segment.title).tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch vm.segment {
            case .vms: KVMVMListView(vm: vm)
            case .iso: KVMISOListView(vm: vm)
            case .templates: KVMTemplateListView(vm: vm)
            case .networks: KVMNetworkListView(vm: vm)
            case .storages: KVMStorageListView(vm: vm)
            }
        }
        .onChange(of: vm.segment) { _, _ in
            Task { await vm.loadSegment() }
        }
    }
}

// MARK: - 环境检测卡

/// 依赖未就绪：逐项显示 通过 / 未通过 + 服务端信息，提供重新检测
struct KVMEnvironmentView: View {
    let environment: KVMEnvironment
    let isChecking: Bool
    let onRetry: () async -> Void

    var body: some View {
        List {
            Section {
                ForEach(Array(environment.checks.enumerated()), id: \.offset) { _, check in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(check.passed ? Color.statusRunning : Color.statusError)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title)
                            if !check.message.isEmpty {
                                Text(check.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                SectionLabel(title: L10n.t("环境检测"), systemImage: "stethoscope")
            } footer: {
                Text(L10n.t("虚拟机管理依赖 KVM 设备、libvirt 服务与存储目录；请在面板网页端完成依赖安装后重新检测。"))
            }

            Section {
                Button {
                    Task { await onRetry() }
                } label: {
                    HStack {
                        if isChecking { ProgressView() } else { Text(L10n.t("重新检测")) }
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(isChecking)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await onRetry() }
    }
}

// MARK: - 虚拟机列表

/// 虚拟机推入路由（详情 / 编辑 / 监控 / 磁盘管理 / 快照共用一个 item 目标——
/// navigationDestination(item:) 同类型多次声明只认第一个，须收敛为单枚举）
enum KVMVMRoute: Hashable {
    case detail(KVMVirtualMachine)
    case edit(KVMVirtualMachine)
    case monitor(KVMVirtualMachine)
    case disks(KVMVirtualMachine)
    case snapshots(KVMVirtualMachine)
}

struct KVMVMListView: View {
    @ObservedObject var vm: KVMViewModel

    @State private var showCreate = false
    @State private var actionVM: KVMVirtualMachine?
    @State private var route: KVMVMRoute?
    @State private var renameVM: KVMVirtualMachine?
    @State private var templateVM: KVMVirtualMachine?
    @State private var deleteVM: KVMVirtualMachine?
    @State private var forceDelete = false
    @State private var pendingOperate: (vm: KVMVirtualMachine, operate: KVMOperate)?
    @State private var isSyncing = false

    var body: some View {
        List {
            if vm.vms.isEmpty {
                vmEmptySection
            } else {
                // 每台虚拟机一张卡（独立 Section）：信息行 + 四个快捷按钮
                ForEach(vm.vms) { machine in
                    vmCard(machine)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await vm.loadVMs() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        isSyncing = true
                        defer { isSyncing = false }
                        await vm.sync()
                    }
                } label: {
                    if isSyncing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(isSyncing)
                .accessibilityLabel(L10n.t("同步"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("创建虚拟机"))
            }
        }
        // 创建中 / 关机中等过渡态轮询，稳定后停
        .adaptivePolling(interval: 5, isActive: { vm.hasTransitioningVM }) {
            await vm.loadVMs()
        }
        .navigationDestination(isPresented: $showCreate) {
            KVMVMFormView(vm: vm)
        }
        .navigationDestination(item: $route) { route in
            switch route {
            case .detail(let machine): KVMVMDetailView(vm: vm, machine: machine)
            case .edit(let machine): KVMVMFormView(vm: vm, machine: machine)
            case .monitor(let machine): KVMVMMonitorView(vm: vm, machine: machine)
            case .disks(let machine): KVMDiskManageView(vm: vm, machine: machine)
            case .snapshots(let machine): KVMSnapshotListView(vm: vm, machine: machine)
            }
        }
        .sheet(item: $actionVM) { machine in
            ActionBottomSheet(
                title: machine.displayName,
                items: actionItems(machine),
                onDismiss: { actionVM = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: actionItems(machine).count))])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $renameVM) { machine in
            KVMRenameSheet(machine: machine) { newName in
                await vm.rename(machine, to: newName) != nil
            }
        }
        .sheet(item: $templateVM) { machine in
            KVMToTemplateSheet(machine: machine, storagePools: vm.storages.compactMap(\.name)) { name, pool, desc in
                await vm.convertToTemplate(machine, templateName: name, storagePool: pool, description: desc) != nil
            }
            .task { if vm.storages.isEmpty { await vm.loadStorages() } }
        }
        .sheet(item: $deleteVM) { machine in
            TextInputConfirmSheet(
                title: L10n.t("删除虚拟机"),
                message: L10n.f("将删除虚拟机「%@」及其磁盘文件，不可恢复。请输入虚拟机名称以确认删除。", machine.displayName),
                expectedText: machine.displayName
            ) {
                await vm.delete(machine, force: forceDelete)
            } options: {
                Section {
                    Toggle(L10n.t("强制删除"), isOn: $forceDelete)
                } footer: {
                    Text(L10n.t("强制删除会先强行停止运行中的虚拟机再删除"))
                }
            }
        }
        .alert(
            pendingOperate.map { $0.operate.displayName } ?? "",
            isPresented: Binding(
                get: { pendingOperate != nil },
                set: { if !$0 { pendingOperate = nil } }
            )
        ) {
            Button(L10n.t("取消"), role: .cancel) { pendingOperate = nil }
            Button(L10n.t("确认"), role: .destructive) {
                Haptic.warning()
                if let pending = pendingOperate {
                    Task { await vm.operate(pending.vm, pending.operate) }
                }
                pendingOperate = nil
            }
        } message: {
            if let pending = pendingOperate {
                Text(L10n.f("将对虚拟机「%@」执行 %@ 操作，是否继续？",
                            pending.vm.displayName, pending.operate.displayName))
            }
        }
    }

    // MARK: 卡片 / 空态

    /// 空态 / 加载失败 / 加载中（无卡可显时）
    private var vmEmptySection: some View {
        Section {
            if vm.isLoading {
                LoadingStateView(compact: true)
                    .padding(.vertical, 30)
            } else if let err = vm.errorMessage {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button(L10n.t("重试")) { Task { await vm.loadVMs() } }
                }
                .listRowBackground(Color.clear)
            } else {
                ContentUnavailableView(
                    L10n.t("暂无虚拟机"),
                    systemImage: "desktopcomputer",
                    description: Text(L10n.t("点击右上角 + 创建虚拟机，或点击同步导入 libvirt 中已有的虚拟机"))
                )
                .listRowBackground(Color.clear)
            }
        }
    }

    /// 单台虚拟机卡：信息行（点击进详情 / 长按弹菜单）+ 快捷按钮行
    /// （监控 运行态、快照 随时、磁盘管理与转为模版 关机态；不可用时按钮置灰保留位）
    private func vmCard(_ machine: KVMVirtualMachine) -> some View {
        Section {
            KVMVMRow(machine: machine, isOperating: vm.operatingIDs.contains(machine.id))
                .rowTapAndLongPress(
                    onTap: { route = .detail(machine) },
                    onLongPress: { actionVM = machine }
                )
                .listRowSeparator(.hidden)
                .onAppear {
                    if machine.id == vm.vms.last?.id {
                        Task { await vm.loadMoreVMs() }
                    }
                }

            HStack(spacing: 8) {
                CardActionButton(
                    title: L10n.t("监控"), icon: "chart.xyaxis.line", color: .blue,
                    disabled: !machine.isRunning
                ) {
                    route = .monitor(machine)
                }
                CardActionButton(
                    title: L10n.t("快照"), icon: "camera.on.rectangle", color: .purple
                ) {
                    route = .snapshots(machine)
                }
                CardActionButton(
                    title: L10n.t("磁盘管理"), icon: "internaldrive", color: .teal,
                    disabled: !machine.isShutOff
                ) {
                    route = .disks(machine)
                }
                CardActionButton(
                    title: L10n.t("转为模版"), icon: "doc.on.doc", color: .indigo,
                    disabled: !machine.isShutOff
                ) {
                    templateVM = machine
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 4)
        }
    }

    /// 长按菜单：电源操作 / 关机态 编辑·重命名 / 删除。
    /// 监控·快照·磁盘管理·转为模版为卡上常驻按钮，菜单不再重复
    private func actionItems(_ machine: KVMVirtualMachine) -> [ActionMenuItem] {
        var items: [ActionMenuItem] = []
        for operate in KVMOperate.available(for: machine) {
            items.append(ActionMenuItem(
                title: operate.displayName, icon: operate.icon,
                color: Self.operateColor(operate),
                role: operate == .destroy ? .destructive : nil
            ) {
                // 启动 / 恢复无破坏性直接执行；停止 / 重启 / 暂停 / 强停需确认
                if operate == .start || operate == .resume {
                    Task { await vm.operate(machine, operate) }
                } else {
                    pendingOperate = (machine, operate)
                }
            })
        }
        if machine.isShutOff {
            items.append(ActionMenuItem(title: L10n.t("编辑"), icon: "pencil", color: .teal) {
                route = .edit(machine)
            })
            items.append(ActionMenuItem(title: L10n.t("重命名"), icon: "character.cursor.ibeam", color: .indigo) {
                renameVM = machine
            })
        }
        items.append(ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red, role: .destructive) {
            forceDelete = false
            deleteVM = machine
        })
        return items
    }

    private static func operateColor(_ operate: KVMOperate) -> Color {
        switch operate {
        case .start, .resume: return .green
        case .shutdown: return .orange
        case .reboot: return .blue
        case .suspend: return .yellow
        case .destroy: return .red
        }
    }
}

// MARK: - 虚拟机行

struct KVMVMRow: View {
    let machine: KVMVirtualMachine
    let isOperating: Bool

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "desktopcomputer", color: .blue)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(machine.displayName)
                        .font(.body.bold())
                        .lineLimit(1)
                    if isOperating {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
                Text(L10n.f("%ld 核 · %ld MB · %ld GB",
                            machine.cpu ?? 0, machine.memory ?? 0, machine.diskSize ?? 0))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if let network = machine.network, !network.isEmpty {
                        Label(network, systemImage: "network")
                    }
                    if let pool = machine.storagePool, !pool.isEmpty {
                        Label(pool, systemImage: "internaldrive")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }

            Spacer()

            KVMStatusBadge(status: machine.status)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// 虚拟机状态徽标（running 绿 / paused 黄 / shut off 灰 / 其余蓝或红）
struct KVMStatusBadge: View {
    let status: String?

    var body: some View {
        let style = Self.style(for: status)
        StatusBadge(text: style.text, color: style.color)
    }

    static func style(for status: String?) -> (text: String, color: Color) {
        switch (status ?? "").lowercased() {
        case "running": return (L10n.t("运行中"), .statusRunning)
        case "shut off", "shutoff": return (L10n.t("已关机"), .secondary)
        case "paused", "pmsuspended": return (L10n.t("已暂停"), .yellow)
        case "in shutdown": return (L10n.t("关机中"), .blue)
        case "crashed": return (L10n.t("已崩溃"), .statusError)
        case "": return ("-", .secondary)
        default: return (status ?? "-", .blue)
        }
    }
}

// MARK: - 重命名

/// 重命名（仅关机态；POST rename {taskID, name, newName} → 任务进度）
struct KVMRenameSheet: View {
    let machine: KVMVirtualMachine
    /// 返回 true 表示已提交（关闭弹层）
    let onSubmit: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    OutlinedTextField(label: L10n.t("新名称"), text: $newName)
                } footer: {
                    Text(L10n.f("当前名称：%@", machine.displayName))
                }
            }
            .navigationTitle(L10n.t("重命名"))
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
                            if await onSubmit(newName.trimmingCharacters(in: .whitespaces)) {
                                dismiss()
                            }
                        }
                    } label: {
                        if isSubmitting { ProgressView() } else { Text(L10n.t("确认")).bold() }
                    }
                    .disabled(!isValid || isSubmitting)
                }
            }
            .onAppear { newName = machine.displayName }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.medium])
    }

    private var isValid: Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != machine.displayName
    }
}

// MARK: - 转为模版

/// 虚拟机转模版（仅关机态；模版名默认「虚拟机名-tpl」，存储池默认沿用虚拟机的）
struct KVMToTemplateSheet: View {
    let machine: KVMVirtualMachine
    let storagePools: [String]
    /// (模版名, 存储池, 描述) → 已提交
    let onSubmit: (String, String, String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var templateName = ""
    @State private var storagePool = ""
    @State private var description = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    OutlinedTextField(label: L10n.t("模版名称"), text: $templateName)
                    OutlinedPicker(label: L10n.t("存储池"),
                                   options: poolOptions, selection: $storagePool)
                    OutlinedMultiLineField(label: L10n.t("描述"), lines: 3, text: $description)
                } footer: {
                    Text(L10n.t("将以当前磁盘内容生成模版镜像，可用于后续「从模版启动」快速创建。"))
                }
            }
            .navigationTitle(L10n.t("转为模版"))
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
                            if await onSubmit(templateName.trimmingCharacters(in: .whitespaces),
                                              storagePool, description) {
                                dismiss()
                            }
                        }
                    } label: {
                        if isSubmitting { ProgressView() } else { Text(L10n.t("确认")).bold() }
                    }
                    .disabled(templateName.trimmingCharacters(in: .whitespaces).isEmpty
                              || storagePool.isEmpty || isSubmitting)
                }
            }
            .onAppear {
                if templateName.isEmpty { templateName = machine.displayName + "-tpl" }
                if storagePool.isEmpty {
                    storagePool = machine.storagePool ?? poolOptions.first ?? ""
                }
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.medium, .large])
    }

    /// 存储池选项：列表为空时至少保留虚拟机当前存储池，避免下拉无值
    private var poolOptions: [String] {
        var options = storagePools
        if let current = machine.storagePool, !current.isEmpty, !options.contains(current) {
            options.insert(current, at: 0)
        }
        return options.isEmpty ? ["default"] : options
    }
}
