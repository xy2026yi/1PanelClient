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
    /// Hermes 网页端无备用模型（抓包核对），隐藏该分区；其余类型不受影响
    var agentType: String? = nil

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
    /// 模型能力配置（账号模型池逐个：输入类型/上下文窗口/Max Tokens；
    /// 能力页保存后回写本镜像，父页保存时随请求带出）
    @State private var metadata: [AIAgentModelMetadata] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var loadError: String?
    @State private var errorMessage: String?
    @State private var showError = false

    private let client: APIClient

    init(server: ServerConfig, agentId: Int, agentType: String? = nil) {
        self.server = server
        self.agentId = agentId
        self.agentType = agentType
        self.client = APIClient.shared(for: server)
    }

    /// Hermes 专属判断（与详情页 isHermesAgent 同一取值）
    private var isHermes: Bool { agentType == "hermes-agent" }

    /// 模型能力配置（metadata）仅 OpenClaw 抓包验证过，其他类型隐藏入口防误提交
    private var isOpenClaw: Bool { agentType == "openclaw" }

    private var selectedAccount: AIAccount? {
        accounts.first { $0.id == selectedAccountId }
    }

    /// 备用模型候选：当前账号池中排除主模型与已选备用
    private var fallbackCandidates: [String] {
        let pool = selectedAccount?.models?.map(\.id) ?? []
        return pool.filter { $0 != selectedModel && !fallbacks.contains($0) }
    }

    /// 模型账号 Int? ↔ String（OutlinedPicker 用）
    private var accountIDText: Binding<String> {
        Binding<String>(
            get: { selectedAccountId.map(String.init) ?? "" },
            set: { selectedAccountId = Int($0) }
        )
    }

    private var canSubmit: Bool {
        selectedAccountId != nil && !selectedModel.isEmpty && !isSaving
    }

    var body: some View {
        Form {
            if isLoading {
                Section { LoadingStateView(compact: true) }
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
                        OutlinedPicker(label: L10n.t("模型账号"),
                                       options: accounts.map { String($0.id) },
                                       selection: accountIDText,
                                       optionLabels: Dictionary(uniqueKeysWithValues:
                                           accounts.map { (String($0.id), $0.name) }))
                        OutlinedPicker(label: L10n.t("主模型"),
                                       options: (selectedAccount?.models ?? []).map(\.id),
                                       selection: $selectedModel)

                        if isOpenClaw,
                           let account = selectedAccount,
                           let models = account.models, !models.isEmpty {
                            NavigationLink {
                                AIAgentModelCapabilityPage(
                                    server: server,
                                    agentId: agentId,
                                    accountId: account.id,
                                    models: models,
                                    currentModel: selectedModel,
                                    fallbacks: isHermes ? (config?.fallbacks ?? []) : fallbacks,
                                    initialMetadata: buildMetadata(models: models)) { updated in
                                    metadata = updated
                                }
                            } label: {
                                HStack {
                                    Text(L10n.t("模型能力配置"))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    if let current = c.model, !current.isEmpty {
                        // 当前生效模型（只读）：描边框展示
                        OutlinedShape(label: L10n.t("当前模型"), isFocused: false,
                                      hasValue: true, trailing: { EmptyView() }) {
                            Text(current)
                                .font(.dataMonospacedCaption)
                                .lineLimit(1)
                        }
                    }
                } header: {
                    SectionLabel(title: L10n.t("模型配置"), systemImage: "brain")
                } footer: {
                    Text(L10n.t("更换账号后主模型将切换到该账号的模型池"))
                }

                // 备用模型：主模型不可用时按顺序回退（抓包确认 fallbacks 数组）。
                // Hermes 网页端无备用模型，整个分区隐藏
                if !isHermes {
                    Section {
                        if fallbacks.isEmpty {
                            Text(L10n.t("暂无备用模型"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(fallbacks.enumerated()), id: \.offset) { _, model in
                                HStack {
                                    Text(model)
                                        .font(.dataMonospaced)
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
                            OutlinedPicker(label: L10n.t("备用模型"),
                                           options: [""] + fallbackCandidates,
                                           selection: $fallbackCandidate,
                                           optionLabels: ["": L10n.t("请选择")])
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
            // 模型能力镜像同备用模型处理：切走不携带原账号能力值（防止账号间
            // 同名模型串台写入），切回配置账号时还原服务端值
            if newValue != config?.accountId {
                metadata = []
            } else {
                metadata = config?.metadata ?? []
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
            metadata = config?.metadata ?? []
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

    /// 账号模型池逐个生成 metadata（顺序稳定；未配置项回落 auto/0/0）
    private func buildMetadata(models: [AIModelRef]) -> [AIAgentModelMetadata] {
        models.map { ref in
            metadata.first(where: { $0.model == ref.id })
                ?? AIAgentModelMetadata(model: ref.id)
        }
    }

    private func save() async {
        guard let accountId = selectedAccountId else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            // Hermes 无备用模型：回传服务端原值，防止隐藏状态下本地空数组误清
            let fallbacksToSend = isHermes ? (config?.fallbacks ?? []) : fallbacks
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentModelUpdate.path,
                body: AIAgentModelUpdateRequest(
                    agentId: agentId,
                    accountId: accountId,
                    model: selectedModel,
                    fallbacks: fallbacksToSend,
                    metadata: buildMetadata(models: selectedAccount?.models ?? [])),
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
    /// Hermes 网页端「其他」无浏览器/NPM 源（核对隐藏），仅保留时区
    private var isHermes: Bool { agentType == "hermes-agent" }

    /// NPM 源预设（抓包下拉项；腾讯源在文档中重复出现，取唯一集）
    private let npmMirrors = [
        "https://mirrors.cloud.tencent.com/npm/",
        "https://registry.npmjs.org/",
        "https://registry.npmmirror.com",
        "https://repo.huaweicloud.com/repository/npm/",
    ]

    /// NPM 源选项：当前值不在预设内时补一个键，避免无效 selection
    private var npmOptionKeys: [String] {
        var keys: [String] = []
        if !npmMirrors.contains(npmRegistry), !npmRegistry.isEmpty {
            keys.append(npmRegistry)
        }
        return keys + npmMirrors
    }

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
                Section { LoadingStateView(compact: true) }
            } else if config != nil {
                if isOpenClaw {
                    securitySection
                }

                if !isCopaw {
                    Section {
                        // Hermes 网页端无浏览器/NPM 源（核对隐藏），保存回传服务端原值
                        if !isHermes {
                            Toggle(L10n.t("浏览器"), isOn: $browserEnabled)
                            OutlinedPicker(label: L10n.t("NPM 源"),
                                           options: npmOptionKeys, selection: $npmRegistry)
                        }
                        OutlinedPicker(label: L10n.t("时区"), options: timezones,
                                       selection: $timezone)
                    } header: {
                        SectionLabel(title: L10n.t("其他"), systemImage: "gearshape")
                    }
                }

                if !isOpenClaw {
                    Section {
                        OutlinedTextField(label: L10n.t("用户名"), text: $username)
                        // 眼睛切换 + 复制内嵌描边框右侧（明文等宽字体便于核对）
                        OutlinedShape(label: L10n.t("密码"), isFocused: false,
                                      hasValue: !password.isEmpty,
                                      trailing: {
                            HStack(spacing: 12) {
                                Button {
                                    showPassword.toggle()
                                } label: {
                                    Image(systemName: showPassword ? "eye.slash" : "eye")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(L10n.t("显示密码"))
                                Button {
                                    UIPasteboard.general.string = password
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption)
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.borderless)
                                .disabled(password.isEmpty)
                                .accessibilityLabel(L10n.t("复制"))
                            }
                        }) {
                            if showPassword {
                                TextField("", text: $password)
                                    .font(.dataMonospacedBody)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            } else {
                                SecureField("", text: $password)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
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
                        .font(.dataMonospacedCaption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                        .contentWidthLimit(860)
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
            // other/update：OpenClaw 不携带控制台账号字段、QwenPaw 不带时区（抓包确认）；
            // Hermes 隐藏的浏览器/NPM 源回传服务端原值（npmRegistry 状态被折叠过，取 config 原值）
            var otherReq = AIAgentOtherUpdateRequest(
                agentId: agentId,
                userTimezone: isCopaw ? nil : timezone,
                browserEnabled: isHermes ? (config?.browserEnabled ?? true) : browserEnabled,
                npmRegistry: isHermes ? (config?.npmRegistry ?? "") : npmRegistry)
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

// MARK: - 模型能力配置页（模型池逐个：输入类型 / 上下文窗口 / Max Tokens）

/// 账号模型池逐模型的能力映射：条目数与模型数一致且不可移除；
/// 保存走 agents/model/update 全量（账号/主模型/备用模型一并带出）。
/// 未设置上下文窗口/Max Tokens 时提交 0（服务端按模型默认值处理）。
struct AIAgentModelCapabilityPage: View {
    let server: ServerConfig
    let agentId: Int
    let accountId: Int
    let models: [AIModelRef]
    /// 父页当前主模型/备用模型（保存时原样带出，能力页不改这两项）
    let currentModel: String
    let fallbacks: [String]
    let initialMetadata: [AIAgentModelMetadata]
    /// 保存成功回调（回写父页 metadata 镜像）
    var onSaved: ([AIAgentModelMetadata]) -> Void

    @Environment(\.dismiss) private var dismiss

    /// 逐模型可编辑副本（输入类型 + 两个可选数值，空 = 0 提交）
    @State private var inputModes: [String: String] = [:]
    @State private var contextTexts: [String: String] = [:]
    @State private var maxTokensTexts: [String: String] = [:]
    @State private var didInit = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showError = false

    private let client: APIClient
    private let inputOptions = ["auto", "text", "image"]

    init(server: ServerConfig, agentId: Int, accountId: Int, models: [AIModelRef],
         currentModel: String, fallbacks: [String],
         initialMetadata: [AIAgentModelMetadata],
         onSaved: @escaping ([AIAgentModelMetadata]) -> Void) {
        self.server = server
        self.agentId = agentId
        self.accountId = accountId
        self.models = models
        self.currentModel = currentModel
        self.fallbacks = fallbacks
        self.initialMetadata = initialMetadata
        self.onSaved = onSaved
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        Form {
            ForEach(models) { ref in
                Section {
                    OutlinedShape(label: L10n.t("模型"), isFocused: false,
                                  hasValue: true, trailing: { EmptyView() }) {
                        Text(ref.id)
                            .font(.dataMonospacedCaption)
                            .lineLimit(1)
                    }
                    OutlinedPicker(label: L10n.t("输入类型"), options: inputOptions,
                                   selection: Binding(
                                       get: { inputModes[ref.id] ?? "auto" },
                                       set: { inputModes[ref.id] = $0 }),
                                   optionLabels: [
                                    "auto": L10n.t("自动识别"),
                                    "text": L10n.t("仅文本"),
                                    "image": L10n.t("文本和图片")
                                   ])
                    OutlinedUnitField(label: L10n.t("上下文窗口"), unit: "",
                                      prompt: L10n.t("使用模型默认值"),
                                      text: Binding(
                                          get: { contextTexts[ref.id] ?? "" },
                                          set: { contextTexts[ref.id] = $0 }))
                    OutlinedUnitField(label: "Max Tokens", unit: "",
                                      prompt: L10n.t("使用模型默认值"),
                                      text: Binding(
                                          get: { maxTokensTexts[ref.id] ?? "" },
                                          set: { maxTokensTexts[ref.id] = $0 }))
                } header: {
                    Text(ref.id)
                }
            }
        }
        .navigationTitle(L10n.t("模型能力配置"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                }
                .disabled(isSaving)
            }
        }
        .onAppear {
            guard !didInit else { return }
            didInit = true
            for item in initialMetadata {
                inputModes[item.model] = item.inputMode
                if item.contextWindow > 0 {
                    contextTexts[item.model] = String(item.contextWindow)
                }
                if item.maxTokens > 0 {
                    maxTokensTexts[item.model] = String(item.maxTokens)
                }
            }
        }
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// 全量 metadata：模型池逐个（顺序稳定），未填数值提交 0
    private func buildMetadata() -> [AIAgentModelMetadata] {
        models.map { ref in
            AIAgentModelMetadata(
                model: ref.id,
                inputMode: inputModes[ref.id] ?? "auto",
                contextWindow: Int(contextTexts[ref.id] ?? "") ?? 0,
                maxTokens: Int(maxTokensTexts[ref.id] ?? "") ?? 0)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let newMetadata = buildMetadata()
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentModelUpdate.path,
                body: AIAgentModelUpdateRequest(
                    agentId: agentId,
                    accountId: accountId,
                    model: currentModel,
                    fallbacks: fallbacks,
                    metadata: newMetadata),
                as: EmptyResponse.self)
            onSaved(newMetadata)
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
