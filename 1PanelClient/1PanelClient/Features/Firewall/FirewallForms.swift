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
    @State private var isSubmitting = false

    private static let protocols = ["tcp", "udp", "tcp/udp", "icmp", "icmpv6"]
    private var isEdit: Bool { editing != nil }

    var body: some View {
        Form {
            Section {
                Picker(L10n.t("协议"), selection: $proto) {
                    ForEach(Self.protocols, id: \.self) { Text($0.uppercased()).tag($0) }
                }
                if proto == "icmp" || proto == "icmpv6" {
                    // ICMP 无端口概念
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
        if proto == "icmp" || proto == "icmpv6" { return true }
        // 端口规则：目标端口必填；纯 IP 规则：源地址必填
        return !destPort.trimmingCharacters(in: .whitespaces).isEmpty
            || !sourceAddress.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func fillIfEditing() {
        guard let rule = editing, sourceAddress.isEmpty, destPort.isEmpty else { return }
        proto = rule.protocolField == "all" ? "tcp/udp" : (rule.protocolField ?? "tcp")
        sourceAddress = rule.sourceAddress ?? ""
        sourcePort = rule.sourcePort ?? ""
        destAddress = rule.destinationAddress ?? ""
        destPort = rule.destinationPort ?? ""
        action = rule.action ?? "accept"
        family = rule.scope?.family == "ipv6" ? "ipv6" : (rule.scope?.family == "inet" ? "ipv4" : (rule.scope?.family ?? "ipv4"))
        descriptionText = rule.descriptionText ?? ""
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }

        var effectiveFamily = family
        if proto == "icmp" { effectiveFamily = "ipv4" }
        if proto == "icmpv6" { effectiveFamily = "ipv6" }
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
        rule.protocolField = (proto == "tcp/udp" && vm.systemStatus?.backend == "ufw") ? "all" : proto
        rule.sourceAddress = sourceAddress.trimmingCharacters(in: .whitespaces)
        rule.sourcePort = sourcePort.trimmingCharacters(in: .whitespaces)
        rule.destinationAddress = destAddress.trimmingCharacters(in: .whitespaces)
        rule.destinationPort = destPort.trimmingCharacters(in: .whitespaces)
        rule.action = action
        rule.descriptionText = descriptionText
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
    @State private var targetIP = ""
    @State private var targetPort = ""
    @State private var iface = "*"
    @State private var isSubmitting = false

    private static let protocols = ["tcp", "udp", "tcp/udp"]
    private var isEdit: Bool { editing != nil }

    var body: some View {
        Form {
            Section {
                TextField(L10n.t("端口"), text: $port)
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
        targetIP = rule.targetIP ?? ""
        targetPort = rule.targetPort ?? ""
        iface = (rule.interface?.isEmpty == false) ? (rule.interface ?? "*") : "*"
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }

        var operations: [FirewallForwardOperation] = []
        // 编辑 = 同请求内先删旧再建新（上游仅支持 add/remove）
        if let old = editing {
            operations.append(FirewallForwardOperation(
                operation: "remove",
                num: old.num,
                family: old.family,
                protocolField: old.protocolField ?? "tcp",
                interface: old.interface,
                port: old.port ?? "",
                targetIP: nil,
                targetPort: ""
            ))
        }
        operations.append(FirewallForwardOperation(
            operation: "add",
            num: nil,
            family: nil,
            protocolField: proto,
            interface: iface == "*" ? nil : iface,
            port: port.trimmingCharacters(in: .whitespaces),
            targetIP: targetIP.isEmpty ? nil : targetIP.trimmingCharacters(in: .whitespaces),
            targetPort: targetPort.trimmingCharacters(in: .whitespaces)
        ))
        if await vm.submitForward(operations) {
            dismiss()
        }
    }
}

// MARK: - 面板端口白名单（v2.3.0：settings.portWhiteList 展示 + 任务式更新）

struct FirewallWhitelistView: View {
    @ObservedObject var vm: FirewallViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var isSubmitting = false

    var body: some View {
        Form {
            Section {
                TextEditor(text: $value)
                    .font(.dataMonospacedBody)
                    .frame(minHeight: 180)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                SectionLabel(title: L10n.t("端口白名单"), systemImage: "checkmark.shield")
            } footer: {
                Text(L10n.t("每行一个端口，可带协议（如 80/tcp、443/udp）；逗号或换行分隔均可，保存为全量覆盖。"))
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
            if value.isEmpty {
                value = vm.settings?.portWhiteList ?? ""
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        if await vm.updatePortWhitelist(value) {
            dismiss()
        }
    }
}
