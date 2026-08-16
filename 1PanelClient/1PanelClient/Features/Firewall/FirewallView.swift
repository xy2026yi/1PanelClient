//
//  FirewallView.swift
//  1PanelClient
//
//  防火墙（ufw）管理：状态卡片 + 端口规则增删
//

import SwiftUI
import Combine

@MainActor
final class FirewallViewModel: ObservableObject {
    @Published var base: FirewallBase?
    @Published var rules: [FirewallRule] = []
    @Published var isLoading = false
    @Published var isOperating = false
    @Published var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    func refresh() async {
        await loadBase()
        await loadRules()
    }

    func loadBase() async {
        struct BaseReq: Encodable { let name: String }
        do {
            let resp: FirewallBase = try await client.send(
                path: APIEndpoint.firewallBase.path,
                body: BaseReq(name: "base"),
                as: FirewallBase.self
            )
            self.base = resp
            self.errorMessage = nil
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func loadRules() async {
        let req = FirewallSearchRequest(type: "port", status: "", strategy: "", page: 1, pageSize: 200)
        do {
            let resp: PageResponse<FirewallRule> = try await client.send(
                path: APIEndpoint.firewallSearch.path,
                body: req,
                as: PageResponse<FirewallRule>.self
            )
            self.rules = resp.items ?? []
            self.errorMessage = nil
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    /// start / stop / restart
    func operateUFW(_ operation: String, withDockerRestart: Bool) async {
        isOperating = true
        defer { isOperating = false }
        let req = FirewallOperateRequest(operation: operation, withDockerRestart: withDockerRestart)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.firewallOperate.path,
                body: req,
                as: EmptyResponse.self
            )
            await loadBase()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func togglePing(_ block: Bool) async {
        let op = block ? "enablePing" : "disablePing"
        await operateUFW(op, withDockerRestart: false)
    }

    func addRule(port: String, proto: String, strategy: String, address: String, description: String) async -> Bool {
        let source = address.isEmpty ? "anyWhere" : address
        let req = FirewallPortRequest(
            protocolField: proto, source: source, strategy: strategy,
            port: port, description: description, operation: "add", address: address
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.firewallPort.path, body: req, as: EmptyResponse.self
            )
            await loadRules()
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteRule(_ rule: FirewallRule) async {
        let br = FirewallBatchRule(
            operation: "remove",
            chain: rule.chain ?? "",
            address: rule.address ?? "",
            port: rule.port ?? "",
            source: rule.address ?? "",
            protocolField: rule.protocolField ?? "",
            strategy: rule.strategy ?? ""
        )
        let req = FirewallBatchRequest(type: "port", rules: [br])
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.firewallBatch.path, body: req, as: EmptyResponse.self
            )
            await loadRules()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    /// 修改端口规则：oldRule(remove) + newRule(add)
    func updateRule(
        old: FirewallRule,
        port: String, proto: String, strategy: String,
        address: String, description: String
    ) async -> Bool {
        let oldFull = FirewallRuleFull(from: old, operation: "remove")
        let newAddr = address.isEmpty ? "Anywhere" : address
        let newRule = FirewallRule(
            address: newAddr,
            port: port,
            protocolField: proto,
            strategy: strategy,
            usedStatus: old.usedStatus,
            description: description,
            family: old.family,
            chain: old.chain
        )
        let newFull = FirewallRuleFull(from: newRule, operation: "add")
        let req = FirewallUpdatePortRequest(oldRule: oldFull, newRule: newFull)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.firewallUpdatePort.path, body: req, as: EmptyResponse.self
            )
            await loadRules()
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }
}

// MARK: - 主视图

struct FirewallView: View {
    @StateObject private var vm: FirewallViewModel
    @State private var showAdd = false
    @State private var pendingUFWOp: String?
    @State private var pendingDeleteRule: FirewallRule?
    @State private var editingRule: FirewallRule?
    @State private var actionRule: FirewallRule?
    @State private var statusExpanded = false

    init(server: ServerConfig) {
        _vm = StateObject(wrappedValue: FirewallViewModel(server: server))
    }

    var body: some View {
        List {
            statusSection
            if vm.rules.isEmpty {
                if vm.isLoading {
                    EmptyView()
                } else {
                    Section {
                        ContentUnavailableView(
                            "暂无端口规则",
                            systemImage: "flame",
                            description: Text("点击右下角 + 添加规则")
                        )
                        .listRowBackground(Color.clear)
                    }
                }
            } else {
                Section {
                    ForEach(vm.rules) { rule in
                        Button {
                            actionRule = rule
                        } label: {
                            FirewallRuleRow(rule: rule)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    SectionLabel(title: "端口规则（\(vm.rules.count)）", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .navigationTitle("防火墙")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.refresh() }
        .task {
            if vm.base == nil {
                vm.isLoading = true
                await vm.refresh()
                vm.isLoading = false
            }
        }
        .overlay {
            if vm.isLoading && vm.base == nil {
                ProgressView()
            } else if let msg = vm.errorMessage, vm.base == nil {
                ErrorBanner(message: msg) { Task { await vm.refresh() } }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            FloatingActionButton(action: { showAdd = true })
                .disabled(vm.base?.isExist != true)
                .opacity(vm.base?.isExist == true ? 1 : 0.4)
        }
        .navigationDestination(isPresented: $showAdd) {
            FirewallAddRuleView(vm: vm)
        }
        .navigationDestination(isPresented: Binding(
            get: { editingRule != nil },
            set: { if !$0 { editingRule = nil } }
        )) {
            if let rule = editingRule {
                FirewallEditRuleView(vm: vm, rule: rule)
            }
        }
        .sheet(isPresented: Binding(
            get: { actionRule != nil },
            set: { if !$0 { actionRule = nil } }
        )) {
            ActionBottomSheet(
                title: actionRule?.port ?? "端口规则",
                items: [
                    ActionMenuItem(title: "修改", icon: "pencil", color: .blue) {
                        let r = actionRule
                        editingRule = r
                    },
                    ActionMenuItem(title: "删除", icon: "trash", color: .red, role: .destructive) {
                        pendingDeleteRule = actionRule
                    },
                ],
                onDismiss: { actionRule = nil }
            )
            .presentationDetents([.height(ActionBottomSheet.height(for: 2))])
            .presentationDragIndicator(.visible)
        }
        .alert(
            pendingDeleteRule.map { "删除端口规则 \($0.port ?? "") ？" } ?? "删除端口规则？",
            isPresented: Binding(
                get: { pendingDeleteRule != nil },
                set: { if !$0 { pendingDeleteRule = nil } }
            )
        ) {
            Button("删除", role: .destructive) {
                if let rule = pendingDeleteRule {
                    pendingDeleteRule = nil
                    Task { await vm.deleteRule(rule) }
                }
            }
            Button("取消", role: .cancel) { pendingDeleteRule = nil }
        }
        .alert(
            pendingUFWOp.map { opTitle($0) } ?? "",
            isPresented: Binding(
                get: { pendingUFWOp != nil },
                set: { if !$0 { pendingUFWOp = nil } }
            )
        ) {
            Button("立即重启 Docker") {
                let op = pendingUFWOp; pendingUFWOp = nil
                if let op { Task { await vm.operateUFW(op, withDockerRestart: true) } }
            }
            Button("稍后手动重启") {
                let op = pendingUFWOp; pendingUFWOp = nil
                if let op { Task { await vm.operateUFW(op, withDockerRestart: false) } }
            }
            Button("取消", role: .cancel) { pendingUFWOp = nil }
        } message: {
            Text("启用/停用防火墙可能影响 Docker 网络连通性。是否立即重启 Docker？")
        }
    }

    private var statusSection: some View {
        Section {
            if let base = vm.base {
                if base.isExist == true {
                    // 状态行：版本（上）+ 状态（下）+ 展开箭头
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text((base.name ?? "ufw").uppercased())
                                    .font(.system(.headline, design: .monospaced))
                                if let v = base.version, !v.isEmpty {
                                    Text("v\(v)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: 4) {
                                StatusBadge(
                                    text: (base.isActive ?? false) ? "运行中" : "已停止",
                                    color: (base.isActive ?? false) ? .green : .red
                                )
                            }
                        }
                        Spacer()
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                statusExpanded.toggle()
                            }
                        } label: {
                            Image(systemName: statusExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.isOperating)
                    }
                    .padding(.vertical, 2)

                    // 展开后显示：关闭/开启 + 重启
                    if statusExpanded {
                        HStack(spacing: 8) {
                            firewallActionButton(
                                title: (base.isActive ?? false) ? "关闭" : "开启",
                                icon: (base.isActive ?? false) ? "stop.fill" : "play.fill",
                                color: (base.isActive ?? false) ? .red : .green
                            ) {
                                pendingUFWOp = (base.isActive ?? false) ? "stop" : "start"
                            }
                            firewallActionButton(
                                title: "重启",
                                icon: "arrow.triangle.2.circlepath",
                                color: .orange
                            ) {
                                pendingUFWOp = "restart"
                            }
                        }
                        .padding(.top, 2)
                        .padding(.bottom, 2)
                    }

                    // 禁 ping
                    Toggle(isOn: Binding(
                        get: { base.pingBlocked },
                        set: { block in Task { await vm.togglePing(block) } }
                    )) {
                        Label("禁 ping", systemImage: "antenna.radiowaves.left.and.right.slash")
                    }
                    .disabled(vm.isOperating || (base.isActive != true))
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.shield")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)
                        Text("未检测到防火墙")
                            .font(.headline)
                        Text("请在服务器上安装 ufw / firewalld 后使用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding(.vertical, 8)
            }
        }
    }

    private func opTitle(_ op: String) -> String {
        switch op {
        case "start":   return "启动防火墙"
        case "stop":    return "停用防火墙"
        case "restart": return "重启防火墙"
        default:        return "操作防火墙"
        }
    }

    @ViewBuilder
    private func firewallActionButton(
        title: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                    .frame(width: 22, height: 22)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(vm.isOperating)
    }
}

// MARK: - 规则行

struct FirewallRuleRow: View {
    let rule: FirewallRule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(rule.port ?? "-")
                    .font(.system(.body, design: .monospaced).bold())
                if let proto = rule.protocolField, !proto.isEmpty {
                    StatusBadge(text: proto.uppercased(), color: .blue)
                }
                Spacer()
                strategyBadge(rule.strategy)
            }
            if let addr = rule.address, !addr.isEmpty {
                Text("来源：\(addr)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let desc = rule.description, !desc.isEmpty {
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
            if let used = rule.usedStatus, !used.isEmpty {
                StatusBadge(text: used, color: .green, icon: "checkmark.circle.fill")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func strategyBadge(_ s: String?) -> some View {
        switch s?.lowercased() {
        case "accept", "允许":
            StatusBadge(text: "允许", color: .green, icon: "checkmark")
        case "drop", "拒绝":
            StatusBadge(text: "拒绝", color: .red, icon: "xmark")
        default:
            if let s { StatusBadge(text: s, color: .secondary) }
        }
    }
}

// MARK: - 添加规则

struct FirewallAddRuleView: View {
    @ObservedObject var vm: FirewallViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var port = ""
    @State private var proto = "tcp"
    @State private var strategy = "accept"
    @State private var address = ""
    @State private var description = ""
    @State private var saving = false

    private let protos = ["tcp", "udp"]
    private let strategies = [("accept", "允许"), ("drop", "拒绝")]

    private var isValid: Bool {
        !port.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("端口", text: $port)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                Text("单个端口如 8080，或范围如 3000-3100。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { SectionLabel(title: "端口", systemImage: "number") }

            Section {
                Picker("协议", selection: $proto) {
                    ForEach(protos, id: \.self) { Text($0.uppercased()).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: { SectionLabel(title: "协议", systemImage: "network") }

            Section {
                Picker("策略", selection: $strategy) {
                    ForEach(strategies, id: \.0) { Text($1).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: { SectionLabel(title: "策略", systemImage: "hand.raised") }

            Section {
                TextField("IP / CIDR，留空=任意", text: $address)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                Text("例如 192.168.1.10、10.0.0.0/24。留空表示允许所有来源。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { SectionLabel(title: "来源地址", systemImage: "location") }

            Section {
                TextField("备注（可选）", text: $description)
            } header: { SectionLabel(title: "备注", systemImage: "text.alignleft") }
        }
        .navigationTitle("添加端口规则")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("添加") {
                    Task {
                        saving = true
                        let ok = await vm.addRule(
                            port: port.trimmingCharacters(in: .whitespaces),
                            proto: proto, strategy: strategy,
                            address: address.trimmingCharacters(in: .whitespaces),
                            description: description
                        )
                        saving = false
                        if ok { dismiss() }
                    }
                }
                .disabled(!isValid || saving)
            }
        }
    }
}

// MARK: - 修改规则

struct FirewallEditRuleView: View {
    @ObservedObject var vm: FirewallViewModel
    let rule: FirewallRule
    @Environment(\.dismiss) private var dismiss

    @State private var port = ""
    @State private var proto = "tcp"
    @State private var strategy = "accept"
    @State private var address = ""
    @State private var description = ""
    @State private var saving = false

    private let protos = ["tcp", "udp"]
    private let strategies = [("accept", "允许"), ("drop", "拒绝")]

    private var isValid: Bool {
        !port.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("端口", text: $port)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                Text("单个端口如 8080，或范围如 3000-3100。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { SectionLabel(title: "端口", systemImage: "number") }

            Section {
                Picker("协议", selection: $proto) {
                    ForEach(protos, id: \.self) { Text($0.uppercased()).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: { SectionLabel(title: "协议", systemImage: "network") }

            Section {
                Picker("策略", selection: $strategy) {
                    ForEach(strategies, id: \.0) { Text($1).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: { SectionLabel(title: "策略", systemImage: "hand.raised") }

            Section {
                TextField("IP / CIDR，留空=任意", text: $address)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                Text("例如 192.168.1.10、10.0.0.0/24。留空表示允许所有来源。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { SectionLabel(title: "来源地址", systemImage: "location") }

            Section {
                TextField("备注（可选）", text: $description)
            } header: { SectionLabel(title: "备注", systemImage: "text.alignleft") }
        }
        .navigationTitle("修改端口规则")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") {
                    Task {
                        saving = true
                        let ok = await vm.updateRule(
                            old: rule,
                            port: port.trimmingCharacters(in: .whitespaces),
                            proto: proto, strategy: strategy,
                            address: address.trimmingCharacters(in: .whitespaces),
                            description: description
                        )
                        saving = false
                        if ok { dismiss() }
                    }
                }
                .disabled(!isValid || saving)
            }
        }
        .onAppear {
            port = rule.port ?? ""
            proto = rule.protocolField ?? "tcp"
            strategy = rule.strategy ?? "accept"
            let addr = rule.address ?? ""
            address = (addr == "Anywhere") ? "" : addr
            description = rule.description ?? ""
        }
    }
}
