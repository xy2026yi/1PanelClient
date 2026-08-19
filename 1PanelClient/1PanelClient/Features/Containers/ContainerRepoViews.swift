//
//  ContainerRepoViews.swift
//  1PanelClient
//

import SwiftUI

// MARK: - 仓库列表

struct RepoListView: View {
    @ObservedObject var vm: ContainersViewModel
    @State private var repos: [ContainerRepo] = []
    @State private var isLoading = false
    @State private var showCreate = false
    /// 当前编辑的仓库（sheet(item:)）
    @State private var editingRepo: ContainerRepo?
    @State private var pendingDelete: ContainerRepo?

    var body: some View {
        Group {
            if isLoading && repos.isEmpty {
                ProgressView(L10n.t("加载仓库…"))
            } else if repos.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无仓库"),
                    systemImage: "shippingbox",
                    description: Text(L10n.t("这台服务器上没有配置镜像仓库"))
                )
            } else {
                List {
                    ForEach(repos) { repo in
                        Button {
                            editingRepo = repo
                        } label: {
                            RepoRow(repo: repo)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = repo
                            } label: {
                                Label(L10n.t("删除"), systemImage: "trash")
                            }
                            Button {
                                Task { await sync(repo) }
                            } label: {
                                Label(L10n.t("同步"), systemImage: "arrow.triangle.2.circlepath")
                            }
                            .tint(.blue)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await loadRepos() }
            }
        }
        .navigationTitle(L10n.t("仓库"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottomTrailing) {
            FloatingActionButton { showCreate = true }
                .accessibilityLabel(L10n.t("创建仓库"))
        }
        .navigationDestination(isPresented: $showCreate) {
            RepoFormView(editing: nil, vm: vm) { await loadRepos() }
        }
        .navigationDestination(item: $editingRepo) { repo in
            RepoFormView(editing: repo, vm: vm) { await loadRepos() }
        }
        .alert(
            L10n.t("删除仓库"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button(L10n.t("取消"), role: .cancel) { pendingDelete = nil }
            Button(L10n.t("删除"), role: .destructive) {
                let repo = pendingDelete
                pendingDelete = nil
                if let repo {
                    Task {
                        if await vm.deleteRepo(id: repo.id) {
                            await loadRepos()
                        }
                    }
                }
            }
        } message: {
            if let repo = pendingDelete {
                Text(L10n.f("确定删除仓库「%@」吗？", repo.name ?? ""))
            }
        }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .task { await loadRepos() }
    }

    private func loadRepos() async {
        isLoading = true
        repos = await vm.loadRepos()
        isLoading = false
    }

    /// 同步仓库状态：提交后稍等再刷新列表，让状态有机会更新
    private func sync(_ repo: ContainerRepo) async {
        if await vm.syncRepo(id: repo.id) {
            try? await Task.sleep(for: .seconds(1))
            await loadRepos()
        }
    }
}

// MARK: - 仓库表单（添加/编辑）

struct RepoFormView: View {
    /// nil = 添加；非 nil = 编辑（信息预填）
    let editing: ContainerRepo?
    @ObservedObject var vm: ContainersViewModel
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var downloadUrl = ""
    @State private var useAuth = false
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    /// true = https
    @State private var useHTTPS = true
    /// http 协议二次确认步骤（需输入「立即重启」）
    @State private var confirmStep = false
    @State private var restartConfirm = ""
    @State private var isSaving = false

    init(editing: ContainerRepo?, vm: ContainersViewModel, onSaved: @escaping () async -> Void) {
        self.editing = editing
        self.vm = vm
        self.onSaved = onSaved
        // 编辑：原有信息预填
        _name = State(initialValue: editing?.name ?? "")
        _downloadUrl = State(initialValue: editing?.downloadUrl ?? "")
        _useAuth = State(initialValue: editing?.auth ?? false)
        _username = State(initialValue: editing?.username ?? "")
        _useHTTPS = State(initialValue: (editing?.protocolField ?? "https").lowercased() != "http")
    }

    private var isEditing: Bool { editing != nil }

    private var canSubmit: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
              !downloadUrl.trimmingCharacters(in: .whitespaces).isEmpty
        else { return false }
        if useAuth {
            guard !username.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            // 添加时密码必填；编辑不提交密码（保留原密码）
            if !isEditing && password.isEmpty { return false }
        }
        return true
    }

    var body: some View {
        Form {
            if confirmStep {
                Section {
                    Label(L10n.t("操作 http 类型仓库需要重启 Docker 服务。\n如果确认操作，请手动输入 '立即重启'"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                }
                Section(L10n.t("确认")) {
                    TextField(L10n.t("立即重启"), text: $restartConfirm)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            } else {
                formSection
            }
        }
        .navigationTitle(isEditing ? L10n.t("编辑仓库") : L10n.t("添加仓库"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // http 二次确认步骤：前导按钮回到表单步骤（替代原 sheet 的「取消」分支）
            if confirmStep {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("上一步")) {
                        confirmStep = false
                        restartConfirm = ""
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSaving ? L10n.t("提交中…") : (confirmStep ? L10n.t("确认") : L10n.t("确认"))) {
                    Task { await submit() }
                }
                .disabled(!canSubmit || isSaving || (confirmStep && restartConfirm != L10n.t("立即重启")))
            }
        }
    }

    private var formSection: some View {
        Section {
            TextField(L10n.t("名称"), text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Toggle(L10n.t("认证"), isOn: $useAuth)
            if useAuth {
                TextField(L10n.t("用户名"), text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !isEditing {
                    HStack {
                        Group {
                            if showPassword {
                                TextField(L10n.t("密码"), text: $password)
                            } else {
                                SecureField(L10n.t("密码"), text: $password)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        Button { showPassword.toggle() } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            TextField(L10n.t("下载地址"), text: $downloadUrl)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Picker(L10n.t("协议"), selection: $useHTTPS) {
                Text("https").tag(true)
                Text("http").tag(false)
            }
            .pickerStyle(.segmented)
            Text(L10n.t("http 仓库添加授信需要重启 Docker 服务"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func submit() async {
        // http 协议：先进入二次确认步骤
        if !useHTTPS && !confirmStep {
            confirmStep = true
            return
        }
        isSaving = true
        defer { isSaving = false }

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = downloadUrl.trimmingCharacters(in: .whitespaces)
        let protocolStr = useHTTPS ? "https" : "http"

        let ok: Bool
        if let repo = editing {
            let req = RepoUpdateRequest(
                id: repo.id,
                createdAt: repo.createdAt ?? "",
                name: trimmedName,
                downloadUrl: trimmedURL,
                protocolField: protocolStr,
                username: useAuth ? username.trimmingCharacters(in: .whitespaces) : "",
                auth: useAuth,
                status: repo.status ?? "",
                message: repo.message ?? ""
            )
            ok = await vm.updateRepo(req)
        } else {
            let req = RepoCreateRequest(
                auth: useAuth,
                protocolField: protocolStr,
                name: trimmedName,
                downloadUrl: trimmedURL,
                username: useAuth ? username.trimmingCharacters(in: .whitespaces) : "",
                password: useAuth ? password : ""
            )
            ok = await vm.createRepo(req)
        }
        if ok {
            await onSaved()
            dismiss()
        }
    }
}

struct RepoRow: View {
    let repo: ContainerRepo

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "shippingbox.fill", color: .indigo, size: 34, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(repo.name ?? L10n.t("未知"))
                    .font(.subheadline.bold())
                if let url = repo.downloadUrl, !url.isEmpty {
                    Text(url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if repo.auth == true {
                        StatusBadge(text: L10n.t("已认证"), color: .green)
                    } else {
                        StatusBadge(text: L10n.t("公开"), color: .gray)
                    }
                    if let status = repo.status, !status.isEmpty {
                        let isSuccess = status.lowercased() == "success"
                        StatusBadge(
                            text: isSuccess ? L10n.t("正常") : status,
                            color: isSuccess ? .green : .orange                        )
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

