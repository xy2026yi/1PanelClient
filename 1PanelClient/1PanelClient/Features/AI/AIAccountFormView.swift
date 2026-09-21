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
        // 表单页内直接弹错误（否则 alert 挂在列表页，需返回上一层才能看到）
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
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
            OutlinedTextField(label: L10n.t("名称"), text: $name)

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
                OutlinedPicker(label: L10n.t("模型供应商"),
                               options: providers.map(\.provider),
                               selection: $selectedProvider,
                               optionLabels: Dictionary(uniqueKeysWithValues:
                                   providers.map { ($0.provider, $0.displayTitle) }))

                if let apiTypes = selectedProviderItem?.apiTypes, !apiTypes.isEmpty {
                    OutlinedPicker(label: L10n.t("API 类型"),
                                   options: apiTypes.map(\.apiType),
                                   selection: $selectedApiType)
                } else {
                    LabeledContent(L10n.t("API 类型"), value: "-")
                }
            }

            OutlinedTextField(label: "Base URL", prompt: "https://api.example.com/v1",
                              text: $baseURL, keyboardType: .URL)
                .disabled(!editableBaseURL)

            if !isEditing && authModeOptions.count > 1 {
                OutlinedPicker(label: L10n.t("认证方式"),
                               options: authModeOptions, selection: authModeBinding)
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
            // 眼睛切换内嵌描边框右侧（明文用等宽字体便于核对密钥）
            OutlinedShape(label: "API Key", isFocused: false,
                          hasValue: !apiKey.isEmpty,
                          trailing: {
                Button {
                    showApiKey.toggle()
                } label: {
                    Image(systemName: showApiKey ? "eye.slash" : "eye")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.t("显示密钥"))
            }) {
                if showApiKey {
                    TextField("", text: $apiKey)
                        .font(.dataMonospacedBody)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField("", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
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

    /// 创建模式的模型池：自动获取 / 手动配置（形态 3 下拉）+ 验证模型单选。
    /// 手动配置的模型编辑走入口行 → 子编辑页（与创建容器端口同模式）
    @State private var poolMode = "auto"
    /// 用户手动选过模型池模式后，联动不再自动覆盖
    @State private var poolModeUserSet = false

    private var modelPoolSection: some View {
        Section {
            OutlinedPicker(label: L10n.t("模型池"), options: ["auto", "manual"],
                           selection: Binding(
                               get: { poolMode },
                               set: { newValue in
                                   poolMode = newValue
                                   poolModeUserSet = true
                               }),
                           optionLabels: ["auto": L10n.t("自动获取"),
                                          "manual": L10n.t("手动配置")])

            if poolMode == "auto" {
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
                } else {
                    Text(L10n.t("当前 API 类型不支持自动获取，请切换为手动配置"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                NavigationLink {
                    AIModelsEditorView(models: $models)
                } label: {
                    HStack {
                        Text(L10n.t("模型"))
                        Spacer()
                        if models.isEmpty {
                            Text(L10n.t("未设置")).foregroundStyle(.secondary)
                        } else {
                            Text(L10n.f("%ld 条", models.count)).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if models.isEmpty {
                if poolMode == "auto" {
                    Text(L10n.t("暂无模型：可自动获取或手动添加"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        } header: {
            SectionLabel(title: L10n.t("模型池"), systemImage: "shippingbox")
        } footer: {
            if validateAvailability {
                Text(L10n.t("已开启可用性验证：点击模型选中验证所用模型"))
            } else {
                Text(L10n.t("自动获取支持当前 API 类型时可用；也可切换手动配置逐个添加"))
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
            OutlinedMultiLineField(label: L10n.t("备注"), prompt: L10n.t("可选"),
                                   lines: 1, text: $remark)
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
        // 预设供应商（DeepSeek 等）直接给固定模型清单；custom 为空靠发现/手填。
        // 模型池模式智能默认：支持自动发现→自动获取，否则（预设清单型）→手动配置；
        // 用户手动选过后不再随联动覆盖
        if !poolModeUserSet {
            poolMode = (apiType?.supportsModelDiscovery ?? false) ? "auto" : "manual"
        }
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
            // 模型池条目创建时统一 recordId=0（服务端按新纪录入库），空行（手动页未填完）丢弃
            let wantsVerify = validateAvailability && !isImageApi
            let poolModels = models
                .filter { !$0.id.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { model -> AIModelRef in
                    var m = model
                    m.recordId = 0
                    return m
                }
            // 验证模型被手动页删掉时回落到首个模型
            var effectiveVerify = verifyModelId
            if wantsVerify && !poolModels.contains(where: { $0.id == effectiveVerify }) {
                effectiveVerify = poolModels.first?.id ?? ""
            }
            let ok = await vm.create(req: AIAccountCreateRequest(
                provider: selectedProvider,
                name: name,
                baseURL: baseURL,
                apiKey: apiKey,
                rememberApiKey: rememberApiKey,
                apiType: selectedApiType,
                authMode: authMode,
                verifyModel: wantsVerify ? effectiveVerify : "",
                validateAvailability: wantsVerify,
                models: poolModels,
                remark: remark
            ))
            if ok { dismiss() }
        }
    }
}

// MARK: - 模型手动编辑页（入口行 → 行编辑，与创建容器端口/挂载编辑页同模式）

/// 手动配置模型池：每行 = 模型 ID + 名称（可选）两个描边框，行右侧删除、底部添加。
/// AIModelRef.id 为常量，编辑经绑定整行重建（按数组下标定位，防空 id 重复键告警）
struct AIModelsEditorView: View {
    @Binding var models: [AIModelRef]

    var body: some View {
        Form {
            ForEach(Array(models.enumerated()), id: \.offset) { idx, _ in
                Section {
                    OutlinedTextField(label: L10n.t("模型"), text: modelIDBinding(idx))
                    OutlinedTextField(label: L10n.t("名称"), prompt: L10n.t("可选"),
                                      text: modelNameBinding(idx))
                } header: {
                    // 样式 A（与负载均衡节点一致）：节头序号 + 节头删除
                    HStack {
                        Text(L10n.f("模型-%ld", idx + 1))
                        Spacer()
                        Button {
                            models.remove(at: idx)
                        } label: {
                            Label(L10n.t("删除模型"), systemImage: "trash")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .accessibilityLabel(L10n.t("删除"))
                    }
                }
            }
            Section {
                Button {
                    models.append(AIModelRef(recordId: 0, id: "", name: nil))
                } label: {
                    Label(L10n.t("添加"), systemImage: "plus.circle")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .navigationTitle(L10n.t("模型"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func modelIDBinding(_ idx: Int) -> Binding<String> {
        Binding(
            get: { models.indices.contains(idx) ? models[idx].id : "" },
            set: { newValue in
                guard models.indices.contains(idx) else { return }
                models[idx] = AIModelRef(recordId: models[idx].recordId,
                                         id: newValue,
                                         name: models[idx].name)
            }
        )
    }

    private func modelNameBinding(_ idx: Int) -> Binding<String> {
        Binding(
            get: { models.indices.contains(idx) ? (models[idx].name ?? "") : "" },
            set: { newValue in
                guard models.indices.contains(idx) else { return }
                models[idx] = AIModelRef(recordId: models[idx].recordId,
                                         id: models[idx].id,
                                         name: newValue.isEmpty ? nil : newValue)
            }
        )
    }
}
