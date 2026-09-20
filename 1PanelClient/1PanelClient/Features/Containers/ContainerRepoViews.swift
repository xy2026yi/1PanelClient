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
    /// 列表加载失败（渲染页内错误态 + 重试）
    @State private var loadError: String?
    @State private var showCreate = false
    /// 当前编辑的仓库（sheet(item:)）
    @State private var editingRepo: ContainerRepo?
    @State private var pendingDelete: ContainerRepo?
    /// 长按弹出的操作菜单目标
    @State private var actionRepo: ContainerRepo?

    var body: some View {
        Group {
            if isLoading && repos.isEmpty {
                LoadingStateView()
            } else if let err = loadError, repos.isEmpty {
                LoadErrorStateView(message: err) {
                    Task { await loadRepos() }
                }
            } else if repos.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无仓库"),
                    systemImage: "shippingbox",
                    description: Text(L10n.t("这台服务器上没有配置镜像仓库"))
                )
            } else {
                List {
                    ForEach(repos) { repo in
                        RepoRow(repo: repo)
                            .contentShape(Rectangle())
                            // 长按弹窗：编辑 / 同步 / 删除（替代原点击直进编辑 + 滑动操作）
                            .onLongPressGesture {
                                actionRepo = repo
                            }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await loadRepos() }
            }
        }
        .navigationTitle(L10n.t("仓库"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("创建仓库"))
            }
        }
        .navigationDestination(isPresented: $showCreate) {
            RepoFormView(editing: nil, vm: vm) { await loadRepos() }
        }
        .navigationDestination(item: $editingRepo) { repo in
            RepoFormView(editing: repo, vm: vm) { await loadRepos() }
        }
        // 长按操作弹窗：编辑 / 同步 / 删除
        .sheet(isPresented: Binding(
            get: { actionRepo != nil },
            set: { if !$0 { actionRepo = nil } }
        )) {
            ActionBottomSheet(
                title: actionRepo?.name ?? L10n.t("仓库"),
                items: [
                    ActionMenuItem(title: L10n.t("编辑"), icon: "pencil", color: .blue) {
                        let repo = actionRepo
                        actionRepo = nil
                        if let repo { editingRepo = repo }
                    },
                    ActionMenuItem(title: L10n.t("同步"), icon: "arrow.triangle.2.circlepath", color: .green) {
                        let repo = actionRepo
                        actionRepo = nil
                        if let repo { Task { await sync(repo) } }
                    },
                    ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red, role: .destructive) {
                        pendingDelete = actionRepo
                        actionRepo = nil
                    },
                ],
                onDismiss: { actionRepo = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: 3))])
            .presentationDragIndicator(.visible)
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
                Haptic.warning()
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
        .toastOverlay(message: $vm.toastMessage)
        .task { await loadRepos() }
    }

    private func loadRepos() async {
        isLoading = true
        defer { isLoading = false }
        do {
            repos = try await vm.loadRepos()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
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
                    OutlinedTextField(label: L10n.t("立即重启"), prompt: L10n.t("立即重启"), text: $restartConfirm, machineValue: false)
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
                Button(isSaving ? L10n.t("保存中…") : (confirmStep ? L10n.t("确认") : L10n.t("保存"))) {
                    Task { await submit() }
                }
                .disabled(!canSubmit || isSaving || (confirmStep && restartConfirm != L10n.t("立即重启")))
            }
        }
    }

    private var formSection: some View {
        Section {
            OutlinedTextField(label: L10n.t("名称"), text: $name)
            Toggle(L10n.t("认证"), isOn: $useAuth)
            if useAuth {
                OutlinedTextField(label: L10n.t("用户名"), text: $username)
                if !isEditing {
                    // 密码框右侧眼睛切换明文/密文（与密码访问账号一致）
                    OutlinedShape(label: L10n.t("密码"), isFocused: false,
                                  hasValue: !password.isEmpty,
                                  trailing: {
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showPassword ? L10n.t("隐藏密码") : L10n.t("显示密码"))
                    }) {
                        if showPassword {
                            TextField("", text: $password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("", text: $password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                }
            }
            OutlinedTextField(label: L10n.t("下载地址"), prompt: "docker.io",
                              text: $downloadUrl, keyboardType: .URL)
            OutlinedPicker(label: L10n.t("协议"), options: ["https", "http"],
                           selection: Binding(
                               get: { useHTTPS ? "https" : "http" },
                               set: { useHTTPS = $0 == "https" }))
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
            IconBadge(systemName: "shippingbox.fill", color: .indigo, size: 34, cornerRadius: Radius.small)
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

