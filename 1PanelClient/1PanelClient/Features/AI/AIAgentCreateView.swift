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
    @State private var memoryUnit = "M"
    @State private var pullImage = true
    @State private var editCompose = false
    @State private var customCompose = ""

    @State private var showProgress = false
    @State private var activeTaskID = ""
    @State private var didLoad = false

    private let restartPolicies = ["no", "always", "on-failure", "unless-stopped"]
    private let memoryUnits = ["M", "G"]

    private var agentType: AIAgentType {
        AIAgentType.all.first { $0.key == selectedTypeKey } ?? AIAgentType.all[0]
    }

    private var selectedAccount: AIAccount? {
        accounts.first { $0.id == selectedAccountId }
    }

    private var portValue: Int { Int(webUIPort) ?? 0 }

    private var canSubmit: Bool {
        let hasBaseURL = selectedAccount?.baseUrl?.isEmpty == false
        guard !name.isEmpty, !selectedVersion.isEmpty, portValue > 0,
              hasBaseURL, !selectedModel.isEmpty, !vm.isSubmitting else { return false }
        if agentType.usesToken {
            return !token.isEmpty
        } else {
            return !username.isEmpty && !password.isEmpty
        }
    }

    var body: some View {
        Form {
            typeSection
            modelSection
            webUISection
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
        .navigationTitle(L10n.t("创建智能体"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await submit() }
                } label: {
                    if vm.isSubmitting { ProgressView() } else { Text(L10n.t("创建")).bold() }
                }
                .disabled(!canSubmit)
            }
        }
        .task { await load() }
        .onChange(of: selectedTypeKey) { _, newValue in
            Task { await applyTypeDefaults(newValue) }
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
                TextField(agentType.displayName, text: $name)
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

            TextField(L10n.t("备注"), text: $remark)
        } header: {
            SectionLabel(title: L10n.t("基本信息"), systemImage: "info.circle")
        } footer: {
            Text(L10n.t("创建智能体将安装对应应用，可在应用列表中管理"))
        }
    }

    private var modelSection: some View {
        Section {
            if accounts.isEmpty {
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

                Picker(L10n.t("模型"), selection: $selectedModel) {
                    ForEach(selectedAccount?.models ?? []) { model in
                        Text(model.id).tag(model.id)
                    }
                }
            }

            LabeledContent("Base URL") {
                Text(selectedAccount?.baseUrl ?? "-")
                    .font(.system(.caption, design: .monospaced))
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
                TextField(L10n.t("访问地址"), text: $allowedOrigin)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(.caption, design: .monospaced))

                HStack {
                    Text("Token").foregroundStyle(.secondary)
                    Spacer()
                    Text(token)
                        .font(.system(.caption, design: .monospaced))
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
                TextField(L10n.t("用户名"), text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
                TextField(L10n.t("留空则自动生成"), text: $containerName)
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
            HStack {
                Text(L10n.t("CPU 核心")).foregroundStyle(.secondary)
                Spacer()
                TextField("0", value: $cpuQuota, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text(L10n.t("核"))
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            HStack {
                Text(L10n.t("内存限制")).foregroundStyle(.secondary)
                Spacer()
                TextField("0", value: $memoryLimit, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Picker("", selection: $memoryUnit) {
                    ForEach(memoryUnits, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 80)
            }
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
                .font(.system(.caption, design: .monospaced))
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
        accounts = await vm.loadAccounts()
        selectedAccountId = accounts.first?.id
        selectedModel = selectedAccount?.models?.first?.id ?? ""
        if !agentType.usesToken && password.isEmpty {
            password = PasswordInputRow.randomPassword()
        }
    }

    /// 切换智能体类型：名称/端口默认值、版本列表、token 重置
    private func applyTypeDefaults(_ key: String, initial: Bool = false) async {
        let type = AIAgentType.all.first { $0.key == key } ?? AIAgentType.all[0]
        name = type.displayName
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
        if let detail = await vm.loadAppDetail(key: key) {
            versions = detail.versions ?? []
            selectedVersion = versions.first ?? ""
        } else {
            versions = []
            selectedVersion = ""
        }
        isLoadingVersions = false
    }

    /// 32 位随机小写字母数字 Token（OpenClaw 接入用，对齐网页端行为）
    static func randomToken() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<32).compactMap { _ in chars.randomElement() })
    }

    // MARK: - 提交

    private func submit() async {
        guard let account = selectedAccount else { return }
        let taskID = UUID().uuidString
        var req = AIAgentCreateRequest(
            name: name,
            remark: remark,
            appVersion: selectedVersion,
            webUIPort: portValue,
            agentType: agentType.key,
            model: selectedModel,
            accountId: account.id,
            taskID: taskID,
            advanced: advancedEnabled,
            containerName: containerName,
            allowPort: allowPort,
            specifyIP: specifyIP,
            restartPolicy: restartPolicy,
            cpuQuota: cpuQuota,
            memoryLimit: memoryLimit,
            memoryUnit: memoryUnit,
            pullImage: pullImage,
            editCompose: editCompose,
            dockerCompose: editCompose ? customCompose : ""
        )
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
