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
}

// MARK: - 主视图

struct FirewallView: View {
    @StateObject private var vm: FirewallViewModel
    @State private var showAdd = false
    @State private var pendingUFWOp: String?

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
                        Text("暂无端口规则")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            } else {
                Section {
                    ForEach(vm.rules) { rule in
                        FirewallRuleRow(rule: rule)
                    }
                    .onDelete { indexSet in
                        Task {
                            for i in indexSet { await vm.deleteRule(vm.rules[i]) }
                        }
                    }
                } header: {
                    SectionLabel(title: "端口规则（\(vm.rules.count)）", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .navigationTitle("防火墙")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: {
                    Image(systemName: "plus")
                }
                .disabled(vm.base?.isExist != true)
            }
        }
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
        .sheet(isPresented: $showAdd) {
            FirewallAddRuleView(vm: vm)
        }
        .confirmationDialog(
            pendingUFWOp.map { opTitle($0) } ?? "",
            isPresented: Binding(
                get: { pendingUFWOp != nil },
                set: { if !$0 { pendingUFWOp = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let op = pendingUFWOp {
                Button("立即重启 Docker") { Task { await vm.operateUFW(op, withDockerRestart: true) } }
                Button("稍后手动重启") { Task { await vm.operateUFW(op, withDockerRestart: false) } }
                Button("取消", role: .cancel) {}
            }
        } message: {
            Text("启用/停用防火墙可能影响 Docker 网络连通性。是否立即重启 Docker？")
        }
    }

    private var statusSection: some View {
        Section {
            if let base = vm.base {
                if base.isExist == true {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text((base.name ?? "ufw").uppercased())
                                .font(.system(.headline, design: .monospaced))
                            if let v = base.version, !v.isEmpty {
                                Text("v\(v)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { base.isActive ?? false },
                            set: { active in
                                pendingUFWOp = active ? "start" : "stop"
                            }
                        ))
                        .labelsHidden()
                        .disabled(vm.isOperating)
                    }

                    Button {
                        pendingUFWOp = "restart"
                    } label: {
                        Label("重启防火墙", systemImage: "arrow.clockwise")
                    }
                    .disabled(vm.isOperating || (base.isActive != true))

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
        } header: {
            SectionLabel(title: "状态", systemImage: "shield")
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
                    Text(proto.uppercased())
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
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
        NavigationStack {
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
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
}
