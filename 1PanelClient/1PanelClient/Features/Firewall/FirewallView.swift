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
    /// 端口转发规则（search type=forward）
    @Published var forwards: [FirewallRule] = []
    /// IP 规则（search type=address）
    @Published var addresses: [FirewallRule] = []
    /// 网卡列表（端口转发的入站网口选择；"all" 展示为「所有」）
    @Published var netOptions: [String] = []
    /// 端口号 → 监听进程名（逗号拼接多个），来自 process/listening；
    /// 面板 firewall/search 的 usedStatus 只覆盖部分端口，这里补全
    @Published var portProcessNames: [String: String] = [:]
    @Published var isLoading = false
    @Published var isOperating = false
    @Published var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    func refresh() async {
        // 六个请求互不依赖，并行发出缩短进页耗时
        async let base: () = loadBase()
        async let rules: () = loadRules()
        async let listening: () = loadListening()
        async let forwards: () = loadForwards()
        async let addresses: () = loadAddresses()
        async let nets: () = loadNetOptions()
        _ = await (base, rules, listening, forwards, addresses, nets)
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

    /// 端口监听进程：映射 端口号 → 进程名（多进程监听同端口去重拼接）。
    /// Protocol 1=tcp / 2=udp，仅用于展示进程名，不区分协议
    func loadListening() async {
        struct EmptyPortInfo: Decodable {}
        struct ListeningItem: Decodable {
            let name: String?
            let port: [String: EmptyPortInfo]?

            enum CodingKeys: String, CodingKey {
                case name = "Name"
                case port = "Port"
            }
        }
        do {
            let items: [ListeningItem] = try await client.send(
                path: APIEndpoint.processListening.path,
                as: [ListeningItem].self
            )
            var map: [String: [String]] = [:]
            for item in items {
                guard let name = item.name?.trimmingCharacters(in: .whitespaces),
                      !name.isEmpty, let ports = item.port else { continue }
                for port in ports.keys where !port.isEmpty {
                    if !map[port, default: []].contains(name) {
                        map[port, default: []].append(name)
                    }
                }
            }
            self.portProcessNames = map.mapValues { $0.joined(separator: ", ") }
        } catch {
            // 进程名只是展示补充，失败静默（规则行仍显示面板返回的 usedStatus）
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
        // v2 后端 oneof=start stop restart disableBanPing enableBanPing；
        // 旧名 enablePing/disablePing 会触发 oneof 校验失败
        let op = block ? "enableBanPing" : "disableBanPing"
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
            chain: old.chain,
            num: old.num,
            apiID: old.apiID,
            targetIP: old.targetIP,
            targetPort: old.targetPort,
            interface: old.interface
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

    // MARK: 端口转发

    func loadForwards() async {
        let req = FirewallSearchRequest(type: "forward", status: "", strategy: "", page: 1, pageSize: 200)
        do {
            let resp: PageResponse<FirewallRule> = try await client.send(
                path: APIEndpoint.firewallSearch.path, body: req, as: PageResponse<FirewallRule>.self
            )
            self.forwards = resp.items ?? []
            self.errorMessage = nil
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func loadNetOptions() async {
        do {
            let resp: [String] = try await client.send(
                path: APIEndpoint.monitorNetOptions.path,
                method: APIEndpoint.monitorNetOptions.method,
                as: [String].self
            )
            self.netOptions = resp
        } catch {
            // 网口列表失败静默：表单回退为只有「所有」
        }
    }

    /// 创建端口转发；interface 传空串 = 所有网口（"all" 仅展示用）
    func createForward(proto: String, port: String, targetIP: String, targetPort: String, interface: String) async -> Bool {
        let rule = FirewallRule(
            address: "", port: port, protocolField: proto, strategy: "",
            usedStatus: "", description: "", family: "", chain: "",
            num: nil, apiID: nil, targetIP: targetIP, targetPort: targetPort, interface: interface
        )
        let req = FirewallForwardRequest(rules: [FirewallRuleFull(fromForward: rule, operation: "add")], forceDelete: nil)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.firewallForward.path, body: req, as: EmptyResponse.self
            )
            await loadForwards()
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    /// 修改端口转发：old(remove，原值完整回传) + new(add)
    func updateForward(
        old: FirewallRule,
        proto: String, port: String, targetIP: String, targetPort: String, interface: String
    ) async -> Bool {
        let oldFull = FirewallRuleFull(fromForward: old, operation: "remove")
        let newRule = FirewallRule(
            address: old.address ?? "", port: port, protocolField: proto,
            strategy: old.strategy ?? "", usedStatus: old.usedStatus ?? "",
            description: old.description ?? "", family: old.family ?? "", chain: old.chain ?? "",
            num: old.num, apiID: old.apiID, targetIP: targetIP, targetPort: targetPort, interface: interface
        )
        let req = FirewallForwardRequest(rules: [oldFull, FirewallRuleFull(fromForward: newRule, operation: "add")], forceDelete: nil)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.firewallForward.path, body: req, as: EmptyResponse.self
            )
            await loadForwards()
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    /// 删除端口转发（force：面板校验端口被占用时需强制删除）
    func deleteForward(_ rule: FirewallRule, force: Bool) async {
        let req = FirewallForwardRequest(rules: [FirewallRuleFull(fromForward: rule, operation: "remove")], forceDelete: force)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.firewallForward.path, body: req, as: EmptyResponse.self
            )
            await loadForwards()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    // MARK: IP 规则

    func loadAddresses() async {
        let req = FirewallSearchRequest(type: "address", status: "", strategy: "", page: 1, pageSize: 200)
        do {
            let resp: PageResponse<FirewallRule> = try await client.send(
                path: APIEndpoint.firewallSearch.path, body: req, as: PageResponse<FirewallRule>.self
            )
            self.addresses = resp.items ?? []
            self.errorMessage = nil
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    /// 创建 IP 规则（address 支持逗号分隔多个）
    func createAddressRule(address: String, strategy: String, description: String) async -> Bool {
        let desc = description.trimmingCharacters(in: .whitespaces)
        let req = FirewallIPRuleRequest(strategy: strategy, address: address, operation: "add", description: desc.isEmpty ? nil : desc)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.firewallIP.path, body: req, as: EmptyResponse.self
            )
            await loadAddresses()
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    /// 修改 IP 规则（指定 IP 不可改，仅策略/描述）；oldRule/newRule 保留 API 真实 id
    func updateAddressRule(old: FirewallRule, strategy: String, description: String) async -> Bool {
        let oldFull = FirewallRuleFull(fromAddressRule: old, operation: "remove")
        let newFull = FirewallRuleFull(
            id: oldFull.id,
            chain: oldFull.chain,
            family: oldFull.family,
            address: oldFull.address,
            port: oldFull.port,
            protocolField: oldFull.protocolField,
            strategy: strategy,
            num: oldFull.num,
            targetIP: oldFull.targetIP,
            targetPort: oldFull.targetPort,
            interface: oldFull.interface,
            usedStatus: oldFull.usedStatus,
            description: description,
            usedPorts: [],
            source: "",
            operation: "add"
        )
        let req = FirewallUpdateAddrRequest(oldRule: oldFull, newRule: newFull)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.firewallUpdateAddr.path, body: req, as: EmptyResponse.self
            )
            await loadAddresses()
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    /// 删除 IP 规则（batch type=address，strategy 回传规则当前值）
    func deleteAddressRule(_ rule: FirewallRule) async {
        let br = FirewallBatchRule(
            operation: "remove",
            chain: rule.chain ?? "",
            address: rule.address ?? "",
            port: rule.port ?? "",
            source: "",
            protocolField: rule.protocolField ?? "",
            strategy: rule.strategy ?? ""
        )
        let req = FirewallBatchRequest(type: "address", rules: [br])
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.firewallBatch.path, body: req, as: EmptyResponse.self
            )
            await loadAddresses()
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
    @State private var pendingDeleteRule: FirewallRule?
    @State private var editingRule: FirewallRule?
    @State private var actionRule: FirewallRule?
    @State private var statusExpanded = false
    @State private var showWhitelist = false
    @State private var showWAF = false
    /// 内容段：0=端口规则 1=端口转发 2=IP 规则（顶部横条三段切换，同告警页）
    @State private var segment = 0
    // 端口转发
    @State private var showAddForward = false
    @State private var editingForward: FirewallRule?
    @State private var actionForward: FirewallRule?
    @State private var pendingDeleteForward: FirewallRule?
    // IP 规则
    @State private var showAddAddress = false
    @State private var editingAddress: FirewallRule?
    @State private var actionAddress: FirewallRule?
    @State private var pendingDeleteAddress: FirewallRule?
    /// 白名单页需要独立建 APIClient（settings 接口与防火墙接口分离）
    private let server: ServerConfig

    init(server: ServerConfig) {
        self.server = server
        _vm = StateObject(wrappedValue: FirewallViewModel(server: server))
    }

    var body: some View {
        List {
            statusSection
            Section {
                Picker(L10n.t("模块"), selection: $segment) {
                    Text(L10n.t("端口规则")).tag(0)
                    Text(L10n.t("端口转发")).tag(1)
                    Text(L10n.t("IP 规则")).tag(2)
                }
                .pickerStyle(.segmented)
                .segmentedPickerRow()
                .listRowSeparator(.hidden)
            }

            switch segment {
            case 0: portRulesSection
            case 1: forwardSection
            default: addressSection
            }
        }
        .navigationTitle(L10n.t("防火墙"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            switch segment {
            case 0: await vm.loadRules()
            case 1: await vm.loadForwards()
            default: await vm.loadAddresses()
            }
        }
        .task {
            if vm.base == nil {
                vm.isLoading = true
                await vm.refresh()
                vm.isLoading = false
            }
        }
        .overlay {
            if vm.isLoading && vm.base == nil {
                LoadingStateView()
            } else if let msg = vm.errorMessage, vm.base == nil {
                ErrorBanner(message: msg) { Task { await vm.refresh() } }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showWAF = true
                } label: {
                    Image(systemName: "flame.fill")
                }
                .accessibilityLabel("WAF")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    switch segment {
                    case 0: showAdd = true
                    case 1: showAddForward = true
                    default: showAddAddress = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(vm.base?.isExist != true)
                .accessibilityLabel(segment == 1 ? L10n.t("添加端口转发") : segment == 2 ? L10n.t("添加 IP 规则") : L10n.t("添加规则"))
            }
        }
        .navigationDestination(isPresented: $showAdd) {
            FirewallAddRuleView(vm: vm)
        }
        // WAF 与防火墙同属主机安全防护，入口收进本页右上角（管理列表不单列）
        .navigationDestination(isPresented: $showWAF) {
            WAFView(server: server)
        }
        .navigationDestination(isPresented: $showWhitelist) {
            // 白名单保存成功后回调刷新本页（状态/规则/进程名都重拉）
            FirewallPortWhitelistView(server: server) {
                Task { await vm.refresh() }
            }
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
            if let rule = actionRule {
                FirewallActionSheet(kind: .port(rule)) { r in
                    actionRule = nil
                    editingRule = r
                } onDelete: { r in
                    actionRule = nil
                    pendingDeleteRule = r
                }
            }
        }
        .alert(L10n.t("删除端口规则"), isPresented: Binding(
            get: { pendingDeleteRule != nil },
            set: { if !$0 { pendingDeleteRule = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingDeleteRule = nil }
            Button(L10n.t("删除"), role: .destructive) {
                Haptic.warning()
                if let rule = pendingDeleteRule {
                    pendingDeleteRule = nil
                    Task { await vm.deleteRule(rule) }
                }
            }
        } message: {
            if let rule = pendingDeleteRule {
                Text(L10n.f("确定删除端口规则「%@」吗？删除后不可恢复。", rule.port ?? ""))
            }
        }
        // 端口转发：创建 / 编辑
        .navigationDestination(isPresented: $showAddForward) {
            FirewallForwardFormView(vm: vm, editing: nil)
        }
        .navigationDestination(isPresented: Binding(
            get: { editingForward != nil },
            set: { if !$0 { editingForward = nil } }
        )) {
            if let rule = editingForward {
                FirewallForwardFormView(vm: vm, editing: rule)
            }
        }
        .sheet(isPresented: Binding(
            get: { actionForward != nil },
            set: { if !$0 { actionForward = nil } }
        )) {
            if let rule = actionForward {
                FirewallActionSheet(kind: .forward(rule)) { r in
                    actionForward = nil
                    editingForward = r
                } onDelete: { r in
                    actionForward = nil
                    pendingDeleteForward = r
                }
            }
        }
        // 删除转发：普通删除 + 强制删除两档（对齐面板 Web 端的可勾选项）
        .alert(L10n.t("删除端口转发"), isPresented: Binding(
            get: { pendingDeleteForward != nil },
            set: { if !$0 { pendingDeleteForward = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingDeleteForward = nil }
            Button(L10n.t("删除"), role: .destructive) {
                Haptic.warning()
                if let rule = pendingDeleteForward {
                    pendingDeleteForward = nil
                    Task { await vm.deleteForward(rule, force: false) }
                }
            }
            Button(L10n.t("强制删除"), role: .destructive) {
                Haptic.warning()
                if let rule = pendingDeleteForward {
                    pendingDeleteForward = nil
                    Task { await vm.deleteForward(rule, force: true) }
                }
            }
        } message: {
            if let rule = pendingDeleteForward {
                Text(L10n.f("确定删除端口转发「%@」吗？若端口被占用可选择强制删除。", rule.port ?? ""))
            }
        }
        // IP 规则：创建 / 编辑
        .navigationDestination(isPresented: $showAddAddress) {
            FirewallAddressFormView(vm: vm, editing: nil)
        }
        .navigationDestination(isPresented: Binding(
            get: { editingAddress != nil },
            set: { if !$0 { editingAddress = nil } }
        )) {
            if let rule = editingAddress {
                FirewallAddressFormView(vm: vm, editing: rule)
            }
        }
        .sheet(isPresented: Binding(
            get: { actionAddress != nil },
            set: { if !$0 { actionAddress = nil } }
        )) {
            if let rule = actionAddress {
                FirewallActionSheet(kind: .address(rule)) { r in
                    actionAddress = nil
                    editingAddress = r
                } onDelete: { r in
                    actionAddress = nil
                    pendingDeleteAddress = r
                }
            }
        }
        .alert(L10n.t("删除 IP 规则"), isPresented: Binding(
            get: { pendingDeleteAddress != nil },
            set: { if !$0 { pendingDeleteAddress = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingDeleteAddress = nil }
            Button(L10n.t("删除"), role: .destructive) {
                Haptic.warning()
                if let rule = pendingDeleteAddress {
                    pendingDeleteAddress = nil
                    Task { await vm.deleteAddressRule(rule) }
                }
            }
        } message: {
            if let rule = pendingDeleteAddress {
                Text(L10n.f("将对 \"%@\" 进行删除操作，是否继续？", rule.address ?? ""))
            }
        }
        .alert(
            pendingUFWOp.map { opTitle($0) } ?? "",
            isPresented: Binding(
                get: { pendingUFWOp != nil },
                set: { if !$0 { pendingUFWOp = nil } }
            )
        ) {
            Button(L10n.t("立即重启 Docker")) {
                let op = pendingUFWOp; pendingUFWOp = nil
                if let op { Task { await vm.operateUFW(op, withDockerRestart: true) } }
            }
            Button(L10n.t("稍后手动重启")) {
                let op = pendingUFWOp; pendingUFWOp = nil
                if let op { Task { await vm.operateUFW(op, withDockerRestart: false) } }
            }
            Button(L10n.t("取消"), role: .cancel) { pendingUFWOp = nil }
        } message: {
            Text(L10n.t("启用/停用防火墙可能影响 Docker 网络连通性。是否立即重启 Docker？"))
        }
    }

    // MARK: - 段内容

    /// 段 0：端口规则（原有逻辑）
    @ViewBuilder
    private var portRulesSection: some View {
        if vm.rules.isEmpty {
            if vm.isLoading {
                EmptyView()
            } else {
                Section {
                    ContentUnavailableView(
                        L10n.t("暂无端口规则"),
                        systemImage: "list.bullet.rectangle",
                        description: Text(L10n.t("点击右上角 + 添加规则"))
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
                        FirewallRuleRow(
                            rule: rule,
                            processName: vm.portProcessNames[rule.port ?? ""]
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                SectionLabel(title: L10n.f("端口规则（%ld）", vm.rules.count), systemImage: "list.bullet.rectangle")
            }
        }
    }

    /// 段 1：端口转发
    @ViewBuilder
    private var forwardSection: some View {
        if vm.forwards.isEmpty {
            if vm.isLoading {
                EmptyView()
            } else {
                Section {
                    ContentUnavailableView(
                        L10n.t("暂无端口转发"),
                        systemImage: "arrow.uturn.right",
                        description: Text(L10n.t("点击右上角 + 添加规则"))
                    )
                    .listRowBackground(Color.clear)
                }
            }
        } else {
            Section {
                ForEach(vm.forwards) { rule in
                    Button {
                        actionForward = rule
                    } label: {
                        FirewallForwardRow(rule: rule)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                SectionLabel(title: L10n.f("端口转发（%ld）", vm.forwards.count), systemImage: "arrow.uturn.right")
            }
        }
    }

    /// 段 2：IP 规则
    @ViewBuilder
    private var addressSection: some View {
        if vm.addresses.isEmpty {
            if vm.isLoading {
                EmptyView()
            } else {
                Section {
                    ContentUnavailableView(
                        L10n.t("暂无 IP 规则"),
                        systemImage: "person.crop.circle.badge.xmark",
                        description: Text(L10n.t("点击右上角 + 添加规则"))
                    )
                    .listRowBackground(Color.clear)
                }
            }
        } else {
            Section {
                ForEach(vm.addresses) { rule in
                    Button {
                        actionAddress = rule
                    } label: {
                        FirewallAddressRow(rule: rule)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                SectionLabel(title: L10n.f("IP 规则（%ld）", vm.addresses.count), systemImage: "person.crop.circle.badge.xmark")
            }
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
                                    text: (base.isActive ?? false) ? L10n.t("运行中") : L10n.t("已停止"),
                                    color: (base.isActive ?? false) ? .statusRunning : .statusStopped
                                )
                            }
                        }
                        Spacer()
                        Button {
                            withAnimation(Motion.standard) {
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

                    // 展开后显示：关闭/开启 + 重启 + 端口白名单
                    if statusExpanded {
                        HStack(spacing: 8) {
                            firewallActionButton(
                                title: (base.isActive ?? false) ? L10n.t("关闭") : L10n.t("开启"),
                                icon: (base.isActive ?? false) ? "stop.fill" : "play.fill",
                                color: (base.isActive ?? false) ? .red : .green
                            ) {
                                pendingUFWOp = (base.isActive ?? false) ? "stop" : "start"
                            }
                            firewallActionButton(
                                title: L10n.t("重启"),
                                icon: "arrow.triangle.2.circlepath",
                                color: .orange
                            ) {
                                pendingUFWOp = "restart"
                            }
                            firewallActionButton(
                                title: L10n.t("端口白名单"),
                                icon: "checkmark.shield",
                                color: .blue
                            ) {
                                showWhitelist = true
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
                        Label(L10n.t("禁 ping"), systemImage: "antenna.radiowaves.left.and.right.slash")
                    }
                    .disabled(vm.isOperating || (base.isActive != true))
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.shield")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)
                        Text(L10n.t("未检测到防火墙"))
                            .font(.headline)
                        Text(L10n.t("请在服务器上安装 ufw / firewalld 后使用。"))
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
        case "start":   return L10n.t("启动防火墙")
        case "stop":    return L10n.t("停用防火墙")
        case "restart": return L10n.t("重启防火墙")
        default:        return L10n.t("操作防火墙")
        }
    }

    private func firewallActionButton(
        title: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        CardActionButton(title: title, icon: icon, color: color, disabled: vm.isOperating, action: action)
    }
}

// MARK: - 行操作弹窗

/// 防火墙行操作弹窗（半屏）：对齐服务器页 ServerActionsSheet 的分组表单形态
/// （信息头 + 修改 + 删除独立分组、图标行），比 ActionBottomSheet 紧凑条
/// 更大气，端口规则/端口转发/IP 规则三段共用
struct FirewallActionSheet: View {
    enum Kind: Equatable {
        case port(FirewallRule)
        case forward(FirewallRule)
        case address(FirewallRule)
    }

    let kind: Kind
    var onEdit: (FirewallRule) -> Void
    var onDelete: (FirewallRule) -> Void

    private var rule: FirewallRule {
        switch kind {
        case .port(let r), .forward(let r), .address(let r): return r
        }
    }

    /// 信息头副行：按段汇总规则要点
    private var subtitle: String {
        switch kind {
        case .port(let r):
            var parts: [String] = []
            if let proto = r.protocolField, !proto.isEmpty { parts.append(proto.uppercased()) }
            if let addr = r.address, !addr.isEmpty, addr != "Anywhere" {
                parts.append(L10n.f("来源：%@", addr))
            }
            if let desc = r.description, !desc.isEmpty { parts.append(desc) }
            return parts.joined(separator: " · ")
        case .forward(let r):
            var parts: [String] = []
            let ip = r.targetIP ?? ""
            let port = r.targetPort ?? ""
            parts.append("→ " + (ip.isEmpty ? port : "\(ip):\(port)"))
            if let proto = r.protocolField, !proto.isEmpty { parts.append(proto.uppercased()) }
            if let i = r.interface, !i.isEmpty, i != "*" {
                parts.append(L10n.f("网卡：%@", i))
            }
            return parts.joined(separator: " · ")
        case .address(let r):
            var parts: [String] = []
            switch r.strategy?.lowercased() {
            case "accept": parts.append(L10n.t("放行"))
            case "drop": parts.append(L10n.t("屏蔽"))
            default: break
            }
            if let desc = r.description, !desc.isEmpty { parts.append(desc) }
            return parts.joined(separator: " · ")
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kind == .address(rule) ? (rule.address ?? "-") : (rule.port ?? "-"))
                            .font(.system(.headline, design: .monospaced))
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Section {
                    actionRow(title: L10n.t("修改"), icon: "pencil", color: .blue) {
                        onEdit(rule)
                    }
                }
                Section {
                    actionRow(title: L10n.t("删除"), icon: "trash", color: .red) {
                        onDelete(rule)
                    }
                }
            }
            .navigationTitle(L10n.t("操作"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .bottomSheetDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func actionRow(
        title: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                    .frame(width: 28)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - 规则行

struct FirewallRuleRow: View {
    let rule: FirewallRule
    /// 监听进程名（process/listening 补全；nil=无数据回落 usedStatus）
    var processName: String? = nil

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
                Text(L10n.f("来源：%@", addr))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let desc = rule.description, !desc.isEmpty {
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
            // 进程名：listening 全量数据优先；无数据时回落面板返回的 usedStatus
            if let name = processName, !name.isEmpty {
                Text(name)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else if let used = rule.usedStatus, !used.isEmpty {
                StatusBadge(text: used, color: .green, icon: "checkmark.circle.fill")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func strategyBadge(_ s: String?) -> some View {
        switch s?.lowercased() {
        case "accept", L10n.t("允许"):
            StatusBadge(text: L10n.t("允许"), color: .green, icon: "checkmark")
        case "drop", L10n.t("拒绝"):
            StatusBadge(text: L10n.t("拒绝"), color: .red, icon: "xmark")
        default:
            if let s { StatusBadge(text: s, color: .secondary) }
        }
    }
}

// MARK: - 端口转发规则行

/// 转发行：源端口 → 目标（IP:端口），协议徽章 + 入站网口说明
struct FirewallForwardRow: View {
    let rule: FirewallRule

    /// 目标展示："IP:端口" 或仅端口（目标 IP 为空时）
    private var targetText: String {
        let ip = rule.targetIP ?? ""
        let port = rule.targetPort ?? ""
        return ip.isEmpty ? port : "\(ip):\(port)"
    }

    /// 入站网口展示："*"/"" → 所有
    private var interfaceText: String? {
        guard let i = rule.interface, !i.isEmpty, i != "*" else { return nil }
        return i
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(rule.port ?? "-")
                    .font(.system(.body, design: .monospaced).bold())
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(targetText)
                    .font(.system(.body, design: .monospaced))
                if let proto = rule.protocolField, !proto.isEmpty {
                    StatusBadge(text: proto.uppercased(), color: .blue)
                }
                Spacer()
            }
            if let iface = interfaceText {
                Text(L10n.f("网卡：%@", iface))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let desc = rule.description, !desc.isEmpty {
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - IP 规则行

/// IP 规则行：地址 + 放行/屏蔽徽章 + 描述
struct FirewallAddressRow: View {
    let rule: FirewallRule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(rule.address ?? "-")
                    .font(.system(.body, design: .monospaced).bold())
                Spacer()
                switch rule.strategy?.lowercased() {
                case "accept":
                    StatusBadge(text: L10n.t("放行"), color: .green, icon: "checkmark")
                case "drop":
                    StatusBadge(text: L10n.t("屏蔽"), color: .red, icon: "xmark")
                default:
                    EmptyView()
                }
            }
            if let desc = rule.description, !desc.isEmpty {
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 端口白名单

/// 端口白名单原始值拆成一行一个端口：同一面板存在两种格式——
/// 逗号分隔（"80/tcp,443/tcp,443/udp"，Web 端初始形态）与换行分隔
/// （"8080\n22\n80\n443"，update 提交后的回显形态），统一兼容并过滤空段。
nonisolated func parseFirewallPortWhitelist(_ raw: String?) -> [String] {
    // 注意不能用 ",\r\n，、".contains($0)：Swift 字面量里 "\r\n" 是单个合成字符，
    // 单独的 "\n" 会匹配失败（换行格式拆不开）
    (raw ?? "")
        .split(whereSeparator: { [",", "\n", "\r", "，", "、"].contains($0) })
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

/// 端口白名单（面板设置项 FirewallPortWhiteList）：一行一个端口（如 17331 或 80/tcp）。
/// 对齐面板 Web 端交互：行内的添加/编辑/删除只改本地列表不发请求，
/// 右上角「确认」才一次性 settings/update 提交（value 为换行拼接），
/// 成功后返回防火墙页并回调刷新。
struct FirewallPortWhitelistView: View {
    let server: ServerConfig
    /// 提交成功回调（调用方刷新防火墙页）
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var entries: [String] = []
    @State private var originalEntries: [String] = []
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    /// 正在编辑的行：nil=无；-1=新增行；其余=对应 entries 下标
    @State private var editingIndex: Int?
    @State private var editingText = ""
    @State private var rowError: String?

    private let client: APIClient

    init(server: ServerConfig, onSaved: @escaping () -> Void) {
        self.server = server
        self.onSaved = onSaved
        self.client = APIClient(server: server)
    }

    private var hasChanges: Bool { entries != originalEntries }

    var body: some View {
        List {
            if isLoading {
                Section { LoadingStateView(compact: true).padding(.vertical, 24) }
            } else if let errorMessage, entries.isEmpty && originalEntries.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button(L10n.t("重试")) { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                Section {
                    // 新增行：编辑态置顶
                    if editingIndex == -1 {
                        editRow(isNew: true)
                    }
                    ForEach(entries.indices, id: \.self) { i in
                        if editingIndex == i {
                            editRow(isNew: false)
                        } else {
                            displayRow(index: i)
                        }
                    }
                    if entries.isEmpty && editingIndex != -1 {
                        Text(L10n.t("无数据"))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    SectionLabel(
                        title: L10n.f("端口（%ld）", entries.count),
                        systemImage: "checkmark.shield"
                    )
                } footer: {
                    Text(L10n.t("一行一个端口，支持 17331 或 80/tcp 格式；修改后点右上角「确认」提交。"))
                }
            }
        }
        .navigationTitle(L10n.t("端口白名单"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text(L10n.t("确认"))
                    }
                }
                .disabled(!hasChanges || isSubmitting || isLoading || editingIndex != nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    beginAdd()
                } label: {
                    Image(systemName: "plus")
                }
                // 加载失败时禁用：错误分支不渲染列表，新增行会无处显示
                .disabled(isLoading || editingIndex != nil || errorMessage != nil)
                .accessibilityLabel(L10n.t("添加端口"))
            }
        }
        .toastOverlay(message: $rowError, systemImage: "exclamationmark.triangle.fill", iconColor: .orange)
        .task { await load() }
    }

    // MARK: 行

    /// 展示态：端口 + 编辑/删除
    private func displayRow(index: Int) -> some View {
        HStack {
            Text(entries[index])
                .font(.system(.body, design: .monospaced))
            Spacer()
            HStack(spacing: 18) {
                Button(L10n.t("编辑")) { beginEdit(index: index) }
                    // List 行内多按钮必须 borderless：默认样式会整行联动触发，
                    // 点删除同时触发编辑，编辑索引悬空后「确认」被永久禁用
                    .buttonStyle(.borderless)
                Button(L10n.t("删除")) { removeRow(at: index) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            }
            .font(.subheadline)
        }
        .padding(.vertical, 2)
    }

    /// 删除本地行：同步维护编辑索引（删正在编辑的行→取消编辑，其后行索引前移）
    private func removeRow(at index: Int) {
        if editingIndex == index {
            cancelEditing()
        } else if let e = editingIndex, e > index {
            editingIndex = e - 1
        }
        withAnimation(Motion.fast) { entries.remove(atOffsets: IndexSet(integer: index)) }
    }

    /// 编辑态：输入框 + 保存/取消（不发请求，仅改本地 entries）
    private func editRow(isNew: Bool) -> some View {
        HStack(spacing: 10) {
            TextField(L10n.t("端口"), text: $editingText)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                .submitLabel(.done)
                .onSubmit { commitEditing() }
            Button(L10n.t("保存")) { commitEditing() }
                .buttonStyle(.borderless)
                .disabled(editingText.trimmingCharacters(in: .whitespaces).isEmpty)
            Button(L10n.t("取消")) { cancelEditing() }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    // MARK: 编辑状态机

    private func beginAdd() {
        editingText = ""
        editingIndex = -1
    }

    private func beginEdit(index: Int) {
        editingText = entries[index]
        editingIndex = index
    }

    private func cancelEditing() {
        editingIndex = nil
        editingText = ""
    }

    private func commitEditing() {
        let value = editingText.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else {
            rowError = L10n.t("端口不能为空")
            return
        }
        // 重复校验：新增查全部；编辑排除自身行
        let duplicates = editingIndex == -1
            ? entries.contains(value)
            : entries.enumerated().contains { $0.offset != editingIndex && $0.element == value }
        guard !duplicates else {
            rowError = L10n.t("该端口已存在")
            return
        }
        withAnimation(Motion.fast) {
            if editingIndex == -1 {
                entries.append(value)
            } else if let i = editingIndex, entries.indices.contains(i) {
                entries[i] = value
            }
        }
        editingIndex = nil
        editingText = ""
    }

    // MARK: 数据

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        struct WhitelistSettings: Decodable {
            let firewallPortWhiteList: String?
        }
        do {
            let resp: WhitelistSettings = try await client.send(
                path: APIEndpoint.settingsSearchPanel.path,
                as: WhitelistSettings.self
            )
            entries = parseFirewallPortWhitelist(resp.firewallPortWhiteList)
            originalEntries = entries
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        struct WhitelistUpdate: Encodable {
            let key: String
            let value: String
        }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.settingsUpdate.path,
                body: WhitelistUpdate(key: "FirewallPortWhiteList", value: entries.joined(separator: "\n")),
                as: EmptyResponse.self
            )
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            rowError = error.localizedDescription
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
    private let strategies = [("accept", L10n.t("允许")), ("drop", L10n.t("拒绝"))]

    private var isValid: Bool {
        !port.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField(L10n.t("端口"), text: $port)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                Text(L10n.t("单个端口如 8080，或范围如 3000-3100。"))
                    .font(.caption).foregroundStyle(.secondary)
            } header: { SectionLabel(title: L10n.t("端口"), systemImage: "number") }

            Section {
                Picker(L10n.t("协议"), selection: $proto) {
                    ForEach(protos, id: \.self) { Text($0.uppercased()).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: { SectionLabel(title: L10n.t("协议"), systemImage: "network") }

            Section {
                Picker(L10n.t("策略"), selection: $strategy) {
                    ForEach(strategies, id: \.0) { Text($1).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: { SectionLabel(title: L10n.t("策略"), systemImage: "hand.raised") }

            Section {
                TextField(L10n.t("IP / CIDR，留空=任意"), text: $address)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                Text(L10n.t("例如 192.168.1.10、10.0.0.0/24。留空表示允许所有来源。"))
                    .font(.caption).foregroundStyle(.secondary)
            } header: { SectionLabel(title: L10n.t("来源地址"), systemImage: "location") }

            Section {
                TextField(L10n.t("备注（可选）"), text: $description)
            } header: { SectionLabel(title: L10n.t("备注"), systemImage: "text.alignleft") }
        }
        .navigationTitle(L10n.t("创建端口规则"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("创建")) {
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
    private let strategies = [("accept", L10n.t("允许")), ("drop", L10n.t("拒绝"))]

    private var isValid: Bool {
        !port.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField(L10n.t("端口"), text: $port)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                Text(L10n.t("单个端口如 8080，或范围如 3000-3100。"))
                    .font(.caption).foregroundStyle(.secondary)
            } header: { SectionLabel(title: L10n.t("端口"), systemImage: "number") }

            Section {
                Picker(L10n.t("协议"), selection: $proto) {
                    ForEach(protos, id: \.self) { Text($0.uppercased()).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: { SectionLabel(title: L10n.t("协议"), systemImage: "network") }

            Section {
                Picker(L10n.t("策略"), selection: $strategy) {
                    ForEach(strategies, id: \.0) { Text($1).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: { SectionLabel(title: L10n.t("策略"), systemImage: "hand.raised") }

            Section {
                TextField(L10n.t("IP / CIDR，留空=任意"), text: $address)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                Text(L10n.t("例如 192.168.1.10、10.0.0.0/24。留空表示允许所有来源。"))
                    .font(.caption).foregroundStyle(.secondary)
            } header: { SectionLabel(title: L10n.t("来源地址"), systemImage: "location") }

            Section {
                TextField(L10n.t("备注（可选）"), text: $description)
            } header: { SectionLabel(title: L10n.t("备注"), systemImage: "text.alignleft") }
        }
        .navigationTitle(L10n.t("修改端口规则"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("保存")) {
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

// MARK: - 端口转发表单（创建 / 编辑共用）

/// 协议 tcp / udp / tcp/udp；源端口与目标端口支持范围（8080-8089）；
/// 目标 IP 可选；入站网口从 monitor/netoptions 拉取（"all" 展示「所有」、提交空串）
struct FirewallForwardFormView: View {
    @ObservedObject var vm: FirewallViewModel
    /// 编辑的原规则（nil=创建）
    var editing: FirewallRule?
    @Environment(\.dismiss) private var dismiss

    @State private var proto = "tcp"
    @State private var port = ""
    @State private var targetIP = ""
    @State private var targetPort = ""
    /// 提交值：空串 = 所有网口
    @State private var networkInterface = ""
    @State private var saving = false

    private let protos = ["tcp", "udp", "tcp/udp"]

    private var isValid: Bool {
        !port.trimmingCharacters(in: .whitespaces).isEmpty
            && !targetPort.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 网口选项：所有（空串）+ netOptions 去掉 "all" 后的具体网卡
    private var interfaceOptions: [(label: String, value: String)] {
        [(L10n.t("所有"), "")] + vm.netOptions
            .filter { $0 != "all" }
            .map { (label: $0, value: $0) }
    }

    var body: some View {
        Form {
            Section {
                Picker(L10n.t("协议"), selection: $proto) {
                    ForEach(protos, id: \.self) { Text($0.uppercased()) }
                }
                .pickerStyle(.segmented)
                .segmentedPickerRow()

                TextField(L10n.t("源端口"), text: $port)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                TextField(L10n.t("目标 IP"), text: $targetIP)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                TextField(L10n.t("目标端口"), text: $targetPort)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Picker(L10n.t("转发入站网口"), selection: $networkInterface) {
                    ForEach(interfaceOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
            } header: {
                Text(L10n.t("端口转发"))
            } footer: {
                Text(L10n.t("源端口与目标端口支持端口范围，如: 8080-8089；目标 IP 可留空。"))
            }
        }
        .navigationTitle(editing == nil ? L10n.t("添加端口转发") : L10n.t("编辑端口转发"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("保存")) {
                    Task {
                        saving = true
                        let p = port.trimmingCharacters(in: .whitespaces)
                        let ip = targetIP.trimmingCharacters(in: .whitespaces)
                        let tp = targetPort.trimmingCharacters(in: .whitespaces)
                        let ok: Bool
                        if let editing {
                            ok = await vm.updateForward(
                                old: editing, proto: proto, port: p,
                                targetIP: ip, targetPort: tp, interface: networkInterface
                            )
                        } else {
                            ok = await vm.createForward(
                                proto: proto, port: p,
                                targetIP: ip, targetPort: tp, interface: networkInterface
                            )
                        }
                        saving = false
                        if ok { dismiss() }
                    }
                }
                .disabled(!isValid || saving)
            }
        }
        .onAppear {
            if let editing {
                port = editing.port ?? ""
                proto = editing.protocolField ?? "tcp"
                targetIP = editing.targetIP ?? ""
                targetPort = editing.targetPort ?? ""
                // "*" 与空都视为所有网口
                if let i = editing.interface, !i.isEmpty, i != "*" {
                    networkInterface = i
                }
            }
        }
    }
}

// MARK: - IP 规则表单（创建 / 编辑共用）

/// 创建：指定 IP（逗号分隔多个）+ 策略（放行/屏蔽）+ 描述；
/// 编辑：指定 IP 不可更改（update/addr 不支持改地址），仅策略/描述
struct FirewallAddressFormView: View {
    @ObservedObject var vm: FirewallViewModel
    var editing: FirewallRule?
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var strategy = "accept"
    @State private var description = ""
    @State private var saving = false

    private var isValid: Bool {
        !address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField(L10n.t("指定 IP"), text: $address)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disabled(editing != nil)
                Picker(L10n.t("策略"), selection: $strategy) {
                    Text(L10n.t("放行")).tag("accept")
                    Text(L10n.t("屏蔽")).tag("drop")
                }
                .pickerStyle(.segmented)
                .segmentedPickerRow()
                TextField(L10n.t("描述"), text: $description)
            } header: {
                Text(L10n.t("IP 规则"))
            } footer: {
                if editing == nil {
                    Text(L10n.t("多个 IP 用英文逗号分隔，如: 192.168.50.100,192.168.51.100"))
                }
            }
        }
        .navigationTitle(editing == nil ? L10n.t("添加 IP 规则") : L10n.t("编辑 IP 规则"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("保存")) {
                    Task {
                        saving = true
                        let ok: Bool
                        if let editing {
                            ok = await vm.updateAddressRule(
                                old: editing,
                                strategy: strategy,
                                description: description.trimmingCharacters(in: .whitespaces)
                            )
                        } else {
                            ok = await vm.createAddressRule(
                                address: address.trimmingCharacters(in: .whitespaces),
                                strategy: strategy,
                                description: description.trimmingCharacters(in: .whitespaces)
                            )
                        }
                        saving = false
                        if ok { dismiss() }
                    }
                }
                .disabled(!isValid || saving)
            }
        }
        .onAppear {
            if let editing {
                address = editing.address ?? ""
                strategy = editing.strategy ?? "accept"
                description = editing.description ?? ""
            }
        }
    }
}
