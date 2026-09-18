//
//  AIAgentCreateView.swift
//  1PanelClient
//
//  智能体创建（POST /api/v2/ai/agents，本质为安装应用）：
//  类型联动（OpenClaw token/访问地址，其余用户名/密码）、版本列表、
//  模型账号→模型→BaseURL 联动、高级设置（对齐应用安装表单）
//

import SwiftUI

struct AIAgentCreateView: View {
    let server: ServerConfig
    @ObservedObject var vm: AIAgentsViewModel
    @Environment(\.dismiss) private var dismiss

    // MARK: 状态

    @State private var selectedTypeKey = AIAgentType.all[0].key
    @State private var name = ""
    @State private var remark = ""
    @State private var versions: [String] = []
    @State private var selectedVersion = ""
    @State private var isLoadingVersions = true

    @State private var webUIPort = ""

    // OpenClaw 专属
    @State private var allowedOrigin = ""
    @State private var token = ""

    // 非 OpenClaw 专属
    @State private var username = "admin"
    @State private var password = ""
    @State private var showPassword = true

    // 模型配置
    @State private var accounts: [AIAccount] = []
    /// 账号列表加载失败（与「无账号」区分，提供重试）
    @State private var accountsLoadFailed = false
    @State private var selectedAccountId: Int?
    @State private var selectedModel = ""

    // 高级设置（默认值对齐 AI.md 抓包）
    @State private var advancedEnabled = true
    @State private var containerName = ""
    @State private var allowPort = true
    @State private var specifyIP = ""
    @State private var restartPolicy = "unless-stopped"
    @State private var cpuQuota = 0
    @State private var memoryLimit = 0
    @State private var pullImage = true
    @State private var editCompose = false
    @State private var customCompose = ""

    @State private var showProgress = false
    @State private var activeTaskID = ""
    @State private var didLoad = false

    // 默认编排（/apps/detail/{appId}/{version}/app 的 dockerCompose）
    @State private var appStoreId = 0
    @State private var defaultCompose = ""
    @State private var composeLoadedKey = ""

    private let restartPolicies = ["no", "always", "on-failure", "unless-stopped"]
    /// CPU/内存 String ↔ Int（描边框接收 String；非法输入回落 0，0 = 不限制）
    private var cpuQuotaText: Binding<String> {
        Binding<String>(get: { String(cpuQuota) }, set: { cpuQuota = Int($0) ?? 0 })
    }
    private var memoryLimitText: Binding<String> {
        Binding<String>(get: { String(memoryLimit) }, set: { memoryLimit = Int($0) ?? 0 })
    }

    private var agentType: AIAgentType {
        AIAgentType.all.first { $0.key == selectedTypeKey } ?? AIAgentType.all[0]
    }

    private var selectedAccount: AIAccount? {
        accounts.first { $0.id == selectedAccountId }
    }

    /// 模型选中值：不在当前账号模型池时回落到首个，避免 Picker 无效 selection 告警
    private var modelSelection: Binding<String> {
        let ids = selectedAccount?.models?.map(\.id) ?? []
        return Binding(
            get: { ids.contains(selectedModel) ? selectedModel : (ids.first ?? "") },
            set: { selectedModel = $0 }
        )
    }

    private var portValue: Int { Int(webUIPort) ?? 0 }

    /// 分页校验：当前页必填满足才可下一步/提交（后续页字段不卡当前页）
    private var currentPageReady: Bool {
        switch wizardPage {
        case 0:
            // 基础页：名称/版本（+ 需模型类型的账号与模型）
            guard !name.isEmpty, !selectedVersion.isEmpty else { return false }
            if agentType.needsModel {
                let hasBaseURL = selectedAccount?.baseUrl?.isEmpty == false
                return hasBaseURL && !selectedModel.isEmpty
            }
            return true
        case 1:
            // 配置页：WebUI 端口
            return portValue > 0
        default:
            return canSubmit
        }
    }

    private var canSubmit: Bool {
        guard !name.isEmpty, !selectedVersion.isEmpty, portValue > 0, !vm.isSubmitting else { return false }
        // QwenPaw(copaw) 创建不绑定模型账号
        if agentType.needsModel {
            let hasBaseURL = selectedAccount?.baseUrl?.isEmpty == false
            guard hasBaseURL, !selectedModel.isEmpty else { return false }
        }
        if agentType.usesToken {
            return !token.isEmpty
        } else {
            return !username.isEmpty && !password.isEmpty
        }
    }

    /// 向导分页：0 基础（类型/名称/模型） 1 配置（WebUI/访问） 2 高级（默认收起）
    @State private var wizardPage = 0
    private let wizardPageNames = [L10n.t("基础"), L10n.t("配置"), L10n.t("高级")]

    var body: some View {
        VStack(spacing: 0) {
            WizardStepsBar(pageNames: wizardPageNames, current: wizardPage)
            Form {
                Group {
                    switch wizardPage {
                    case 0:
                        typeSection
                        if agentType.needsModel {
                            modelSection
                        }
                    case 1:
                        webUISection
                    default:
                        advancedToggleSection
                        if advancedEnabled {
                            advancedContainerSection
                            advancedResourceSection
                            advancedImageSection
                            if editCompose {
                                composeSection
                            }
                        }
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WizardBottomBar(
                page: wizardPage,
                totalPages: wizardPageNames.count,
                primaryTitle: L10n.t("创建"),
                isBusy: vm.isSubmitting,
                primaryDisabled: !currentPageReady,
                onBack: { withAnimation { wizardPage -= 1 } },
                onNext: { withAnimation { wizardPage += 1 } },
                onPrimary: { Task { await submit() } }
            )
        }
        .animation(.easeInOut(duration: 0.22), value: wizardPage)
        .navigationTitle(L10n.t("创建智能体"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .task { await load() }
        .onChange(of: selectedTypeKey) { _, newValue in
            Task {
                await applyTypeDefaults(newValue)
                // 从 QwenPaw 切到需绑定模型的类型时补拉账号
                if AIAgentType.all.first(where: { $0.key == newValue })?.needsModel == true,
                   accounts.isEmpty, !accountsLoadFailed {
                    await reloadAccounts()
                }
            }
        }
        .onChange(of: selectedAccountId) { _, _ in
            selectedModel = selectedAccount?.models?.first?.id ?? ""
        }
        .onChange(of: webUIPort) { _, newValue in
            // OpenClaw 访问地址默认跟随端口
            if agentType.usesToken, let port = Int(newValue), port > 0 {
                allowedOrigin = "http://127.0.0.1:\(port)"
            }
        }
        .onChange(of: selectedVersion) { _, _ in
            Task { await loadDefaultCompose() }
        }
        .onChange(of: editCompose) { _, on in
            if on { Task { await loadDefaultCompose() } }
        }
        .navigationDestination(isPresented: $showProgress) {
            TaskProgressView(taskID: activeTaskID, title: L10n.f("安装 %@", name)) { isDone in
                if isDone {
                    Task { await vm.load() }
                    // 分步收栈：进度页自行 dismiss 后再收创建表单
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        dismiss()
                    }
                }
                return false
            }
        }
    }

    // MARK: - Sections

    private var typeSection: some View {
        Section {
            Picker(L10n.t("智能体类型"), selection: $selectedTypeKey) {
                ForEach(AIAgentType.all) { t in
                    Text(t.displayName).tag(t.key)
                }
            }

            HStack {
                Text(L10n.t("名称")).foregroundStyle(.secondary)
                Spacer()
                TextField(agentType.displayName, text: $name)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if isLoadingVersions {
                HStack {
                    Text(L10n.t("应用版本"))
                    Spacer()
                    ProgressView()
                }
            } else {
                Picker(L10n.t("应用版本"), selection: $selectedVersion) {
                    ForEach(versions, id: \.self) { v in
                        Text(v).tag(v)
                    }
                }
            }

            OutlinedTextField(label: L10n.t("备注"), text: $remark, machineValue: false)
        } header: {
            SectionLabel(title: L10n.t("基本信息"), systemImage: "info.circle")
        } footer: {
            Text(L10n.t("创建智能体将安装对应应用，可在应用列表中管理"))
        }
    }

    private var modelSection: some View {
        Section {
            if accountsLoadFailed {
                LoadErrorStateView(message: L10n.t("账号列表加载失败")) {
                    Task { await reloadAccounts() }
                }
                .listRowBackground(Color.clear)
            } else if accounts.isEmpty {
                HStack {
                    Text(L10n.t("模型账号"))
                    Spacer()
                    Text(L10n.t("暂无可用账号"))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            } else {
                Picker(L10n.t("模型账号"), selection: $selectedAccountId) {
                    ForEach(accounts) { account in
                        Text(account.name).tag(Optional(account.id))
                    }
                }

                if let models = selectedAccount?.models, !models.isEmpty {
                    Picker(L10n.t("模型"), selection: modelSelection) {
                        ForEach(models) { model in
                            Text(model.id).tag(model.id)
                        }
                    }
                } else {
                    HStack {
                        Text(L10n.t("模型"))
                        Spacer()
                        Text(L10n.t("暂无可用模型"))
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }

            LabeledContent("Base URL") {
                Text(selectedAccount?.baseUrl ?? "-")
                    .font(.dataMonospacedCaption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SectionLabel(title: L10n.t("模型配置"), systemImage: "brain")
        } footer: {
            if accounts.isEmpty {
                Text(L10n.t("请先在模型账号页添加账号"))
            }
        }
    }

    private var webUISection: some View {
        Section {
            HStack {
                Text("WebUI " + L10n.t("端口")).foregroundStyle(.secondary)
                Spacer()
                TextField("18789", text: $webUIPort)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 120)
            }

            if agentType.usesToken {
                FormTextField(label: L10n.t("访问地址"), text: $allowedOrigin, style: .stacked, keyboardType: .URL)
                    .font(.dataMonospacedCaption)

                HStack {
                    Text("Token").foregroundStyle(.secondary)
                    Spacer()
                    Text(token)
                        .font(.dataMonospacedCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        UIPasteboard.general.string = token
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.t("复制"))
                }
            } else {
                OutlinedTextField(label: L10n.t("用户名"), text: $username)
                PasswordInputRow(password: $password, showPassword: $showPassword)
            }
        } header: {
            SectionLabel(title: L10n.t("访问配置"), systemImage: "globe")
        } footer: {
            if agentType.usesToken {
                Text(L10n.t("Token 由系统自动生成，用于 OpenClaw 控制台接入"))
            }
        }
    }

    private var advancedToggleSection: some View {
        Section {
            Toggle(L10n.t("高级设置"), isOn: $advancedEnabled)
        }
    }

    private var advancedContainerSection: some View {
        Section(L10n.t("容器")) {
            HStack {
                Text(L10n.t("容器名称")).foregroundStyle(.secondary)
                Spacer()
                TextField(L10n.t("留空则自动生成"), text: $containerName)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Toggle(L10n.t("端口外部访问"), isOn: $allowPort)
            if allowPort {
                HStack {
                    Text(L10n.t("绑定主机 IP")).foregroundStyle(.secondary)
                    Spacer()
                    TextField(L10n.t("留空则全部 IP"), text: $specifyIP)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 140)
                }
            }
            Picker(L10n.t("重启规则"), selection: $restartPolicy) {
                ForEach(restartPolicies, id: \.self) { Text($0).tag($0) }
            }
        }
    }

    private var advancedResourceSection: some View {
        Section {
            OutlinedUnitField(label: L10n.t("CPU核心数"), unit: L10n.t("核"),
                              text: cpuQuotaText, range: 0...1024)
            OutlinedUnitField(label: L10n.t("内存"), unit: "MB",
                              text: memoryLimitText, range: 0...9_999_999)
        } header: {
            Text(L10n.t("资源限制"))
        } footer: {
            Text(L10n.t("填 0 表示不限制"))
        }
    }

    private var advancedImageSection: some View {
        Section(L10n.t("镜像与编排")) {
            Toggle(L10n.t("拉取镜像"), isOn: $pullImage)
            Toggle(L10n.t("编辑 docker-compose.yml"), isOn: $editCompose)
        }
    }

    private var composeSection: some View {
        Section {
            TextEditor(text: $customCompose)
                .font(.dataMonospacedCaption)
                .frame(minHeight: 200)
        } header: {
            Text("docker-compose.yml")
        } footer: {
            Text(L10n.t("编辑后将使用自定义内容覆盖默认编排文件"))
        }
    }

    // MARK: - 数据加载

    private func load() async {
        guard !didLoad else { return }
        didLoad = true
        await applyTypeDefaults(selectedTypeKey, initial: true)
        await reloadAccounts()
        if !agentType.usesToken && password.isEmpty {
            password = PasswordInputRow.randomPassword()
        }
    }

    /// 拉取模型账号：失败置错误态（可重试），不误显示为「暂无可用账号」
    private func reloadAccounts() async {
        guard let list = await vm.loadAccounts() else {
            accountsLoadFailed = true
            return
        }
        accountsLoadFailed = false
        accounts = list
        if selectedAccount == nil {
            selectedAccountId = accounts.first?.id
            selectedModel = selectedAccount?.models?.first?.id ?? ""
        }
    }

    /// 切换智能体类型：名称/端口默认值、版本列表、token 重置
    private func applyTypeDefaults(_ key: String, initial: Bool = false) async {
        let type = AIAgentType.all.first { $0.key == key } ?? AIAgentType.all[0]
        name = type.defaultName
        if type.usesToken {
            token = Self.randomToken()
            webUIPort = "18789"
            allowedOrigin = "http://127.0.0.1:18789"
        } else {
            password = PasswordInputRow.randomPassword()
            if key == "hermes-agent" {
                webUIPort = "9119"
            } else if webUIPort == "18789" || webUIPort == "9119" || webUIPort.isEmpty {
                webUIPort = ""
            }
            allowedOrigin = ""
        }
        username = "admin"

        isLoadingVersions = true
        defaultCompose = ""
        composeLoadedKey = ""
        if let detail = await vm.loadAppDetail(key: key) {
            appStoreId = detail.id
            versions = detail.versions ?? []
            selectedVersion = versions.first ?? ""
            await loadDefaultCompose()
        } else {
            versions = []
            selectedVersion = ""
        }
        isLoadingVersions = false
    }

    /// 拉取当前版本的默认 docker-compose（编辑编排时预填）
    private func loadDefaultCompose() async {
        guard appStoreId > 0, !selectedVersion.isEmpty else { return }
        let loadKey = "\(appStoreId)/\(selectedVersion)"
        guard composeLoadedKey != loadKey else { return }
        composeLoadedKey = loadKey
        do {
            let detail: AppDetail = try await vm.client.send(
                path: APIEndpoint.appsDetailApp.path
                .replacingOccurrences(of: ":id", with: String(appStoreId))
                .replacingOccurrences(of: ":version", with: selectedVersion),
                method: "GET",
                as: AppDetail.self)
            let compose = detail.dockerCompose ?? ""
            // 用户未改动过时跟随新默认值
            if customCompose.isEmpty || customCompose == defaultCompose {
                customCompose = compose
            }
            defaultCompose = compose
        } catch {
            // 静默：编辑器保持现状
            composeLoadedKey = ""
        }
    }

    /// 32 位随机小写字母数字 Token（OpenClaw 接入用，对齐网页端行为）
    static func randomToken() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<32).compactMap { _ in chars.randomElement() })
    }

    // MARK: - 提交

    private func submit() async {
        let taskID = UUID().uuidString
        var req = AIAgentCreateRequest(
            name: name,
            remark: remark,
            appVersion: selectedVersion,
            webUIPort: portValue,
            agentType: agentType.key,
            taskID: taskID,
            advanced: advancedEnabled,
            containerName: containerName,
            allowPort: allowPort,
            specifyIP: specifyIP,
            restartPolicy: restartPolicy,
            cpuQuota: cpuQuota,
            memoryLimit: memoryLimit,
            // UI 单位固定 MB（无 M/G 切换），按 MB 语义提交 M
            memoryUnit: "M",
            pullImage: pullImage,
            editCompose: editCompose,
            dockerCompose: editCompose ? customCompose : ""
        )
        if agentType.needsModel {
            // QwenPaw(copaw) 创建请求不含模型绑定字段（抓包确认）
            guard let account = selectedAccount else { return }
            req.model = modelSelection.wrappedValue
            req.accountId = account.id
        }
        if agentType.usesToken {
            req.allowedOrigins = [allowedOrigin]
            req.token = token
        } else {
            req.dashboardUsername = username
            req.dashboardPassword = password
        }

        if let returnedID = await vm.create(req: req) {
            activeTaskID = returnedID
            showProgress = true
        }
    }
}
