//
//  WAFCommonRulesView.swift
//  1PanelClient
//

import SwiftUI

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


