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
    /// 账号列表加载失败（与「真无账号」区分）
    @State private var accountsLoadFailed = false
    @State private var selectedAccountId: Int?
    @State private var selectedModel = ""
    /// 备用模型（主模型不可用时按顺序回退）
    @State private var fallbacks: [String] = []
    @State private var fallbackCandidate = ""
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

    /// 备用模型候选：当前账号池中排除主模型与已选备用
    private var fallbackCandidates: [String] {
        let pool = selectedAccount?.models?.map(\.id) ?? []
        return pool.filter { $0 != selectedModel && !fallbacks.contains($0) }
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
                    if accountsLoadFailed {
                        // 配置已加载但账号列表失败：展示错误 + 重试，
                        // 不误显示为「暂无可用模型账号」
                        LoadErrorStateView(message: loadError ?? L10n.t("账号列表加载失败")) {
                            Task { await loadAccountsOnly() }
                        }
                        .listRowBackground(Color.clear)
                    } else if accounts.isEmpty {
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

                // 备用模型：主模型不可用时按顺序回退（抓包确认 fallbacks 数组）
                Section {
                    if fallbacks.isEmpty {
                        Text(L10n.t("暂无备用模型"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(fallbacks.enumerated()), id: \.offset) { _, model in
                            HStack {
                                Text(model)
                                    .font(.system(.subheadline, design: .monospaced))
                                Spacer()
                                Button {
                                    fallbacks.removeAll { $0 == model }
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(L10n.t("删除"))
                            }
                        }
                    }

                    if !fallbackCandidates.isEmpty {
                        Picker(L10n.t("备用模型"), selection: $fallbackCandidate) {
                            Text(L10n.t("请选择")).tag("")
                            ForEach(fallbackCandidates, id: \.self) { m in
                                Text(m).tag(m)
                            }
                        }
                        Button {
                            guard !fallbackCandidate.isEmpty else { return }
                            fallbacks.append(fallbackCandidate)
                            fallbackCandidate = ""
                        } label: {
                            Label(L10n.t("新增备用"), systemImage: "plus.circle")
                        }
                        .disabled(fallbackCandidate.isEmpty)
                    }
                } header: {
                    SectionLabel(title: L10n.t("备用模型"), systemImage: "arrow.triangle.branch")
                } footer: {
                    Text(L10n.t("主模型不可用时按列表顺序使用备用模型"))
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
            // 备用模型属于账号的模型池：切走清空待重选；切回配置账号时还原
            // 服务端值（滚轮 Picker 误滑再滑回是常见操作，不还原的话一次保存
            // 就会把服务端的备用模型清掉）。config 账号为 nil 时任何选择都算切走
            if newValue != config?.accountId {
                fallbacks = []
            } else {
                fallbacks = config?.fallbacks ?? []
            }
            fallbackCandidate = ""
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
            // 网页端模型页仅查文本类账号（textOnly，过滤 openai-images 图片账号）
            let resp: PageResponse<AIAccount> = try await client.send(
                path: APIEndpoint.aiAccountsSearch.path,
                body: AISearchPageRequest(page: 1, pageSize: 200, textOnly: true),
                as: PageResponse<AIAccount>.self)
            accounts = resp.items ?? []
            accountsLoadFailed = false
            selectedAccountId = config?.accountId ?? accounts.first?.id
            if let model = config?.model, !model.isEmpty {
                selectedModel = model
            } else {
                selectedModel = selectedAccount?.models?.first?.id ?? ""
            }
            fallbacks = config?.fallbacks ?? []
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            // config 已加载时仅账号请求失败：进错误态分支（loadAccountsOnly 重试）
            if config != nil { accountsLoadFailed = true }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    /// 仅重试账号列表（配置已加载、账号请求失败的分支）
    private func loadAccountsOnly() async {
        do {
            let resp: PageResponse<AIAccount> = try await client.send(
                path: APIEndpoint.aiAccountsSearch.path,
                body: AISearchPageRequest(page: 1, pageSize: 200, textOnly: true),
                as: PageResponse<AIAccount>.self)
            accounts = resp.items ?? []
            accountsLoadFailed = false
            if selectedAccountId == nil {
                selectedAccountId = config?.accountId ?? accounts.first?.id
                selectedModel = selectedAccount?.models?.first?.id ?? ""
            }
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
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
                    fallbacks: fallbacks),
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
    /// copaw(QwenPaw) 仅有控制台账号设置（抓包确认），隐藏时区与配置文件
    var agentType: String? = nil

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

    // 安全设置（OpenClaw）
    @State private var allowedOrigins: [String] = []
    /// security/get 失败标记：保存时跳过 security/update，
    /// 避免把读失败的空列表全量写回、清掉服务端白名单
    @State private var securityLoadFailed = false

    private let client: APIClient

    /// 常用时区（settings 页 device/zone/options 接口可选时区过多，取常用子集）
    private let timezones = [
        "Asia/Shanghai", "Asia/Hong_Kong", "Asia/Taipei", "Asia/Tokyo",
        "Asia/Singapore", "Asia/Seoul", "Asia/Kolkata", "Asia/Dubai",
        "Europe/London", "Europe/Paris", "Europe/Berlin", "Europe/Moscow",
        "America/New_York", "America/Chicago", "America/Los_Angeles",
        "Australia/Sydney", "UTC"
    ]

    init(server: ServerConfig, agentId: Int, agentType: String? = nil) {
        self.server = server
        self.agentId = agentId
        self.agentType = agentType
        self.client = APIClient.shared(for: server)
    }

    private var isCopaw: Bool { agentType == "copaw" }
    /// OpenClaw 设置页与其他类型不同：无控制台账号，另有「安全」（allowedOrigins）
    private var isOpenClaw: Bool { agentType == "openclaw" }

    /// NPM 源预设（抓包下拉项；腾讯源在文档中重复出现，取唯一集）
    private let npmMirrors = [
        "https://mirrors.cloud.tencent.com/npm/",
        "https://registry.npmjs.org/",
        "https://repo.huaweicloud.com/repository/npm/",
    ]

    private var canSubmit: Bool {
        // 加载失败（config 未落地）时禁止保存：@State 全是默认值，
        // 保存会用默认值覆盖服务端真实配置
        guard !isSaving, config != nil else { return false }
        // 控制台账号仅非 OpenClaw 类型显示（OpenClaw 抓包无该分区）
        if !isOpenClaw, username.isEmpty || password.isEmpty { return false }
        return true
    }

    var body: some View {
        Form {
            if isLoading {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            } else if config != nil {
                if isOpenClaw {
                    securitySection
                }

                if !isCopaw {
                    Section {
                        Toggle(L10n.t("浏览器"), isOn: $browserEnabled)
                        Picker(L10n.t("NPM 源"), selection: $npmRegistry) {
                            // 当前值不在预设内时补一个 tag，避免无效 selection 告警
                            if !npmMirrors.contains(npmRegistry), !npmRegistry.isEmpty {
                                Text(npmRegistry).tag(npmRegistry)
                            }
                            ForEach(npmMirrors, id: \.self) { mirror in
                                Text(mirror).tag(mirror)
                            }
                        }
                        Picker(L10n.t("时区"), selection: $timezone) {
                            ForEach(timezones, id: \.self) { tz in
                                Text(tz).tag(tz)
                            }
                        }
                    } header: {
                        SectionLabel(title: L10n.t("其他"), systemImage: "gearshape")
                    }
                }

                if !isOpenClaw {
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
                }

                if !isCopaw {
                    Section {
                        NavigationLink {
                            configFileView
                        } label: {
                            Label(L10n.t("配置文件"), systemImage: "doc.text")
                        }
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

    /// 安全设置（OpenClaw 专属）：allowedOrigins 多行编辑，一行一个
    private var securitySection: some View {
        Section {
            WhitelistEditor(title: L10n.t("允许的访问来源"), list: $allowedOrigins)
        } header: {
            SectionLabel(title: L10n.t("安全"), systemImage: "lock.shield")
        } footer: {
            Text(L10n.t("一行一个来源（协议+地址+端口），如 http://127.0.0.1:18789"))
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
            timezone = (c.userTimezone ?? "").isEmpty ? "Asia/Shanghai" : c.userTimezone!
            browserEnabled = c.browserEnabled ?? true
            // npmRegistry 可能返回空串（抓包确认）：折叠为首个预设，
            // 避免 Picker 空 selection 告警
            npmRegistry = (c.npmRegistry ?? "").isEmpty ? npmMirrors[0] : c.npmRegistry!
            username = (c.dashboardUsername ?? "").isEmpty ? "admin" : c.dashboardUsername!
            password = c.dashboardPassword ?? ""
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        if isOpenClaw {
            await loadSecurity()
        }
        isLoading = false
    }

    private func loadSecurity() async {
        do {
            let resp = try await client.send(
                path: APIEndpoint.aiAgentSecurityGet.path,
                body: AIAgentModelRequest(agentId: agentId),
                as: AIAgentSecurityConfig.self)
            allowedOrigins = resp.allowedOrigins ?? []
            securityLoadFailed = false
        } catch {
            // 读取失败置标记：保存时跳过该分区（发空列表会清掉服务端数据）
            allowedOrigins = []
            securityLoadFailed = true
        }
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
            // other/update：OpenClaw 不携带控制台账号字段（抓包确认）；
            // copaw 只有控制台账号分区（无其他分区），全量回传
            var otherReq = AIAgentOtherUpdateRequest(
                agentId: agentId,
                userTimezone: timezone,
                browserEnabled: browserEnabled,
                npmRegistry: npmRegistry)
            if !isOpenClaw {
                otherReq.dashboardUsername = username
                otherReq.dashboardPassword = password
            }
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentOtherUpdate.path,
                body: otherReq,
                as: EmptyResponse.self)

            // OpenClaw 的安全设置单独保存；读取失败时跳过（防止空列表覆盖服务端白名单）
            if isOpenClaw {
                if securityLoadFailed {
                    errorMessage = L10n.t("其他设置已保存；安全设置未加载，本次未保存")
                    showError = true
                    return
                }
                do {
                    let _: EmptyResponse = try await client.send(
                        path: APIEndpoint.aiAgentSecurityUpdate.path,
                        body: AIAgentSecurityConfig(agentId: agentId, allowedOrigins: allowedOrigins),
                        as: EmptyResponse.self)
                } catch {
                    guard !APIError.isCancellation(error) else { return }
                    errorMessage = L10n.f("安全设置保存失败：%@（其他设置已保存）", error.localizedDescription)
                    showError = true
                    return
                }
            }

            errorMessage = L10n.t("保存成功")
            showError = true
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = L10n.f("保存失败：%@", error.localizedDescription)
            showError = true
        }
    }
}
