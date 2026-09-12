//
//  AIVllmCreateView.swift
//  1PanelClient
//
//  vLLM 创建/编辑表单（/api/v2/xpack/vllm）：
//  类型 → 版本（apps/vllm 列表按前缀过滤）→ 镜像（按命名约定推导，可改）→
//  端口/模型目录（服务端目录选择）→ 命令模板联动 → 模型账号 Base URL 四选一 →
//  高级设置（容器名/外部访问/重启策略/资源限制/compose 编辑）
//
//  创建成功跳任务进度（operateNode=local）；编辑提交 update [推测端点]
//

import SwiftUI

/// POST compose / command-template/list 共用请求 {imageType}
private struct VllmImageTypeRequest: Encodable {
    let imageType: String
}

/// 重启规则选项（rawValue 为 compose restart 取值）
private enum VllmRestartPolicy: String, CaseIterable, Identifiable {
    case unlessStopped = "unless-stopped"
    case no = "no"
    case always = "always"
    case onFailure = "on-failure"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .unlessStopped: return L10n.t("未手动停止则重启")
        case .no: return L10n.t("不重启")
        case .always: return L10n.t("一直重启")
        case .onFailure: return L10n.t("失败后重启")
        }
    }
}

struct AIVllmCreateView: View {
    let server: ServerConfig
    @ObservedObject var vm: AIVllmViewModel
    /// 非空 = 编辑模式（提交 update）
    var instance: VllmInstance? = nil
    /// 创建成功回调（taskID，供进度页轮询）
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    // MARK: 表单状态

    @State private var name = "vLLM"
    @State private var imageType: VllmImageType = .nvidia
    @State private var appVersion = ""
    @State private var image = ""
    @State private var portText = "8000"
    @State private var modelDir = ""

    @State private var templates: [VllmCommandTemplate] = []
    /// 0 = 自定义（不关联模板）
    @State private var selectedTemplateID = 0
    @State private var command = ""

    @State private var syncModelAccount = true
    @State private var baseURLType: VllmBaseURLType = .systemIP
    @State private var baseURL = ""

    @State private var advanced = true
    @State private var containerName = ""
    @State private var allowPort = true
    @State private var specifyIP = ""
    @State private var restartPolicy = VllmRestartPolicy.unlessStopped
    @State private var cpuQuotaText = "0"
    @State private var memoryLimitText = "0"
    @State private var memoryUnit = "M"
    @State private var pullImage = true
    @State private var editCompose = false
    @State private var dockerCompose = ""

    // MARK: 弹层 / 加载

    @State private var showComposeEditor = false
    @State private var showDirPicker = false
    @State private var allVersions: [String] = []
    @State private var isLoadingMeta = true
    @State private var isSubmitting = false
    @State private var validationMessage: String?

    private let client: APIClient

    private var isEdit: Bool { instance != nil }

    init(server: ServerConfig,
         vm: AIVllmViewModel,
         instance: VllmInstance? = nil,
         onSubmit: @escaping (String) -> Void) {
        self.server = server
        self.vm = vm
        self.instance = instance
        self.onSubmit = onSubmit
        self.client = APIClient.shared(for: server)

        if let i = instance {
            _name = State(initialValue: i.name ?? "vLLM")
            _imageType = State(initialValue: VllmImageType(rawValue: i.imageType ?? "") ?? .nvidia)
            _appVersion = State(initialValue: i.appVersion ?? "")
            _image = State(initialValue: i.image ?? "")
            _portText = State(initialValue: String(i.port ?? 8000))
            _modelDir = State(initialValue: i.modelDir ?? "")
            _selectedTemplateID = State(initialValue: i.commandTemplateID ?? 0)
            _command = State(initialValue: i.command ?? "")
            _syncModelAccount = State(initialValue: i.syncModelAccount ?? true)
            _baseURLType = State(initialValue: VllmBaseURLType(rawValue: i.modelAccountBaseURLType ?? "") ?? .systemIP)
            _baseURL = State(initialValue: i.modelAccountBaseURL ?? "")
            _containerName = State(initialValue: i.containerName ?? "")
            _allowPort = State(initialValue: i.allowPort ?? true)
            _specifyIP = State(initialValue: i.specifyIP ?? "")
            _restartPolicy = State(initialValue: VllmRestartPolicy(rawValue: i.restartPolicy ?? "") ?? .unlessStopped)
            _cpuQuotaText = State(initialValue: Self.shortNumber(i.cpuQuota))
            _memoryLimitText = State(initialValue: Self.shortNumber(i.memoryLimit))
            _memoryUnit = State(initialValue: i.memoryUnit ?? "M")
            _pullImage = State(initialValue: i.pullImage ?? true)
            _editCompose = State(initialValue: i.editCompose ?? false)
            _dockerCompose = State(initialValue: i.dockerCompose ?? "")
        }
    }

    /// 2.0 显示为 2（表单数字输入尽量短）
    private static func shortNumber(_ v: Double?) -> String {
        guard let v else { return "0" }
        return v == v.rounded() ? String(Int(v)) : String(v)
    }

    // MARK: 视图

    var body: some View {
        NavigationStack {
            Form {
                basicSection
                commandSection
                accountSection
                advancedSection
                if let msg = validationMessage {
                    Section {
                        Text(msg)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(isEdit ? L10n.t("编辑实例") : L10n.t("创建实例"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEdit ? L10n.t("保存") : L10n.t("创建")) {
                        Task { await submit() }
                    }
                    .disabled(isSubmitting)
                }
            }
        }
        .task { await loadMeta() }
        .onChange(of: imageType) { _, _ in
            // 切类型：重选该类型最新版本（appVersion 变化联动镜像推导），
            // 重载命令模板与 compose，并按新端口/容器名刷新 Base URL
            selectedTemplateID = 0
            command = ""
            appVersion = availableVersions.first ?? ""
            refreshBaseURL()
            Task {
                await loadTemplates()
                await loadCompose()
            }
        }
        .sheet(isPresented: $showDirPicker) {
            DirectoryPickerSheet(client: client) { path in
                modelDir = path
            }
        }
        .sheet(isPresented: $showComposeEditor) {
            ComposeEditorSheet(compose: $dockerCompose)
        }
        .interactiveDismissDisabled(isSubmitting)
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.large])
    }

    // MARK: 基础

    private var availableVersions: [String] {
        var list = VllmImageMapper.versions(of: imageType, in: allVersions)
        // 编辑中的版本可能已从商店下架，保底保留当前类型下的当前值
        // （切到别的类型时不保留，避免混入不属于该类型的版本）
        if let current = instance?.appVersion, !current.isEmpty, !list.contains(current),
           imageType.rawValue == instance?.imageType {
            list.insert(current, at: 0)
        }
        return list
    }

    private var basicSection: some View {
        Section {
            TextField(L10n.t("名称"), text: $name)
                .disabled(isEdit)

            if isEdit {
                // 编辑时类型/版本不可修改（服务端约定），以信息行展示
                InfoRow(L10n.t("类型"), value: imageType.displayName)
                InfoRow(L10n.t("版本"), value: appVersion)
            } else {
                Picker(L10n.t("类型"), selection: $imageType) {
                    ForEach(VllmImageType.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }

                if isLoadingMeta && allVersions.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.7)
                        Text(L10n.t("加载版本列表…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker(L10n.t("版本"), selection: $appVersion) {
                        ForEach(availableVersions, id: \.self) { v in
                            Text(v).tag(v)
                        }
                    }
                    .onChange(of: appVersion) { _, newValue in
                        // 版本切换重新推导镜像（用户可再手动改）
                        if let mapped = VllmImageMapper.defaultImage(appVersion: newValue) {
                            image = mapped
                        }
                    }
                }
            }

            TextField(L10n.t("镜像"), text: $image)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))

            TextField(L10n.t("端口"), text: $portText)
                .keyboardType(.numberPad)
                .onChange(of: portText) { _, _ in refreshBaseURL() }

            HStack(spacing: 10) {
                TextField(L10n.t("模型目录"), text: $modelDir)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                Button {
                    showDirPicker = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.t("浏览目录"))
            }
        } header: {
            SectionLabel(title: L10n.t("基础设置"), systemImage: "gearshape")
        } footer: {
            Text(L10n.t("镜像按版本自动推导，通常无需修改；模型目录用于挂载权重文件"))
        }
    }

    // MARK: 启动命令

    private var commandSection: some View {
        Section {
            Picker(L10n.t("启动命令模板"), selection: $selectedTemplateID) {
                Text(L10n.t("自定义")).tag(0)
                ForEach(templates) { t in
                    Text(t.name ?? "#\(t.id)").tag(t.id)
                }
            }
            .onChange(of: selectedTemplateID) { _, newValue in
                if let t = templates.first(where: { $0.id == newValue }) {
                    command = t.command ?? ""
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("启动命令"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $command)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 110)
                    .scrollContentBackground(.hidden)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        } header: {
            SectionLabel(title: L10n.t("启动命令"), systemImage: "terminal")
        } footer: {
            Text(L10n.t("模板选择后自动填入，可手动调整启动参数"))
        }
    }

    // MARK: 模型账号

    private var accountSection: some View {
        Section {
            Toggle(L10n.t("同步到模型账号"), isOn: $syncModelAccount)

            if syncModelAccount {
                Picker(L10n.t("访问地址"), selection: $baseURLType) {
                    ForEach(VllmBaseURLType.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .onChange(of: baseURLType) { _, newValue in
                    if let url = newValue.baseURL(port: portValue ?? 8000,
                                                  containerName: containerName,
                                                  panelHost: panelHost) {
                        baseURL = url
                    }
                }

                TextField("Base URL", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(.body, design: .monospaced))
                    .disabled(baseURLType != .custom)
            }
        } header: {
            SectionLabel(title: L10n.t("模型账号"), systemImage: "key.horizontal")
        } footer: {
            Text(L10n.t("实例创建后自动写入模型账号，供智能体等模块直接调用"))
        }
    }

    // MARK: 高级设置

    private var advancedSection: some View {
        Section {
            Toggle(L10n.t("高级设置"), isOn: $advanced)

            if advanced {
                TextField(L10n.t("容器名称"), text: $containerName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: containerName) { _, _ in refreshBaseURL() }

                Toggle(L10n.t("端口外部访问"), isOn: $allowPort)

                TextField(L10n.t("绑定主机 IP"), text: $specifyIP)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.decimalPad)
                    .font(.system(.body, design: .monospaced))

                Picker(L10n.t("重启规则"), selection: $restartPolicy) {
                    ForEach(VllmRestartPolicy.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }

                HStack {
                    TextField(L10n.t("CPU 限制"), text: $cpuQuotaText)
                        .keyboardType(.decimalPad)
                    Text(L10n.t("核心"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    TextField(L10n.t("内存限制"), text: $memoryLimitText)
                        .keyboardType(.decimalPad)
                    Picker("", selection: $memoryUnit) {
                        Text("MB").tag("M")
                        Text("GB").tag("G")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                Toggle(L10n.t("拉取镜像"), isOn: $pullImage)

                Toggle(L10n.t("编辑 Compose 文件"), isOn: $editCompose)

                if editCompose {
                    Button {
                        showComposeEditor = true
                    } label: {
                        Label(
                            dockerCompose.isEmpty ? L10n.t("加载模板中…") : L10n.t("查看 / 编辑 Compose"),
                            systemImage: "chevron.right"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(dockerCompose.isEmpty)
                    .listRowBackground(Color.clear)
                }
            }
        } header: {
            SectionLabel(title: L10n.t("高级设置"), systemImage: "slider.horizontal.3")
        } footer: {
            if advanced {
                Text(L10n.t("限制为 0 表示不限制；勾选编辑 Compose 后将以编辑内容创建"))
            }
        }
    }

    // MARK: 提交

    private var portValue: Int? {
        Int(portText.trimmingCharacters(in: .whitespaces))
    }

    private var panelHost: String {
        URLComponents(string: server.normalizedBaseURL)?.host ?? server.baseURL
    }

    /// 端口/容器名变化时同步 Base URL（自定义除外）
    private func refreshBaseURL() {
        guard baseURLType != .custom else { return }
        if let url = baseURLType.baseURL(port: portValue ?? 8000,
                                         containerName: containerName,
                                         panelHost: panelHost) {
            baseURL = url
        }
    }

    private func submit() async {
        validationMessage = nil
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            validationMessage = L10n.t("请输入实例名称")
            return
        }
        guard !appVersion.isEmpty else {
            validationMessage = L10n.t("请选择版本")
            return
        }
        guard !image.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationMessage = L10n.t("请输入镜像")
            return
        }
        guard let port = portValue, (1...65535).contains(port) else {
            validationMessage = L10n.t("端口需为 1-65535 之间的数字")
            return
        }
        guard !modelDir.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationMessage = L10n.t("请输入或选择模型目录")
            return
        }
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationMessage = L10n.t("启动命令不能为空")
            return
        }
        if syncModelAccount, baseURL.trimmingCharacters(in: .whitespaces).isEmpty {
            validationMessage = L10n.t("请填写 Base URL")
            return
        }

        let request = VllmCreateRequest(
            name: trimmedName,
            appVersion: appVersion,
            imageType: imageType.rawValue,
            image: image.trimmingCharacters(in: .whitespaces),
            commandTemplateID: selectedTemplateID,
            port: port,
            modelDir: modelDir.trimmingCharacters(in: .whitespaces),
            command: command.trimmingCharacters(in: .whitespaces),
            advanced: advanced,
            containerName: containerName.trimmingCharacters(in: .whitespaces),
            allowPort: allowPort,
            specifyIP: specifyIP.trimmingCharacters(in: .whitespaces),
            restartPolicy: restartPolicy.rawValue,
            cpuQuota: Double(cpuQuotaText) ?? 0,
            memoryLimit: Double(memoryLimitText) ?? 0,
            memoryUnit: memoryUnit,
            syncModelAccount: syncModelAccount,
            modelAccountBaseURLType: syncModelAccount ? baseURLType.rawValue : "",
            modelAccountBaseURL: syncModelAccount ? baseURL.trimmingCharacters(in: .whitespaces) : "",
            pullImage: pullImage,
            editCompose: editCompose,
            dockerCompose: editCompose ? dockerCompose : "",
            syncAgents: false,
            taskID: UUID().uuidString,
            id: instance?.id)

        isSubmitting = true
        defer { isSubmitting = false }

        if isEdit {
            if await vm.submitUpdate(request) {
                dismiss()
            }
        } else if let taskID = await vm.submitCreate(request) {
            dismiss()
            onSubmit(taskID)
        }
    }

    // MARK: 元数据加载

    /// 版本列表（apps/vllm）+ 当前类型的命令模板与 compose 模板
    private func loadMeta() async {
        isLoadingMeta = true
        defer { isLoadingMeta = false }

        // 版本列表
        if allVersions.isEmpty {
            let path = APIEndpoint.appsStoreDetail.path.replacingOccurrences(of: ":key", with: "vllm")
            if let detail: AppStoreDetail = try? await client.send(
                path: path, method: "GET", body: nil, as: AppStoreDetail.self) {
                allVersions = detail.versions ?? []
            }
        }
        if appVersion.isEmpty {
            appVersion = availableVersions.first ?? ""
            if let mapped = VllmImageMapper.defaultImage(appVersion: appVersion) {
                image = mapped
            }
        }

        await loadTemplates()
        await loadCompose()
    }

    private func loadTemplates() async {
        do {
            let list: [VllmCommandTemplate] = try await client.send(
                path: APIEndpoint.vllmCommandTemplateList.path,
                body: VllmImageTypeRequest(imageType: imageType.rawValue),
                as: [VllmCommandTemplate].self)
            templates = list
            // 创建模式默认选中第一个模板填入命令；编辑模式保留原命令，
            // 原模板已不在列表时回退「自定义」（不覆盖已填命令）
            if !isEdit, selectedTemplateID == 0, let first = list.first {
                selectedTemplateID = first.id
            } else if isEdit, selectedTemplateID != 0,
                      !list.contains(where: { $0.id == selectedTemplateID }) {
                selectedTemplateID = 0
            }
        } catch {
            templates = []
        }
    }

    private func loadCompose() async {
        do {
            let resp: VllmComposeResponse = try await client.send(
                path: APIEndpoint.vllmCompose.path,
                body: VllmImageTypeRequest(imageType: imageType.rawValue),
                as: VllmComposeResponse.self)
            dockerCompose = resp.dockerCompose ?? ""
        } catch {
            // 模板加载失败不阻塞创建（未勾选编辑 compose 时后端自行取默认模板）
        }
    }
}

// MARK: - Compose 编辑 Sheet

private struct ComposeEditorSheet: View {
    @Binding var compose: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $compose)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .navigationTitle(L10n.t("Compose 文件"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("完成")) { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.large])
    }
}
