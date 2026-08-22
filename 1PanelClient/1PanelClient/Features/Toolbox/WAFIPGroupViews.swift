//
//  WAFIPGroupViews.swift
//  1PanelClient
//

import SwiftUI

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
                LoadingStateView()
            } else if items.isEmpty {
                ContentUnavailableView(L10n.t("暂无 IP 组"), systemImage: "rectangle.on.rectangle.angled")
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
                                    StatusBadge(text: source == "imported" ? L10n.t("手动") : L10n.t("远程"), color: .blue)
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
                            Label(L10n.t("删除"), systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.t("IP 组"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottomTrailing) {
            FloatingActionButton { showCreate = true }
                .accessibilityLabel(L10n.t("创建 IP 组"))
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
                get: { pendingDeleteGroup != nil },
                set: { if !$0 { pendingDeleteGroup = nil } }
            ),
            presenting: pendingDeleteGroup
        ) { _ in
            Button(L10n.t("取消"), role: .cancel) { pendingDeleteGroup = nil }
            Button(L10n.t("删除"), role: .destructive) {
                let item = pendingDeleteGroup
                pendingDeleteGroup = nil
                if let item = item {
                    Task { await deleteItem(item) }
                }
            }
        } message: { item in
            Text(L10n.f("将对 \"%@\" 进行删除操作，是否继续？", item.name))
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
            successMessage = L10n.t("已删除")
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
            Section(L10n.t("名称")) {
                TextField(L10n.t("组名称"), text: $name)
            }
            Section(L10n.t("导入方式")) {
                Picker(L10n.t("方式"), selection: $source) {
                    Text(L10n.t("手动创建")).tag("imported")
                    Text(L10n.t("远程下载")).tag("remoteFile")
                }
            }
            if source == "imported" {
                Section(L10n.t("IP 列表")) {
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
        .navigationTitle(L10n.t("创建 IP 组"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("创建")) {
                    Task { await create() }
                }
                .disabled(isSaving || name.isEmpty)
            }
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
            Section(L10n.t("名称")) {
                Text(item.name).foregroundStyle(.secondary)
            }
            if item.source == "remoteFile" {
                Section(L10n.t("远程 URL")) {
                    Text(item.remoteURL ?? "—").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L10n.t("IP 列表")) {
                TextEditor(text: $content)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 200)
            }
        }
        .navigationTitle(L10n.t("编辑 IP 组"))
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
                        Text(L10n.t("保存"))
                    }
                }
                .disabled(isSaving)
            }
        }
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { successMessage != nil || errorMessage != nil },
            set: { _ in successMessage = nil; errorMessage = nil }
        )) {
            Button(L10n.t("好的"), role: .cancel) { successMessage = nil; errorMessage = nil }
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
            successMessage = L10n.t("已保存")
            onUpdated()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

