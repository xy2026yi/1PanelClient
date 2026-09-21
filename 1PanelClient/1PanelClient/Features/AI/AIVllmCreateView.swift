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

/// POST compose / command-template/list 共用请求 {imageType, appVersion}
///（compose 的 AppVersion 必填，抓包 2026-09-21：缺失报 400 参数错误；
/// 模板列表对 appVersion 兼容忽略）
private struct VllmImageTypeRequest: Encodable {
    let imageType: String
    var appVersion: String? = nil
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

    @State private var containerName = ""
    @State private var allowPort = true
    @State private var specifyIP = ""
    @State private var restartPolicy = VllmRestartPolicy.unlessStopped
    @State private var cpuQuotaText = "0"
    @State private var memoryLimitText = "0"
    /// 内存单位（K/M/G，随请求提交）
    @State private var memoryUnitValue = "M"
    @State private var pullImage = true
    @State private var editCompose = false
    @State private var dockerCompose = ""

    // MARK: 弹层 / 加载

    @State private var showComposeEditor = false
    @State private var showDirPicker = false
    @State private var allVersions: [String] = []
    @State private var isLoadingMeta = true
    /// 版本列表加载失败（与「无版本」区分，提供重试）
    @State private var metaError: String?
    @State private var isSubmitting = false
    @State private var validationMessage: String?
    /// 创建任务进度（提交成功后由表单内 push，与安装应用同模式）
    @State private var showProgress = false
    @State private var activeTaskID = ""

    private let client: APIClient

    /// 实例的原始 imageType 无法映射到已知枚举时保留原值，
    /// 展示与提交都用原字符串，不回退成 nvidia（违反「类型不可改」约定）
    private let originalImageTypeRaw: String?

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
            let rawType = i.imageType ?? ""
            // 未知类型（如服务端新增 rocm）保留原值，不回退 nvidia
            originalImageTypeRaw = VllmImageType(rawValue: rawType) == nil && !rawType.isEmpty
                ? rawType : nil
            _name = State(initialValue: i.name ?? "vLLM")
            _imageType = State(initialValue: VllmImageType(rawValue: rawType) ?? .nvidia)
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
            // 编辑按实例原值 + 原单位回填（服务端单位取首字母归一 K/M/G）
            _memoryLimitText = State(initialValue: Self.shortNumber(i.memoryLimit))
            _memoryUnitValue = State(initialValue: {
                let u = (i.memoryUnit ?? "M").uppercased().first.map(String.init) ?? "M"
                return ["K", "M", "G"].contains(u) ? u : "M"
            }())
            _pullImage = State(initialValue: i.pullImage ?? true)
            _editCompose = State(initialValue: i.editCompose ?? false)
            _dockerCompose = State(initialValue: i.dockerCompose ?? "")
        } else {
            originalImageTypeRaw = nil
        }
    }

    /// 2.0 显示为 2（表单数字输入尽量短）
    private static func shortNumber(_ v: Double?) -> String {
        guard let v else { return "0" }
        return v == v.rounded() ? String(Int(v)) : String(v)
    }

    // MARK: 视图

    /// 向导分页：0 基础（类型/版本/模型） 1 配置（命令/账号） 2 高级（默认收起）
    @State private var wizardPage = 0
    @State private var advancedEnabled = false
    private let wizardPageNames = [L10n.t("基础"), L10n.t("配置"), L10n.t("高级")]

    /// 当前页必填是否满足（模型目录为必填，随名称一起卡「下一步」）
    private var pageReady: Bool {
        wizardPage != 0
            || (!name.trimmingCharacters(in: .whitespaces).isEmpty
                && !modelDir.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            WizardStepsBar(pageNames: wizardPageNames, current: wizardPage)
            Form {
                Group {
                    switch wizardPage {
                    case 0:
                        basicSection
                    case 1:
                        commandSection
                        accountSection
                    default:
                        // 高级页主开关（默认收起）；开启后直接展示全部高级字段，
                        // 不再有内层第二个「高级设置」开关
                        Section {
                            Toggle(L10n.t("高级设置"), isOn: $advancedEnabled)
                        } footer: {
                            Text(L10n.t("资源限制、编排覆盖等进阶项"))
                        }
                        if advancedEnabled {
                            advancedSection
                        }
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
                if let msg = validationMessage {
                    Section {
                        Text(msg)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WizardBottomBar(
                page: wizardPage,
                totalPages: wizardPageNames.count,
                primaryTitle: isEdit ? L10n.t("保存") : L10n.t("创建"),
                isBusy: isSubmitting,
                primaryDisabled: !pageReady,
                onBack: { withAnimation { wizardPage -= 1 } },
                onNext: { withAnimation { wizardPage += 1 } },
                onPrimary: { Task { await submit() } }
            )
        }
        .animation(.easeInOut(duration: 0.22), value: wizardPage)
        .modifier(WizardDiscardGuard(page: wizardPage))
        .navigationTitle(isEdit ? L10n.t("编辑实例") : L10n.t("创建实例"))
        .navigationBarTitleDisplayMode(.inline)
        // 创建进度由表单内 push（与安装应用同模式）：完成后分步收栈
        .navigationDestination(isPresented: $showProgress) {
            TaskProgressView(taskID: activeTaskID,
                             title: L10n.t("创建 vLLM 实例"),
                             latest: false, node: "local") { isDone in
                if isDone {
                    Task { await vm.loadInstances() }
                    // 进度页自行 dismiss，这里稍后收创建表单（分步收栈避免同帧拆多层）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        dismiss()
                    }
                }
                return false
            }
        }
        .task {
            await loadMeta()
            // 创建态访问地址默认类型下 Base URL 为空（首刷），补一次推导；
            // 编辑态已回填非空不覆盖
            if baseURL.isEmpty { refreshBaseURL() }
        }
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
        // 编辑中的版本可能已从商店下架，保底保留当前值
        // （编辑模式类型已锁定，不存在跨类型混入的问题）
        if let current = instance?.appVersion, !current.isEmpty, !list.contains(current) {
            list.insert(current, at: 0)
        }
        return list
    }

    private var basicSection: some View {
        Section {
            OutlinedTextField(label: L10n.t("名称"), text: $name)
                .disabled(isEdit)
                // 名称即默认容器名：改名联动刷新容器地址 Base URL
                .onChange(of: name) { _, _ in refreshBaseURL() }

            if isEdit {
                // 编辑时类型/版本不可修改（服务端约定），以信息行展示；
                // 未知类型保留服务端原字符串
                InfoRow(L10n.t("类型"), value: originalImageTypeRaw ?? imageType.displayName)
                InfoRow(L10n.t("版本"), value: appVersion)
            } else {
                OutlinedPicker(label: L10n.t("类型"), options: VllmImageType.allCases,
                               selection: $imageType) { $0.displayName }

                if isLoadingMeta && allVersions.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.7)
                        Text(L10n.t("加载版本列表…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let err = metaError, allVersions.isEmpty {
                    LoadErrorStateView(message: err) {
                        Task { await loadMeta() }
                    }
                    .listRowBackground(Color.clear)
                } else {
                    OutlinedPicker(label: L10n.t("版本"), options: availableVersions,
                                   selection: $appVersion)
                        .onChange(of: appVersion) { _, newValue in
                            // 版本切换重新推导镜像（用户可再手动改）
                            if let mapped = VllmImageMapper.defaultImage(appVersion: newValue) {
                                image = mapped
                            }
                            // 首刷时版本为空被跳过的 compose 模板，版本选定后补拉
                            if !newValue.isEmpty, dockerCompose.isEmpty {
                                Task { await loadCompose() }
                            }
                        }
                }
            }

            OutlinedTextField(label: L10n.t("镜像"), text: $image)
                .font(.dataMonospacedBody)

            OutlinedTextField(label: L10n.t("端口"), text: $portText, keyboardType: .numberPad)
                .onChange(of: portText) { _, _ in refreshBaseURL() }

            FilePathBrowseRow(title: L10n.t("模型目录"), path: $modelDir, client: client)
        } header: {
            SectionLabel(title: L10n.t("基础设置"), systemImage: "gearshape")
        } footer: {
            Text(L10n.t("镜像按版本自动推导，通常无需修改；模型目录用于挂载权重文件"))
        }
    }

    // MARK: 启动命令

    private var commandSection: some View {
        Section {
            OutlinedPicker(label: L10n.t("启动命令模板"),
                           options: commandTemplateOptionKeys, selection: commandTemplateText,
                           optionLabels: commandTemplateOptionLabels)
                .onChange(of: selectedTemplateID) { _, newValue in
                    if let t = templates.first(where: { $0.id == newValue }) {
                        command = t.command ?? ""
                    }
                }

            OutlinedMultiLineField(label: L10n.t("启动命令"), prompt: "vllm serve …",
                                   text: $command)
        } header: {
            SectionLabel(title: L10n.t("启动命令"), systemImage: "terminal")
        } footer: {
            Text(L10n.t("模板选择后自动填入，可手动调整启动参数"))
        }
    }

    /// 启动命令模板选项（0=自定义）
    private var commandTemplateOptionKeys: [String] {
        ["0"] + templates.map { String($0.id) }
    }

    private var commandTemplateOptionLabels: [String: String] {
        var labels = ["0": L10n.t("自定义")]
        for t in templates { labels[String(t.id)] = t.name ?? "#\(t.id)" }
        return labels
    }

    private var commandTemplateText: Binding<String> {
        Binding<String>(
            get: { String(selectedTemplateID) },
            set: { selectedTemplateID = Int($0) ?? 0 }
        )
    }

    // MARK: 模型账号

    private var accountSection: some View {
        Section {
            Toggle(L10n.t("同步到模型账号"), isOn: $syncModelAccount)

            if syncModelAccount {
                OutlinedPicker(label: L10n.t("访问地址"), options: VllmBaseURLType.allCases,
                               selection: $baseURLType) { $0.displayName }
                    .onChange(of: baseURLType) { _, newValue in
                        if let url = newValue.baseURL(port: portValue ?? 8000,
                                                      containerName: effectiveContainerName,
                                                      panelHost: panelHost) {
                            baseURL = url
                        }
                    }

                OutlinedTextField(label: "Base URL", prompt: "http://127.0.0.1:8000/v1",
                                  text: $baseURL, keyboardType: .URL)
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
            OutlinedTextField(label: L10n.t("容器名称"), prompt: L10n.t("默认与名称一致"),
                              text: $containerName)
                .font(.dataMonospacedBody)
                .onChange(of: containerName) { _, _ in refreshBaseURL() }

            Toggle(L10n.t("端口外部访问"), isOn: $allowPort)

            OutlinedTextField(label: L10n.t("绑定主机 IP"), text: $specifyIP)
                .keyboardType(.decimalPad)
                .font(.dataMonospacedBody)

            OutlinedPicker(label: L10n.t("重启规则"), options: VllmRestartPolicy.allCases,
                           selection: $restartPolicy) { $0.displayName }

            // CPU 配额允许小数（如 0.5 核，提交按 Double 解析）
            OutlinedUnitField(label: L10n.t("CPU 限制"), unit: L10n.t("核心"),
                              text: $cpuQuotaText, keyboardType: .decimalPad,
                              allowsDecimal: true)

            // 数值 + 单位菜单（提交携带单位，后端换算）；MB 为整数输入
            OutlinedUnitField(label: L10n.t("内存限制"), unit: "",
                              text: $memoryLimitText, keyboardType: .numberPad)
            OutlinedPicker(label: L10n.t("内存单位"), options: ["K", "M", "G"],
                           selection: $memoryUnitValue,
                           optionLabels: ["K": "KB", "M": "MB", "G": "GB"])

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
        } header: {
            SectionLabel(title: L10n.t("高级设置"), systemImage: "slider.horizontal.3")
        } footer: {
            Text(L10n.t("限制为 0 表示不限制；勾选编辑 Compose 后将以编辑内容创建"))
        }
    }

    // MARK: 提交

    private var portValue: Int? {
        Int(portText.trimmingCharacters(in: .whitespaces))
    }

    private var panelHost: String {
        URLComponents(string: server.normalizedBaseURL)?.host ?? server.baseURL
    }

    /// 容器地址用的容器名：未指定容器名称时与实例名一致
    ///（后端默认以实例名创建容器，抓包确认；Base URL 需用同名主机别名访问）
    private var effectiveContainerName: String {
        let trimmed = containerName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name.trimmingCharacters(in: .whitespaces) : trimmed
    }

    /// 端口/容器名/名称变化时同步 Base URL（自定义除外）
    private func refreshBaseURL() {
        guard baseURLType != .custom else { return }
        if let url = baseURLType.baseURL(port: portValue ?? 8000,
                                         containerName: effectiveContainerName,
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
        if editCompose, dockerCompose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validationMessage = L10n.t("Compose 内容为空，请先获取模板或关闭「编辑 Compose 文件」")
            return
        }

        let request = VllmCreateRequest(
            name: trimmedName,
            appVersion: appVersion,
            imageType: originalImageTypeRaw ?? imageType.rawValue,
            image: image.trimmingCharacters(in: .whitespaces),
            commandTemplateID: selectedTemplateID,
            port: port,
            modelDir: modelDir.trimmingCharacters(in: .whitespaces),
            command: command.trimmingCharacters(in: .whitespaces),
            advanced: advancedEnabled,
            containerName: containerName.trimmingCharacters(in: .whitespaces),
            allowPort: allowPort,
            specifyIP: specifyIP.trimmingCharacters(in: .whitespaces),
            restartPolicy: restartPolicy.rawValue,
            cpuQuota: Double(cpuQuotaText) ?? 0,
            memoryLimit: Double(memoryLimitText) ?? 0,
            memoryUnit: memoryUnitValue,
            syncModelAccount: syncModelAccount,
            modelAccountBaseURLType: syncModelAccount ? baseURLType.rawValue : "",
            modelAccountBaseURL: syncModelAccount ? baseURL.trimmingCharacters(in: .whitespaces) : "",
            pullImage: pullImage,
            editCompose: editCompose,
            // 抓包显示 editCompose=false 时创建体也携带完整模板内容；
            // 状态里模板已随类型加载（编辑模式为实例保存值），直接回传
            dockerCompose: dockerCompose,
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
            // 创建进度由本表单内 push（与安装应用同模式），完成后分步收栈；
            // onSubmit 保留兼容（调用方不再需要自行 push 进度）
            activeTaskID = taskID
            showProgress = true
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
            do {
                let detail: AppStoreDetail = try await client.send(
                    path: path, method: "GET", body: nil, as: AppStoreDetail.self)
                allVersions = detail.versions ?? []
                metaError = nil
            } catch {
                guard !APIError.isCancellation(error) else { return }
                // 版本拿不到时创建无法继续：展示错误 + 重试（模板/compose 仍尝试加载）
                metaError = error.localizedDescription
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
        // 编辑模式优先保留实例已保存的 compose（可能含用户自定义内容），
        // 不用默认模板覆盖——覆盖后原样保存会静默丢失自定义配置；
        // 仅创建模式（或实例未保存过 compose）时拉取当前类型的模板
        if let saved = instance?.dockerCompose, !saved.isEmpty {
            dockerCompose = saved
            return
        }
        // appVersion 为必填：版本列表还没就绪（映射不到可用版本）时先跳过，
        // 待版本选定后由 onChange(of: appVersion) 补拉，避免必填参数空发 400
        guard !appVersion.isEmpty else { return }
        do {
            let resp: VllmComposeResponse = try await client.send(
                path: APIEndpoint.vllmCompose.path,
                body: VllmImageTypeRequest(imageType: imageType.rawValue, appVersion: appVersion),
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
                    .font(.dataMonospacedCaption)
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
