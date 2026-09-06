//
//  WAFCommonRulesView.swift
//  1PanelClient
//

import SwiftUI

// MARK: - 通用规则视图（黑白名单 URL/UA · 全局配置-默认规则 · 文件上传限制）

struct WAFCommonRulesView: View {
    let server: ServerConfig
    let scope: String
    let title: String
    /// 内置规则集模式（全局配置-默认规则）：规则只读 + 开关 + 「应用到网站」，
    /// 无创建/编辑/删除；黑白名单与文件上传限制走完整 CRUD（默认 false）
    var builtin: Bool = false

    @State private var items: [WAFCommonRuleItem] = []
    @State private var isLoading = false
    @State private var showCreate = false
    @State private var showApply = false
    @State private var editingItem: WAFCommonRuleItem?
    @State private var successMessage: String?
    @State private var errorMessage: String?
    /// 列表加载失败（区别于操作失败 errorMessage：本状态渲染页内错误态 + 重试）
    @State private var loadError: String?
    @State private var pendingDeleteRule: WAFCommonRuleItem?
    @State private var actionItem: WAFCommonRuleItem?

    private let client: APIClient

    init(server: ServerConfig, scope: String, title: String, builtin: Bool = false) {
        self.server = server
        self.scope = scope
        self.title = title
        self.builtin = builtin
        self.client = APIClient.shared(for: server)
    }

    /// 全列表唯一类型（如文件上传限制恒为 fileExt）：徽标此时冗余，不显示
    private var singleType: String? {
        let types = Set(items.compactMap { $0.type }.filter { !$0.isEmpty })
        return types.count == 1 ? types.first : nil
    }

    var body: some View {
        List {
            if isLoading && items.isEmpty {
                LoadingStateView()
            } else if let err = loadError, items.isEmpty {
                LoadErrorStateView(message: err) {
                    Task { await loadItems() }
                }
                .listRowBackground(Color.clear)
            } else if items.isEmpty {
                ContentUnavailableView(L10n.t("暂无通用规则"), systemImage: "list.bullet.rectangle.shield")
            } else {
                ForEach(items) { item in
                    HStack {
                        if builtin {
                            ruleLabel(item)
                        } else {
                            Button {
                                actionItem = item
                            } label: {
                                ruleLabel(item)
                            }
                            .buttonStyle(.plain)
                        }

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if builtin {
                    Button {
                        showApply = true
                    } label: {
                        Text(L10n.t("应用规则"))
                    }
                    .accessibilityLabel(L10n.t("应用到网站"))
                } else {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L10n.t("添加规则"))
                }
            }
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
        .sheet(isPresented: $showApply) {
            WAFRuleApplySheet(server: server, scope: scope) {
                successMessage = L10n.t("应用成功")
            }
        }
        .sheet(isPresented: Binding(
            get: { actionItem != nil },
            set: { if !$0 { actionItem = nil } }
        )) {
            ActionBottomSheet(
                title: actionItem?.rule ?? L10n.t("规则"),
                items: [
                    ActionMenuItem(title: L10n.t("编辑"), icon: "pencil", color: .blue) {
                        editingItem = actionItem
                    },
                    ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red, role: .destructive) {
                        pendingDeleteRule = actionItem
                    },
                ],
                onDismiss: { actionItem = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: 2))])
            .presentationDragIndicator(.visible)
        }
        .localToast(message: $successMessage)
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(
            L10n.t("删除"),
            isPresented: Binding(
                get: { pendingDeleteRule != nil },
                set: { if !$0 { pendingDeleteRule = nil } }
            ),
            presenting: pendingDeleteRule
        ) { _ in
            Button(L10n.t("取消"), role: .cancel) { pendingDeleteRule = nil }
            Button(L10n.t("删除"), role: .destructive) {
                Haptic.warning()
                let item = pendingDeleteRule
                pendingDeleteRule = nil
                if let item = item {
                    Task { await deleteItem(item) }
                }
            }
        } message: { item in
            Text(L10n.f("将对 \"%@\" 进行删除操作，是否继续？", item.name))
        }
    }

    /// 规则行左侧内容：正则 + 类型徽标 + 备注
    private func ruleLabel(_ item: WAFCommonRuleItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.rule)
                .font(.system(.body, design: .monospaced))

            let showType = item.type != singleType
            if showType || !(item.description ?? "").isEmpty {
                HStack(spacing: 6) {
                    if showType, let typeName = item.typeDisplayName {
                        StatusBadge(text: typeName, color: .secondary)
                    }
                    if let desc = item.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
            loadError = nil
        } catch {
            loadError = error.localizedDescription
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
            successMessage = newState == "on" ? L10n.t("已启用") : L10n.t("已禁用")
            await loadItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteItem(_ item: WAFCommonRuleItem) async {
        let req = WAFCommonRuleDeleteRequest(name: item.name, scope: scope, websiteID: 0)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafRuleCommonDelete.path, body: req, as: EmptyResponse.self)
            successMessage = L10n.t("已删除")
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
        self.client = APIClient.shared(for: server)
        if let item = editingItem {
            _rule = State(initialValue: item.rule)
            _description = State(initialValue: item.description ?? "")
        }
    }

    var body: some View {
        Form {
            Section(L10n.t("规则内容")) {
                TextField(L10n.t("输入规则"), text: $rule)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            Section(L10n.t("备注")) {
                TextField(L10n.t("描述(可选)"), text: $description)
            }
        }
        .navigationTitle(editingItem == nil ? L10n.t("添加规则") : L10n.t("编辑规则"))
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
                .disabled(isSaving || rule.isEmpty)
            }
        }
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) { errorMessage = nil }
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

// MARK: - 应用到网站（内置规则集）

/// 内置规则「应用到网站」选择器：多选网站（含全选，全部网站 = 传入所有网站 ID，
/// 与面板 Web 端一致），确认后提交 rule/common/apply
private struct WAFRuleApplySheet: View {
    let server: ServerConfig
    let scope: String
    let onApplied: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var websites: [WAFWebsiteItem] = []
    @State private var selected: Set<Int> = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isApplying = false
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig, scope: String, onApplied: @escaping () -> Void) {
        self.server = server
        self.scope = scope
        self.onApplied = onApplied
        self.client = APIClient.shared(for: server)
    }

    private var allSelected: Bool {
        !websites.isEmpty && selected.count == websites.count
    }

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    LoadingStateView()
                        .listRowBackground(Color.clear)
                } else if let err = loadError {
                    LoadErrorStateView(message: err) {
                        Task { await loadWebsites() }
                    }
                    .listRowBackground(Color.clear)
                } else if websites.isEmpty {
                    ContentUnavailableView(
                        L10n.t("暂无网站"),
                        systemImage: "globe",
                        description: Text(L10n.t("安装 OpenResty 并创建网站后才能应用规则"))
                    )
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        Button {
                            if allSelected {
                                selected.removeAll()
                            } else {
                                selected = Set(websites.map(\.id))
                            }
                        } label: {
                            HStack {
                                Text(allSelected ? L10n.t("取消全选") : L10n.t("全选"))
                                Spacer()
                                if allSelected {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    } footer: {
                        Text(L10n.t("全部网站即传入所有网站，与面板 Web 端一致"))
                    }

                    Section {
                        ForEach(websites) { site in
                            Button {
                                if selected.contains(site.id) {
                                    selected.remove(site.id)
                                } else {
                                    selected.insert(site.id)
                                }
                            } label: {
                                HStack {
                                    Text(site.primaryDomain ?? site.alias ?? "#\(site.id)")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selected.contains(site.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(L10n.t("选择网站"))
                    }
                }
            }
            .navigationTitle(L10n.t("应用到网站"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await apply() }
                    } label: {
                        if isApplying {
                            ProgressView()
                        } else {
                            Text(L10n.t("应用规则"))
                        }
                    }
                    .disabled(selected.isEmpty || isApplying)
                }
            }
        }
        .task { await loadWebsites() }
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func loadWebsites() async {
        isLoading = true
        defer { isLoading = false }
        do {
            websites = try await fetchAllWebsites()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// 分页拉全量网站列表（与 WAFWebsiteSettingsView 一致）
    private func fetchAllWebsites() async throws -> [WAFWebsiteItem] {
        var result: [WAFWebsiteItem] = []
        var page = 1
        let pageSize = 20
        while page <= 50 {
            let resp: PageResponse<WAFWebsiteItem> = try await client.send(
                path: APIEndpoint.wafWebsitesSearch.path,
                body: WAFWebsiteSearchRequest(page: page, pageSize: pageSize, name: ""),
                as: PageResponse<WAFWebsiteItem>.self
            )
            let items = resp.items ?? []
            result += items
            let total = resp.total ?? 0
            if items.isEmpty || items.count < pageSize || result.count >= total { break }
            page += 1
        }
        return result
    }

    private func apply() async {
        isApplying = true
        defer { isApplying = false }
        let req = WAFCommonRuleApplyRequest(scope: scope, websites: Array(selected))
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.wafRuleCommonApply.path, body: req, as: EmptyResponse.self
            )
            onApplied()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}


