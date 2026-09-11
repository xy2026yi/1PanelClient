//
//  AIAccountModelsPoolView.swift
//  1PanelClient
//
//  模型账号 · 模型池（/api/v2/ai/accounts/models）：账号信息回显 +
//  模型列表（添加/编辑/删除）；验证模型对应的条目不可删除
//

import SwiftUI

struct AIAccountModelsPoolView: View {
    let server: ServerConfig
    let account: AIAccount
    /// 变更后刷新账号列表（行上的模型数）
    @ObservedObject var listVM: AIAccountViewModel

    @State private var models: [AIModelRef] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var toastMessage: String?

    @State private var showAdd = false
    @State private var editingModel: AIModelRef?
    @State private var pendingDelete: AIModelRef?
    @State private var isDeleting = false
    @State private var actionModel: AIModelRef?
    @State private var showEditAccount = false

    private let client: APIClient

    init(server: ServerConfig, account: AIAccount, listVM: AIAccountViewModel) {
        self.server = server
        self.account = account
        self.listVM = listVM
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        List {
            Section {
                InfoRow(L10n.t("名称"), value: account.name)
                InfoRow(L10n.t("模型供应商"), value: account.providerName ?? account.provider)
                InfoRow(L10n.t("API 类型"), value: account.apiType ?? "-")
                InfoRow("Base URL", value: account.baseUrl ?? "-", monospaced: true)
                if let verify = account.verifyModel, !verify.isEmpty {
                    InfoRow(L10n.t("验证模型"), value: verify, monospaced: true)
                }
                if let remark = account.remark, !remark.isEmpty {
                    InfoRow(L10n.t("备注"), value: remark)
                }
            } header: {
                SectionLabel(title: L10n.t("账号信息"), systemImage: "info.circle")
            }

            Section {
                if isLoading && models.isEmpty {
                    HStack {
                        Spacer()
                        LoadingStateView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else if let err = errorMessage, models.isEmpty {
                    LoadErrorStateView(message: err) {
                        Task { await load() }
                    }
                    .listRowBackground(Color.clear)
                } else if models.isEmpty {
                    ContentUnavailableView(
                        L10n.t("暂无模型"),
                        systemImage: "shippingbox",
                        description: Text(L10n.t("点击右上角 + 添加模型"))
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(models) { model in
                        Button {
                            editingModel = model
                        } label: {
                            modelRow(model)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                Haptic.selection()
                                actionModel = model
                            }
                        )
                    }
                }
            } header: {
                SectionLabel(
                    title: L10n.f("模型池 · 共 %d 个", models.count),
                    systemImage: "shippingbox"
                )
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("模型池"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("添加模型"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                EllipsisMenuButton {
                    showEditAccount = true
                }
                .accessibilityLabel(L10n.t("编辑账号"))
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .toastOverlay(message: $toastMessage)
        .sheet(item: $actionModel) { model in
            ActionBottomSheet(
                title: model.id,
                items: modelMenuItems(model),
                onDismiss: { actionModel = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: modelMenuItems(model).count))])
            .presentationDragIndicator(.visible)
        }
        .alert(L10n.t("删除模型"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingDelete = nil }
            Button(L10n.t("删除"), role: .destructive) {
                Haptic.warning()
                if let model = pendingDelete {
                    Task { await deleteModel(model) }
                }
            }
        } message: {
            Text(L10n.f("确定从模型池删除「%@」吗？", pendingDelete?.id ?? ""))
        }
        .navigationDestination(isPresented: $showAdd) {
            AIAccountModelFormView(server: server, accountId: account.id, editing: nil) {
                Task { await load() }
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { editingModel != nil },
            set: { if !$0 { editingModel = nil } }
        )) {
            if let model = editingModel {
                AIAccountModelFormView(server: server, accountId: account.id, editing: model) {
                    Task { await load() }
                }
            }
        }
        .navigationDestination(isPresented: $showEditAccount) {
            AIAccountFormView(server: server, editing: account, vm: listVM)
        }
    }

    // MARK: - 行

    private func modelRow(_ model: AIModelRef) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.id)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                if let display = model.name, !display.isEmpty, display != model.id {
                    Text(display)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isVerifyModel(model) {
                StatusBadge(text: L10n.t("验证模型"), color: .statusRunning, icon: "checkmark.seal.fill")
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func isVerifyModel(_ model: AIModelRef) -> Bool {
        account.verifyModel == model.id
    }

    /// 长按菜单条目：验证模型不可删除
    private func modelMenuItems(_ model: AIModelRef) -> [ActionMenuItem] {
        var items: [ActionMenuItem] = [
            ActionMenuItem(title: L10n.t("编辑"), icon: "pencil") {
                editingModel = model
            },
        ]
        if !isVerifyModel(model) {
            items.append(ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red, role: .destructive) {
                pendingDelete = model
            })
        }
        return items
    }

    // MARK: - 数据

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            models = try await client.send(
                path: APIEndpoint.aiAccountModelsList.path,
                body: AIAccountModelsRequest(accountId: account.id),
                as: [AIModelRef].self)
            errorMessage = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            models = []
            errorMessage = error.localizedDescription
        }
    }

    private func deleteModel(_ model: AIModelRef) async {
        pendingDelete = nil
        isDeleting = true
        defer { isDeleting = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAccountModelDelete.path,
                body: AIAccountModelDeleteRequest(accountId: account.id, recordId: model.recordId ?? 0),
                as: EmptyResponse.self)
            toastMessage = L10n.f("模型「%@」已删除", model.id)
            await load()
            await listVM.load()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            toastMessage = L10n.f("删除失败：%@", error.localizedDescription)
        }
    }
}

// MARK: - 模型 添加/编辑 表单

struct AIAccountModelFormView: View {
    let server: ServerConfig
    let accountId: Int
    let editing: AIModelRef?
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var modelId = ""
    @State private var modelName = ""
    @State private var isSaving = false
    @State private var didFill = false
    @State private var errorMessage: String?
    @State private var showError = false

    private let client: APIClient

    init(server: ServerConfig, accountId: Int, editing: AIModelRef?, onSaved: @escaping () async -> Void) {
        self.server = server
        self.accountId = accountId
        self.editing = editing
        self.onSaved = onSaved
        self.client = APIClient.shared(for: server)
    }

    private var canSubmit: Bool {
        !modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    var body: some View {
        Form {
            Section {
                TextField(L10n.t("模型"), text: $modelId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .disabled(editing != nil)
                TextField(L10n.t("名称"), text: $modelName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                SectionLabel(title: L10n.t("模型"), systemImage: "shippingbox")
            } footer: {
                if editing != nil {
                    Text(L10n.t("模型 ID 不可修改"))
                } else {
                    Text(L10n.t("名称留空时与模型 ID 一致"))
                }
            }
        }
        .navigationTitle(editing == nil ? L10n.t("添加模型") : L10n.t("编辑模型"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                }
                .disabled(!canSubmit)
            }
        }
        .task {
            guard !didFill else { return }
            didFill = true
            if let model = editing {
                modelId = model.id
                modelName = model.name ?? ""
            }
        }
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let id = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = AIModelRef(recordId: editing?.recordId ?? 0, id: id, name: display.isEmpty ? id : display)
        let req = AIAccountModelUpsertRequest(accountId: accountId, model: model)
        do {
            let _: EmptyResponse = try await client.send(
                path: editing == nil ? APIEndpoint.aiAccountModelCreate.path : APIEndpoint.aiAccountModelUpdate.path,
                body: req,
                as: EmptyResponse.self)
            await onSaved()
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
