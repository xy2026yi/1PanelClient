//
//  WAFView.swift
//  1PanelClient
//
//  WAF 管理：状态 / 全局规则开关 / IP黑白名单 / IP组
//

import SwiftUI
import Combine

// MARK: - 数据模型

nonisolated struct WAFStatus: Decodable {
    let healthy: Bool
    let openrestyVersion: String?
    let open: Bool
}

nonisolated struct WAFConfig: Decodable {
    let waf: WAFCore?
    let ipWhite: WAFRuleItem?
    let ipBlack: WAFRuleItem?
    let urlWhite: WAFRuleItem?
    let urlBlack: WAFRuleItem?
    let uaWhite: WAFRuleItem?
    let uaBlack: WAFRuleItem?
    let xss: WAFRuleItem?
    let sql: WAFRuleItem?
    let cc: WAFCcRuleConfig?
    let attackCount: WAFCcRuleConfig?
    let notFoundCount: WAFCcRuleConfig?
    let args: WAFRuleItem?
    let cookie: WAFRuleItem?
    let header: WAFRuleItem?
    let fileExt: WAFRuleItem?
    let vuln: WAFRuleItem?
    let strict: WAFRuleItem?
    let allowSpider: WAFRuleItem?
    let defaultIpBlack: WAFRuleItem?
    let defaultUaBlack: WAFRuleItem?
    let defaultUrlBlack: WAFRuleItem?
    let unknownWebsite: WAFRuleItem?
}

nonisolated struct WAFCore: Decodable {
    let state: String?
    let mode: String?
}

nonisolated struct WAFRuleItem: Decodable {
    let state: String?
    let code: Int?
    let action: String?
    let type: String?

    var isOn: Bool { state == "on" }
}

nonisolated struct WAFGlobalStateRequest: Encodable {
    let scope: String
    let state: String
}

// MARK: IP 规则

nonisolated struct WAFRuleIPSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let type: String
}

nonisolated struct WAFRuleIPItem: Decodable, Identifiable, Hashable {
    let name: String
    let state: String
    let type: String       // ipv4 / ipArr / ipv6 / ipGroup
    let ipv4: String?
    let ipv6: String?
    let ipStart: String?
    let ipEnd: String?
    let ipGroup: String?
    let description: String?

    var id: String { name }

    var displayValue: String {
        switch type {
        case "ipv4": return ipv4 ?? ""
        case "ipArr": return "\(ipStart ?? "") - \(ipEnd ?? "")"
        case "ipv6": return ipv6 ?? ""
        case "ipGroup": return ipGroup ?? ""
        default: return ""
        }
    }

    var typeLabel: String {
        switch type {
        case "ipv4": return "IPv4"
        case "ipArr": return "IPv4范围"
        case "ipv6": return "IPv6"
        case "ipGroup": return "IP组"
        default: return type
        }
    }
}

nonisolated struct WAFRuleIPCreateRequest: Encodable {
    let name: String
    let type: String
    let ipv4: String
    let ipStart: String
    let ipEnd: String
    let ipv6: String
    let state: String
    let description: String
    let scope: String
    let ipGroup: String
}

nonisolated struct WAFRuleIPUpdateRequest: Encodable {
    let name: String
    let state: String
    let type: String
    let ipv4: String
    let ipv6: String
    let ipStart: String
    let ipEnd: String
    let ipGroup: String
    let description: String
    let scope: String
}

nonisolated struct WAFRuleIPDeleteRequest: Encodable {
    let name: String
    let scope: String
}

// MARK: IP 组

nonisolated struct WAFIPGroupSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let type: String
    let name: String
    let all: Bool
}

nonisolated struct WAFIPGroupItem: Decodable, Identifiable, Hashable {
    let name: String
    let content: String?
    let source: String?
    let remoteURL: String?

    var id: String { name }
}

nonisolated struct WAFIPGroupCreateRequest: Encodable {
    let name: String
    let content: String
    let source: String
    let remoteURL: String
}

nonisolated struct WAFIPGroupDeleteRequest: Encodable {
    let name: String
}

// MARK: - 通用规则 (URL / UA)

nonisolated struct WAFCommonRuleSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let scope: String
    let websiteID: Int
}

nonisolated struct WAFCommonRuleItem: Decodable, Identifiable, Hashable {
    let name: String
    let state: String
    let rule: String
    let type: String?
    let description: String?

    var id: String { name }
}

nonisolated struct WAFCommonRuleCreateRequest: Encodable {
    let name: String
    let state: String
    let description: String
    let scope: String
    let rule: String
    let websiteID: Int
}

nonisolated struct WAFCommonRuleUpdateRequest: Encodable {
    let name: String
    let state: String
    let rule: String
    let type: String
    let description: String
    let scope: String
    let websiteID: Int
}

nonisolated struct WAFCommonRuleDeleteRequest: Encodable {
    let name: String
    let scope: String
    let websiteID: Int
}

// MARK: - CC / 频率限制配置

nonisolated struct WAFCcRuleConfig: Decodable {
    let state: String?
    let code: Int?
    let action: String?
    let type: String?
    let duration: Int?
    let threshold: Int?
    let ipBlockTime: Int?
    let mode: String?
    let ipBlock: String?

    var isOn: Bool { state == "on" }
}

nonisolated struct WAFCcRuleSaveRequest: Encodable {
    let state: String
    let code: Int
    let action: String
    let type: String
    let res: String
    let ipBlock: String
    let ipBlockTime: Int
    let threshold: Int
    let duration: Int
    let mode: String
    let scope: String
    let applyWebsite: Bool?

    enum CodingKeys: String, CodingKey {
        case state, code, action, type, res, ipBlock, ipBlockTime, threshold, duration, mode, scope, applyWebsite
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        try c.encode(code, forKey: .code)
        try c.encode(action, forKey: .action)
        try c.encode(type, forKey: .type)
        try c.encode(res, forKey: .res)
        try c.encode(ipBlock, forKey: .ipBlock)
        try c.encode(ipBlockTime, forKey: .ipBlockTime)
        try c.encode(threshold, forKey: .threshold)
        try c.encode(duration, forKey: .duration)
        try c.encode(mode, forKey: .mode)
        try c.encode(scope, forKey: .scope)
        try c.encodeIfPresent(applyWebsite, forKey: .applyWebsite)
    }
}

nonisolated struct WAFLocationUpdateRequest: Encodable {
    let type: String
}

// MARK: - WAF ViewModel

@MainActor
final class WAFViewModel: ObservableObject {
    @Published var status: WAFStatus?
    @Published var config: WAFConfig?
    @Published var isLoading = true
    @Published var isOperating = false
    @Published var errorMessage: String?
    @Published var successMessage: String?

    private let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    func loadAll() async {
        isLoading = true
        defer { isLoading = false }
        async let s = client.send(path: APIEndpoint.wafStatus.path, method: "GET", as: WAFStatus.self)
        async let c = client.send(path: APIEndpoint.wafConfigGlobal.path, method: "GET", as: WAFConfig.self)
        do {
            let (s, c) = try await (s, c)
            status = s
            config = c
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleRule(scope: String, state: String) async {
        isOperating = true
        defer { isOperating = false }
        let req = WAFGlobalStateRequest(scope: scope, state: state)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafConfigGlobalState.path, body: req, as: EmptyResponse.self)
            successMessage = state == "on" ? "已启用" : "已禁用"
            await loadAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - WAF 主视图

struct WAFView: View {
    @StateObject private var vm: WAFViewModel
    let server: ServerConfig
    @State private var pendingAction: String?

    init(server: ServerConfig) {
        self.server = server
        _vm = StateObject(wrappedValue: WAFViewModel(server: server))
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.config == nil {
                ProgressView("加载中…")
            } else if let config = vm.config {
                content(config: config)
            } else if let err = vm.errorMessage {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button("重试") { Task { await vm.loadAll() } }
                }
            }
        }
        .navigationTitle("WAF")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.loadAll() }
        .task { await vm.loadAll() }
        .alert("提示", isPresented: Binding(
            get: { vm.successMessage != nil || vm.errorMessage != nil },
            set: { _ in vm.successMessage = nil; vm.errorMessage = nil }
        )) {
            Button("好的") { vm.successMessage = nil; vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? vm.successMessage ?? "")
        }
        .alert(
            pendingAction == "on" ? "启动" : "停止",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingAction = nil }
            Button("确认", role: .destructive) {
                let action = pendingAction
                pendingAction = nil
                if let action = action {
                    Task { await vm.toggleRule(scope: "Waf", state: action) }
                }
            }
        } message: {
            Text("将对 WAF 进行 \(pendingAction == "on" ? "启动" : "停止") 操作，是否继续？")
        }
    }

    @ViewBuilder
    private func content(config: WAFConfig) -> some View {
        List {
            // 状态
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WAF").font(.headline)
                        if let v = vm.status?.openrestyVersion {
                            Text("OpenResty \(v)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { vm.status?.open ?? false },
                        set: { newVal in
                            pendingAction = newVal ? "on" : "off"
                        }
                    ))
                    .labelsHidden()
                    .disabled(vm.isOperating)
                }
            }

            // 黑名单
            Section {
                NavigationLink {
                    WAFIPRulesView(server: server, scope: "ipBlack", title: "IP")
                } label: {
                    ruleRow(icon: "hand.raised", color: .red, title: "IP", item: config.ipBlack, scope: "IPBlack")
                }
                NavigationLink {
                    WAFCommonRulesView(server: server, scope: "urlBlack", title: "URL")
                } label: {
                    ruleRow(icon: "link.badge.plus", color: .orange, title: "URL", item: config.urlBlack, scope: "UrlBlack")
                }
                NavigationLink {
                    WAFCommonRulesView(server: server, scope: "uaBlack", title: "User-Agent")
                } label: {
                    ruleRow(icon: "person.crop.square", color: .pink, title: "User-Agent", item: config.uaBlack, scope: "UaBlack")
                }
            } header: {
                SectionLabel(title: "黑名单", systemImage: "hand.raised")
            }

            // 白名单
            Section {
                NavigationLink {
                    WAFIPRulesView(server: server, scope: "ipWhite", title: "IP")
                } label: {
                    ruleRow(icon: "checkmark.shield", color: .green, title: "IP", item: config.ipWhite, scope: "IPWhite")
                }
                NavigationLink {
                    WAFCommonRulesView(server: server, scope: "urlWhite", title: "URL")
                } label: {
                    ruleRow(icon: "link.badge.plus", color: .teal, title: "URL", item: config.urlWhite, scope: "UrlWhite")
                }
                NavigationLink {
                    WAFCommonRulesView(server: server, scope: "uaWhite", title: "User-Agent")
                } label: {
                    ruleRow(icon: "person.crop.square", color: .mint, title: "User-Agent", item: config.uaWhite, scope: "UaWhite")
                }
            } header: {
                SectionLabel(title: "白名单", systemImage: "checkmark.shield")
            }

            // IP 组
            Section {
                NavigationLink {
                    WAFIPGroupsView(server: server)
                } label: {
                    Text("IP 组")
                }
            }

            // 频率限制
            Section {
                NavigationLink {
                    WAFCcSettingsView(server: server, config: config.cc, scope: "Cc", title: "访问频率限制")
                } label: {
                    ccToggleRow(title: "访问频率限制", item: config.cc, scope: "Cc")
                }
                NavigationLink {
                    WAFAttackCountSettingsView(server: server, config: config.attackCount, scope: "AttackCount", title: "攻击频率限制")
                } label: {
                    ccToggleRow(title: "攻击频率限制", item: config.attackCount, scope: "AttackCount")
                }
                NavigationLink {
                    WAFAttackCountSettingsView(server: server, config: config.notFoundCount, scope: "NotFoundCount", title: "404 频率限制")
                } label: {
                    ccToggleRow(title: "404 频率限制", item: config.notFoundCount, scope: "NotFoundCount")
                }
            } header: {
                SectionLabel(title: "频率限制", systemImage: "gauge.with.dots.needle.67percent")
            }

            // 配置
            Section {
                NavigationLink {
                    WAFConfigItemView(server: server, title: "恶意 IP 组", scope: "DefaultIpBlack", updateType: "blackIP", item: config.defaultIpBlack)
                } label: {
                    toggleRow(title: "恶意 IP 组", item: config.defaultIpBlack, scope: "DefaultIpBlack")
                }
                NavigationLink {
                    WAFConfigItemView(server: server, title: "蜘蛛 IP 池", scope: "AllowSpider", updateType: "spiderIP", item: config.allowSpider)
                } label: {
                    toggleRow(title: "蜘蛛 IP 池", item: config.allowSpider, scope: "AllowSpider")
                }
                NavigationLink {
                    WAFLocationUpdateView(server: server)
                } label: {
                    Text("IP 地址库")
                }
            } header: {
                SectionLabel(title: "配置", systemImage: "gearshape")
            }
        }
    }

    private func ruleRow(icon: String, color: Color, title: String, item: WAFRuleItem?, scope: String) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemName: icon, color: color, size: 34, cornerRadius: 8)
            Text(title)
            Spacer()
            Toggle("", isOn: Binding(
                get: { item?.isOn ?? false },
                set: { newVal in
                    Task { await vm.toggleRule(scope: scope, state: newVal ? "on" : "off") }
                }
            ))
            .labelsHidden()
            .disabled(vm.isOperating)
        }
    }

    private func toggleRow(title: String, item: WAFRuleItem?, scope: String) -> some View {
        Toggle(isOn: Binding(
            get: { item?.isOn ?? false },
            set: { newVal in
                Task { await vm.toggleRule(scope: scope, state: newVal ? "on" : "off") }
            }
        )) {
            Text(title)
        }
        .disabled(vm.isOperating)
    }

    private func ccToggleRow(title: String, item: WAFCcRuleConfig?, scope: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle("", isOn: Binding(
                get: { item?.isOn ?? false },
                set: { newVal in
                    Task { await vm.toggleRule(scope: scope, state: newVal ? "on" : "off") }
                }
            ))
            .labelsHidden()
            .disabled(vm.isOperating)
        }
    }
}

// MARK: - IP 黑白名单视图

struct WAFIPRulesView: View {
    let server: ServerConfig
    let scope: String
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var items: [WAFRuleIPItem] = []
    @State private var isLoading = false
    @State private var showCreate = false
    @State private var successMessage: String?
    @State private var errorMessage: String?
    @State private var pendingDeleteIP: WAFRuleIPItem?
    @State private var actionItem: WAFRuleIPItem?
    @State private var editingItem: WAFRuleIPItem?

    private let client: APIClient

    init(server: ServerConfig, scope: String, title: String) {
        self.server = server
        self.scope = scope
        self.title = title
        self.client = APIClient(server: server)
    }

    var body: some View {
        List {
            if isLoading && items.isEmpty {
                ProgressView()
            } else if items.isEmpty {
                ContentUnavailableView("暂无 IP 规则", systemImage: "ipaddress")
            } else {
                ForEach(items) { item in
                    HStack {
                        Button {
                            actionItem = item
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.displayValue)
                                    .font(.system(.body, design: .monospaced))
                                HStack(spacing: 8) {
                                    StatusBadge(text: item.typeLabel, color: .blue)
                                    if let desc = item.description, !desc.isEmpty {
                                        Text(desc).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Toggle(isOn: Binding(
                            get: { item.state == "on" },
                            set: { _ in Task { await toggleState(item) } }
                        )) {}
                        .labelsHidden()
                        .tint(item.state == "on" ? .green : .gray)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottomTrailing) {
            FloatingActionButton { showCreate = true }
                .accessibilityLabel("添加规则")
        }
        .refreshable { await loadItems() }
        .task { await loadItems() }
        .navigationDestination(isPresented: $showCreate) {
            WAFIPRuleFormView(server: server, scope: scope) {
                Task { await loadItems() }
            }
        }
        .navigationDestination(item: $editingItem) { item in
            WAFIPRuleFormView(server: server, scope: scope, editingItem: item) {
                Task { await loadItems() }
            }
        }
        .sheet(isPresented: Binding(
            get: { actionItem != nil },
            set: { if !$0 { actionItem = nil } }
        )) {
            ActionBottomSheet(
                title: actionItem?.displayValue ?? "IP 规则",
                items: [
                    ActionMenuItem(title: "编辑", icon: "pencil", color: .blue) {
                        editingItem = actionItem
                    },
                    ActionMenuItem(title: "删除", icon: "trash", color: .red, role: .destructive) {
                        pendingDeleteIP = actionItem
                    },
                ],
                onDismiss: { actionItem = nil }
            )
            .presentationDetents([.height(ActionBottomSheet.height(for: 2))])
            .presentationDragIndicator(.visible)
        }
        .alert("提示", isPresented: Binding(
            get: { successMessage != nil || errorMessage != nil },
            set: { _ in successMessage = nil; errorMessage = nil }
        )) {
            Button("好的") { successMessage = nil; errorMessage = nil }
        } message: {
            Text(errorMessage ?? successMessage ?? "")
        }
        .alert(
            "删除",
            isPresented: Binding(
                get: { pendingDeleteIP != nil },
                set: { if !$0 { pendingDeleteIP = nil } }
            ),
            presenting: pendingDeleteIP
        ) { _ in
            Button("取消", role: .cancel) { pendingDeleteIP = nil }
            Button("确认", role: .destructive) {
                let item = pendingDeleteIP
                pendingDeleteIP = nil
                if let item = item {
                    Task { await deleteItem(item) }
                }
            }
        } message: { item in
            Text("将对 \"\(item.displayValue.isEmpty ? item.name : item.displayValue)\" 进行删除操作，是否继续？")
        }
    }

    private func loadItems() async {
        isLoading = true
        let req = WAFRuleIPSearchRequest(page: 1, pageSize: 100, type: scope)
        do {
            let resp: PageResponse<WAFRuleIPItem> = try await client.send(
                path: APIEndpoint.wafRuleIPSearch.path, body: req,
                as: PageResponse<WAFRuleIPItem>.self
            )
            items = resp.items ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func toggleState(_ item: WAFRuleIPItem) async {
        let newState = item.state == "on" ? "off" : "on"
        let req = WAFRuleIPUpdateRequest(
            name: item.name, state: newState, type: item.type,
            ipv4: item.ipv4 ?? "", ipv6: item.ipv6 ?? "",
            ipStart: item.ipStart ?? "", ipEnd: item.ipEnd ?? "",
            ipGroup: item.ipGroup ?? "", description: item.description ?? "", scope: scope
        )
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafRuleIPUpdate.path, body: req, as: EmptyResponse.self)
            successMessage = newState == "on" ? "已启用" : "已禁用"
            await loadItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteItem(_ item: WAFRuleIPItem) async {
        let req = WAFRuleIPDeleteRequest(name: item.name, scope: scope)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafRuleIPDelete.path, body: req, as: EmptyResponse.self)
            successMessage = "已删除"
            await loadItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - IP 规则表单（创建/编辑共用）

/// IP 规则表单：`editingItem` 为 nil 时是创建模式，非 nil 时为编辑模式（多一个启用开关）。
/// 统一以 sheet 呈现（取消 + 提交按钮，提交时显示 loading）。
struct WAFIPRuleFormView: View {
    let server: ServerConfig
    let scope: String
    /// 编辑中的规则；nil = 创建
    let editingItem: WAFRuleIPItem?
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var ipType = "ipv4"
    @State private var ipv4 = ""
    @State private var ipStart = ""
    @State private var ipEnd = ""
    @State private var ipv6 = ""
    @State private var ipGroup = ""
    @State private var description = ""
    @State private var state = "on"
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var ipGroups: [WAFIPGroupItem] = []

    private let client: APIClient

    init(server: ServerConfig, scope: String, editingItem: WAFRuleIPItem? = nil, onSaved: @escaping () -> Void) {
        self.server = server
        self.scope = scope
        self.editingItem = editingItem
        self.onSaved = onSaved
        self.client = APIClient(server: server)
        if let item = editingItem {
            _ipType = State(initialValue: item.type)
            _ipv4 = State(initialValue: item.ipv4 ?? "")
            _ipStart = State(initialValue: item.ipStart ?? "")
            _ipEnd = State(initialValue: item.ipEnd ?? "")
            _ipv6 = State(initialValue: item.ipv6 ?? "")
            _ipGroup = State(initialValue: item.ipGroup ?? "")
            _description = State(initialValue: item.description ?? "")
            _state = State(initialValue: item.state)
        }
    }

    private let typeOptions: [(value: String, label: String)] = [
        ("ipv4", "IPv4"),
        ("ipArr", "IPv4 范围"),
        ("ipv6", "IPv6"),
        ("ipGroup", "IP 组"),
    ]

    var body: some View {
        Form {
            Section("类型") {
                Picker("IP 类型", selection: $ipType) {
                    ForEach(typeOptions, id: \.value) { Text($0.label).tag($0.value) }
                }
                .onChange(of: ipType) { _, _ in
                    if ipType == "ipGroup" { Task { await loadGroups() } }
                }
            }

            switch ipType {
            case "ipv4":
                Section("IPv4 地址") {
                    TextField("例: 192.168.1.1", text: $ipv4)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                }
            case "ipArr":
                Section("IPv4 范围") {
                    TextField("起始 IP", text: $ipStart)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                    TextField("结束 IP", text: $ipEnd)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                }
            case "ipv6":
                Section("IPv6 地址") {
                    TextField("例: 2001:db8::1", text: $ipv6)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            case "ipGroup":
                Section("IP 组") {
                    if ipGroups.isEmpty {
                        Text("请先创建 IP 组").foregroundStyle(.secondary)
                    } else {
                        Picker("选择 IP 组", selection: $ipGroup) {
                            ForEach(ipGroups) { group in
                                Text(group.name).tag(group.name)
                            }
                        }
                    }
                }
            default:
                EmptyView()
            }

            if editingItem != nil {
                Section("状态") {
                    Toggle("启用", isOn: Binding(
                        get: { state == "on" },
                        set: { state = $0 ? "on" : "off" }
                    ))
                }
            }

            Section("备注") {
                TextField("描述(可选)", text: $description)
            }
        }
        .navigationTitle(editingItem == nil ? "添加 IP 规则" : "编辑 IP 规则")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text(editingItem == nil ? "创建" : "保存")
                    }
                }
                .disabled(isSaving || !isValid)
            }
        }
        .onAppear {
            if ipType == "ipGroup" { Task { await loadGroups() } }
        }
        .alert("错误", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好的") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var isValid: Bool {
        switch ipType {
        case "ipv4": return !ipv4.isEmpty
        case "ipArr": return !ipStart.isEmpty && !ipEnd.isEmpty
        case "ipv6": return !ipv6.isEmpty
        case "ipGroup": return !ipGroup.isEmpty
        default: return false
        }
    }

    private func loadGroups() async {
        let req = WAFIPGroupSearchRequest(page: 1, pageSize: 100, type: "", name: "", all: false)
        do {
            let resp: PageResponse<WAFIPGroupItem> = try await client.send(
                path: APIEndpoint.wafIPGroupSearch.path, body: req,
                as: PageResponse<WAFIPGroupItem>.self
            )
            ipGroups = resp.items ?? []
        } catch { }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            if let item = editingItem {
                let req = WAFRuleIPUpdateRequest(
                    name: item.name, state: state, type: ipType,
                    ipv4: ipv4, ipv6: ipv6, ipStart: ipStart, ipEnd: ipEnd,
                    ipGroup: ipGroup, description: description, scope: scope
                )
                let _: EmptyResponse = try await client.send(path: APIEndpoint.wafRuleIPUpdate.path, body: req, as: EmptyResponse.self)
            } else {
                let req = WAFRuleIPCreateRequest(
                    name: "", type: ipType, ipv4: ipv4, ipStart: ipStart, ipEnd: ipEnd,
                    ipv6: ipv6, state: "on", description: description, scope: scope, ipGroup: ipGroup
                )
                let _: EmptyResponse = try await client.send(path: APIEndpoint.wafRuleIPCreate.path, body: req, as: EmptyResponse.self)
            }
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}


// MARK: - IP 组管理视图

struct WAFIPGroupsView: View {
    let server: ServerConfig

    @Environment(\.dismiss) private var dismiss
    @State private var items: [WAFIPGroupItem] = []
    @State private var isLoading = false
    @State private var showCreate = false
    @State private var editingGroup: WAFIPGroupItem?
    @State private var successMessage: String?
    @State private var errorMessage: String?
    @State private var pendingDeleteGroup: WAFIPGroupItem?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient(server: server)
    }

    var body: some View {
        List {
            if isLoading && items.isEmpty {
                ProgressView()
            } else if items.isEmpty {
                ContentUnavailableView("暂无 IP 组", systemImage: "rectangle.on.rectangle.angled")
            } else {
                ForEach(items) { item in
                    Button {
                        editingGroup = item
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).font(.body)
                                if let content = item.content, !content.isEmpty {
                                    Text(content.replacingOccurrences(of: "\n", with: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                if let source = item.source, !source.isEmpty {
                                    StatusBadge(text: source == "imported" ? "手动" : "远程", color: .blue)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            pendingDeleteGroup = item
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("IP 组")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottomTrailing) {
            FloatingActionButton { showCreate = true }
                .accessibilityLabel("创建 IP 组")
        }
        .refreshable { await loadItems() }
        .task { await loadItems() }
        .navigationDestination(isPresented: $showCreate) {
            WAFCreateIPGroupView(server: server) {
                Task { await loadItems() }
            }
        }
        .navigationDestination(item: $editingGroup) { item in
            WAFIPGroupEditView(server: server, item: item) {
                Task { await loadItems() }
            }
        }
        .alert("提示", isPresented: Binding(
            get: { successMessage != nil || errorMessage != nil },
            set: { _ in successMessage = nil; errorMessage = nil }
        )) {
            Button("好的") { successMessage = nil; errorMessage = nil }
        } message: {
            Text(errorMessage ?? successMessage ?? "")
        }
        .alert(
            "删除",
            isPresented: Binding(
                get: { pendingDeleteGroup != nil },
                set: { if !$0 { pendingDeleteGroup = nil } }
            ),
            presenting: pendingDeleteGroup
        ) { _ in
            Button("取消", role: .cancel) { pendingDeleteGroup = nil }
            Button("确认", role: .destructive) {
                let item = pendingDeleteGroup
                pendingDeleteGroup = nil
                if let item = item {
                    Task { await deleteItem(item) }
                }
            }
        } message: { item in
            Text("将对 \"\(item.name)\" 进行删除操作，是否继续？")
        }
    }

    private func loadItems() async {
        isLoading = true
        let req = WAFIPGroupSearchRequest(page: 1, pageSize: 100, type: "", name: "", all: false)
        do {
            let resp: PageResponse<WAFIPGroupItem> = try await client.send(
                path: APIEndpoint.wafIPGroupSearch.path, body: req,
                as: PageResponse<WAFIPGroupItem>.self
            )
            items = resp.items ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func deleteItem(_ item: WAFIPGroupItem) async {
        let req = WAFIPGroupDeleteRequest(name: item.name)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafIPGroupDelete.path, body: req, as: EmptyResponse.self)
            successMessage = "已删除"
            await loadItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 创建 IP 组

struct WAFCreateIPGroupView: View {
    let server: ServerConfig
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var source = "imported"
    @State private var content = ""
    @State private var remoteURL = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig, onCreated: @escaping () -> Void) {
        self.server = server
        self.onCreated = onCreated
        self.client = APIClient(server: server)
    }

    var body: some View {
        Form {
            Section("名称") {
                TextField("组名称", text: $name)
            }
            Section("导入方式") {
                Picker("方式", selection: $source) {
                    Text("手动创建").tag("imported")
                    Text("远程下载").tag("remoteFile")
                }
            }
            if source == "imported" {
                Section("IP 列表") {
                    TextEditor(text: $content)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 120)
                }
            } else {
                Section("URL") {
                    TextField("https://...", text: $remoteURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
        }
        .navigationTitle("创建 IP 组")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("创建") {
                    Task { await create() }
                }
                .disabled(isSaving || name.isEmpty)
            }
        }
        .alert("错误", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好的") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func create() async {
        isSaving = true
        let req = WAFIPGroupCreateRequest(name: name, content: content, source: source, remoteURL: remoteURL)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafIPGroupCreate.path, body: req, as: EmptyResponse.self)
            onCreated()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

// MARK: - 编辑 IP 组

struct WAFIPGroupEditView: View {
    let server: ServerConfig
    let item: WAFIPGroupItem
    let onUpdated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var isSaving = false
    @State private var successMessage: String?
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig, item: WAFIPGroupItem, onUpdated: @escaping () -> Void) {
        self.server = server
        self.item = item
        self.onUpdated = onUpdated
        self.client = APIClient(server: server)
    }

    var body: some View {
        Form {
            Section("名称") {
                Text(item.name).foregroundStyle(.secondary)
            }
            if item.source == "remoteFile" {
                Section("远程 URL") {
                    Text(item.remoteURL ?? "—").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("IP 列表") {
                TextEditor(text: $content)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 200)
            }
        }
        .navigationTitle("编辑 IP 组")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { content = item.content ?? "" }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("保存")
                    }
                }
                .disabled(isSaving)
            }
        }
        .alert("提示", isPresented: Binding(
            get: { successMessage != nil || errorMessage != nil },
            set: { _ in successMessage = nil; errorMessage = nil }
        )) {
            Button("好的") { successMessage = nil; errorMessage = nil }
        } message: {
            Text(successMessage ?? errorMessage ?? "")
        }
    }

    private func save() async {
        isSaving = true
        let req = WAFIPGroupCreateRequest(
            name: item.name, content: content,
            source: item.source ?? "imported", remoteURL: item.remoteURL ?? ""
        )
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafIPGroupUpdate.path, body: req, as: EmptyResponse.self)
            successMessage = "已保存"
            onUpdated()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

// MARK: - URL / User-Agent 通用规则视图

struct WAFCommonRulesView: View {
    let server: ServerConfig
    let scope: String
    let title: String

    @State private var items: [WAFCommonRuleItem] = []
    @State private var isLoading = false
    @State private var showCreate = false
    @State private var editingItem: WAFCommonRuleItem?
    @State private var successMessage: String?
    @State private var errorMessage: String?
    @State private var pendingDeleteRule: WAFCommonRuleItem?
    @State private var actionItem: WAFCommonRuleItem?

    private let client: APIClient

    init(server: ServerConfig, scope: String, title: String) {
        self.server = server
        self.scope = scope
        self.title = title
        self.client = APIClient(server: server)
    }

    var body: some View {
        List {
            if isLoading && items.isEmpty {
                ProgressView()
            } else if items.isEmpty {
                ContentUnavailableView("暂无通用规则", systemImage: "list.bullet.rectangle.shield")
            } else {
                ForEach(items) { item in
                    HStack {
                        Button {
                            actionItem = item
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.rule)
                                    .font(.system(.body, design: .monospaced))
                                if let desc = item.description, !desc.isEmpty {
                                    Text(desc).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Toggle(isOn: Binding(
                            get: { item.state == "on" },
                            set: { _ in Task { await toggleState(item) } }
                        )) {}
                        .labelsHidden()
                        .tint(item.state == "on" ? .green : .gray)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottomTrailing) {
            FloatingActionButton { showCreate = true }
                .accessibilityLabel("添加规则")
        }
        .refreshable { await loadItems() }
        .task { await loadItems() }
        .navigationDestination(isPresented: $showCreate) {
            WAFCommonRuleFormView(server: server, scope: scope) {
                Task { await loadItems() }
            }
        }
        .navigationDestination(item: $editingItem) { item in
            WAFCommonRuleFormView(server: server, scope: scope, editingItem: item) {
                Task { await loadItems() }
            }
        }
        .sheet(isPresented: Binding(
            get: { actionItem != nil },
            set: { if !$0 { actionItem = nil } }
        )) {
            ActionBottomSheet(
                title: actionItem?.rule ?? "规则",
                items: [
                    ActionMenuItem(title: "编辑", icon: "pencil", color: .blue) {
                        editingItem = actionItem
                    },
                    ActionMenuItem(title: "删除", icon: "trash", color: .red, role: .destructive) {
                        pendingDeleteRule = actionItem
                    },
                ],
                onDismiss: { actionItem = nil }
            )
            .presentationDetents([.height(ActionBottomSheet.height(for: 2))])
            .presentationDragIndicator(.visible)
        }
        .alert("提示", isPresented: Binding(
            get: { successMessage != nil || errorMessage != nil },
            set: { _ in successMessage = nil; errorMessage = nil }
        )) {
            Button("好的") { successMessage = nil; errorMessage = nil }
        } message: {
            Text(errorMessage ?? successMessage ?? "")
        }
        .alert(
            "删除",
            isPresented: Binding(
                get: { pendingDeleteRule != nil },
                set: { if !$0 { pendingDeleteRule = nil } }
            ),
            presenting: pendingDeleteRule
        ) { _ in
            Button("取消", role: .cancel) { pendingDeleteRule = nil }
            Button("确认", role: .destructive) {
                let item = pendingDeleteRule
                pendingDeleteRule = nil
                if let item = item {
                    Task { await deleteItem(item) }
                }
            }
        } message: { item in
            Text("将对 \"\(item.name)\" 进行删除操作，是否继续？")
        }
    }

    private func loadItems() async {
        isLoading = true
        let req = WAFCommonRuleSearchRequest(page: 1, pageSize: 100, scope: scope, websiteID: 0)
        do {
            let resp: PageResponse<WAFCommonRuleItem> = try await client.send(
                path: APIEndpoint.wafRuleCommonSearch.path, body: req,
                as: PageResponse<WAFCommonRuleItem>.self
            )
            items = resp.items ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func toggleState(_ item: WAFCommonRuleItem) async {
        let newState = item.state == "on" ? "off" : "on"
        let req = WAFCommonRuleUpdateRequest(
            name: item.name, state: newState, rule: item.rule,
            type: item.type ?? "", description: item.description ?? "",
            scope: scope, websiteID: 0
        )
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafRuleCommonUpdate.path, body: req, as: EmptyResponse.self)
            successMessage = newState == "on" ? "已启用" : "已禁用"
            await loadItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteItem(_ item: WAFCommonRuleItem) async {
        let req = WAFCommonRuleDeleteRequest(name: item.name, scope: scope, websiteID: 0)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafRuleCommonDelete.path, body: req, as: EmptyResponse.self)
            successMessage = "已删除"
            await loadItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 通用规则表单（创建/编辑共用）

/// 通用规则表单：`editingItem` 为 nil 时是创建模式，非 nil 时为编辑模式。
/// 以页面推入呈现（右上角提交按钮，提交时显示 loading，返回即取消）。
struct WAFCommonRuleFormView: View {
    let server: ServerConfig
    let scope: String
    /// 编辑中的规则；nil = 创建
    let editingItem: WAFCommonRuleItem?
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rule = ""
    @State private var description = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig, scope: String, editingItem: WAFCommonRuleItem? = nil, onSaved: @escaping () -> Void) {
        self.server = server
        self.scope = scope
        self.editingItem = editingItem
        self.onSaved = onSaved
        self.client = APIClient(server: server)
        if let item = editingItem {
            _rule = State(initialValue: item.rule)
            _description = State(initialValue: item.description ?? "")
        }
    }

    var body: some View {
        Form {
            Section("规则内容") {
                TextField("输入规则", text: $rule)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            Section("备注") {
                TextField("描述(可选)", text: $description)
            }
        }
        .navigationTitle(editingItem == nil ? "添加规则" : "编辑规则")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text(editingItem == nil ? "创建" : "保存")
                    }
                }
                .disabled(isSaving || rule.isEmpty)
            }
        }
        .alert("错误", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好的") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            if let item = editingItem {
                let req = WAFCommonRuleUpdateRequest(
                    name: item.name, state: item.state, rule: rule,
                    type: item.type ?? "", description: description,
                    scope: scope, websiteID: 0
                )
                let _: EmptyResponse = try await client.send(path: APIEndpoint.wafRuleCommonUpdate.path, body: req, as: EmptyResponse.self)
            } else {
                let req = WAFCommonRuleCreateRequest(
                    name: "", state: "on", description: description,
                    scope: scope, rule: rule, websiteID: 0
                )
                let _: EmptyResponse = try await client.send(path: APIEndpoint.wafRuleCommonCreate.path, body: req, as: EmptyResponse.self)
            }
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}


// MARK: - CC 访问频率限制设置

struct WAFCcSettingsView: View {
    let server: ServerConfig
    let config: WAFCcRuleConfig?
    let scope: String
    let title: String

    @State private var mode = "global"
    @State private var duration = "10"
    @State private var threshold = "100"
    @State private var ipBlockTime = "600"
    @State private var isSaving = false
    @State private var successMessage: String?
    @State private var errorMessage: String?
    @State private var showMenu = false

    private let client: APIClient

    init(server: ServerConfig, config: WAFCcRuleConfig?, scope: String, title: String) {
        self.server = server
        self.config = config
        self.scope = scope
        self.title = title
        self.client = APIClient(server: server)
    }

    var body: some View {
        Form {
            Section("模式") {
                Picker("模式", selection: $mode) {
                    Text("URL 模式").tag("uri")
                    Text("全局模式").tag("global")
                }
            }
            Section("参数") {
                HStack {
                    Text("周期")
                    Spacer()
                    TextField("", text: $duration)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text("秒").foregroundStyle(.secondary)
                }
                HStack {
                    Text("频率")
                    Spacer()
                    TextField("", text: $threshold)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text("次").foregroundStyle(.secondary)
                }
                HStack {
                    Text("封禁时间")
                    Spacer()
                    TextField("", text: $ipBlockTime)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text("秒").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadConfig() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EllipsisMenuButton {
                    withAnimation(.easeOut(duration: 0.18)) { showMenu.toggle() }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if showMenu {
                EllipsisMenuPopup(entries: [
                    .action(title: "保存默认") { Task { await save(applyWebsite: nil) } },
                    .action(title: "应用到网站") { Task { await save(applyWebsite: true) } },
                ]) {
                    withAnimation(.easeIn(duration: 0.12)) { showMenu = false }
                }
            }
        }
        .alert("提示", isPresented: Binding(
            get: { successMessage != nil || errorMessage != nil },
            set: { _ in successMessage = nil; errorMessage = nil }
        )) {
            Button("好的") { successMessage = nil; errorMessage = nil }
        } message: {
            Text(errorMessage ?? successMessage ?? "")
        }
    }

    private func loadConfig() {
        guard let c = config else { return }
        mode = c.mode ?? "global"
        duration = String(c.duration ?? 10)
        threshold = String(c.threshold ?? 100)
        ipBlockTime = String(c.ipBlockTime ?? 600)
    }

    private func save(applyWebsite: Bool?) async {
        isSaving = true
        let req = WAFCcRuleSaveRequest(
            state: config?.state ?? "off",
            code: config?.code ?? 0,
            action: config?.action ?? "deny",
            type: "cc",
            res: "",
            ipBlock: config?.ipBlock ?? "on",
            ipBlockTime: Int(ipBlockTime) ?? 600,
            threshold: Int(threshold) ?? 100,
            duration: Int(duration) ?? 10,
            mode: mode,
            scope: scope,
            applyWebsite: applyWebsite
        )
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafRuleCc.path, body: req, as: EmptyResponse.self)
            successMessage = applyWebsite == true ? "已应用到网站" : "已保存"
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

// MARK: - 攻击频率 / 404 频率限制设置

struct WAFAttackCountSettingsView: View {
    let server: ServerConfig
    let config: WAFCcRuleConfig?
    let scope: String
    let title: String

    @State private var duration = "60"
    @State private var threshold = "10"
    @State private var ipBlockTime = "3000"
    @State private var isSaving = false
    @State private var successMessage: String?
    @State private var errorMessage: String?

    private let client: APIClient
    private var ruleType: String { scope == "NotFoundCount" ? "notFoundCount" : "attackCount" }
    private var defaultCode: Int { scope == "NotFoundCount" ? 403 : 0 }

    init(server: ServerConfig, config: WAFCcRuleConfig?, scope: String, title: String) {
        self.server = server
        self.config = config
        self.scope = scope
        self.title = title
        self.client = APIClient(server: server)
    }

    var body: some View {
        Form {
            Section("参数") {
                HStack {
                    Text("周期")
                    Spacer()
                    TextField("", text: $duration)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text("秒").foregroundStyle(.secondary)
                }
                HStack {
                    Text("频率")
                    Spacer()
                    TextField("", text: $threshold)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text("次").foregroundStyle(.secondary)
                }
                HStack {
                    Text("封禁时间")
                    Spacer()
                    TextField("", text: $ipBlockTime)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text("秒").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadConfig() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { Task { await save() } }
                    .disabled(isSaving)
            }
        }
        .alert("提示", isPresented: Binding(
            get: { successMessage != nil || errorMessage != nil },
            set: { _ in successMessage = nil; errorMessage = nil }
        )) {
            Button("好的") { successMessage = nil; errorMessage = nil }
        } message: {
            Text(errorMessage ?? successMessage ?? "")
        }
    }

    private func loadConfig() {
        guard let c = config else { return }
        duration = String(c.duration ?? 60)
        threshold = String(c.threshold ?? 10)
        ipBlockTime = String(c.ipBlockTime ?? 3000)
    }

    private func save() async {
        isSaving = true
        let req = WAFCcRuleSaveRequest(
            state: config?.state ?? "off",
            code: config?.code ?? defaultCode,
            action: config?.action ?? "deny",
            type: ruleType,
            res: "",
            ipBlock: config?.ipBlock ?? "on",
            ipBlockTime: Int(ipBlockTime) ?? 3000,
            threshold: Int(threshold) ?? 10,
            duration: Int(duration) ?? 60,
            mode: "",
            scope: scope,
            applyWebsite: nil
        )
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafRuleCc.path, body: req, as: EmptyResponse.self)
            successMessage = "已保存"
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

// MARK: - IP 地址库更新

struct WAFLocationUpdateView: View {
    let server: ServerConfig

    @State private var isUpdating = false
    @State private var successMessage: String?
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient(server: server)
    }

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await update(type: "geoIP") }
                } label: {
                    HStack {
                        Image(systemName: "globe.asia.australia")
                        Text("更新 IP 地址库")
                        Spacer()
                        if isUpdating { ProgressView() }
                    }
                }
            } header: {
                Text("IP 地址库")
            } footer: {
                Text("更新 GeoIP 数据库以支持基于地理位置的访问控制")
            }
        }
        .navigationTitle("IP 地址库")
        .navigationBarTitleDisplayMode(.inline)
        .alert("提示", isPresented: Binding(
            get: { successMessage != nil || errorMessage != nil },
            set: { _ in successMessage = nil; errorMessage = nil }
        )) {
            Button("好的") { successMessage = nil; errorMessage = nil }
        } message: {
            Text(errorMessage ?? successMessage ?? "")
        }
    }

    private func update(type: String) async {
        isUpdating = true
        let req = WAFLocationUpdateRequest(type: type)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafLocationUpdate.path, body: req, as: EmptyResponse.self)
            successMessage = "更新成功"
        } catch {
            errorMessage = error.localizedDescription
        }
        isUpdating = false
    }
}

// MARK: - 配置项（开关 + 更新）

struct WAFConfigItemView: View {
    let server: ServerConfig
    let title: String
    let scope: String
    let updateType: String
    let item: WAFRuleItem?

    @State private var isUpdating = false
    @State private var successMessage: String?
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig, title: String, scope: String, updateType: String, item: WAFRuleItem?) {
        self.server = server
        self.title = title
        self.scope = scope
        self.updateType = updateType
        self.item = item
        self.client = APIClient(server: server)
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { item?.isOn ?? false },
                    set: { newVal in
                        Task { await toggle(newVal) }
                    }
                )) {
                    Text("启用")
                }
            } header: {
                Text(title)
            }

            Section {
                Button {
                    Task { await update() }
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("更新")
                        Spacer()
                        if isUpdating { ProgressView() }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .alert("提示", isPresented: Binding(
            get: { successMessage != nil || errorMessage != nil },
            set: { _ in successMessage = nil; errorMessage = nil }
        )) {
            Button("好的") { successMessage = nil; errorMessage = nil }
        } message: {
            Text(errorMessage ?? successMessage ?? "")
        }
    }

    private func toggle(_ on: Bool) async {
        let req = WAFGlobalStateRequest(scope: scope, state: on ? "on" : "off")
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafConfigGlobalState.path, body: req, as: EmptyResponse.self)
            successMessage = on ? "已启用" : "已禁用"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func update() async {
        isUpdating = true
        let req = WAFLocationUpdateRequest(type: updateType)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafLocationUpdate.path, body: req, as: EmptyResponse.self)
            successMessage = "更新成功"
        } catch {
            errorMessage = error.localizedDescription
        }
        isUpdating = false
    }
}
