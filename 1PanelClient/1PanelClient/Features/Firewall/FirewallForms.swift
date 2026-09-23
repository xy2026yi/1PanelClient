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

struct FirewallRuleFormView: View {
    @ObservedObject var vm: FirewallViewModel
    /// 编辑模式的既有规则与操作键（创建时均为 nil）
    let editing: FirewallRule?
    let editingUUID: String?

    @Environment(\.dismiss) private var dismiss

    @State private var proto = "tcp"
    @State private var sourceAddress = ""
    @State private var sourcePort = ""
    @State private var destAddress = ""
    @State private var destPort = ""
    @State private var action = "accept"
    @State private var family = "ipv4"
    @State private var descriptionText = ""
    /// 优先级（编辑态可选；抓包 2026-09-17：rules/update 支持 orderIndex 单改）
    @State private var priority = ""
    @State private var isSubmitting = false

    /// 抓包 2026-09-17：Web 端创建仅 TCP/UDP/TCP-UDP/ALL 四档（ALL 不带端口）
    private static let protocols = ["tcp", "udp", "tcp/udp", "all"]
    private var isEdit: Bool { editing != nil }

    var body: some View {
        Form {
            Section {
                OutlinedPicker(label: L10n.t("协议"), options: Self.protocols,
                               selection: $proto,
                               optionLabels: Dictionary(uniqueKeysWithValues:
                                   Self.protocols.map { ($0, $0.uppercased()) }))
                if proto == "all" {
                    // ALL 无端口概念（抓包：destinationPort 留空）
                } else {
                    OutlinedTextField(label: L10n.t("源地址"), prompt: "192.168.1.0/24",
                                      text: $sourceAddress)
                    OutlinedTextField(label: L10n.t("源端口"), prompt: "8000-8009",
                                      text: $sourcePort, keyboardType: .numbersAndPunctuation)
                    OutlinedTextField(label: L10n.t("目标地址"), prompt: "10.0.0.1",
                                      text: $destAddress)
                    OutlinedTextField(label: L10n.t("目标端口"), prompt: "80",
                                      text: $destPort, keyboardType: .numbersAndPunctuation)
                }
                OutlinedPicker(label: L10n.t("地址族"), options: ["ipv4", "ipv6"],
                               selection: $family,
                               optionLabels: ["ipv4": "IPv4", "ipv6": "IPv6"])
            } header: {
                SectionLabel(title: L10n.t("规则内容"), systemImage: "shield")
            } footer: {
                Text(L10n.t("源地址支持 CIDR（如 192.168.1.0/24）；端口支持 8000-8009 区间；留空源地址表示全部来源。"))
            }

            Section {
                OutlinedPicker(label: L10n.t("策略"), options: ["accept", "drop", "reject"],
                               selection: $action,
                               optionLabels: ["accept": L10n.t("放行"),
                                              "drop": L10n.t("拒绝"),
                                              "reject": L10n.t("驳回")])
                if isEdit {
                    OutlinedTextField(label: L10n.t("优先级"), prompt: L10n.t("留空不变"),
                                      text: $priority, keyboardType: .numberPad)
                }
                OutlinedTextField(label: L10n.t("备注"), prompt: L10n.t("可选"),
                                  text: $descriptionText)
            } header: {
                SectionLabel(title: L10n.t("策略与备注"), systemImage: "slider.horizontal.3")
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

    private var canSubmit: Bool {
        if proto == "all" { return true }
        // 端口规则：目标端口必填；纯 IP 规则：源地址必填
        return !destPort.trimmingCharacters(in: .whitespaces).isEmpty
            || !sourceAddress.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func fillIfEditing() {
        guard let rule = editing, sourceAddress.isEmpty, destPort.isEmpty else { return }
        proto = rule.protocolField ?? "tcp"
        sourceAddress = rule.sourceAddress ?? ""
        sourcePort = rule.sourcePort ?? ""
        destAddress = rule.destinationAddress ?? ""
        destPort = rule.destinationPort ?? ""
        action = rule.action ?? "accept"
        family = rule.scope?.family == "ipv6" ? "ipv6" : (rule.scope?.family == "inet" ? "ipv4" : (rule.scope?.family ?? "ipv4"))
        descriptionText = rule.descriptionText ?? ""
        if let idx = rule.orderIndex {
            priority = String(idx)
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }

        var effectiveFamily = family
        if !sourceAddress.isEmpty, sourceAddress.contains(":") { effectiveFamily = "ipv6" }
        if !destAddress.isEmpty, destAddress.contains(":") { effectiveFamily = "ipv6" }

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
        rule.sourceAddress = sourceAddress.trimmingCharacters(in: .whitespaces)
        rule.sourcePort = sourcePort.trimmingCharacters(in: .whitespaces)
        rule.destinationAddress = destAddress.trimmingCharacters(in: .whitespaces)
        rule.destinationPort = destPort.trimmingCharacters(in: .whitespaces)
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

    private var isDirty: Bool { entries != original }

    private var ipv4Entries: [FirewallPortWhitelistEntry] { entries.filter { $0.family != "ipv6" } }
    private var ipv6Entries: [FirewallPortWhitelistEntry] { entries.filter { $0.family == "ipv6" } }

    var body: some View {
        Form {
            familySection("IPv4", items: ipv4Entries, footer: false)
            familySection("IPv6", items: ipv6Entries, footer: true)
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
                        Image(systemName: "plus.circle")
                    }
                    .accessibilityLabel(L10n.t("添加"))
                }
            }
        }
        .sheet(isPresented: $showEntryForm) {
            FirewallWhitelistEntryFormView(
                editing: editingID.flatMap { id in entries.first { $0.id == id } }
            ) { result in
                applyResult(result)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .interactiveDismissDisabled(isSubmitting)
        .onAppear {
            if original.isEmpty {
                // 双格式解析：初始逗号串 / 编辑后的 JSON 数组字符串
                let parsed = parseFirewallWhitelistEntries(vm.settings?.portWhiteList)
                entries = parsed
                original = parsed
            }
        }
    }

    /// 按 IP 版本分组的列表（行内不带地址族后缀）；长按行弹 编辑 / 添加 菜单
    private func familySection(_ title: String, items: [FirewallPortWhitelistEntry],
                               footer: Bool) -> some View {
        Section {
            if items.isEmpty {
                Text(L10n.t("未设置"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { entry in
                    HStack {
                        Text(entry.display)
                            .font(.dataMonospacedBody)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button {
                            editingID = entry.id
                            showEntryForm = true
                        } label: {
                            Label(L10n.t("编辑"), systemImage: "pencil")
                        }
                        Button {
                            editingID = nil
                            showEntryForm = true
                        } label: {
                            Label(L10n.t("添加"), systemImage: "plus.circle")
                        }
                    }
                }
                .onDelete { offsets in
                    let doomed = offsets.map { items[$0].id }
                    entries.removeAll { doomed.contains($0.id) }
                }
            }
        } header: {
            Text(title)
        } footer: {
            if footer {
                Text(L10n.t("支持 IPv4/IPv6、TCP/UDP、单端口及 8000-8100 格式的端口范围；保存为全量覆盖。"))
            }
        }
    }

    /// 编辑/添加结果落库：按原 id 替换或追加
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
        let value = encodeFirewallWhitelistEntries(
            entries.map { entry in
                FirewallPortWhitelistEntry(
                    family: entry.family,
                    protocolField: entry.protocolField,
                    port: entry.port.trimmingCharacters(in: .whitespaces))
            }
        )
        if await vm.updatePortWhitelist(value) {
            dismiss()
        }
    }
}

// MARK: - 端口白名单条目表单（编辑 / 添加）

/// IP 版本 / 协议（形态 3）+ 端口范围（形态 1）
struct FirewallWhitelistEntryFormView: View {
    /// nil = 添加
    let editing: FirewallPortWhitelistEntry?
    let onSave: (FirewallPortWhitelistEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var family = "ipv4"
    @State private var proto = "tcp"
    @State private var port = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    OutlinedPicker(label: L10n.t("IP版本"), options: ["ipv4", "ipv6"],
                                   selection: $family,
                                   optionLabels: ["ipv4": "IPv4", "ipv6": "IPv6"])
                    OutlinedPicker(label: L10n.t("协议"), options: ["tcp", "udp"],
                                   selection: $proto,
                                   optionLabels: ["tcp": "TCP", "udp": "UDP"])
                    OutlinedTextField(label: L10n.t("端口范围"), prompt: "8080 或 8000-8100",
                                      text: $port, keyboardType: .numbersAndPunctuation)
                } footer: {
                    Text(L10n.t("支持单端口及 8000-8100 格式的端口范围"))
                }
            }
            .navigationTitle(editing == nil ? L10n.t("添加") : L10n.t("编辑"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("保存")) {
                        onSave(FirewallPortWhitelistEntry(
                            family: family,
                            protocolField: proto,
                            port: port.trimmingCharacters(in: .whitespaces)))
                        dismiss()
                    }
                    .disabled(port.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let e = editing {
                    family = e.family
                    proto = e.protocolField
                    port = e.port
                }
            }
        }
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
                        statRow(L10n.t("可同步"), p.ready ?? 0, color: .statusRunning)
                        statRow(L10n.t("已一致"), p.existing ?? 0, color: .secondary)
                        statRow(L10n.t("将移除"), p.removed ?? 0, color: .statusError)
                        statRow(L10n.t("受阻"), p.blocked ?? 0, color: .semanticWarning)
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
                    if mode != "deny_all" {
                        OutlinedMultiLineField(label: L10n.t("来源"), prompt: "172.29.0.0/24",
                                               lines: 1, text: $sourcesText)
                    }
                    OutlinedMultiLineField(label: L10n.t("备注"), prompt: L10n.t("可选"),
                                           lines: 1, text: $descriptionText)
                } header: {
                    SectionLabel(title: L10n.t("防护策略"), systemImage: "shield.lefthalf.filled")
                } footer: {
                    Text(L10n.t("禁止指定来源：拦截列出的来源；仅允许指定来源：只放行列出的来源；禁止所有访问：拦截全部访问。"))
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

    private func fill() {
        if let m = endpoint.mode, !m.isEmpty {
            mode = m
        }
        sourcesText = (endpoint.sources ?? []).filter { !$0.isEmpty }.joined(separator: "\n")
        descriptionText = endpoint.descriptionText ?? ""
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let policy = DockerGuardPolicy(
            family: endpoint.family ?? "ipv4",
            hostIP: endpoint.hostIP ?? "0.0.0.0",
            hostPort: endpoint.hostPort ?? 0,
            protocolField: endpoint.protocolField ?? "tcp",
            mode: mode,
            sources: mode == "deny_all" ? [] : sourceLines,
            descriptionText: descriptionText
        )
        if await vm.upsertDockerPolicy(policy) {
            dismiss()
        }
    }
}

