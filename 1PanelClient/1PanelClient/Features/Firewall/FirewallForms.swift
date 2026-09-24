//
//  FirewallForms.swift
//  1PanelClient
//
//  防火墙 v2.3.0 表单：统一规则（创建/编辑，端口与 IP 规则同型）、
//  端口转发（编辑 = remove + add 同请求）、面板端口白名单（任务式提交）。
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - 规则表单（创建 / 编辑；v2.3.0 统一模型）

/// Web 端同款精简表单：策略 / 协议 / IP / 端口 / 描述（无源/目标之分，
/// 无地址族选择——按 IP 是否含「:」自动判定；编辑态多一个优先级）
struct FirewallRuleFormView: View {
    @ObservedObject var vm: FirewallViewModel
    /// 编辑模式的既有规则与操作键（创建时均为 nil）
    let editing: FirewallRule?
    let editingUUID: String?
    /// 编辑中规则的链内当前位置（observed.locator.position；表单回显）
    var editingPosition: Int? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var proto = "tcp"
    /// 来源 IP / CIDR（留空 = 全部来源）
    @State private var address = ""
    @State private var port = ""
    @State private var action = "accept"
    @State private var descriptionText = ""
    /// 优先级（编辑态可选；rules/update 支持 orderIndex 单改）
    @State private var priority = ""
    /// 编辑保持原作用域的地址族（表单不再提供选择，仅随 IP 自动判定）
    @State private var family = "ipv4"
    @State private var isSubmitting = false

    /// Web 端创建仅 TCP/UDP/TCP-UDP/ALL 四档（ALL 不带端口）
    private static let protocols = ["tcp", "udp", "tcp/udp", "all"]
    private var isEdit: Bool { editing != nil }

    var body: some View {
        Form {
            Section {
                OutlinedPicker(label: L10n.t("策略"), options: ["accept", "drop"],
                               selection: $action,
                               optionLabels: ["accept": L10n.t("允许"),
                                              "drop": L10n.t("拒绝")])
                OutlinedPicker(label: L10n.t("协议"), options: Self.protocols,
                               selection: $proto,
                               optionLabels: Dictionary(uniqueKeysWithValues:
                                   Self.protocols.map { ($0, $0.uppercased()) }))
                if proto != "all" {
                    OutlinedTextField(label: L10n.t("端口"), prompt: "80 或 8000-8099",
                                      text: $port, keyboardType: .numbersAndPunctuation)
                    OutlinedTextField(label: "IP", prompt: "192.168.1.0/24",
                                      text: $address)
                }
                OutlinedTextField(label: L10n.t("描述"), prompt: L10n.t("可选"),
                                  text: $descriptionText)
            } header: {
                SectionLabel(title: L10n.t("规则内容"), systemImage: "shield")
            } footer: {
                Text(L10n.t("端口支持 8000-8099 区间；IP 支持 IP 或 CIDR，留空表示全部来源。"))
            }

            if isEdit {
                Section {
                    OutlinedTextField(label: L10n.t("优先级"), prompt: priorityPrompt,
                                      text: $priority, keyboardType: .numberPad)
                } header: {
                    SectionLabel(title: L10n.t("优先级"), systemImage: "list.number")
                } footer: {
                    if !priorityPrompt.isEmpty {
                        Text(L10n.f("可设置范围 %@，留空保持不变。", priorityPrompt))
                    }
                }
            }
        }
        .navigationTitle(isEdit ? L10n.t("编辑规则") : L10n.t("创建规则"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text(isEdit ? L10n.t("保存") : L10n.t("创建"))
                    }
                }
                .disabled(!canSubmit || isSubmitting)
            }
        }
        .onAppear { fillIfEditing() }
    }

    /// 优先级可设范围提示（ipvxRange；如「1 ～ 4」），未知时不提示
    private var priorityPrompt: String {
        guard let range = vm.positionRange(family: family),
              let min = range.min, let max = range.max else { return "" }
        return "\(min) ～ \(max)"
    }

    private var canSubmit: Bool {
        if proto == "all" { return true }
        // 端口规则：端口必填；纯 IP 规则：IP 必填
        return !port.trimmingCharacters(in: .whitespaces).isEmpty
            || !address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func fillIfEditing() {
        guard let rule = editing, port.isEmpty, address.isEmpty else { return }
        proto = rule.protocolField ?? "tcp"
        address = rule.sourceAddress ?? ""
        port = rule.destinationPort ?? ""
        action = (rule.action == "drop" || rule.action == "reject") ? "drop" : "accept"
        descriptionText = rule.descriptionText ?? ""
        family = rule.scope?.family == "ipv6" ? "ipv6"
            : (rule.scope?.family == "inet" ? "ipv4" : (rule.scope?.family ?? "ipv4"))
        // 当前优先级：链内位置优先，缺失回落规则自带 orderIndex
        if let position = editingPosition {
            priority = String(position)
        } else if let idx = rule.orderIndex {
            priority = String(idx)
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }

        // 地址族自动判定：IPv6 字面量含「:」，否则维持原族（默认 ipv4）
        var effectiveFamily = family
        if !address.isEmpty, address.contains(":") { effectiveFamily = "ipv6" }

        var scope = FirewallViewModel.scopeForCreate(
            backend: vm.systemStatus?.backend, family: effectiveFamily)
        if isEdit, let oldScope = editing?.scope {
            // 编辑保持原作用域（链位置不变），仅随地址族换 family
            scope = oldScope
            scope.family = effectiveFamily
        }

        var rule = FirewallRule()
        rule.scope = scope
        rule.nativeKind = editing?.nativeKind ?? "rule"
        rule.protocolField = proto
        rule.sourceAddress = address.trimmingCharacters(in: .whitespaces)
        rule.destinationPort = port.trimmingCharacters(in: .whitespaces)
        rule.action = action
        rule.descriptionText = descriptionText
        let trimmedPriority = priority.trimmingCharacters(in: .whitespaces)
        rule.orderIndex = isEdit && !trimmedPriority.isEmpty ? Int64(trimmedPriority) : nil
        if isEdit {
            rule.uuid = editing?.uuid ?? editingUUID
        }

        let ok: Bool
        if isEdit, let uuid = editingUUID ?? editing?.uuid {
            ok = await vm.updateRule(uuid: uuid, rule: rule)
        } else {
            ok = await vm.createRule(rule)
        }
        if ok { dismiss() }
    }
}

// MARK: - 转发表单（创建 / 编辑）

struct FirewallForwardFormView: View {
    @ObservedObject var vm: FirewallViewModel
    let editing: FirewallForwardRule?

    @Environment(\.dismiss) private var dismiss

    @State private var port = ""
    @State private var proto = "tcp"
    @State private var family = "ipv4"
    @State private var targetIP = ""
    @State private var targetPort = ""
    @State private var iface = "*"
    @State private var isSubmitting = false

    private static let protocols = ["tcp", "udp", "tcp/udp"]
    private var isEdit: Bool { editing != nil }

    var body: some View {
        Form {
            Section {
                OutlinedPicker(label: L10n.t("地址族"), options: ["ipv4", "ipv6"],
                               selection: $family,
                               optionLabels: ["ipv4": "IPv4", "ipv6": "IPv6"])
                OutlinedTextField(label: L10n.t("源端口"), prompt: "8080",
                                  text: $port, keyboardType: .numbersAndPunctuation)
                OutlinedPicker(label: L10n.t("协议"), options: Self.protocols,
                               selection: $proto,
                               optionLabels: Dictionary(uniqueKeysWithValues:
                                   Self.protocols.map { ($0, $0.uppercased()) }))
                OutlinedTextField(label: L10n.t("目标地址"), prompt: "10.0.0.1",
                                  text: $targetIP)
                OutlinedTextField(label: L10n.t("目标端口"), prompt: "80",
                                  text: $targetPort, keyboardType: .numbersAndPunctuation)
                OutlinedPicker(label: L10n.t("入站网卡"),
                               options: ["*"] + vm.netOptions.filter { !$0.isEmpty },
                               selection: $iface,
                               optionLabels: ["*": L10n.t("所有网卡")])
            } header: {
                SectionLabel(title: L10n.t("转发内容"), systemImage: "arrow.triangle.branch")
            } footer: {
                Text(L10n.t("将入站端口的流量转发到目标地址；目标地址留空表示本机。"))
            }
        }
        .navigationTitle(isEdit ? L10n.t("编辑转发") : L10n.t("创建转发"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text(isEdit ? L10n.t("保存") : L10n.t("创建"))
                    }
                }
                .disabled(!canSubmit || isSubmitting)
            }
        }
        .onAppear { fillIfEditing() }
    }

    private var canSubmit: Bool {
        !port.trimmingCharacters(in: .whitespaces).isEmpty
            && !targetPort.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func fillIfEditing() {
        guard let rule = editing, port.isEmpty else { return }
        port = rule.port ?? ""
        proto = rule.protocolField ?? "tcp"
        family = rule.family == "ipv6" ? "ipv6" : "ipv4"
        targetIP = rule.targetIP ?? ""
        targetPort = rule.targetPort ?? ""
        iface = (rule.interface?.isEmpty == false) ? (rule.interface ?? "*") : "*"
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }

        var operations: [FirewallForwardOperation] = []
        // 编辑 = 同请求内先删旧（整行回显）再建新（抓包 2026-09-17）
        if let old = editing {
            operations.append(.remove(old))
        }
        operations.append(FirewallForwardOperation(
            operation: "add",
            id: nil, chain: nil, family: family, address: nil,
            port: port.trimmingCharacters(in: .whitespaces),
            protocolField: proto, strategy: nil, num: nil,
            targetIP: targetIP.isEmpty ? nil : targetIP.trimmingCharacters(in: .whitespaces),
            targetPort: targetPort.trimmingCharacters(in: .whitespaces),
            interface: iface == "*" ? nil : iface,
            usedStatus: nil, descriptionText: nil,
            isDesired: nil, isRuntime: nil, syncStatus: nil
        ))
        if await vm.submitForward(operations) {
            dismiss()
        }
    }
}

// MARK: - 面板端口白名单（列表 + 长按编辑/添加；提交 JSON 数组字符串）

struct FirewallWhitelistView: View {
    @ObservedObject var vm: FirewallViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [FirewallPortWhitelistEntry] = []
    /// 进入时的原始条目（脏检查：编辑/添加/删除过则右上角从「添加」变「保存」）
    @State private var original: [FirewallPortWhitelistEntry] = []
    @State private var isSubmitting = false
    /// 编辑中的条目 id（nil = 添加）
    @State private var editingID: String?
    @State private var showEntryForm = false
    /// 长按弹出的操作目标（半屏操作弹窗，与规则/转发行一致）
    @State private var actionEntry: FirewallPortWhitelistEntry?

    private var isDirty: Bool { entries != original }

    var body: some View {
        Form {
            whitelistSection
        }
        .navigationTitle(L10n.t("面板端口白名单"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // 融合按钮：无未保存更改 = 添加；编辑/添加/删除过 = 保存
                if isDirty {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text(L10n.t("保存"))
                        }
                    }
                    .disabled(isSubmitting)
                } else {
                    Button {
                        editingID = nil
                        showEntryForm = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L10n.t("添加"))
                }
            }
        }
        // 条目表单以 push 进入（不再 sheet）
        .navigationDestination(isPresented: $showEntryForm) {
            FirewallWhitelistEntryFormView(
                vm: vm,
                editing: editingID.flatMap { id in entries.first { $0.id == id } }
            ) { result in
                applyResult(result)
            }
        }
        // 长按行：半屏操作弹窗（编辑/删除，与规则/转发行一致；添加走右上角 ＋，
        // 删除为本地标记，随右上角「保存」按 diff 提交）
        .sheet(isPresented: Binding(
            get: { actionEntry != nil },
            set: { if !$0 { actionEntry = nil } }
        )) {
            ActionBottomSheet(
                title: actionEntry?.display ?? L10n.t("面板端口白名单"),
                items: [
                    ActionMenuItem(title: L10n.t("编辑"), icon: "pencil", color: .blue) {
                        let entry = actionEntry
                        actionEntry = nil
                        if let entry {
                            editingID = entry.id
                            showEntryForm = true
                        }
                    },
                    ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red,
                                   role: .destructive) {
                        Haptic.warning()
                        let entry = actionEntry
                        actionEntry = nil
                        if let entry {
                            entries.removeAll { $0.id == entry.id }
                        }
                    },
                ],
                onDismiss: { actionEntry = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: 2))])
            .presentationDragIndicator(.visible)
        }
        .interactiveDismissDisabled(isSubmitting)
        .onAppear {
            if original.isEmpty {
                // v2.3.1 上游即为对象数组，直接取用
                let loaded = vm.settings?.portWhiteList ?? []
                entries = loaded
                original = loaded
            }
        }
    }

    /// 白名单列表（不分 IPv4/IPv6——来源已含 v4/v6；行尾显示允许来源）
    private var whitelistSection: some View {
        Section {
            if entries.isEmpty {
                Text(L10n.t("未设置"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    entryRow(entry)
                }
            }
        } footer: {
            Text(L10n.t("支持 TCP/UDP、单端口及 8000-8100 格式的端口范围；保存为全量覆盖。"))
        }
    }

    private func entryRow(_ entry: FirewallPortWhitelistEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(entry.display)
                    .font(.dataMonospacedBody)
                if let label = entry.typeLabel {
                    StatusBadge(text: label, color: .blue)
                }
                Spacer()
            }
            if let sources = entry.sources, !sources.isEmpty {
                Text(L10n.f("允许来源：%@", sources.joined(separator: ", ")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .contentShape(Rectangle())
        // 长按弹半屏操作菜单（编辑/删除/添加）
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                Haptic.selection()
                actionEntry = entry
            }
        )
        // VoiceOver 无长按手势：以自定义操作暴露同一菜单
        .accessibilityAction(named: L10n.t("更多操作")) {
            actionEntry = entry
        }
    }

    /// 编辑/添加结果落库：按原 id 替换或追加（类型与来源均随表单结果，
    /// 其他扩展字段以表单产出为准）
    private func applyResult(_ result: FirewallPortWhitelistEntry) {
        if let id = editingID,
           let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx] = result
        } else {
            entries.append(result)
        }
        editingID = nil
    }

    private func submit() async {
        guard entries.allSatisfy({ !$0.port.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            vm.errorMessage = L10n.t("端口不能为空")
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        if await vm.savePortWhitelist(original: original, entries: entries) {
            dismiss()
        }
    }
}

// MARK: - 端口白名单条目表单（编辑 / 添加；push 进入）

/// 类型 / 协议（形态 3）+ 端口范围（形态 1，类型联动自动填端口）+
/// 允许来源（形态 7.1，默认 0.0.0.0/0, ::/0）
struct FirewallWhitelistEntryFormView: View {
    @ObservedObject var vm: FirewallViewModel
    /// nil = 添加
    let editing: FirewallPortWhitelistEntry?
    let onSave: (FirewallPortWhitelistEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    /// "" = 其他 / "ssh" / "panel"
    @State private var type = ""
    @State private var proto = "tcp"
    @State private var port = ""
    @State private var sourcesText = "0.0.0.0/0, ::/0"

    private static let typeOptions = ["", "ssh", "panel"]

    var body: some View {
        Form {
            Section {
                OutlinedPicker(label: L10n.t("类型"), options: Self.typeOptions,
                               selection: $type,
                               optionLabels: ["": L10n.t("其他"),
                                              "ssh": "SSH",
                                              "panel": "1Panel"])
                    .disabled(editing != nil)
                OutlinedPicker(label: L10n.t("协议"), options: ["tcp", "udp"],
                               selection: $proto,
                               optionLabels: ["tcp": "TCP", "udp": "UDP"])
                OutlinedTextField(label: L10n.t("端口范围"), prompt: "80 或 8000-8100",
                                  text: $port, keyboardType: .numbersAndPunctuation)
            } footer: {
                Text(L10n.t("支持单个端口（如 80）或端口范围（如 8000-8100），端口取值为 1-65535。"))
            }

            Section {
                OutlinedMultiLineField(label: L10n.t("允许来源"), prompt: "0.0.0.0/0, ::/0",
                                       lines: 2, text: $sourcesText)
            } footer: {
                Text(L10n.t("支持 IP 或 CIDR，多个以逗号或换行分隔。留空默认允许所有 IPv4 和 IPv6 来源。"))
            }
        }
        .navigationTitle(editing == nil ? L10n.t("添加") : L10n.t("编辑"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.t("保存")) {
                    onSave(FirewallPortWhitelistEntry(
                        protocolField: proto,
                        port: port.trimmingCharacters(in: .whitespaces),
                        type: type.isEmpty ? nil : type,
                        sources: sourceLines))
                    dismiss()
                }
                .disabled(port.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onChange(of: type) { _, newType in
            // SSH / 1Panel 端口跟随面板设置自动填入（端口框同步锁定）
            switch newType {
            case "ssh":
                if let p = vm.settings?.sshPort, !p.isEmpty { port = p }
            case "panel":
                if let p = vm.settings?.panelPort, !p.isEmpty { port = p }
            default: break
            }
        }
        .onAppear {
            if let e = editing {
                type = e.type ?? ""
                proto = e.protocolField
                port = e.port
                let stored = (e.sources ?? []).filter { !$0.isEmpty }
                sourcesText = stored.isEmpty ? "0.0.0.0/0, ::/0" : stored.joined(separator: "\n")
            }
        }
    }

    /// 允许来源原文 → 数组（逗号/换行分隔；空值回落默认全放行）
    private var sourceLines: [String] {
        let lines = sourcesText
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? ["0.0.0.0/0", "::/0"] : lines
    }
}

// MARK: - 规则同步预览（preview 计数 + ready 清单 → 确认执行；抓包 2026-09-17）

struct FirewallSyncPreviewView: View {
    @ObservedObject var vm: FirewallViewModel
    /// system / forwarding
    let subsystem: String

    @Environment(\.dismiss) private var dismiss
    @State private var preview: FirewallRuleSyncPreview?
    @State private var isExecuting = false
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Form {
                if let p = preview {
                    Section {
                        statRow(L10n.t("数据库规则"), p.total ?? 0, color: .blue)
                        statRow(L10n.t("可同步"), p.ready ?? 0, color: .statusRunning)
                        statRow(L10n.t("已存在"), p.existing ?? 0, color: .secondary)
                        statRow(L10n.t("待删除"), p.removed ?? 0, color: .statusError)
                        statRow(L10n.t("不可同步"), p.blocked ?? 0, color: .semanticWarning)
                    } header: {
                        SectionLabel(title: L10n.t("同步预览"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    let readyItems = (p.items ?? []).filter { $0.status == "ready" }
                    if !readyItems.isEmpty {
                        Section {
                            ForEach(Array(readyItems.enumerated()), id: \.offset) { _, item in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.displayToken)
                                        .font(.dataMonospacedBody.bold())
                                    if let reason = item.reason, !reason.isEmpty {
                                        Text(reason)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } header: {
                            Text(L10n.t("待同步条目"))
                        }
                    }
                } else if let err = loadError {
                    Section {
                        LoadErrorStateView(message: err) {
                            Task { await load() }
                        }
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section { LoadingStateView() }
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle(L10n.t("同步规则"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("同步")) {
                        Task {
                            isExecuting = true
                            await vm.executeSync(subsystem: subsystem)
                            isExecuting = false
                            dismiss()
                        }
                    }
                    .disabled((preview?.ready ?? 0) == 0 || isExecuting)
                }
            }
            .interactiveDismissDisabled(isExecuting)
            .task { await load() }
        }
    }

    private func statRow(_ title: String, _ value: Int, color: Color) -> some View {
        HStack {
            Text(title)
            Spacer()
            StatusBadge(text: String(value), color: color, monospaced: true)
        }
    }

    private func load() async {
        loadError = nil
        if let p = await vm.syncPreview(subsystem: subsystem) {
            preview = p
        } else {
            loadError = vm.errorMessage ?? L10n.t("未知错误")
        }
    }
}

// MARK: - Docker 端口防护策略表单（三模式 + 来源；抓包 2026-09-17）

struct DockerPolicyFormView: View {
    @ObservedObject var vm: FirewallViewModel
    let endpoint: DockerGuardEndpoint

    @Environment(\.dismiss) private var dismiss
    /// deny_sources / allow_sources / deny_all
    @State private var mode = "deny_all"
    /// 来源多行原文（每行一条 IP 或 CIDR，形态 7.1；提交拆数组）
    @State private var sourcesText = ""
    @State private var descriptionText = ""
    @State private var isSubmitting = false

    private let modeOptions: [(String, String)] = [
        ("deny_sources", L10n.t("禁止指定来源")),
        ("allow_sources", L10n.t("仅允许指定来源")),
        ("deny_all", L10n.t("禁止所有访问")),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    OutlinedShape(label: L10n.t("端点"), isFocused: false,
                                  hasValue: true, trailing: { EmptyView() }) {
                        Text("\(endpoint.hostIP ?? ""):\(endpoint.hostPort.map(String.init) ?? "")/\(endpoint.protocolField?.uppercased() ?? "")")
                            .font(.dataMonospacedBody)
                            .lineLimit(1)
                    }
                    OutlinedShape(label: L10n.t("容器"), isFocused: false,
                                  hasValue: !(endpoint.containerName ?? "").isEmpty,
                                  trailing: { EmptyView() }) {
                        Text(endpoint.containerName ?? "—")
                            .lineLimit(1)
                    }
                } header: {
                    SectionLabel(title: L10n.t("防护目标"), systemImage: "shippingbox")
                }

                Section {
                    OutlinedPicker(label: L10n.t("防护模式"),
                                   options: modeOptions.map(\.0),
                                   selection: $mode,
                                   optionLabels: Dictionary(uniqueKeysWithValues:
                                       modeOptions.map { ($0.0, $0.1) }))
                    OutlinedMultiLineField(label: L10n.t("来源"), prompt: "172.29.0.0/24",
                                           lines: 1, text: $sourcesText)
                    OutlinedMultiLineField(label: L10n.t("备注"), prompt: L10n.t("可选"),
                                           lines: 1, text: $descriptionText)
                } header: {
                    SectionLabel(title: L10n.t("防护策略"), systemImage: "shield.lefthalf.filled")
                } footer: {
                    Text(L10n.t("禁止指定来源：拦截列出的来源；仅允许指定来源：只放行列出的来源；禁止所有访问：拦截全部来源（0.0.0.0/0 与 ::/0）。"))
                }
            }
            .navigationTitle(L10n.t("设置端口防护"))
            .navigationBarTitleDisplayMode(.inline)
            .formWidthLimit()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text(L10n.t("保存"))
                        }
                    }
                    .disabled(!canSubmit || isSubmitting)
                }
            }
            .interactiveDismissDisabled(isSubmitting)
            .onAppear { fill() }
        }
    }

    private var canSubmit: Bool {
        mode == "deny_all" || !sourceLines.isEmpty
    }

    /// 来源多行原文 → 非空行数组
    private var sourceLines: [String] {
        sourcesText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 禁止所有访问的固定来源（v4/v6 全量；服务端按此存储，回显同值）
    private static let denyAllSourcesText = "0.0.0.0/0\n::/0"

    private func fill() {
        if let m = endpoint.mode, !m.isEmpty {
            mode = m
        }
        let stored = (endpoint.sources ?? []).filter { !$0.isEmpty }
        if stored.isEmpty && (endpoint.mode ?? "deny_all") == "deny_all" {
            sourcesText = Self.denyAllSourcesText
        } else {
            sourcesText = stored.joined(separator: "\n")
        }
        descriptionText = endpoint.descriptionText ?? ""
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        // deny_all 且未改动时按固定来源提交（与 Web 端一致），避免落库空数组
        let sources: [String]
        if mode == "deny_all" && sourceLines.isEmpty {
            sources = ["0.0.0.0/0", "::/0"]
        } else {
            sources = sourceLines
        }
        let policy = DockerGuardPolicy(
            family: endpoint.family ?? "ipv4",
            hostIP: endpoint.hostIP ?? "0.0.0.0",
            hostPort: endpoint.hostPort ?? 0,
            protocolField: endpoint.protocolField ?? "tcp",
            mode: mode,
            sources: sources,
            descriptionText: descriptionText
        )
        if await vm.upsertDockerPolicy(policy) {
            dismiss()
        }
    }
}

