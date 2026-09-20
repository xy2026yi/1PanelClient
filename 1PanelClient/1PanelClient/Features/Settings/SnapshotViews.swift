//
//  SnapshotViews.swift
//  1PanelClient
//
//  面板快照（logs/推荐实现-计划任务和面板.md 抓包 2026-09-14）：
//  列表（删除/恢复）· 创建（数据树勾选 + 基础配置，全量回传 + 任务进度）
//  网页端 6 步向导在移动端收敛为单页分区表单
//

import SwiftUI

// MARK: - 快照列表

struct SnapshotListView: View {
    let server: ServerConfig

    @State private var snapshots: [SnapshotItem] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var showCreate = false
    @State private var toastMessage: String?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var pendingDelete: SnapshotItem?
    @State private var deleteWithFile = false
    @State private var recoveringItem: SnapshotItem?
    /// 创建/恢复任务（taskID → 任务进度页）
    @State private var progressTask: SnapshotTaskTarget?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); LoadingStateView(); Spacer() }
                    .listRowBackground(Color.clear)
            } else if let err = loadError {
                LoadErrorStateView(message: err) {
                    Task { await load() }
                }
                .listRowBackground(Color.clear)
            } else if snapshots.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无快照"),
                    systemImage: "externaldrive.badge.timemachine",
                    description: Text(L10n.t("点击右上角 + 创建快照")))
                .listRowBackground(Color.clear)
            } else {
                ForEach(snapshots) { snapshot in
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
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("创建快照"))
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .toastOverlay(message: $toastMessage)
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showCreate) {
            // 创建成功的进度跳转由本页（NavigationStack 内）承接：
            // Sheet 内无导航栈，navigationDestination 不生效会表现为无任何反馈
            SnapshotCreateView(server: server) { target in
                progressTask = target
            }
        }
        .sheet(item: $recoveringItem) { snapshot in
            SnapshotRecoverSheet(snapshot: snapshot) { secret, taskID in
                Task { await recover(snapshot, secret: secret, taskID: taskID) }
            }
        }
        .alert(L10n.t("删除快照"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingDelete = nil }
            Button(L10n.t("删除"), role: .destructive) {
                if let snapshot = pendingDelete {
                    Task { await delete(snapshot) }
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
                    Task { await load() }
                    if target.title.hasPrefix(L10n.t("恢复快照")) { toastMessage = L10n.t("快照已恢复") }
                }
                return false
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
        }
    }

    private func load() async {
        do {
            let resp: SnapshotSearchResponse = try await client.send(
                path: APIEndpoint.settingsSnapshotSearch.path,
                body: SnapshotSearchRequest(page: 1, pageSize: 100, orderBy: "createdAt", order: "null"),
                as: SnapshotSearchResponse.self)
            snapshots = resp.items ?? []
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func delete(_ snapshot: SnapshotItem) async {
        pendingDelete = nil
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.settingsSnapshotDelete.path,
                body: SnapshotDeleteRequest(ids: [snapshot.id], deleteWithFile: deleteWithFile),
                as: EmptyResponse.self)
            toastMessage = L10n.f("已删除「%@」", snapshot.displayName)
            await load()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// 提交恢复任务（isNew=true / reDownload=false，抓包确认），成功后进入任务进度
    private func recover(_ snapshot: SnapshotItem, secret: String, taskID: String) async {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.settingsSnapshotRecover.path,
                body: SnapshotRecoverRequest(
                    id: snapshot.id, taskID: taskID,
                    isNew: true, reDownload: false, secret: secret),
                as: EmptyResponse.self)
            progressTask = SnapshotTaskTarget(
                taskID: taskID, title: L10n.f("恢复快照 %@", snapshot.displayName))
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
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

// MARK: - 恢复 Sheet（压缩密码 + 风险确认）

private struct SnapshotRecoverSheet: View {
    let snapshot: SnapshotItem
    let onConfirm: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var secret = ""
    @State private var confirmed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    InfoRow(L10n.t("快照"), value: snapshot.displayName)
                }
                Section {
                    OutlinedTextField(label: L10n.t("压缩密码（可选）"), text: $secret, isSecure: true)
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
                        Haptic.warning()
                        let taskID = UUID().uuidString
                        onConfirm(secret, taskID)
                        dismiss()
                    }
                    .disabled(!confirmed)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.medium])
    }
}

// MARK: - 数据树勾选

/// 快照数据树：父节点为分组标题（DisclosureGroup），叶子节点为勾选行
private struct SnapshotTreeSection: View {
    let title: String
    let systemIcon: String
    let nodes: [SnapshotNode]
    @Binding var checked: Set<String>

    var body: some View {
        Section {
            ForEach(nodes) { node in
                if node.isLeaf {
                    SnapshotLeafRow(node: node, checked: $checked)
                } else {
                    SnapshotGroupNode(node: node, checked: $checked)
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

    var body: some View {
        DisclosureGroup {
            ForEach(node.children ?? []) { child in
                if child.isLeaf {
                    SnapshotLeafRow(node: child, checked: $checked)
                } else {
                    SnapshotGroupNode(node: child, checked: $checked)
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

// MARK: - 创建快照（单页分区表单）

struct SnapshotCreateView: View {
    let server: ServerConfig
    /// 创建请求成功后回传任务目标（父级在 NavigationStack 内 push 进度页）
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
        Form {
            Section {
                if accounts.isEmpty {
                    Text(L10n.t("无数据"))
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

            Section {
                Toggle(L10n.t("备份所有应用镜像"), isOn: $backupAllImage)
            } header: {
                SectionLabel(title: L10n.t("系统应用"), systemImage: "app.badge")
            }
            SnapshotTreeSection(title: L10n.t("应用数据"), systemIcon: "shippingbox",
                                nodes: data.appData ?? [], checked: $checked)

            SnapshotTreeSection(title: L10n.t("系统数据"), systemIcon: "gearshape.2",
                                nodes: data.panelData ?? [], checked: $checked)
            SnapshotTreeSection(title: L10n.t("备份数据"), systemIcon: "externaldrive.badge.icloud",
                                nodes: data.backupData ?? [], checked: $checked)

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

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        if isSubmitting { ProgressView() } else { Text(L10n.t("创建")) }
                    }
                    .frame(maxWidth: .infinity)
                    .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
                .disabled(isSubmitting || selectedAccountID == nil)
            }
        }
        // 创建快照进行中禁下拉关闭，防异步提交被误中断（与 TextInputConfirmSheet 同款防护）
        .interactiveDismissDisabled(isSubmitting)
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
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
            // 交给父级 push 进度页后关闭 Sheet（Sheet 内无导航栈，自身无法跳转）
            onTaskStarted(SnapshotTaskTarget(taskID: taskID, title: L10n.t("创建快照")))
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
