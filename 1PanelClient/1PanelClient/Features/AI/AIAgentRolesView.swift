//
//  AIAgentRolesView.swift
//  1PanelClient
//
//  OpenClaw 多角色（/api/v2/ai/agents/agent/*）：角色卡片列表（模型/目录/
//  频道绑定）+ 创建（模型下拉 + 频道绑定动态行）+ 卡片内绑定/解绑/删除
//

import SwiftUI

struct AIAgentRolesView: View {
    let server: ServerConfig
    let agentId: Int

    @State private var roles: [AIAgentRole] = []
    @State private var channels: [AIAgentRoleChannel] = []
    @State private var accounts: [AIAccount] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var showCreate = false
    @State private var toastMessage: String?
    @State private var errorMessage: String?
    @State private var showError = false
    /// 删除确认目标
    @State private var pendingDelete: AIAgentRole?

    private let client: APIClient

    init(server: ServerConfig, agentId: Int) {
        self.server = server
        self.agentId = agentId
        self.client = APIClient.shared(for: server)
    }

    /// 模型候选：文本类账号的模型池平铺（id 显示）
    private var modelOptions: [String] {
        accounts.flatMap { $0.models?.map(\.id) ?? [] }
    }

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); LoadingStateView(); Spacer() }
                    .listRowBackground(Color.clear)
            } else if let err = loadError {
                LoadErrorStateView(message: err) {
                    Task { await load() }
                }
                .listRowBackground(Color.clear)
            } else if roles.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无角色"),
                    systemImage: "person.2",
                    description: Text(L10n.t("点击右上角 + 创建角色"))
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(roles) { role in
                    roleSection(role)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("角色"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("创建角色"))
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .toastOverlay(message: $toastMessage)
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(L10n.t("删除角色"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingDelete = nil }
            Button(L10n.t("删除"), role: .destructive) {
                if let role = pendingDelete {
                    Task { await deleteRole(role) }
                }
            }
        } message: {
            Text(L10n.f("确定删除角色「%@」吗？其工作区与绑定将一并移除。", pendingDelete?.name ?? ""))
        }
        .sheet(isPresented: $showCreate) {
            AIAgentRoleCreateSheet(client: client, agentId: agentId,
                                   channels: channels, modelOptions: modelOptions) {
                Task { await load() }
            }
        }
    }

    // MARK: 角色卡片

    private func roleSection(_ role: AIAgentRole) -> some View {
        Section {
            LabeledContent(L10n.t("模型"), value: role.model ?? "-")
            if let workspace = role.workspace, !workspace.isEmpty {
                CopyableInfoRow(L10n.t("工作区目录"), value: workspace, monospaced: true)
            }
            if let dir = role.agentDir, !dir.isEmpty {
                CopyableInfoRow("Agent " + L10n.t("目录"), value: dir, monospaced: true)
            }

            ForEach(role.bindings ?? []) { binding in
                HStack {
                    Image(systemName: "link")
                        .foregroundStyle(.teal)
                    Text("\(binding.channel ?? "-"):\(binding.accountId ?? "-")")
                        .font(.system(.subheadline, design: .monospaced))
                    Spacer()
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        Task { await unbind(role, binding) }
                    } label: {
                        Label(L10n.t("取消绑定"), systemImage: "link.badge.plus")
                    }
                }
            }

            RoleBindRow(channels: channels) { channel, account in
                Task { await bind(role, channel: channel, account: account) }
            }

            Button(role: .destructive) {
                pendingDelete = role
            } label: {
                Label(L10n.t("删除角色"), systemImage: "trash")
            }
        } header: {
            SectionLabel(title: role.name ?? role.id, systemImage: "person.crop.circle")
        }
    }

    // MARK: 操作

    private func bind(_ role: AIAgentRole, channel: String, account: String) async {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentRoleBind.path,
                body: AIAgentRoleBindRequest(agentId: agentId, id: role.id, channel: channel, accountId: account),
                as: EmptyResponse.self)
            toastMessage = L10n.t("已绑定")
            await load()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func unbind(_ role: AIAgentRole, _ binding: AIAgentRoleBinding) async {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentRoleUnbind.path,
                body: AIAgentRoleUnbindRequest(
                    agentId: agentId, id: role.id,
                    channel: binding.channel ?? "", accountId: binding.accountId ?? ""),
                as: EmptyResponse.self)
            toastMessage = L10n.t("已解绑")
            await load()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func deleteRole(_ role: AIAgentRole) async {
        pendingDelete = nil
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentRoleDelete.path,
                body: AIAgentRoleDeleteRequest(agentId: agentId, id: role.id),
                as: EmptyResponse.self)
            toastMessage = L10n.f("已删除「%@」", role.name ?? role.id)
            await load()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func load() async {
        // client 为 MainActor 隔离，async let 并发调用不合法（Swift 6），顺序加载
        let rolesResp: [AIAgentRole]? = try? await client.send(
            path: APIEndpoint.aiAgentRolesList.path,
            body: AIAgentModelRequest(agentId: agentId),
            as: [AIAgentRole].self)
        roles = rolesResp ?? []
        let channelsResp: [AIAgentRoleChannel]? = try? await client.send(
            path: APIEndpoint.aiAgentRoleChannels.path,
            body: AIAgentModelRequest(agentId: agentId),
            as: [AIAgentRoleChannel].self)
        channels = channelsResp ?? []
        let accountsResp: PageResponse<AIAccount>? = try? await client.send(
            path: APIEndpoint.aiAccountsSearch.path,
            body: AISearchPageRequest(page: 1, pageSize: 200, textOnly: true),
            as: PageResponse<AIAccount>.self)
        accounts = accountsResp?.items ?? []

        if rolesResp == nil {
            loadError = L10n.t("加载失败，请下拉重试")
        } else {
            loadError = nil
        }
        isLoading = false
    }
}

// MARK: - 绑定行（频道 + 账户 二级联动 + 添加按钮）

struct RoleBindRow: View {
    let channels: [AIAgentRoleChannel]
    let onAdd: (String, String) -> Void

    @State private var channel: String = ""
    @State private var account: String = ""

    private var accountOptions: [String] {
        channels.first(where: { $0.name == channel })?.accountIds ?? []
    }

    var body: some View {
        HStack(spacing: 10) {
            Picker(L10n.t("频道"), selection: $channel) {
                Text(L10n.t("请选择")).tag("")
                ForEach(channels) { ch in
                    Text(ch.name).tag(ch.name)
                }
            }
            .onChange(of: channel) { _, _ in
                account = accountOptions.first ?? ""
            }

            if !accountOptions.isEmpty {
                Picker(L10n.t("账户 ID"), selection: $account) {
                    ForEach(accountOptions, id: \.self) { id in
                        Text(id).tag(id)
                    }
                }
            }

            Button {
                guard !channel.isEmpty, !account.isEmpty else { return }
                onAdd(channel, account)
            } label: {
                Image(systemName: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
            .disabled(channel.isEmpty || account.isEmpty)
            .accessibilityLabel(L10n.t("添加"))
        }
    }
}

// MARK: - 创建角色 Sheet（模型 + 频道绑定动态行）

private struct AIAgentRoleCreateSheet: View {
    let client: APIClient
    let agentId: Int
    let channels: [AIAgentRoleChannel]
    let modelOptions: [String]
    let onCreated: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var model = ""
    @State private var bindings: [AIAgentRoleBinding] = []
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showError = false

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.isEmpty && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.t("名称"), text: $name)
                        .textInputAutocapitalization(.never)
                    Picker(L10n.t("模型"), selection: $model) {
                        Text(L10n.t("请选择")).tag("")
                        ForEach(modelOptions, id: \.self) { m in
                            Text(m).tag(m)
                        }
                    }
                } header: {
                    SectionLabel(title: L10n.t("基本信息"), systemImage: "info.circle")
                }

                Section {
                    ForEach(Array(bindings.enumerated()), id: \.offset) { idx, binding in
                        HStack {
                            Text("\(binding.channel ?? "-"):\(binding.accountId ?? "-")")
                                .font(.system(.subheadline, design: .monospaced))
                            Spacer()
                            Button {
                                bindings.remove(at: idx)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L10n.t("删除"))
                        }
                    }
                    RoleBindRow(channels: channels) { channel, account in
                        // 同频道同账号不重复添加
                        guard !bindings.contains(where: { $0.channel == channel && $0.accountId == account }) else { return }
                        bindings.append(AIAgentRoleBinding(channel: channel, accountId: account))
                    }
                } header: {
                    SectionLabel(title: L10n.t("频道绑定"), systemImage: "link")
                } footer: {
                    Text(L10n.t("可选；创建后也可在角色卡片内添加或取消绑定"))
                }
            }
            .navigationTitle(L10n.t("创建角色"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("创建")) {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit)
                }
            }
            .alert(L10n.t("提示"), isPresented: $showError) {
                Button(L10n.t("好的"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.large])
        .interactiveDismissDisabled(isSubmitting)
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentRoleCreate.path,
                body: AIAgentRoleCreateRequest(
                    agentId: agentId,
                    name: name.trimmingCharacters(in: .whitespaces),
                    model: model,
                    bindings: bindings),
                as: EmptyResponse.self)
            await onCreated()
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
