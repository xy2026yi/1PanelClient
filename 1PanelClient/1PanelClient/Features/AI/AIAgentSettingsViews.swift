//
//  AIAgentSettingsViews.swift
//  1PanelClient
//
//  智能体 · 配置：
//  - AIAgentModelConfigView 模型配置（账号/主模型下拉联动，/agents/model/*）
//  - AIAgentSettingsView    其他设置（时区/用户名/密码，/agents/other/*）+ 配置文件只读（/agents/config-file/get）
//

import SwiftUI

// MARK: - 模型配置

struct AIAgentModelConfigView: View {
    let server: ServerConfig
    let agentId: Int

    @Environment(\.dismiss) private var dismiss

    @State private var config: AIAgentModelConfig?
    @State private var accounts: [AIAccount] = []
    @State private var selectedAccountId: Int?
    @State private var selectedModel = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var loadError: String?
    @State private var errorMessage: String?
    @State private var showError = false

    private let client: APIClient

    init(server: ServerConfig, agentId: Int) {
        self.server = server
        self.agentId = agentId
        self.client = APIClient.shared(for: server)
    }

    private var selectedAccount: AIAccount? {
        accounts.first { $0.id == selectedAccountId }
    }

    private var canSubmit: Bool {
        selectedAccountId != nil && !selectedModel.isEmpty && !isSaving
    }

    var body: some View {
        Form {
            if isLoading {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            } else if let c = config {
                Section {
                    if accounts.isEmpty {
                        Text(L10n.t("暂无可用模型账号"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(L10n.t("模型账号"), selection: $selectedAccountId) {
                            ForEach(accounts) { account in
                                Text(account.name).tag(Optional(account.id))
                            }
                        }
                        Picker(L10n.t("主模型"), selection: $selectedModel) {
                            ForEach(selectedAccount?.models ?? []) { model in
                                Text(model.id).tag(model.id)
                            }
                        }
                    }
                    if let current = c.model, !current.isEmpty {
                        LabeledContent(L10n.t("当前模型"), value: current)
                    }
                } header: {
                    SectionLabel(title: L10n.t("模型配置"), systemImage: "brain")
                } footer: {
                    Text(L10n.t("更换账号后主模型将切换到该账号的模型池"))
                }
            } else {
                Section {
                    LoadErrorStateView(message: loadError ?? "") {
                        Task { await load() }
                    }
                }
            }
        }
        .navigationTitle(L10n.t("模型"))
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
        .task { await load() }
        .onChange(of: selectedAccountId) { _, newValue in
            // 切换账号时主模型回落到该账号池中的当前值或首个
            if let model = config?.model,
               let account = accounts.first(where: { $0.id == newValue }),
               account.models?.contains(where: { $0.id == model }) == true {
                selectedModel = model
            } else {
                selectedModel = selectedAccount?.models?.first?.id ?? ""
            }
        }
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func load() async {
        do {
            config = try await client.send(
                path: APIEndpoint.aiAgentModelGet.path,
                body: AIAgentModelRequest(agentId: agentId),
                as: AIAgentModelConfig.self)
            let resp: PageResponse<AIAccount> = try await client.send(
                path: APIEndpoint.aiAccountsSearch.path,
                body: AISearchPageRequest(page: 1, pageSize: 200),
                as: PageResponse<AIAccount>.self)
            accounts = resp.items ?? []
            selectedAccountId = config?.accountId ?? accounts.first?.id
            if let model = config?.model, !model.isEmpty {
                selectedModel = model
            } else {
                selectedModel = selectedAccount?.models?.first?.id ?? ""
            }
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        guard let accountId = selectedAccountId else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentModelUpdate.path,
                body: AIAgentModelUpdateRequest(
                    agentId: agentId,
                    accountId: accountId,
                    model: selectedModel,
                    fallbacks: config?.fallbacks ?? []),
                as: EmptyResponse.self)
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - 设置（其他 + 配置文件）

struct AIAgentSettingsView: View {
    let server: ServerConfig
    let agentId: Int

    @State private var config: AIAgentOtherConfig?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var loadError: String?
    @State private var errorMessage: String?
    @State private var showError = false

    // 表单
    @State private var timezone = "Asia/Shanghai"
    @State private var browserEnabled = true
    @State private var npmRegistry = "https://registry.npmjs.org/"
    @State private var username = "admin"
    @State private var password = ""
    @State private var showPassword = false

    // 配置文件
    @State private var configFile: String?
    @State private var isLoadingConfigFile = false
    @State private var configFileError: String?
    @State private var showConfigFile = false

    private let client: APIClient

    /// 常用时区（settings 页 device/zone/options 接口可选时区过多，取常用子集）
    private let timezones = [
        "Asia/Shanghai", "Asia/Hong_Kong", "Asia/Taipei", "Asia/Tokyo",
        "Asia/Singapore", "Asia/Seoul", "Asia/Kolkata", "Asia/Dubai",
        "Europe/London", "Europe/Paris", "Europe/Berlin", "Europe/Moscow",
        "America/New_York", "America/Chicago", "America/Los_Angeles",
        "Australia/Sydney", "UTC"
    ]

    init(server: ServerConfig, agentId: Int) {
        self.server = server
        self.agentId = agentId
        self.client = APIClient.shared(for: server)
    }

    private var canSubmit: Bool {
        !username.isEmpty && !password.isEmpty && !isSaving
    }

    var body: some View {
        Form {
            if isLoading {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            } else if config != nil {
                Section {
                    Picker(L10n.t("时区"), selection: $timezone) {
                        ForEach(timezones, id: \.self) { tz in
                            Text(tz).tag(tz)
                        }
                    }
                } header: {
                    SectionLabel(title: L10n.t("其他"), systemImage: "gearshape")
                }

                Section {
                    TextField(L10n.t("用户名"), text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        if showPassword {
                            TextField(L10n.t("密码"), text: $password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(.body, design: .monospaced))
                        } else {
                            SecureField(L10n.t("密码"), text: $password)
                        }
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L10n.t("显示密码"))
                        Button {
                            UIPasteboard.general.string = password
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .disabled(password.isEmpty)
                        .accessibilityLabel(L10n.t("复制"))
                    }
                } header: {
                    SectionLabel(title: L10n.t("控制台账号"), systemImage: "person.crop.circle")
                } footer: {
                    Text(L10n.t("用于登录智能体 Web 控制台"))
                }

                Section {
                    NavigationLink {
                        configFileView
                    } label: {
                        Label(L10n.t("配置文件"), systemImage: "doc.text")
                    }
                }
            } else {
                Section {
                    LoadErrorStateView(message: loadError ?? "") {
                        Task { await load() }
                    }
                }
            }
        }
        .navigationTitle(L10n.t("设置"))
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
        .task { await load() }
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// 配置文件只读视图（加载失败不落地，防误存空内容）
    private var configFileView: some View {
        Group {
            if isLoadingConfigFile {
                LoadingStateView()
            } else if let content = configFile {
                ScrollView {
                    Text(content)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                }
            } else {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "doc.text")
                } description: {
                    Text(configFileError ?? "")
                } actions: {
                    Button(L10n.t("重试")) {
                        Task { await loadConfigFile() }
                    }
                }
            }
        }
        .navigationTitle(L10n.t("配置文件"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = configFile ?? ""
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(configFile == nil)
                .accessibilityLabel(L10n.t("复制"))
            }
        }
        .task { await loadConfigFile() }
    }

    private func load() async {
        do {
            let c = try await client.send(
                path: APIEndpoint.aiAgentOtherGet.path,
                body: AIAgentModelRequest(agentId: agentId),
                as: AIAgentOtherConfig.self)
            config = c
            timezone = c.userTimezone ?? "Asia/Shanghai"
            browserEnabled = c.browserEnabled ?? true
            npmRegistry = c.npmRegistry ?? "https://registry.npmjs.org/"
            username = c.dashboardUsername ?? "admin"
            password = c.dashboardPassword ?? ""
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func loadConfigFile() async {
        isLoadingConfigFile = true
        defer { isLoadingConfigFile = false }
        do {
            let resp: AIAgentConfigFile = try await client.send(
                path: APIEndpoint.aiAgentConfigFileGet.path,
                body: AIAgentConfigFileRequest(agentId: agentId),
                as: AIAgentConfigFile.self)
            configFile = resp.content
            configFileError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            configFile = nil
            configFileError = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentOtherUpdate.path,
                body: AIAgentOtherUpdateRequest(
                    agentId: agentId,
                    userTimezone: timezone,
                    browserEnabled: browserEnabled,
                    npmRegistry: npmRegistry,
                    dashboardUsername: username,
                    dashboardPassword: password),
                as: EmptyResponse.self)
            errorMessage = L10n.t("保存成功")
            showError = true
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = L10n.f("保存失败：%@", error.localizedDescription)
            showError = true
        }
    }
}
