//
//  WAFIPRulesView.swift
//  1PanelClient
//

import SwiftUI

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
                LoadingStateView()
            } else if items.isEmpty {
                ContentUnavailableView(L10n.t("暂无 IP 规则"), systemImage: "ipaddress")
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
                .accessibilityLabel(L10n.t("添加规则"))
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
                title: actionItem?.displayValue ?? L10n.t("IP 规则"),
                items: [
                    ActionMenuItem(title: L10n.t("编辑"), icon: "pencil", color: .blue) {
                        editingItem = actionItem
                    },
                    ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red, role: .destructive) {
                        pendingDeleteIP = actionItem
                    },
                ],
                onDismiss: { actionItem = nil }
            )
            .presentationDetents([.height(ActionBottomSheet.height(for: 2))])
            .presentationDragIndicator(.visible)
        }
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { successMessage != nil || errorMessage != nil },
            set: { _ in successMessage = nil; errorMessage = nil }
        )) {
            Button(L10n.t("好的"), role: .cancel) { successMessage = nil; errorMessage = nil }
        } message: {
            Text(errorMessage ?? successMessage ?? "")
        }
        .alert(
            L10n.t("删除"),
            isPresented: Binding(
                get: { pendingDeleteIP != nil },
                set: { if !$0 { pendingDeleteIP = nil } }
            ),
            presenting: pendingDeleteIP
        ) { _ in
            Button(L10n.t("取消"), role: .cancel) { pendingDeleteIP = nil }
            Button(L10n.t("删除"), role: .destructive) {
                let item = pendingDeleteIP
                pendingDeleteIP = nil
                if let item = item {
                    Task { await deleteItem(item) }
                }
            }
        } message: { item in
            Text(L10n.f("将对 \"%@\" 进行删除操作，是否继续？", item.displayValue.isEmpty ? item.name : item.displayValue))
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
            successMessage = newState == "on" ? L10n.t("已启用") : L10n.t("已禁用")
            await loadItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteItem(_ item: WAFRuleIPItem) async {
        let req = WAFRuleIPDeleteRequest(name: item.name, scope: scope)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafRuleIPDelete.path, body: req, as: EmptyResponse.self)
            successMessage = L10n.t("已删除")
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
        ("ipArr", L10n.t("IPv4 范围")),
        ("ipv6", "IPv6"),
        ("ipGroup", L10n.t("IP 组")),
    ]

    var body: some View {
        Form {
            Section(L10n.t("类型")) {
                Picker(L10n.t("IP 类型"), selection: $ipType) {
                    ForEach(typeOptions, id: \.value) { Text($0.label).tag($0.value) }
                }
                .onChange(of: ipType) { _, _ in
                    if ipType == "ipGroup" { Task { await loadGroups() } }
                }
            }

            switch ipType {
            case "ipv4":
                Section(L10n.t("IPv4 地址")) {
                    TextField(L10n.t("例: 192.168.1.1"), text: $ipv4)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                }
            case "ipArr":
                Section(L10n.t("IPv4 范围")) {
                    TextField(L10n.t("起始 IP"), text: $ipStart)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                    TextField(L10n.t("结束 IP"), text: $ipEnd)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                }
            case "ipv6":
                Section(L10n.t("IPv6 地址")) {
                    TextField(L10n.t("例: 2001:db8::1"), text: $ipv6)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            case "ipGroup":
                Section(L10n.t("IP 组")) {
                    if ipGroups.isEmpty {
                        Text(L10n.t("请先创建 IP 组")).foregroundStyle(.secondary)
                    } else {
                        Picker(L10n.t("选择 IP 组"), selection: $ipGroup) {
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
                Section(L10n.t("状态")) {
                    Toggle(L10n.t("启用"), isOn: Binding(
                        get: { state == "on" },
                        set: { state = $0 ? "on" : "off" }
                    ))
                }
            }

            Section(L10n.t("备注")) {
                TextField(L10n.t("描述(可选)"), text: $description)
            }
        }
        .navigationTitle(editingItem == nil ? L10n.t("创建 IP 规则") : L10n.t("编辑 IP 规则"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text(editingItem == nil ? L10n.t("创建") : L10n.t("保存"))
                    }
                }
                .disabled(isSaving || !isValid)
            }
        }
        .onAppear {
            if ipType == "ipGroup" { Task { await loadGroups() } }
        }
        .alert(L10n.t("错误"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) { errorMessage = nil }
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


