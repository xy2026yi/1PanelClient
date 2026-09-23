//
//  SnapshotViews.swift
//  1PanelClient
//
//  面板快照（logs/推荐实现-计划任务和面板.md 抓包 2026-09-14）：
//  列表（删除/恢复）· 创建（分页向导：基础数据 → 应用 → 数据 → 其他，全量回传 + 任务进度）
//  网页端 6 步向导在移动端收敛为 4 页（数据树勾选保持原生 Toggle，形态 9 约定）
//

import SwiftUI

// MARK: - 快照列表

struct SnapshotListView: View {
    let server: ServerConfig

    /// 数据态与网络动作（@Observable 样板：导航/弹窗呈现态留在视图）
    @State private var vm: SnapshotListViewModel

    @State private var showCreate = false
    @State private var showImport = false
    @State private var showAddMenu = false
    @State private var pendingDelete: SnapshotItem?
    @State private var deleteWithFile = false
    @State private var recoveringItem: SnapshotItem?
    @State private var editingSnapshot: SnapshotItem?
    @State private var pendingRecreate: SnapshotItem?
    /// 创建/恢复任务（taskID → 任务进度页）
    @State private var progressTask: SnapshotTaskTarget?

    init(server: ServerConfig) {
        self.server = server
        _vm = State(initialValue: SnapshotListViewModel(server: server))
    }

    var body: some View {
        List {
            if vm.isLoading {
                HStack { Spacer(); LoadingStateView(); Spacer() }
                    .listRowBackground(Color.clear)
            } else if let err = vm.loadError {
                LoadErrorStateView(message: err) {
                    Task { await vm.load() }
                }
                .listRowBackground(Color.clear)
            } else if vm.snapshots.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无快照"),
                    systemImage: "externaldrive.badge.timemachine",
                    description: Text(L10n.t("点击右上角 + 创建快照")))
                .listRowBackground(Color.clear)
            } else {
                ForEach(vm.snapshots) { snapshot in
                    snapshotRow(snapshot)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("快照"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddMenu = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("创建快照"))
            }
        }
        .sheet(isPresented: $showAddMenu) {
            ActionBottomSheet(title: L10n.t("快照"), items: [
                ActionMenuItem(title: L10n.t("创建快照"), icon: "plus.circle", color: .accentColor) {
                    showCreate = true
                },
                ActionMenuItem(title: L10n.t("导入快照"), icon: "square.and.arrow.down", color: .blue) {
                    showImport = true
                },
            ]) {
                showAddMenu = false
            }
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: 2))])
            .presentationDragIndicator(.visible)
        }
        .task { await vm.load() }
        .refreshable { await vm.load() }
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("提示"), isPresented: $vm.showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
        // 创建表单 push 进入（与安装应用一致）；创建进度由表单内自行 push，
        // 完成回调仅用于刷新列表
        .navigationDestination(isPresented: $showCreate) {
            SnapshotCreateView(server: server) { _ in
                Task { await vm.load() }
            }
        }
        .sheet(item: $recoveringItem) { snapshot in
            SnapshotRecoverSheet(server: server, snapshot: snapshot) { secret, taskID in
                Task {
                    if let tid = await vm.recover(snapshot, secret: secret, taskID: taskID) {
                        progressTask = SnapshotTaskTarget(
                            taskID: tid, title: L10n.f("恢复快照 %@", snapshot.displayName))
                    }
                }
            }
        }
        .alert(L10n.t("删除快照"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingDelete = nil }
            Button(L10n.t("删除"), role: .destructive) {
                if let snapshot = pendingDelete {
                    Task { await vm.delete(snapshot, deleteWithFile: deleteWithFile) }
                }
            }
        } message: {
            if let snapshot = pendingDelete {
                Text(L10n.f("确定删除快照「%@」吗？", snapshot.displayName) + (deleteWithFile ? "\n" + L10n.t("将同时删除备份文件") : ""))
            }
        }
        .navigationDestination(item: $progressTask) { target in
            TaskProgressView(taskID: target.taskID, title: target.title) { isDone in
                if isDone {
                    Task { await vm.load() }
                    if target.title.hasPrefix(L10n.t("恢复快照")) { vm.toastMessage = L10n.t("快照已恢复") }
                }
                return false
            }
        }
        .navigationDestination(isPresented: $showImport) {
            SnapshotImportView(server: server) {
                Task { await vm.load() }
            }
        }
        .sheet(item: $editingSnapshot) { snapshot in
            DescriptionEditSheet(
                title: L10n.t("修改描述"),
                initial: snapshot.description ?? ""
            ) { newText in
                await vm.submitDescription(snapshot, newText)
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .alert(L10n.t("重新制作快照"), isPresented: Binding(
            get: { pendingRecreate != nil },
            set: { if !$0 { pendingRecreate = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingRecreate = nil }
            Button(L10n.t("重新制作"), role: .destructive) {
                if let snapshot = pendingRecreate {
                    Task {
                        if let tid = await vm.recreate(snapshot) {
                            progressTask = SnapshotTaskTarget(
                                taskID: tid, title: L10n.f("重新制作快照 %@", snapshot.displayName))
                        }
                    }
                }
                pendingRecreate = nil
            }
        } message: {
            if let snapshot = pendingRecreate {
                Text(L10n.f("确定重新制作快照「%@」吗？将沿用原有配置并复用原任务进度。", snapshot.displayName))
            }
        }
    }

    private func snapshotRow(_ snapshot: SnapshotItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(snapshot.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Spacer()
                StatusDot(color: snapshot.isOK ? .green : .orange, diameter: 8)
                Text(snapshot.status ?? "-")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(snapshot.displayCreatedAt)
                if let size = snapshot.size, size > 0 {
                    Text(Self.fmt(size))
                }
                if let version = snapshot.version, !version.isEmpty {
                    Text(version)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let accounts = snapshot.sourceAccounts, !accounts.isEmpty {
                Text((L10n.t("备份账号")) + ": " + accounts.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let desc = snapshot.description, !desc.isEmpty {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { recoveringItem = snapshot }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteWithFile = false
                pendingDelete = snapshot
            } label: {
                Label(L10n.t("删除"), systemImage: "trash")
            }
            Button {
                recoveringItem = snapshot
            } label: {
                Label(L10n.t("恢复"), systemImage: "arrow.counterclockwise")
            }
            .tint(.blue)
            Button {
                editingSnapshot = snapshot
            } label: {
                Label(L10n.t("修改描述"), systemImage: "pencil.line")
            }
            .tint(.teal)
            Button {
                pendingRecreate = snapshot
            } label: {
                Label(L10n.t("重新制作"), systemImage: "hammer")
            }
            .tint(.indigo)
        }
    }

    static func fmt(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(bytes)
        var idx = 0
        while size >= 1024 && idx < units.count - 1 {
            size /= 1024
            idx += 1
        }
        return String(format: "%.2f %@", size, units[idx])
    }
}

/// 快照任务（创建/恢复共用：taskID → 任务进度页）
struct SnapshotTaskTarget: Identifiable, Hashable {
    let taskID: String
    let title: String
    var id: String { taskID }
}

// MARK: - 恢复 Sheet（压缩密码 + 磁盘空间校验 + 风险确认）

private struct SnapshotRecoverSheet: View {
    let snapshot: SnapshotItem
    let onConfirm: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var secret = ""
    @State private var confirmed = false
    /// 磁盘空间校验：系统可用空间与快照文件大小（任一取不到则不拦截）
    @State private var diskSize: Int64?
    @State private var snapshotFileSize: Int64?
    /// 校验数据加载完成（含失败）：完成前禁用恢复，避免异步间隙绕过校验
    @State private var diskCheckReady = false
    @State private var showSpaceAlert = false

    private let client: APIClient

    init(server: ServerConfig, snapshot: SnapshotItem,
         onConfirm: @escaping (String, String) -> Void) {
        self.snapshot = snapshot
        self.onConfirm = onConfirm
        self.client = APIClient.shared(for: server)
    }

    /// 可用空间需大于快照文件大小；数据取不到时放行（不因辅助接口失败卡死恢复）
    private var hasEnoughSpace: Bool {
        guard let diskSize, let snapshotFileSize else { return true }
        return diskSize > snapshotFileSize
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // 形态 1 只读展示 + 小锁：快照由列表选定，此处不可改
                    OutlinedShape(label: L10n.t("快照"), isFocused: false,
                                  hasValue: true,
                                  trailing: {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }) {
                        Text(snapshot.displayName)
                            .lineLimit(2)
                    }
                    if !diskCheckReady {
                        HStack(spacing: 6) {
                            ProgressView()
                            Text(L10n.t("正在检查磁盘空间…"))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else if diskSize != nil || snapshotFileSize != nil {
                        VStack(alignment: .leading, spacing: 2) {
                            if let size = snapshotFileSize {
                                Text(L10n.f("快照大小：%@", SnapshotListView.fmt(size)))
                            }
                            if let disk = diskSize {
                                Text(L10n.f("系统可用空间：%@", SnapshotListView.fmt(disk)))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Section {
                    OutlinedPasswordField(label: L10n.t("压缩密码（可选）"), text: $secret)
                } header: {
                    SectionLabel(title: L10n.t("恢复选项"), systemImage: "key")
                }
                Section {
                    Toggle(L10n.t("我已知晓恢复将重启 Docker 与 1Panel 服务"), isOn: $confirmed)
                } footer: {
                    Text(L10n.t("该操作仅回滚主节点；请确保磁盘空间充足且服务器架构与创建快照时一致。"))
                }
            }
            .navigationTitle(L10n.t("恢复快照"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("恢复"), role: .destructive) {
                        guard hasEnoughSpace else {
                            showSpaceAlert = true
                            return
                        }
                        Haptic.warning()
                        let taskID = UUID().uuidString
                        onConfirm(secret, taskID)
                        dismiss()
                    }
                    .disabled(!confirmed || !diskCheckReady)
                }
            }
            .alert(L10n.t("提示"), isPresented: $showSpaceAlert) {
                Button(L10n.t("好的"), role: .cancel) {}
            } message: {
                Text(L10n.t("系统可用空间不足，无法恢复快照"))
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.medium])
        .task { await loadDiskInfo() }
    }

    /// 并行取系统可用空间（dashboard/base/os）与快照文件大小（backups/record/size，按 id 匹配）；
    /// 结束（含失败）置 diskCheckReady，恢复按钮在此之前禁用
    private func loadDiskInfo() async {
        defer { diskCheckReady = true }
        async let os: OsInfo? = try? await client.send(
            path: APIEndpoint.dashboardOS.path,
            method: APIEndpoint.dashboardOS.method,
            as: OsInfo.self
        )
        async let sizes: [BackupRecordSizeItem]? = try? await client.send(
            path: APIEndpoint.backupsRecordSize.path,
            body: BackupRecordSearchRequest(
                page: 1, pageSize: 500, type: "snapshot", name: "", detailName: ""),
            as: [BackupRecordSizeItem].self
        )
        diskSize = (await os)?.diskSize
        // 列表页兜底：record/size 分页超过 500 条时匹配不到，用列表项自带 size
        snapshotFileSize = (await sizes)?.first(where: { $0.id == snapshot.id })?.size
            ?? snapshot.size
    }
}

// MARK: - 数据树勾选

/// 快照数据树：父节点为分组标题（DisclosureGroup），叶子节点为勾选行
private struct SnapshotTreeSection: View {
    let title: String
    let systemIcon: String
    let nodes: [SnapshotNode]
    @Binding var checked: Set<String>
    /// 叶子勾选变化回调（应用数据树用于「应用镜像」与总开关联动）
    var onLeafToggled: ((SnapshotNode, Bool) -> Void)? = nil

    var body: some View {
        Section {
            ForEach(nodes) { node in
                if node.isLeaf {
                    SnapshotLeafRow(node: node, checked: $checked, onToggled: onLeafToggled)
                } else {
                    SnapshotGroupNode(node: node, checked: $checked, onLeafToggled: onLeafToggled)
                }
            }
        } header: {
            SectionLabel(title: title, systemImage: systemIcon)
        }
    }
}

/// 分组节点（应用/备份树的中间层）：DisclosureGroup 展开子节点
private struct SnapshotGroupNode: View {
    let node: SnapshotNode
    @Binding var checked: Set<String>
    var onLeafToggled: ((SnapshotNode, Bool) -> Void)? = nil

    var body: some View {
        DisclosureGroup {
            ForEach(node.children ?? []) { child in
                if child.isLeaf {
                    SnapshotLeafRow(node: child, checked: $checked, onToggled: onLeafToggled)
                } else {
                    SnapshotGroupNode(node: child, checked: $checked, onLeafToggled: onLeafToggled)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(node.label)
                    .font(.subheadline.weight(.medium))
                Text(SnapshotListView.fmt(node.size))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 叶子勾选行：label + 大小 + 开关（isDisable 锁定，如 docker/geo/runtime/task）
private struct SnapshotLeafRow: View {
    let node: SnapshotNode
    @Binding var checked: Set<String>
    var onToggled: ((SnapshotNode, Bool) -> Void)? = nil

    private var label: String {
        switch node.label {
        case "appData": return L10n.t("应用数据")
        case "appImage": return L10n.t("应用镜像")
        default: return node.label
        }
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { checked.contains(node.id) },
            set: { on in
                if on { checked.insert(node.id) } else { checked.remove(node.id) }
                onToggled?(node, on)
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                HStack(spacing: 6) {
                    if !node.name.isEmpty, node.name != node.label {
                        Text(node.name)
                    }
                    if node.size > 0 {
                        Text(SnapshotListView.fmt(node.size))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .disabled(node.isDisable)
    }
}

// MARK: - 创建快照（分页向导：基础数据 → 应用 → 数据 → 其他）

struct SnapshotCreateView: View {
    let server: ServerConfig
    /// 创建任务完成回调（表单内已自行展示任务进度，回调仅用于父级刷新列表）
    let onTaskStarted: (SnapshotTaskTarget) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var loadData: SnapshotLoadData?
    @State private var loadError: String?
    @State private var accounts: [BackupOption] = []
    @State private var selectedAccountID: Int?
    @State private var secret = ""
    @State private var timeoutValue = 3600
    @State private var timeoutUnit = "s"
    @State private var descriptionText = ""
    @State private var backupAllImage = false
    @State private var withDockerConf = true
    @State private var withMonitorData = false
    @State private var withLoginLog = false
    @State private var withOperationLog = false
    @State private var withSystemLog = false
    @State private var withTaskLog = false
    /// 勾选的叶子节点 id 集合（提交时回写树的 isCheck）
    @State private var checked: Set<String> = []
    /// 排除规则多行文本（每行一条；提交时拆分为 ignoreFiles 数组）
    @State private var ignoreRulesText = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showError = false
    /// 创建任务进度（提交成功后由表单内 push，与安装应用同模式）
    @State private var activeTask: SnapshotTaskTarget?

    /// 向导分页：0 基础数据 1 系统应用+应用数据 2 系统数据+备份数据 3 其他数据+排除规则
    @State private var wizardPage = 0
    private let wizardPageNames = [L10n.t("基础"), L10n.t("应用"), L10n.t("数据"), L10n.t("其他")]
    /// 叶子关闭引发的级联置位：此时总开关关闭只改自身，不清空其余应用的个别勾选
    @State private var suppressMasterClear = false

    private let client: APIClient
    private let timeoutUnits: [(value: String, label: String, seconds: Int)] = [
        ("s", L10n.t("秒"), 1), ("m", L10n.t("分钟"), 60), ("h", L10n.t("小时"), 3600),
    ]

    init(server: ServerConfig, onTaskStarted: @escaping (SnapshotTaskTarget) -> Void) {
        self.server = server
        self.onTaskStarted = onTaskStarted
        self.client = APIClient.shared(for: server)
    }

    private var timeoutSeconds: Int {
        timeoutValue * (timeoutUnits.first(where: { $0.value == timeoutUnit })?.seconds ?? 1)
    }

    /// 超时数值 Int ↔ String（描边框用）
    private var timeoutText: Binding<String> {
        Binding<String>(get: { String(timeoutValue) },
                        set: { timeoutValue = Int($0) ?? timeoutValue })
    }

    /// 备份账号 Int? ↔ String（描边菜单用；空列表时回落首项）
    private var accountText: Binding<String> {
        Binding<String>(
            get: {
                if let id = selectedAccountID, accounts.contains(where: { $0.id == id }) {
                    return String(id)
                }
                return String(accounts.first?.id ?? 0)
            },
            set: { selectedAccountID = Int($0) ?? accounts.first?.id }
        )
    }

    var body: some View {
        Group {
            if loadData == nil && loadError == nil {
                LoadingStateView()
            } else if let loadError {
                LoadErrorStateView(message: loadError) {
                    Task { await loadAll() }
                }
            } else if let data = loadData {
                createForm(data)
            }
        }
        .navigationTitle(L10n.t("创建快照"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadAll() }
    }

    private func createForm(_ data: SnapshotLoadData) -> some View {
        VStack(spacing: 0) {
            WizardStepsBar(pageNames: wizardPageNames, current: wizardPage)
            Form {
                Group {
                    switch wizardPage {
                    case 0:
                        basicDataSection
                    case 1:
                        appPage(data)
                    case 2:
                        dataPage(data)
                    default:
                        otherPage
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WizardBottomBar(
                page: wizardPage,
                totalPages: wizardPageNames.count,
                primaryTitle: L10n.t("创建"),
                isBusy: isSubmitting,
                primaryDisabled: selectedAccountID == nil,
                onBack: { withAnimation { wizardPage -= 1 } },
                onNext: { withAnimation { wizardPage += 1 } },
                onPrimary: { Task { await submit() } }
            )
        }
        .animation(.easeInOut(duration: 0.22), value: wizardPage)
        // 提交在途隐藏返回（含守卫确认），防止请求进行中退出丢进度
        .modifier(WizardDiscardGuard(page: wizardPage, busy: isSubmitting))
        // 总开关 ↔ 应用镜像双向联动：开 → 全选；直接关 → 全部取消（对齐网页端）；
        // 由叶子关闭引发的级联关（suppressMasterClear）保留其余应用的个别勾选
        .onChange(of: backupAllImage) { _, on in
            guard let data = loadData else { return }
            let imageIDs = Self.appImageLeafIDs(data.appData ?? [])
            if on {
                checked.formUnion(imageIDs)
            } else if suppressMasterClear {
                suppressMasterClear = false
            } else {
                checked.subtract(imageIDs)
            }
        }
        // 创建进度由本表单内 push（与安装应用同模式）：完成 or 后台运行都收栈回列表
        //（后台运行后留在表单可再次「创建」，会产生重复快照任务）
        .navigationDestination(item: $activeTask) { target in
            TaskProgressView(taskID: target.taskID, title: target.title) { _ in
                onTaskStarted(target)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    dismiss()
                }
                return false
            }
        }
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: 向导分页成员（自单页表单拆出）

    /// 页 0 · 基础数据：备份账号 / 压缩密码 / 超时 / 描述
    private var basicDataSection: some View {
        Section {
            if accounts.isEmpty {
                // 无备份账号时给出指引（此前仅「无数据」，下一步全程禁用原因不明）
                Text(L10n.t("暂无可用备份账号，请先在「备份账号」中创建后重试"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                OutlinedPicker(label: L10n.t("备份账号"),
                               options: accounts.map { String($0.id) },
                               selection: accountText,
                               optionLabels: Dictionary(uniqueKeysWithValues:
                                   accounts.map { (String($0.id), $0.name ?? "#\($0.id)") }))
            }
            OutlinedTextField(label: L10n.t("压缩密码（可选）"), text: $secret)
            // 超时：数值 + 单位下拉（形态 3）
            OutlinedUnitField(label: L10n.t("超时时间"), unit: "",
                              text: timeoutText, range: 1...8760)
            OutlinedPicker(label: L10n.t("超时单位"),
                           options: timeoutUnits.map(\.value),
                           selection: $timeoutUnit,
                           optionLabels: Dictionary(uniqueKeysWithValues:
                               timeoutUnits.map { ($0.value, $0.label) }))
            OutlinedMultiLineField(label: L10n.t("描述"), prompt: L10n.t("可选"), text: $descriptionText)
        } header: {
            SectionLabel(title: L10n.t("基础数据"), systemImage: "externaldrive")
        }
    }

    /// 页 1 · 应用：系统应用（备份所有应用镜像总开关）+ 应用数据树（与总开关联动）
    private func appPage(_ data: SnapshotLoadData) -> some View {
        Group {
            Section {
                Toggle(L10n.t("备份所有应用镜像"), isOn: $backupAllImage)
            } header: {
                SectionLabel(title: L10n.t("系统应用"), systemImage: "app.badge")
            }
            SnapshotTreeSection(title: L10n.t("应用数据"), systemIcon: "shippingbox",
                                nodes: data.appData ?? [], checked: $checked,
                                onLeafToggled: { node, on in
                // 关闭任一应用的「应用镜像」时，联动关闭「备份所有应用镜像」总开关
                // （置 suppressMasterClear：其余应用的个别勾选不被级联清空）。
                // 仅在总开关原本为开时置标志并触发关闭；总开关已关时不再置标志，
                // 否则标志滞留会让之后「直接关」误走级联分支、不清空镜像勾选
                if node.label == "appImage" && !on, backupAllImage {
                    suppressMasterClear = true
                    backupAllImage = false
                }
            })
        }
    }

    /// 页 2 · 数据：系统数据树 + 备份数据树
    private func dataPage(_ data: SnapshotLoadData) -> some View {
        Group {
            SnapshotTreeSection(title: L10n.t("系统数据"), systemIcon: "gearshape.2",
                                nodes: data.panelData ?? [], checked: $checked)
            SnapshotTreeSection(title: L10n.t("备份数据"), systemIcon: "externaldrive.badge.icloud",
                                nodes: data.backupData ?? [], checked: $checked)
        }
    }

    /// 页 3 · 其他：日志类开关 + 排除规则
    private var otherPage: some View {
        Group {
            Section {
                Toggle(L10n.t("Docker配置"), isOn: $withDockerConf)
                Toggle(L10n.t("监控数据"), isOn: $withMonitorData)
                Toggle(L10n.t("操作日志"), isOn: $withOperationLog)
                Toggle(L10n.t("访问日志"), isOn: $withLoginLog)
                Toggle(L10n.t("系统日志"), isOn: $withSystemLog)
                Toggle(L10n.t("任务日志"), isOn: $withTaskLog)
            } header: {
                SectionLabel(title: L10n.t("其他数据"), systemImage: "doc.on.doc")
            }

            Section {
                OutlinedMultiLineField(label: L10n.t("排除规则"), prompt: "*.log",
                                       lines: 3, text: $ignoreRulesText)
            } header: {
                SectionLabel(title: L10n.t("排除规则"), systemImage: "exclamationmark.triangle")
            } footer: {
                Text(L10n.t("快照将跳过匹配的文件，每行一条规则"))
            }
        }
    }

    private func loadAll() async {
        do {
            let data: SnapshotLoadData = try await client.send(
                path: APIEndpoint.settingsSnapshotLoad.path, method: "GET",
                as: SnapshotLoadData.self)
            loadData = data
            withDockerConf = data.withDockerConf ?? true
            withMonitorData = data.withMonitorData ?? false
            withLoginLog = data.withLoginLog ?? false
            withOperationLog = data.withOperationLog ?? false
            withSystemLog = data.withSystemLog ?? false
            withTaskLog = data.withTaskLog ?? false
            ignoreRulesText = (data.ignoreFiles ?? []).joined(separator: "\n")
            // 叶子勾选初始 = load 默认值（网页端默认勾选态）
            checked = Self.leafChecked(data.appData ?? [])
                .union(Self.leafChecked(data.panelData ?? []))
                .union(Self.leafChecked(data.backupData ?? []))
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        if let opts: [BackupOption] = try? await client.send(
            path: APIEndpoint.cronjobsBackups.path, method: "GET", as: [BackupOption].self) {
            accounts = opts
            selectedAccountID = opts.first?.id
        }
    }

    /// 树内 isCheck 的叶子 id 集合
    private static func leafChecked(_ nodes: [SnapshotNode]) -> Set<String> {
        var result: Set<String> = []
        func walk(_ list: [SnapshotNode]) {
            for n in list {
                if n.isLeaf {
                    if n.isCheck { result.insert(n.id) }
                } else {
                    walk(n.children ?? [])
                }
            }
        }
        walk(nodes)
        return result
    }

    /// 应用数据树内全部「应用镜像」叶子 id（总开关打开时全量勾选）
    private static func appImageLeafIDs(_ nodes: [SnapshotNode]) -> Set<String> {
        var result: Set<String> = []
        func walk(_ list: [SnapshotNode]) {
            for n in list {
                if n.isLeaf {
                    if n.label == "appImage" { result.insert(n.id) }
                } else {
                    walk(n.children ?? [])
                }
            }
        }
        walk(nodes)
        return result
    }

    /// 按勾选集合回写整棵树的叶子 isCheck（父节点保持 load 原值，与抓包一致）
    private static func applyChecked(_ nodes: [SnapshotNode], checked: Set<String>, backupAllImage: Bool) -> [SnapshotNode] {
        nodes.map { node in
            var n = node
            if n.isLeaf {
                // backupAllImage=true 时镜像子节点按全量备份语义提交
                if backupAllImage && n.label == "appImage" {
                    n.isCheck = true
                } else {
                    n.isCheck = checked.contains(n.id)
                }
            } else {
                n.children = applyChecked(n.children ?? [], checked: checked, backupAllImage: backupAllImage)
            }
            return n
        }
    }

    /// 多行排除规则文本 → ignoreFiles 数组（每行一条，去空白行）
    private static func parseIgnoreRules(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func submit() async {
        guard let accountID = selectedAccountID, let data = loadData else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        let taskID = UUID().uuidString
        let req = SnapshotCreateRequest(
            id: 0,
            taskID: taskID,
            downloadAccountID: accountID,
            fromAccounts: [accountID],
            sourceAccountIDs: String(accountID),
            description: descriptionText,
            secret: secret,
            timeout: timeoutSeconds,
            timeoutItem: timeoutValue,
            timeoutUnit: timeoutUnit,
            backupAllImage: backupAllImage,
            withDockerConf: withDockerConf,
            withLoginLog: withLoginLog,
            withOperationLog: withOperationLog,
            withSystemLog: withSystemLog,
            withTaskLog: withTaskLog,
            withMonitorData: withMonitorData,
            panelData: Self.applyChecked(data.panelData ?? [], checked: checked, backupAllImage: backupAllImage),
            backupData: Self.applyChecked(data.backupData ?? [], checked: checked, backupAllImage: backupAllImage),
            appData: Self.applyChecked(data.appData ?? [], checked: checked, backupAllImage: backupAllImage),
            ignoreFiles: Self.parseIgnoreRules(ignoreRulesText))
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.settingsSnapshotCreate.path, body: req, as: EmptyResponse.self)
            // 进度页由本表单内 push（与安装应用同模式），完成后回调刷新列表并收栈
            activeTask = SnapshotTaskTarget(taskID: taskID, title: L10n.t("创建快照"))
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
