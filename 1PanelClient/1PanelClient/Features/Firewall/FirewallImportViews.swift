//
//  FirewallImportViews.swift
//  1PanelClient
//
//  规则/转发导入 + 原文查看 + 导出多选（自 FirewallForms.swift 拆出，内容未改动）
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - 规则导入（文件解析 + 勾选 + sourceKind imported；对齐 Web 端交互）

struct FirewallImportView: View {
    @ObservedObject var vm: FirewallViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var parsed: [FirewallRule] = []
    @State private var selected: Set<String> = []
    @State private var parseError: String?
    @State private var fileName: String?
    @State private var isImporting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showPicker = true
                    } label: {
                        Label(fileName ?? L10n.t("选择 JSON 文件"), systemImage: "doc.badge.arrow.up")
                    }
                } header: {
                    SectionLabel(title: L10n.t("导入规则"), systemImage: "square.and.arrow.down")
                } footer: {
                    Text(L10n.t("选择导出的 1Panel 防火墙规则 JSON 文件，勾选需要导入的规则。"))
                }
                if let err = parseError {
                    Section { Text(err).foregroundStyle(Color.statusError) }
                }
                if !parsed.isEmpty {
                    Section {
                        ForEach(parsed) { rule in
                            Button {
                                if selected.contains(rule.id) {
                                    selected.remove(rule.id)
                                } else {
                                    selected.insert(rule.id)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: selected.contains(rule.id)
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(rule.id) ? Color.accentColor : .secondary)
                                    FirewallRuleRowView(
                                        item: FirewallImportPreview.item(for: rule),
                                        processName: nil,
                                        showsUsage: false)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text(L10n.f("共 %ld 条，已选 %ld 条", parsed.count, selected.count))
                            Spacer()
                            Button(selected.count == parsed.count ? L10n.t("全不选") : L10n.t("全选")) {
                                if selected.count == parsed.count { selected.removeAll() }
                                else { selected = Set(parsed.map(\.id)) }
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle(L10n.t("导入规则"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isImporting { ProgressView() } else { Text(L10n.t("导入")) }
                    }
                    .disabled(selected.isEmpty || isImporting)
                }
            }
            .interactiveDismissDisabled(isImporting)
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.json]) { result in
                handlePick(result)
            }
        }
    }

    private func handlePick(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let rules = try JSONDecoder().decode([FirewallRule].self, from: data)
            guard !rules.isEmpty else {
                parseError = L10n.t("文件中没有可导入的规则")
                parsed = []; selected = []
                return
            }
            parsed = rules
            selected = Set(rules.map(\.id))
            parseError = nil
            fileName = url.lastPathComponent
        } catch {
            parsed = []; selected = []
            parseError = L10n.f("解析失败：%@", error.localizedDescription)
        }
    }

    private func submit() async {
        isImporting = true
        defer { isImporting = false }
        let chosen = parsed.filter { selected.contains($0.id) }
        if await vm.importRules(chosen) {
            dismiss()
        }
    }
}

/// 导入预览用的极简 InventoryItem 包装（无观察态，中性样式）
private enum FirewallImportPreview {
    static func item(for rule: FirewallRule) -> FirewallInventoryItem {
        FirewallInventoryItem(
            rule: rule, observed: nil, isWhitelist: nil, descriptionID: nil)
    }
}

// MARK: - 初始化并恢复规则（rules/backups 选择 + POST rules initialize）

/// 「初始化并恢复规则」：列出服务器上的规则备份（rules/backups?subsystem=system），
/// 点选一条 → 确认 → POST rules {"initialize":true,"backupFile":…,"items":[]}（任务进度页）。
/// 抓包 2026-10-21
struct FirewallRestoreBackupView: View {
    @ObservedObject var vm: FirewallViewModel

    @Environment(\.dismiss) private var dismiss
    /// 待确认恢复的备份
    @State private var pendingRestore: FirewallRuleBackupFile?
    @State private var isRestoring = false

    private var files: [FirewallRuleBackupFile] { vm.ruleBackups?.files ?? [] }

    var body: some View {
        NavigationStack {
            Group {
                if let err = vm.ruleBackupsError {
                    LoadErrorStateView(message: err) {
                        Task { await vm.loadRuleBackups() }
                    }
                } else if vm.isLoadingBackups && vm.ruleBackups == nil {
                    LoadingStateView()
                } else if files.isEmpty {
                    ContentUnavailableView(
                        L10n.t("暂无备份文件"),
                        systemImage: "externaldrive.badge.timemachine",
                        description: Text(L10n.t("重置时勾选「备份规则后重置」会生成备份文件，生成后可在此恢复。"))
                    )
                } else {
                    backupList
                }
            }
            .navigationTitle(L10n.t("初始化并恢复规则"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                        .disabled(isRestoring)
                }
            }
            .interactiveDismissDisabled(isRestoring)
            .refreshable { await vm.loadRuleBackups() }
        }
        .task {
            if vm.ruleBackups == nil && vm.ruleBackupsError == nil {
                await vm.loadRuleBackups()
            }
        }
        .alert(L10n.t("确认恢复规则"), isPresented: Binding(
            get: { pendingRestore != nil },
            set: { if !$0 { pendingRestore = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingRestore = nil }
            Button(L10n.t("恢复"), role: .destructive) {
                Haptic.warning()
                guard let file = pendingRestore, let name = file.name else { return }
                pendingRestore = nil
                isRestoring = true
                Task {
                    // 成功即 dismiss：activeTask 已携带任务号，进度页随外层导航推出
                    if await vm.initializeWithRestore(backupFile: name) {
                        dismiss()
                    } else {
                        isRestoring = false
                    }
                }
            }
        } message: {
            if let file = pendingRestore {
                Text(L10n.f("将初始化基础链并从备份恢复 %ld 条规则，当前运行时规则将被替换。确认使用备份「%@」吗？",
                            file.ruleCount ?? 0, file.name ?? ""))
            }
        }
    }

    private var backupList: some View {
        Form {
            Section {
                ForEach(files) { file in
                    Button {
                        pendingRestore = file
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(file.name ?? "—")
                                    .font(.footnote)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                HStack(spacing: 8) {
                                    if let provider = file.provider {
                                        Text(provider.uppercased())
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.secondary.opacity(0.15),
                                                        in: RoundedRectangle(cornerRadius: 4))
                                    }
                                    Text(L10n.f("%ld 条规则", file.ruleCount ?? 0))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let ts = file.modifiedAt {
                                        Text(Date(timeIntervalSince1970:
                                                    TimeInterval(ts) / 1000)
                                            .formatted(date: .numeric, time: .shortened))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isRestoring)
                }
            } header: {
                SectionLabel(title: L10n.t("选择备份"), systemImage: "externaldrive.badge.timemachine")
            } footer: {
                if let dir = vm.ruleBackups?.directory, !dir.isEmpty {
                    Text(L10n.f("备份目录：%@", dir))
                }
            }
        }
    }
}

// MARK: - 规则原文查看（observed.raw / native detail）

struct FirewallRawDetailView: View {
    let title: String
    let text: String

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.isEmpty ? "—" : text)
                    .font(.dataMonospacedCaption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
                    .contentWidthLimit(860)
            }
            .navigationTitle(L10n.t("规则原文"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel(L10n.t("复制"))
                }
            }
        }
    }
}

// MARK: - 转发导入（文件解析 + 勾选 + forward/operate 批量 add）

/// 导入端口转发：选择导出的 JSON 文件 → 解析勾选 → 批量 add（任务进度）
struct FirewallForwardImportView: View {
    @ObservedObject var vm: FirewallViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var parsed: [FirewallForwardRule] = []
    /// 选中下标（FirewallForwardRule.id 为可选，导入文件可能缺 id，用下标更稳）
    @State private var selected: Set<Int> = []
    @State private var parseError: String?
    @State private var fileName: String?
    @State private var isImporting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showPicker = true
                    } label: {
                        Label(fileName ?? L10n.t("选择 JSON 文件"), systemImage: "doc.badge.arrow.up")
                    }
                } header: {
                    SectionLabel(title: L10n.t("导入转发规则"), systemImage: "square.and.arrow.down")
                } footer: {
                    Text(L10n.t("选择导出的 1Panel 端口转发 JSON 文件，勾选需要导入的转发。"))
                }
                if let err = parseError {
                    Section { Text(err).foregroundStyle(Color.statusError) }
                }
                if !parsed.isEmpty {
                    Section {
                        ForEach(Array(parsed.enumerated()), id: \.offset) { idx, rule in
                            Button {
                                if selected.contains(idx) {
                                    selected.remove(idx)
                                } else {
                                    selected.insert(idx)
                                }
                            } label: {
                                HStack {
                                    FirewallForwardRowView(rule: rule)
                                    Image(systemName: selected.contains(idx)
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(idx)
                                                         ? Color.accentColor : Color.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text(L10n.f("共 %ld 条，已选 %ld 条", parsed.count, selected.count))
                            Spacer()
                            Button(selected.count == parsed.count ? L10n.t("全不选") : L10n.t("全选")) {
                                if selected.count == parsed.count { selected.removeAll() }
                                else { selected = Set(parsed.indices) }
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle(L10n.t("导入转发规则"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isImporting { ProgressView() } else { Text(L10n.t("导入")) }
                    }
                    .disabled(selected.isEmpty || isImporting)
                }
            }
            .interactiveDismissDisabled(isImporting)
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.json]) { result in
                handlePick(result)
            }
        }
    }

    private func handlePick(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let rules = try JSONDecoder().decode([FirewallForwardRule].self, from: data)
            guard !rules.isEmpty else {
                parseError = L10n.t("文件中没有可导入的规则")
                parsed = []; selected = []
                return
            }
            parsed = rules
            selected = Set(rules.indices)
            parseError = nil
            fileName = url.lastPathComponent
        } catch {
            parsed = []; selected = []
            parseError = L10n.f("解析失败：%@", error.localizedDescription)
        }
    }

    private func submit() async {
        isImporting = true
        defer { isImporting = false }
        let chosen = selected.sorted().compactMap { parsed.indices.contains($0) ? parsed[$0] : nil }
        if await vm.importForwards(chosen) {
            dismiss()
        }
    }
}

// MARK: - Docker 防护策略导入（文件解析 + 勾选 + docker/policies/batch）

/// 导入 Docker 端口防护策略：选择导出的 JSON 文件 → 解析勾选 → 批量提交（任务进度）
struct FirewallDockerImportView: View {
    @ObservedObject var vm: FirewallViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var parsed: [DockerGuardPolicy] = []
    @State private var selected: Set<Int> = []
    @State private var parseError: String?
    @State private var fileName: String?
    @State private var isImporting = false

    /// 策略模式显示名（与 DockerPolicyFormView 的防护模式选项一致）
    private let modeLabels = [
        "deny_sources": L10n.t("禁止指定来源"),
        "allow_sources": L10n.t("仅允许指定来源"),
        "deny_all": L10n.t("禁止所有访问"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showPicker = true
                    } label: {
                        Label(fileName ?? L10n.t("选择 JSON 文件"), systemImage: "doc.badge.arrow.up")
                    }
                } header: {
                    SectionLabel(title: L10n.t("导入防护策略"), systemImage: "square.and.arrow.down")
                } footer: {
                    Text(L10n.t("选择导出的 1Panel Docker 防护策略 JSON 文件，勾选需要导入的策略。"))
                }
                if let err = parseError {
                    Section { Text(err).foregroundStyle(Color.statusError) }
                }
                if !parsed.isEmpty {
                    Section {
                        ForEach(Array(parsed.enumerated()), id: \.offset) { idx, policy in
                            Button {
                                if selected.contains(idx) {
                                    selected.remove(idx)
                                } else {
                                    selected.insert(idx)
                                }
                            } label: {
                                // plain 样式命中区只有文字部分，补全行矩形命中
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text("\(policy.hostIP):\(String(policy.hostPort))")
                                                .font(.dataMonospacedBody.bold())
                                            Text(policy.protocolField.uppercased())
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        HStack(spacing: 6) {
                                            Text(modeLabels[policy.mode] ?? policy.mode)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            if !policy.sources.isEmpty {
                                                Text(policy.sources.joined(separator: ", "))
                                                    .font(.caption.monospaced())
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: selected.contains(idx)
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(idx)
                                                         ? Color.accentColor : Color.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text(L10n.f("共 %ld 条，已选 %ld 条", parsed.count, selected.count))
                            Spacer()
                            Button(selected.count == parsed.count ? L10n.t("全不选") : L10n.t("全选")) {
                                if selected.count == parsed.count { selected.removeAll() }
                                else { selected = Set(parsed.indices) }
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle(L10n.t("导入防护策略"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isImporting { ProgressView() } else { Text(L10n.t("导入")) }
                    }
                    .disabled(selected.isEmpty || isImporting)
                }
            }
            .interactiveDismissDisabled(isImporting)
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.json]) { result in
                handlePick(result)
            }
        }
    }

    private func handlePick(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let policies = try JSONDecoder().decode([DockerGuardPolicy].self, from: data)
            guard !policies.isEmpty else {
                parseError = L10n.t("文件中没有可导入的规则")
                parsed = []; selected = []
                return
            }
            parsed = policies
            selected = Set(policies.indices)
            parseError = nil
            fileName = url.lastPathComponent
        } catch {
            parsed = []; selected = []
            parseError = L10n.f("解析失败：%@", error.localizedDescription)
        }
    }

    private func submit() async {
        isImporting = true
        defer { isImporting = false }
        let chosen = selected.sorted().compactMap { parsed.indices.contains($0) ? parsed[$0] : nil }
        if await vm.importDockerPolicies(chosen) {
            dismiss()
        }
    }
}

// MARK: - 规则导出多选（长按菜单「导出规则」进入）

/// 可导出规则多选：全选/反全选 + 勾选 → 导出（本地组 JSON → Documents/Exports）
struct FirewallExportPickerView: View {
    @ObservedObject var vm: FirewallViewModel
    /// 长按入口预选（仅长按的这条；nil = 默认全选）
    var preselectedIDs: Set<String>? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    private var exportable: [FirewallInventoryItem] {
        vm.inventory.filter { $0.operationTarget != nil && !$0.isProtected }
    }

    var body: some View {
        NavigationStack {
            Form {
                if exportable.isEmpty {
                    Section {
                        ContentUnavailableView(
                            L10n.t("暂无可导出的规则"),
                            systemImage: "shield"
                        )
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        ForEach(exportable) { item in
                            Button {
                                if selected.contains(item.id) {
                                    selected.remove(item.id)
                                } else {
                                    selected.insert(item.id)
                                }
                            } label: {
                                HStack {
                                    FirewallRuleRowView(item: item, processName: nil, showsUsage: false)
                                    Image(systemName: selected.contains(item.id)
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(item.id)
                                                         ? Color.accentColor : Color.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text(L10n.f("共 %ld 条，已选 %ld 条", exportable.count, selected.count))
                            Spacer()
                            Button(selected.count == exportable.count
                                   ? L10n.t("全不选") : L10n.t("全选")) {
                                if selected.count == exportable.count {
                                    selected.removeAll()
                                } else {
                                    selected = Set(exportable.map(\.id))
                                }
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle(L10n.t("导出规则"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("导出")) { export() }
                        .disabled(selected.isEmpty)
                }
            }
            .onAppear {
                selected = preselectedIDs ?? Set(exportable.map(\.id))
                // 主列表懒加载只到当前滚动位置：导出前后台补齐剩余分页，
                // 保证「全选」等于全部规则而非已加载部分；
                // 任务句柄随页消失取消（用户取消导出后不再后台拉页）
                fillTask = Task { await fillRemainingPages() }
            }
            .onDisappear {
                fillTask?.cancel()
            }
        }
    }

    /// 补页任务句柄（页消失即取消）
    @State private var fillTask: Task<Void, Never>?

    /// 补齐未加载的分页（上限 50 页防失控；完成后默认全选态同步到全量）
    private func fillRemainingPages() async {
        var pages = 0
        while vm.inventory.count < vm.rulesAllTotal, pages < 50, !Task.isCancelled {
            let before = vm.inventory.count
            await vm.loadRules(replacing: false)
            pages += 1
            // 一轮下来 count 不增（早退/失败/翻页到底）：继续循环只会空转，退出
            if vm.inventory.count == before { break }
        }
        if preselectedIDs == nil {
            selected = Set(exportable.map(\.id))
        }
    }

    /// 落盘后关闭多选页，保存位置经防火墙页的 toast 呈现（本页之下，关掉才看得见）
    private func export() {
        let chosen = exportable.filter { selected.contains($0.id) }
        guard let saved = vm.exportRules(for: chosen) else {
            vm.toastMessage = L10n.t("暂无可导出的规则")
            return
        }
        dismiss()
        vm.toastMessage = saved.successMessage
    }
}

// MARK: - 转发导出多选（长按菜单「导出规则」进入）

/// 可导出转发多选：全选/反全选 + 勾选 → 导出（本地组 JSON → Documents/Exports）
struct FirewallForwardExportPickerView: View {
    @ObservedObject var vm: FirewallViewModel
    /// 长按入口预选（仅长按的这条转发；nil = 默认全选）
    var preselectedIndex: Int? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int> = []

    /// 转发 id 为可选，导入文件可能缺 id，按下标选择
    private var indices: Range<Int> { vm.forwards.indices }

    var body: some View {
        NavigationStack {
            Form {
                if vm.forwards.isEmpty {
                    Section {
                        ContentUnavailableView(
                            L10n.t("暂无可导出的转发"),
                            systemImage: "arrow.triangle.branch"
                        )
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        ForEach(Array(vm.forwards.enumerated()), id: \.offset) { idx, rule in
                            Button {
                                if selected.contains(idx) {
                                    selected.remove(idx)
                                } else {
                                    selected.insert(idx)
                                }
                            } label: {
                                HStack {
                                    FirewallForwardRowView(rule: rule)
                                    Image(systemName: selected.contains(idx)
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(idx)
                                                         ? Color.accentColor : Color.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text(L10n.f("共 %ld 条，已选 %ld 条", vm.forwards.count, selected.count))
                            Spacer()
                            Button(selected.count == vm.forwards.count
                                   ? L10n.t("全不选") : L10n.t("全选")) {
                                if selected.count == vm.forwards.count {
                                    selected.removeAll()
                                } else {
                                    selected = Set(vm.forwards.indices)
                                }
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle(L10n.t("导出规则"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("导出")) { export() }
                        .disabled(selected.isEmpty)
                }
            }
            .onAppear {
                if let preselectedIndex, vm.forwards.indices.contains(preselectedIndex) {
                    selected = [preselectedIndex]
                } else {
                    selected = Set(vm.forwards.indices)
                }
            }
        }
    }

    private func export() {
        let chosen = selected.sorted().compactMap {
            vm.forwards.indices.contains($0) ? vm.forwards[$0] : nil
        }
        guard let saved = vm.exportForwards(for: chosen) else {
            vm.toastMessage = L10n.t("暂无可导出的转发")
            return
        }
        dismiss()
        vm.toastMessage = saved.successMessage
    }
}

// MARK: - Docker 导出多选（容器行长按「导出规则」进入）

/// 可导出防护策略多选：全选/反全选 + 勾选 → 导出（本地组 JSON → Documents/Exports）
struct FirewallDockerExportPickerView: View {
    @ObservedObject var vm: FirewallViewModel
    /// 容器行长按入口预选（仅该容器的策略；nil = 默认全选）
    var preselectedIndices: Set<Int>? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int> = []

    private let modeLabels = [
        "deny_sources": L10n.t("禁止指定来源"),
        "allow_sources": L10n.t("仅允许指定来源"),
        "deny_all": L10n.t("禁止所有访问"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                if vm.dockerExportablePolicies.isEmpty {
                    Section {
                        ContentUnavailableView(
                            L10n.t("暂无可导出的防护策略"),
                            systemImage: "shippingbox"
                        )
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        ForEach(Array(vm.dockerExportablePolicies.enumerated()), id: \.offset) { idx, policy in
                            Button {
                                if selected.contains(idx) {
                                    selected.remove(idx)
                                } else {
                                    selected.insert(idx)
                                }
                            } label: {
                                // plain 样式命中区只有文字部分，补全行矩形命中
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text("\(policy.hostIP):\(String(policy.hostPort))")
                                                .font(.dataMonospacedBody.bold())
                                            Text(policy.protocolField.uppercased())
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        HStack(spacing: 6) {
                                            Text(modeLabels[policy.mode] ?? policy.mode)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            if !policy.sources.isEmpty {
                                                Text(policy.sources.joined(separator: ", "))
                                                    .font(.caption.monospaced())
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: selected.contains(idx)
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(idx)
                                                         ? Color.accentColor : Color.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text(L10n.f("共 %ld 条，已选 %ld 条",
                                        vm.dockerExportablePolicies.count, selected.count))
                            Spacer()
                            Button(selected.count == vm.dockerExportablePolicies.count
                                   ? L10n.t("全不选") : L10n.t("全选")) {
                                if selected.count == vm.dockerExportablePolicies.count {
                                    selected.removeAll()
                                } else {
                                    selected = Set(vm.dockerExportablePolicies.indices)
                                }
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle(L10n.t("导出规则"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("导出")) { export() }
                        .disabled(selected.isEmpty)
                }
            }
            .onAppear {
                selected = preselectedIndices ?? Set(vm.dockerExportablePolicies.indices)
            }
        }
    }

    private func export() {
        let all = vm.dockerExportablePolicies
        let chosen = selected.sorted().compactMap { all.indices.contains($0) ? all[$0] : nil }
        guard let saved = vm.exportDockerPolicies(for: chosen) else {
            vm.toastMessage = L10n.t("暂无可导出的防护策略")
            return
        }
        dismiss()
        vm.toastMessage = saved.successMessage
    }
}
