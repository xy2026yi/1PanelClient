//
//  WAFView.swift
//  1PanelClient
//
//  WAF 管理：状态 / 全局规则开关 / IP黑白名单 / IP组
//

import SwiftUI
import Combine

// MARK: - 数据模型

struct WAFStatus: Decodable {
    let healthy: Bool
    let openrestyVersion: String?
    let open: Bool
}

struct WAFConfig: Decodable {
    let waf: WAFCore?
    let ipWhite: WAFRuleItem?
    let ipBlack: WAFRuleItem?
    let urlWhite: WAFRuleItem?
    let urlBlack: WAFRuleItem?
    let uaWhite: WAFRuleItem?
    let uaBlack: WAFRuleItem?
    let xss: WAFRuleItem?
    let sql: WAFRuleItem?
    let cc: WAFRuleItem?
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

struct WAFCore: Decodable {
    let state: String?
    let mode: String?
}

struct WAFRuleItem: Decodable {
    let state: String?
    let code: Int?
    let action: String?
    let type: String?

    var isOn: Bool { state == "on" }
}

struct WAFGlobalStateRequest: Encodable {
    let scope: String
    let state: String
}

// MARK: IP 规则

struct WAFRuleIPSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let type: String
}

struct WAFRuleIPItem: Decodable, Identifiable, Hashable {
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

struct WAFRuleIPCreateRequest: Encodable {
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

struct WAFRuleIPUpdateRequest: Encodable {
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

struct WAFRuleIPDeleteRequest: Encodable {
    let name: String
    let scope: String
}

// MARK: IP 组

struct WAFIPGroupSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let all: Bool
}

struct WAFIPGroupItem: Decodable, Identifiable, Hashable {
    let name: String
    let content: String?
    let source: String?
    let remoteURL: String?

    var id: String { name }
}

struct WAFIPGroupCreateRequest: Encodable {
    let name: String
    let content: String
    let source: String
    let remoteURL: String
}

struct WAFIPGroupDeleteRequest: Encodable {
    let name: String
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
            get: { vm.successMessage != nil },
            set: { if !$0 { vm.successMessage = nil } }
        )) {
            Button("好的") { vm.successMessage = nil }
        } message: {
            Text(vm.successMessage ?? "")
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
                    StatusBadge(
                        text: vm.status?.open == true ? "运行中" : "已关闭",
                        color: vm.status?.open == true ? .green : .red,
                        backgroundOpacity: 0.15
                    )
                }
            }

            // 黑白名单
            Section {
                NavigationLink {
                    WAFIPRulesView(server: server, scope: "ipBlack", title: "IP 黑名单")
                } label: {
                    ruleRow(icon: "hand.raised", color: .red, title: "IP 黑名单", item: config.ipBlack)
                }
                NavigationLink {
                    WAFIPRulesView(server: server, scope: "ipWhite", title: "IP 白名单")
                } label: {
                    ruleRow(icon: "checkmark.shield", color: .green, title: "IP 白名单", item: config.ipWhite)
                }
            } header: {
                SectionLabel(title: "黑白名单", systemImage: "shield")
            }

            // IP 组
            Section {
                NavigationLink {
                    WAFIPGroupsView(server: server)
                } label: {
                    HStack(spacing: 12) {
                        IconBadge(systemName: "rectangle.group", color: .indigo, size: 34, cornerRadius: 8)
                        Text("IP 组管理")
                    }
                }
            }

            // 防护规则
            Section {
                toggleRow(title: "XSS 攻击", item: config.xss, scope: "XSS")
                toggleRow(title: "SQL 注入", item: config.sql, scope: "SQL")
                toggleRow(title: "CC 攻击", item: config.cc, scope: "CC")
                toggleRow(title: "参数过滤", item: config.args, scope: "ARGS")
                toggleRow(title: "Cookie 校验", item: config.cookie, scope: "COOKIE")
                toggleRow(title: "Header 校验", item: config.header, scope: "HEADER")
                toggleRow(title: "文件扩展名", item: config.fileExt, scope: "FILEEXTCHECK")
                toggleRow(title: "漏洞防护", item: config.vuln, scope: "VULNCHECK")
                toggleRow(title: "严格模式", item: config.strict, scope: "STRICT")
                toggleRow(title: "允许爬虫", item: config.allowSpider, scope: "SPIDER")
                toggleRow(title: "默认 IP 黑名单", item: config.defaultIpBlack, scope: "DEFAULTIPBLACK")
                toggleRow(title: "默认 UA 黑名单", item: config.defaultUaBlack, scope: "DEFAULTUABLACK")
                toggleRow(title: "默认 URL 黑名单", item: config.defaultUrlBlack, scope: "DEFAULTURLBLACK")
                toggleRow(title: "未知网站拦截", item: config.unknownWebsite, scope: "UNKNOWNWEBSITE")
            } header: {
                SectionLabel(title: "防护规则", systemImage: "lock.shield")
            }
        }
    }

    private func ruleRow(icon: String, color: Color, title: String, item: WAFRuleItem?) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemName: icon, color: color, size: 34, cornerRadius: 8)
            Text(title)
            Spacer()
            if let item, item.isOn {
                StatusBadge(text: "开启", color: .green, backgroundOpacity: 0.15)
            } else {
                StatusBadge(text: "关闭", color: .secondary, backgroundOpacity: 0.1)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
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
                Text("暂无数据").foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    WAFIPRuleRow(item: item, onToggle: {
                        Task { await toggleState(item) }
                    })
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { await deleteItem(item) }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .refreshable { await loadItems() }
        .task { await loadItems() }
        .sheet(isPresented: $showCreate) {
            WAFCreateIPRuleView(server: server, scope: scope) {
                Task { await loadItems() }
            }
        }
        .alert("提示", isPresented: Binding(
            get: { successMessage != nil },
            set: { if !$0 { successMessage = nil } }
        )) {
            Button("好的") { successMessage = nil }
        } message: {
            Text(successMessage ?? "")
        }
    }

    private func loadItems() async {
        isLoading = true
        let req = WAFRuleIPSearchRequest(page: 1, pageSize: 100, type: scope)
        do {
            let resp: PageResponse<WAFRuleIPItem> = try await client.send(
                path: APIEndpoint.wafRuleIPSearch.path, body: req,
                as: PaginatedResponse<WAFRuleIPItem>.self
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

struct WAFIPRuleRow: View {
    let item: WAFRuleIPItem
    let onToggle: () -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { item.state == "on" }, set: { _ in onToggle() })) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.displayValue)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                }
                HStack(spacing: 8) {
                    StatusBadge(text: item.typeLabel, color: .blue, backgroundOpacity: 0.1)
                    if let desc = item.description, !desc.isEmpty {
                        Text(desc).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .tint(item.state == "on" ? .green : .gray)
    }
}

// MARK: - 创建 IP 规则

struct WAFCreateIPRuleView: View {
    let server: ServerConfig
    let scope: String
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var ipType = "ipv4"
    @State private var ipv4 = ""
    @State private var ipStart = ""
    @State private var ipEnd = ""
    @State private var ipv6 = ""
    @State private var ipGroup = ""
    @State private var description = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var ipGroups: [WAFIPGroupItem] = []

    private let client: APIClient

    init(server: ServerConfig, scope: String, onCreated: @escaping () -> Void) {
        self.server = server
        self.scope = scope
        self.onCreated = onCreated
        self.client = APIClient(server: server)
    }

    private let typeOptions: [(value: String, label: String)] = [
        ("ipv4", "IPv4"),
        ("ipArr", "IPv4 范围"),
        ("ipv6", "IPv6"),
        ("ipGroup", "IP 组"),
    ]

    var body: some View {
        NavigationStack {
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

                Section("备注") {
                    TextField("描述(可选)", text: $description)
                }
            }
            .navigationTitle("添加 IP 规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        Task { await create() }
                    }
                    .disabled(isSaving || !isValid)
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
        let req = WAFIPGroupSearchRequest(page: 1, pageSize: 100, all: true)
        do {
            let resp: PaginatedResponse<WAFIPGroupItem> = try await client.send(
                path: APIEndpoint.wafIPGroupSearch.path, body: req,
                as: PaginatedResponse<WAFIPGroupItem>.self
            )
            ipGroups = resp.items ?? []
        } catch { }
    }

    private func create() async {
        isSaving = true
        let req = WAFRuleIPCreateRequest(
            name: "", type: ipType, ipv4: ipv4, ipStart: ipStart, ipEnd: ipEnd,
            ipv6: ipv6, state: "on", description: description, scope: scope, ipGroup: ipGroup
        )
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafRuleIPCreate.path, body: req, as: EmptyResponse.self)
            onCreated()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

// MARK: - IP 组管理视图

struct WAFIPGroupsView: View {
    let server: ServerConfig

    @Environment(\.dismiss) private var dismiss
    @State private var items: [WAFIPGroupItem] = []
    @State private var isLoading = false
    @State private var showCreate = false
    @State private var successMessage: String?
    @State private var errorMessage: String?

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
                Text("暂无数据").foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    NavigationLink {
                        WAFIPGroupEditView(server: server, item: item) {
                            Task { await loadItems() }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.body)
                            if let content = item.content, !content.isEmpty {
                                Text(content.replacingOccurrences(of: "\n", with: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            if let source = item.source, !source.isEmpty {
                                StatusBadge(text: source == "imported" ? "手动" : "远程", color: .blue, backgroundOpacity: 0.1)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { await deleteItem(item) }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("IP 组")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .refreshable { await loadItems() }
        .task { await loadItems() }
        .sheet(isPresented: $showCreate) {
            WAFCreateIPGroupView(server: server) {
                Task { await loadItems() }
            }
        }
        .alert("提示", isPresented: Binding(
            get: { successMessage != nil },
            set: { if !$0 { successMessage = nil } }
        )) {
            Button("好的") { successMessage = nil }
        } message: {
            Text(successMessage ?? "")
        }
    }

    private func loadItems() async {
        isLoading = true
        let req = WAFIPGroupSearchRequest(page: 1, pageSize: 100, all: false)
        do {
            let resp: PaginatedResponse<WAFIPGroupItem> = try await client.send(
                path: APIEndpoint.wafIPGroupSearch.path, body: req,
                as: PaginatedResponse<WAFIPGroupItem>.self
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
        NavigationStack {
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
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
                Button("保存") {
                    Task { await save() }
                }
                .disabled(isSaving)
            }
        }
        .alert("提示", isPresented: Binding(
            get: { successMessage != nil || errorMessage != nil },
            set: { successMessage = nil; errorMessage = nil }
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
