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
        await loadBase()
        await loadRules()
        await loadListening()
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
    @State private var showWhitelist = false
    /// 白名单页需要独立建 APIClient（settings 接口与防火墙接口分离）
    private let server: ServerConfig

    init(server: ServerConfig) {
        self.server = server
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
                            L10n.t("暂无端口规则"),
                            systemImage: "flame",
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
        .navigationTitle(L10n.t("防火墙"))
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
                LoadingStateView()
            } else if let msg = vm.errorMessage, vm.base == nil {
                ErrorBanner(message: msg) { Task { await vm.refresh() } }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(vm.base?.isExist != true)
                .accessibilityLabel(L10n.t("添加规则"))
            }
        }
        .navigationDestination(isPresented: $showAdd) {
            FirewallAddRuleView(vm: vm)
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
            ActionBottomSheet(
                title: actionRule?.port ?? L10n.t("端口规则"),
                items: [
                    ActionMenuItem(title: L10n.t("修改"), icon: "pencil", color: .blue) {
                        let r = actionRule
                        editingRule = r
                    },
                    ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red, role: .destructive) {
                        pendingDeleteRule = actionRule
                    },
                ],
                onDismiss: { actionRule = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: 2))])
            .presentationDragIndicator(.visible)
        }
        .alert(L10n.t("删除端口规则"), isPresented: Binding(
            get: { pendingDeleteRule != nil },
            set: { if !$0 { pendingDeleteRule = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingDeleteRule = nil }
            Button(L10n.t("删除"), role: .destructive) {
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

// MARK: - 端口白名单

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
                Button(L10n.t("删除")) {
                    withAnimation(Motion.fast) { entries.remove(atOffsets: IndexSet(integer: index)) }
                }
                .foregroundStyle(.red)
            }
            .font(.subheadline)
        }
        .padding(.vertical, 2)
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
            // 拆成一行一个端口：分隔符兼容逗号（Web 端抓包）、换行（update 提交格式）
            // 与全角逗号/顿号，空段与首尾空白过滤
            entries = (resp.firewallPortWhiteList ?? "")
                .split(whereSeparator: { ",\r\n，、".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
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
