//
//  AIAccountFormView.swift
//  1PanelClient
//
//  模型账号 创建/编辑表单：供应商预设联动（供应商→API类型→BaseURL/认证方式）、
//  模型池（自动发现 / 预设清单 / 手动添加）、验证账号可用性（单选验证模型）；
//  编辑模式供应商与 API 类型不可更改、API Key 必填、可选同步关联智能体
//

import SwiftUI

struct AIAccountFormView: View {
    let server: ServerConfig
    /// 编辑模式传入已有账号；创建模式传 nil
    let editing: AIAccount?
    @ObservedObject var vm: AIAccountViewModel
    @Environment(\.dismiss) private var dismiss

    // MARK: 表单状态

    @State private var providers: [AIProvider] = []
    @State private var isLoadingProviders = true

    @State private var name = ""
    @State private var selectedProvider = ""
    @State private var selectedApiType = ""
    @State private var authMode = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var showApiKey = false
    @State private var rememberApiKey = false
    @State private var validateAvailability = true
    @State private var remark = ""
    @State private var syncAgents = false

    // 模型池（创建模式）
    @State private var models: [AIModelRef] = []
    /// 验证账号可用性使用的模型 id（空 = 未选）
    @State private var verifyModelId = ""
    @State private var manualModelId = ""
    @State private var manualModelName = ""
    @State private var isDiscovering = false

    @State private var isSaving = false
    @State private var didFill = false

    private var isEditing: Bool { editing != nil }

    // MARK: 联动计算

    private var selectedProviderItem: AIProvider? {
        providers.first { $0.provider == selectedProvider }
    }

    private var selectedApiTypeItem: AIProviderApiType? {
        selectedProviderItem?.apiTypes?.first { $0.apiType == selectedApiType }
    }

    /// 该 API 类型下 Base URL 是否可编辑（DeepSeek 等固定地址）
    private var editableBaseURL: Bool {
        if isEditing { return true }
        return selectedApiTypeItem?.editableBaseUrl ?? true
    }

    /// 是否支持「获取模型」发现（custom 的 openai 系列为 true）
    private var supportsDiscovery: Bool {
        selectedApiTypeItem?.supportsModelDiscovery ?? false
    }

    /// 认证方式候选（如 anthropic 的 x-api-key / bearer）
    private var authModeOptions: [String] {
        selectedApiTypeItem?.authModes ?? []
    }

    /// 认证方式 Picker 的取值兜底：当前值不在候选内（含空串）时显示首个候选，
    /// 提交仍以 state 为准（applyApiTypeDefaults 已归一化）
    private var authModeBinding: Binding<String> {
        Binding(
            get: {
                if authModeOptions.contains(authMode) { return authMode }
                return authModeOptions.first ?? ""
            },
            set: { authMode = $0 }
        )
    }

    private var canSubmit: Bool {
        guard !isSaving, !name.isEmpty, !baseURL.isEmpty, !apiKey.isEmpty else { return false }
        if isEditing { return true }
        guard !selectedProvider.isEmpty, !selectedApiType.isEmpty else { return false }
        // 开启验证时必须选择验证模型（图片类型不支持验证）
        return isImageApi || !validateAvailability || !verifyModelId.isEmpty
    }

    var body: some View {
        Form {
            baseInfoSection
            authSection
            verifySection
            if !isEditing {
                modelPoolSection
            }
            if isEditing {
                syncSection
            }
            remarkSection
        }
        .navigationTitle(isEditing ? L10n.t("编辑账号") : L10n.t("添加账号"))
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
        .task { await prepare() }
        .onChange(of: selectedProvider) { _, _ in
            guard !isEditing else { return }
            onProviderChange()
        }
        .onChange(of: selectedApiType) { _, _ in
            guard !isEditing else { return }
            onApiTypeChange()
        }
    }

    // MARK: - Sections

    private var baseInfoSection: some View {
        Section {
            FormTextField(label: L10n.t("名称"), text: $name)

            if isEditing {
                LabeledContent(L10n.t("模型供应商"), value: editing?.providerName ?? editing?.provider ?? "")
                LabeledContent(L10n.t("API 类型"), value: editing?.apiType ?? "")
            } else if isLoadingProviders {
                HStack {
                    Text(L10n.t("模型供应商"))
                    Spacer()
                    ProgressView()
                }
            } else if providers.isEmpty {
                // 供应商列表加载失败（空）：占位展示，避免零选项 Picker 的
                // 空 selection 告警；重进或重试后恢复
                LabeledContent(L10n.t("模型供应商"), value: "-")
                LabeledContent(L10n.t("API 类型"), value: "-")
            } else {
                Picker(L10n.t("模型供应商"), selection: $selectedProvider) {
                    ForEach(providers) { p in
                        Text(p.displayTitle).tag(p.provider)
                    }
                }

                if let apiTypes = selectedProviderItem?.apiTypes, !apiTypes.isEmpty {
                    Picker(L10n.t("API 类型"), selection: $selectedApiType) {
                        ForEach(apiTypes) { t in
                            Text(t.apiType).tag(t.apiType)
                        }
                    }
                } else {
                    LabeledContent(L10n.t("API 类型"), value: "-")
                }
            }

            FormTextField(label: "Base URL", text: $baseURL, style: .stacked, keyboardType: .URL)
                .font(.dataMonospacedBody)
                .disabled(!editableBaseURL)

            if !isEditing && authModeOptions.count > 1 {
                Picker(L10n.t("认证方式"), selection: authModeBinding) {
                    ForEach(authModeOptions, id: \.self) { mode in
                        Text(mode).tag(mode)
                    }
                }
            }
        } header: {
            SectionLabel(title: L10n.t("基本信息"), systemImage: "info.circle")
        } footer: {
            if isImageApi {
                Text(L10n.t("图片账号请填写完整的图片生成接口 URL，系统不会自动补全路径，例如：http://127.0.0.1:8000/v1/images/generations"))
            } else if !editableBaseURL {
                Text(L10n.t("该 API 类型的访问地址由供应商固定，不可修改"))
            }
        }
    }

    /// openai-images 图片类型：Base URL 需完整接口地址，且不支持可用性验证（抓包确认）
    private var isImageApi: Bool {
        selectedApiTypeItem?.apiType == "openai-images" || editing?.apiType == "openai-images"
    }

    private var authSection: some View {
        Section {
            HStack {
                if showApiKey {
                    FormTextField(label: "API Key", text: $apiKey)
                        .font(.dataMonospacedBody)
                } else {
                    FormTextField(label: "API Key", text: $apiKey, isSecure: true)
                }
                Button {
                    showApiKey.toggle()
                } label: {
                    Image(systemName: showApiKey ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.t("显示密钥"))
            }
            Toggle(L10n.t("记住认证信息"), isOn: $rememberApiKey)
        } header: {
            SectionLabel(title: L10n.t("认证"), systemImage: "key")
        } footer: {
            if isEditing {
                Text(L10n.t("请重新输入 API Key 后保存"))
            } else {
                Text(L10n.t("勾选后密钥将保存在服务端，供其他功能直接调用"))
            }
        }
    }

    /// 编辑模式下账号原本就没有验证模型：无法在编辑表单里补选，
    /// 开关置灰说明（避免 UI 开着、提交时被静默置 false）
    private var isEditingWithoutVerifyModel: Bool {
        editing != nil && verifyModelId.isEmpty
    }

    private var verifySection: some View {
        Section {
            Toggle(L10n.t("验证账号可用性"), isOn: Binding(
                get: { validateAvailability && !isImageApi },
                set: { validateAvailability = isImageApi ? false : $0 }))
                .disabled(isEditingWithoutVerifyModel || isImageApi)
        } header: {
            SectionLabel(title: L10n.t("可用性验证"), systemImage: "checkmark.seal")
        } footer: {
            if isImageApi {
                Text(L10n.t("图片类型账号不支持可用性验证"))
            } else if isEditingWithoutVerifyModel {
                Text(L10n.t("该账号未设置验证模型，编辑时无法启用验证（验证模型在创建账号时选择）"))
            } else {
                Text(L10n.t("开启后保存时将使用所选验证模型测试账号连接，不可用时保存失败"))
            }
        }
    }

    /// 创建模式的模型池：发现 / 预设清单 / 手动添加 + 验证模型单选
    private var modelPoolSection: some View {
        Section {
            if supportsDiscovery {
                Button {
                    Task { await discover() }
                } label: {
                    HStack {
                        Label(L10n.t("获取模型"), systemImage: "arrow.down.circle")
                        Spacer()
                        if isDiscovering { ProgressView() }
                    }
                }
                .disabled(isDiscovering || apiKey.isEmpty || baseURL.isEmpty)
            }

            if models.isEmpty {
                Text(L10n.t("暂无模型：可自动获取或手动添加"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(models) { model in
                    Button {
                        if validateAvailability {
                            verifyModelId = model.id
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.id)
                                    .font(.dataMonospaced)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if let display = model.name, !display.isEmpty, display != model.id {
                                    Text(display)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if validateAvailability {
                                if verifyModelId == model.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    let removed = offsets.map { models[$0].id }
                    models.remove(atOffsets: offsets)
                    if removed.contains(verifyModelId) {
                        verifyModelId = models.first?.id ?? ""
                    }
                }
            }

            HStack(spacing: 8) {
                FormTextField(label: L10n.t("模型"), text: $manualModelId)
                    .font(.dataMonospacedCaption)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                FormTextField(label: L10n.t("名称"), text: $manualModelName)
                Button {
                    addManualModel()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(manualModelId.isEmpty ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.borderless)
                .disabled(manualModelId.isEmpty)
                .accessibilityLabel(L10n.t("添加模型"))
            }
        } header: {
            SectionLabel(title: L10n.t("模型池"), systemImage: "shippingbox")
        } footer: {
            if validateAvailability {
                Text(L10n.t("已开启可用性验证：点击模型选中验证所用模型"))
            } else {
                Text(L10n.t("自动获取支持当前 API 类型时可用；也可在下方手动输入模型与名称逐个添加"))
            }
        }
    }

    private var syncSection: some View {
        Section {
            Toggle(L10n.t("同步关联智能体"), isOn: $syncAgents)
        } header: {
            SectionLabel(title: L10n.t("关联"), systemImage: "arrow.triangle.2.circlepath")
        } footer: {
            Text(L10n.t("勾选后连接信息变更将同步到使用该账号的智能体"))
        }
    }

    private var remarkSection: some View {
        Section {
            FormTextField(label: L10n.t("备注"), text: $remark, axis: .vertical, machineValue: false)
                .lineLimit(1...3)
        } header: {
            SectionLabel(title: L10n.t("备注"), systemImage: "text.alignleft")
        }
    }

    // MARK: - 数据准备与联动

    private func prepare() async {
        guard !didFill else { return }
        didFill = true

        if let account = editing {
            name = account.name
            selectedProvider = account.provider
            selectedApiType = account.apiType ?? ""
            authMode = account.authMode ?? ""
            baseURL = account.baseUrl ?? ""
            rememberApiKey = account.rememberApiKey ?? false
            validateAvailability = false
            verifyModelId = account.verifyModel ?? ""
            remark = account.remark ?? ""
            isLoadingProviders = false
        } else {
            let loaded = await vm.loadProviders()
            providers = loaded
            isLoadingProviders = false
            if let first = loaded.first {
                selectedProvider = first.provider
                applyProviderDefaults(first)
            }
        }
    }

    /// 选中供应商后：默认 API 类型 → BaseURL / 认证方式 / 预设模型
    private func applyProviderDefaults(_ provider: AIProvider) {
        let apiType = provider.apiTypes?.first { $0.apiType == provider.defaultApiType }
            ?? provider.apiTypes?.first
        selectedApiType = apiType?.apiType ?? ""
        applyApiTypeDefaults(apiType, provider: provider)
    }

    private func applyApiTypeDefaults(_ apiType: AIProviderApiType?, provider: AIProvider?) {
        baseURL = apiType?.baseUrl ?? provider?.baseUrl ?? ""
        // 服务端预设可能缺 defaultAuthMode 或取值不在候选内：
        // 回退到首个候选，避免认证方式 Picker 出现无 tag 的空 selection 告警
        let modes = apiType?.authModes ?? []
        let def = apiType?.defaultAuthMode ?? ""
        authMode = modes.contains(def) ? def : (modes.first ?? "")
        // 预设供应商（DeepSeek 等）直接给固定模型清单；custom 为空靠发现/手填
        models = provider?.models ?? []
        verifyModelId = models.first?.id ?? ""
    }

    /// 供应商切换联动（API 类型回到默认，模型池重置）
    private func onProviderChange() {
        guard let provider = selectedProviderItem else { return }
        applyProviderDefaults(provider)
    }

    /// API 类型切换联动（BaseURL / 认证方式 / 模型池重置）
    private func onApiTypeChange() {
        applyApiTypeDefaults(selectedApiTypeItem, provider: selectedProviderItem)
    }

    private func addManualModel() {
        let id = manualModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !models.contains(where: { $0.id == id }) else { return }
        let display = manualModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        models.append(AIModelRef(recordId: 0, id: id, name: display.isEmpty ? id : display))
        if verifyModelId.isEmpty { verifyModelId = id }
        manualModelId = ""
        manualModelName = ""
    }

    private func discover() async {
        isDiscovering = true
        defer { isDiscovering = false }
        if let discovered = await vm.discoverModels(
            provider: selectedProvider,
            baseURL: baseURL,
            apiKey: apiKey,
            apiType: selectedApiType
        ) {
            models = discovered
            verifyModelId = discovered.first?.id ?? ""
            if discovered.isEmpty {
                vm.toastMessage = L10n.t("未发现可用模型")
            }
        }
    }

    // MARK: - 保存

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        if let account = editing {
            let ok = await vm.update(req: AIAccountUpdateRequest(
                id: account.id,
                name: name,
                baseURL: baseURL,
                apiKey: apiKey,
                rememberApiKey: rememberApiKey,
                apiType: account.apiType ?? "",
                authMode: account.authMode ?? "",
                verifyModel: account.verifyModel ?? "",
                validateAvailability: validateAvailability && !verifyModelId.isEmpty,
                remark: remark,
                syncAgents: syncAgents
            ))
            if ok { dismiss() }
        } else {
            // 图片类型不支持可用性验证（抓包确认 validateAvailability=false）；
            // 模型池条目创建时统一 recordId=0（服务端按新纪录入库）
            let wantsVerify = validateAvailability && !isImageApi
            let poolModels = models.map { model -> AIModelRef in
                var m = model
                m.recordId = 0
                return m
            }
            let ok = await vm.create(req: AIAccountCreateRequest(
                provider: selectedProvider,
                name: name,
                baseURL: baseURL,
                apiKey: apiKey,
                rememberApiKey: rememberApiKey,
                apiType: selectedApiType,
                authMode: authMode,
                verifyModel: wantsVerify ? verifyModelId : "",
                validateAvailability: wantsVerify,
                models: poolModels,
                remark: remark
            ))
            if ok { dismiss() }
        }
    }
}
