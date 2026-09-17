//
//  FirewallForms.swift
//  1PanelClient
//
//  防火墙 v2.3.0 表单：统一规则（创建/编辑，端口与 IP 规则同型）、
//  端口转发（编辑 = remove + add 同请求）、面板端口白名单（任务式提交）。
//

import SwiftUI

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
                Picker(L10n.t("协议"), selection: $proto) {
                    ForEach(Self.protocols, id: \.self) { Text($0.uppercased()).tag($0) }
                }
                if proto == "all" {
                    // ALL 无端口概念（抓包：destinationPort 留空）
                } else {
                    TextField(L10n.t("源地址"), text: $sourceAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.dataMonospaced)
                    TextField(L10n.t("源端口"), text: $sourcePort)
                        .keyboardType(.numbersAndPunctuation)
                        .font(.dataMonospaced)
                    TextField(L10n.t("目标地址"), text: $destAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.dataMonospaced)
                    TextField(L10n.t("目标端口"), text: $destPort)
                        .keyboardType(.numbersAndPunctuation)
                        .font(.dataMonospaced)
                }
                Picker(L10n.t("地址族"), selection: $family) {
                    Text("IPv4").tag("ipv4")
                    Text("IPv6").tag("ipv6")
                }
            } header: {
                SectionLabel(title: L10n.t("规则内容"), systemImage: "shield")
            } footer: {
                Text(L10n.t("源地址支持 CIDR（如 192.168.1.0/24）；端口支持 8000-8009 区间；留空源地址表示全部来源。"))
            }

            Section {
                Picker(L10n.t("策略"), selection: $action) {
                    Text(L10n.t("放行")).tag("accept")
                    Text(L10n.t("拒绝")).tag("drop")
                    Text(L10n.t("驳回")).tag("reject")
                }
                if isEdit {
                    TextField(L10n.t("优先级（留空不变）"), text: $priority)
                        .keyboardType(.numberPad)
                }
                TextField(L10n.t("备注"), text: $descriptionText)
            } header: {
                SectionLabel(title: L10n.t("策略与备注"), systemImage: "slider.horizontal.3")
            }
        }
        .navigationTitle(isEdit ? L10n.t("编辑规则") : L10n.t("创建规则"))
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
                        Text(isEdit ? L10n.t("保存") : L10n.t("创建"))
                    }
                }
                .disabled(!canSubmit || isSubmitting)
            }
        }
        .interactiveDismissDisabled(isSubmitting)
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
                Picker(L10n.t("地址族"), selection: $family) {
                    Text("IPv4").tag("ipv4")
                    Text("IPv6").tag("ipv6")
                }
                TextField(L10n.t("源端口"), text: $port)
                    .keyboardType(.numbersAndPunctuation)
                    .font(.dataMonospaced)
                Picker(L10n.t("协议"), selection: $proto) {
                    ForEach(Self.protocols, id: \.self) { Text($0.uppercased()).tag($0) }
                }
                TextField(L10n.t("目标地址"), text: $targetIP)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.dataMonospaced)
                TextField(L10n.t("目标端口"), text: $targetPort)
                    .keyboardType(.numbersAndPunctuation)
                    .font(.dataMonospaced)
                Picker(L10n.t("入站网卡"), selection: $iface) {
                    Text(L10n.t("所有网卡")).tag("*")
                    ForEach(vm.netOptions.filter { !$0.isEmpty }, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
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
                        Text(isEdit ? L10n.t("保存") : L10n.t("创建"))
                    }
                }
                .disabled(!canSubmit || isSubmitting)
            }
        }
        .interactiveDismissDisabled(isSubmitting)
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

// MARK: - 面板端口白名单（抓包 2026-09-17：结构化条目编辑，提交 JSON 数组字符串）

struct FirewallWhitelistView: View {
    @ObservedObject var vm: FirewallViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [FirewallPortWhitelistEntry] = []
    @State private var isSubmitting = false

    var body: some View {
        Form {
            Section {
                ForEach($entries) { $entry in
                    HStack(spacing: 8) {
                        Picker("", selection: $entry.family) {
                            Text("IPv4").tag("ipv4")
                            Text("IPv6").tag("ipv6")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 84)
                        Picker("", selection: $entry.protocolField) {
                            Text("TCP").tag("tcp")
                            Text("UDP").tag("udp")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 76)
                        TextField(L10n.t("端口/范围"), text: $entry.port)
                            .keyboardType(.numbersAndPunctuation)
                            .font(.dataMonospaced)
                    }
                }
                .onDelete { entries.remove(atOffsets: $0) }
                Button {
                    entries.append(FirewallPortWhitelistEntry(family: "ipv4",
                                                              protocolField: "tcp", port: ""))
                } label: {
                    Label(L10n.t("添加"), systemImage: "plus.circle")
                }
            } header: {
                SectionLabel(title: L10n.t("端口白名单"), systemImage: "checkmark.shield")
            } footer: {
                Text(L10n.t("支持 IPv4/IPv6、TCP/UDP、单端口及 8000-8100 格式的端口范围；保存为全量覆盖。"))
            }
        }
        .navigationTitle(L10n.t("面板端口白名单"))
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
                .disabled(isSubmitting)
            }
        }
        .interactiveDismissDisabled(isSubmitting)
        .onAppear {
            if entries.isEmpty {
                // 双格式解析：初始逗号串 / 编辑后的 JSON 数组字符串
                entries = parseFirewallWhitelistEntries(vm.settings?.portWhiteList)
            }
        }
    }

    private var canSubmit: Bool {
        entries.allSatisfy { !$0.port.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func submit() async {
        guard canSubmit else {
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
