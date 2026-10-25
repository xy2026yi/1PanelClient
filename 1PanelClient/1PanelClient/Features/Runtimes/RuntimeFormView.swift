//
//  RuntimeFormView.swift
//  1PanelClient
//
//  运行环境创建/编辑表单（PHP / Node.js / Python / Go）。
//  创建：选类型 → 应用商店取版本 → apps/detail/{id}/{ver}/runtime 取表单定义。
//  PHP 动态渲染 formFields（扩展多选）；Node 解析 package.json scripts；
//  Python/Go 固定字段。编辑经 GET /runtimes/:id 回填（定义取 appParams）。
//

import SwiftUI

// MARK: - 表单模式

enum RuntimeFormMode {
    case create
    case edit(RuntimeEntry)
}

// MARK: - 归一化表单字段（apps/detail formFields 与详情 appParams 双源归一）

struct RuntimeDynField: Identifiable {
    let key: String
    let label: String
    let type: String          // select / number / text
    let multiple: Bool
    /// select 候选 {label: value}
    let options: [(label: String, value: String)]
    let defaultValue: String?

    var id: String { key }
}

// MARK: - 表单

struct RuntimeFormView: View {
    let mode: RuntimeFormMode
    /// 创建时的初始类型（nil = 默认 PHP）
    var initialType: RuntimeType?
    let server: ServerConfig
    @ObservedObject var listVM: RuntimesViewModel

    @Environment(\.dismiss) private var dismiss

    private let client: APIClient

    init(mode: RuntimeFormMode, initialType: RuntimeType?, server: ServerConfig,
         listVM: RuntimesViewModel) {
        self.mode = mode
        self.initialType = initialType
        self.server = server
        self.listVM = listVM
        self.client = APIClient.shared(for: server)
    }

    // MARK: 状态

    @State private var selectedType: RuntimeType = .php
    @State private var name = ""
    @State private var containerName = ""
    @State private var remark = ""

    // 应用商店数据源
    @State private var appID = 0
    @State private var appVersions: [String] = []
    @State private var selectedVersion = ""
    @State private var appDetailID = 0
    @State private var dynFields: [RuntimeDynField] = []
    @State private var fieldValues: [String: String] = [:]
    // PHP 动态字段 + 扩展源
    @State private var packageSource = ""
    @State private var extensionSelection: [String] = []

    // 扩展模版（PHP）
    @State private var templates: [RuntimePHPTemplate] = []
    @State private var selectedTemplateID = 0

    // Node / Python / Go 字段
    @State private var codeDir = ""
    @State private var execScript = ""
    @State private var customScript = false
    @State private var nodeScripts: [RuntimeNodeScript] = []
    /// 所选目录无 package.json（服务端 500 "package.json 文件不存在"）→ 卡下一步/创建
    @State private var nodePackageMissing = false
    @State private var packageManager = "npm"
    @State private var installDeps = true
    @State private var source = ""
    @State private var portText = ""

    // 高级数组（环境变量/挂载/extraHosts 用多行文本，端口结构化）
    @State private var exposedPorts: [RuntimePortRow] = []
    @State private var envRows: [RuntimeEnvRow] = []
    @State private var volumeRows: [RuntimeVolumeRow] = []
    @State private var hostRows: [RuntimeHostRow] = []

    @State private var isLoadingMeta = false
    @State private var isSubmitting = false
    @State private var metaError: String?
    @State private var showDirPicker = false
    @State private var showExtensionPicker = false
    @State private var activeTask: RuntimeTaskTarget?
    /// 提交前校验错误（高级数组行级）
    @State private var validationToast: String?
    /// codeDir 防抖代号（连续输入只解析最后一次）
    @State private var nodeScriptsGeneration = 0
    /// 初始加载防重入：高级子编辑页返回时 .task 重跑不再重置已填表单
    @State private var didInitialLoad = false

    private var isEdit: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var editingEntry: RuntimeEntry? {
        if case .edit(let e) = mode { return e }
        return nil
    }

    private var isPHP: Bool { selectedType == .php }

    var body: some View {
        Group {
            if isEdit { editBody } else { createBody }
        }
        .navigationTitle(isEdit ? L10n.t("编辑运行环境") : L10n.t("创建运行环境"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .task {
            // 高级数组子编辑页（端口/环境变量/挂载/主机映射）push 返回时父页 disappear/appear
            // 会重启 .task：防重入，避免整个表单被 initialLoad 重置
            guard !didInitialLoad else { return }
            didInitialLoad = true
            await initialLoad()
        }
        .sheet(isPresented: $showDirPicker) {
            DirectoryPickerSheet(client: client) { path in
                codeDir = path
            }
        }
        .sheet(isPresented: $showExtensionPicker) {
            RuntimeExtensionPickerSheet(
                options: phpExtensionOptions, selection: $extensionSelection
            )
        }
        .navigationDestination(item: $activeTask) { target in
            TaskProgressView(taskID: target.taskID, title: target.title, node: "local") { isDone in
                if isDone {
                    Task { await listVM.load() }
                    // 分步收栈（AppStoreTab 同款）：return false 让进度页自行 pop，
                    // 稍后收创建表单——列表刷新与多层 pop 同帧执行会互相吞掉（完成无反应）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        dismiss()
                    }
                }
                return false
            }
        }
        .alert(L10n.t("提示"), isPresented: $listVM.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(listVM.alertMessage)
        }
        .toastOverlay(message: $validationToast)
    }

    // MARK: - 编辑（单页表单 + 右上角保存，KVM 表单同款）

    private var editBody: some View {
        Form {
            editLockedSection
            basicSection
            if isPHP { phpSection }
            if selectedType != .php { scriptSection }
            if selectedType != .php { advancedSection }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSubmitting {
                    ProgressView()
                } else {
                    Button(L10n.t("保存")) { Task { await submit() } }
                        .disabled(!canSubmit)
                }
            }
        }
    }

    // MARK: - 创建（三页向导：基础 / 配置 / 高级）

    @State private var wizardPage = 0
    /// PHP 无容器高级配置（端口映射/环境变量/挂载/主机映射），只有两页
    private var wizardPageNames: [String] {
        isPHP ? [L10n.t("基础"), L10n.t("配置")]
              : [L10n.t("基础"), L10n.t("配置"), L10n.t("高级")]
    }

    private var createBody: some View {
        VStack(spacing: 0) {
            WizardStepsBar(pageNames: wizardPageNames, current: wizardPage)
            Form {
                Group {
                    switch wizardPage {
                    case 0:
                        basicPage
                    case 1:
                        configPage
                    default:
                        advancedSection
                    }
                }
                // 纯 opacity 转场：move 会驱动 Form 内 UIKit 单元格 position 动画
                // （iOS 26 composite 警告来源）
                .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WizardBottomBar(
                page: wizardPage,
                totalPages: wizardPageNames.count,
                primaryTitle: L10n.t("创建"),
                isBusy: isSubmitting,
                primaryDisabled: pageInvalid,
                onBack: { withAnimation { wizardPage -= 1 } },
                onNext: { withAnimation { wizardPage += 1 } },
                onPrimary: { Task { await submit() } }
            )
        }
        // 页切换动画由 onNext/onBack 的 withAnimation 驱动 transition；不挂全 Form 的
        // 隐式 .animation——Menu（OutlinedPicker）弹层的 position 动画会进同一协调器，
        // 触发 iOS 26「composite animation already running」警告
        .modifier(WizardDiscardGuard(page: wizardPage, busy: isSubmitting))
    }

    /// 每页「下一步/创建」可用性：后续页字段不卡当前页
    private var pageInvalid: Bool {
        switch wizardPage {
        case 0:
            return name.isEmpty || containerName.isEmpty
        case 1:
            // PHP 两页制：配置页即末页，按完整提交校验
            if isPHP { return !canSubmit }
            return codeDir.isEmpty || execScript.isEmpty
                || (selectedType == .node && nodePackageMissing)
        default:
            return !canSubmit
        }
    }

    /// 第 0 页：类型（形态 3）+ 基础字段 + 版本加载态
    private var basicPage: some View {
        Group {
            typeSection
            basicSection
            if isLoadingMeta {
                Section {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text(L10n.t("正在加载版本信息…"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let err = metaError {
                Section {
                    Text(err).font(.footnote).foregroundStyle(.red)
                    Button(L10n.t("重试")) { Task { await loadAppMeta() } }
                }
            }
        }
    }

    /// 第 1 页：类型相关配置（PHP 动态字段 / 脚本与端口）
    private var configPage: some View {
        Group {
            if isPHP { phpSection }
            if selectedType != .php { scriptSection }
        }
    }

    // MARK: - 类型选择（创建，形态 3）

    private var typeSection: some View {
        Section(L10n.t("类型")) {
            OutlinedPicker(label: L10n.t("类型"),
                           options: RuntimeType.allCases.map(\.rawValue),
                           selection: typeBinding,
                           optionLabels: Dictionary(uniqueKeysWithValues:
                               RuntimeType.allCases.map { ($0.rawValue, $0.displayName) }))
            // 类型切换重拉应用元数据（版本与表单定义）
                .onChange(of: selectedType) { _, new in
                    // Node 镜像源缺省回填默认（切类型进入时 source 尚为空）
                    if new == .node, source.isEmpty, !isEdit {
                        source = npmSourceValues[0]
                    }
                    if new == .node { nodePackageMissing = false }
                    Task { await loadAppMeta() }
                }
        }
    }

    private var typeBinding: Binding<String> {
        Binding(
            get: { selectedType.rawValue },
            set: { selectedType = RuntimeType(rawValue: $0) ?? .php }
        )
    }

    /// 编辑模式锁定的信息
    private var editLockedSection: some View {
        Section {
            LabeledContent(L10n.t("名称"), value: name)
            LabeledContent(L10n.t("类型"), value: selectedType.displayName)
        }
    }

    // MARK: - 基础字段

    private var basicSection: some View {
        Section(L10n.t("基础信息")) {
            if !isEdit {
                OutlinedTextField(label: L10n.t("名称"), text: $name)
                    .onChange(of: name) { _, new in
                        // 容器名默认跟随名称（面板行为；手改后不再跟随）
                        if containerName.isEmpty || containerName == previousAutoContainer {
                            containerName = new
                            previousAutoContainer = new
                        }
                    }
            }
            OutlinedTextField(label: L10n.t("容器名称"), text: $containerName,
                              hint: isEdit ? nil : L10n.t("由名称自动带入，可修改"))

            // 版本（应用商店 versions）
            if !appVersions.isEmpty {
                OutlinedPicker(label: L10n.t("版本"), options: appVersions,
                               selection: $selectedVersion)
                    .onChange(of: selectedVersion) { _, _ in
                        Task { await loadAppDetail() }
                    }
            }

            if selectedType != .php {
                OutlinedTextField(label: L10n.t("运行目录"), prompt: "/",
                                  text: $codeDir,
                                  hint: L10n.t("项目代码所在的服务器目录"),
                                  browseAction: { showDirPicker = true })
                    .disabled(isEdit)
                    .onChange(of: codeDir) { _, _ in
                        scheduleLoadNodeScripts()
                    }
            }

            OutlinedMultiLineField(label: L10n.t("备注"), prompt: L10n.t("可选"),
                                   lines: 1, text: $remark)
        }
    }

    @State private var previousAutoContainer = ""

    // MARK: - PHP 动态字段（formFields）+ 扩展模版

    private var phpSection: some View {
        Section("PHP") {
            // 扩展源（7 项硬编码，选中同步 params.CONTAINER_PACKAGE_URL 与顶层 source）
            OutlinedPicker(label: L10n.t("扩展源"),
                           options: packageSources.map(\.url),
                           selection: packageSourceBinding,
                           optionLabels: Dictionary(uniqueKeysWithValues:
                               packageSources.map { ($0.url, $0.label) }))
            // 扩展模版（可选；带入后仍可增删）
            if !templates.isEmpty {
                OutlinedPicker(label: L10n.t("扩展模版"),
                               options: [L10n.t("不使用")] + templates.map(\.displayName),
                               selection: templateSelectionBinding)
            }
            // CONTAINER_PACKAGE_URL 由上方专属「扩展源」Picker 承担（接口 values 仅默认 1 项）
            ForEach(dynFields.filter { $0.key != "CONTAINER_PACKAGE_URL" }) { field in
                if field.multiple {
                    // PHP_EXTENSIONS 多选
                    Button {
                        showExtensionPicker = true
                    } label: {
                        HStack {
                            Text(field.label)
                            Spacer()
                            Text(extensionSelection.isEmpty
                                 ? L10n.t("默认")
                                 : extensionSelection.joined(separator: ","))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    // 单值动态字段：select 下拉 / number 数字键盘 / 其余文本
                    let value = fieldValueBinding(field.key)
                    if field.type == "select", !field.options.isEmpty {
                        OutlinedPicker(label: field.label,
                                       options: field.options.map(\.value),
                                       selection: value,
                                       optionLabels: Dictionary(
                                           uniqueKeysWithValues:
                                            field.options.map { ($0.value, $0.label) }
                                       ))
                    } else {
                        OutlinedTextField(label: field.label, text: value,
                                          keyboardType: field.type == "number" ? .numberPad : .default)
                    }
                }
            }
        }
    }

    private var templateSelectionBinding: Binding<String> {
        Binding(
            get: {
                templates.first(where: { $0.id == selectedTemplateID })?.displayName
                    ?? L10n.t("不使用")
            },
            set: { newName in
                if let tpl = templates.first(where: { $0.displayName == newName }) {
                    selectedTemplateID = tpl.id
                    extensionSelection = tpl.extensionList
                } else {
                    selectedTemplateID = 0
                }
            }
        )
    }

    private func fieldValueBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { fieldValues[key] ?? "" },
            set: { fieldValues[key] = $0 }
        )
    }

    private var phpExtensionOptions: [String] {
        (dynFields.first(where: \.multiple)?.options.map(\.value)) ?? []
    }

    /// PHP 扩展源（形态 3）。面板 Web 前端硬编码 7 项（接口 formFields 的 values 仅下发
    /// 默认项 1 条）；选中值写入 params.CONTAINER_PACKAGE_URL 并同步顶层 source——
    /// PHP 创建 source 为空服务端 500（抓包 L88/L354/L363）
    private let packageSources: [(label: String, url: String)] = [
        ("清华大学", "https://mirrors.tuna.tsinghua.edu.cn"),
        ("中科大", "https://mirrors.ustc.edu.cn"),
        ("网易", "https://mirrors.163.com"),
        ("阿里云", "https://mirrors.aliyun.com"),
        ("XTOM 镜像站(香港)", "https://mirrors.xtom.com.hk"),
        ("XTOM 镜像站(全球)", "https://mirrors.xtom.com"),
        ("默认", "https://deb.debian.org"),
    ]

    private var packageSourceBinding: Binding<String> {
        Binding(
            get: { packageSource },
            set: { packageSource = $0 }
        )
    }

    // MARK: - Node / Python / Go 脚本区

    private var scriptSection: some View {
        Section(L10n.t("运行")) {
            if selectedType == .node {
                Toggle(L10n.t("自定义脚本"), isOn: $customScript)
                if customScript {
                    OutlinedTextField(label: L10n.t("运行脚本"), prompt: "npm run start",
                                      text: $execScript)
                } else if !nodeScripts.isEmpty {
                    OutlinedPicker(label: L10n.t("运行脚本"),
                                   options: nodeScripts.map(\.displayName),
                                   selection: scriptNameBinding,
                                   optionLabels: scriptLabels)
                } else {
                    OutlinedTextField(label: L10n.t("运行脚本"), prompt: "npm run start",
                                      text: $execScript,
                                      hint: L10n.t("填目录后自动解析 package.json"))
                }
                if nodePackageMissing {
                    Text(L10n.t("所选目录未找到 package.json，无法解析运行脚本"))
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                OutlinedPicker(label: L10n.t("包管理器"),
                               options: packageManagerOptions,
                               selection: $packageManager)
                Toggle(L10n.t("安装 node_modules"), isOn: $installDeps)
                OutlinedPicker(label: L10n.t("镜像源"), options: npmSourceValues,
                               selection: $source, optionLabels: npmSourceLabels)
            } else {
                OutlinedTextField(label: L10n.t("运行脚本"),
                                  prompt: scriptPrompt,
                                  text: $execScript)
                // Java/.NET 创建页有「端口」输入（抓包 port:8080；node/python/go Web 端无此字段）
                if selectedType == .java || selectedType == .dotnet {
                    OutlinedTextField(label: L10n.t("端口"), prompt: defaultPort.description,
                                      text: $portText, keyboardType: .numberPad)
                }
            }
            // 外部端口/依赖源不在表单（node/python/go Web 端创建/编辑均无，经网页核对）：
            // 端口由容器配置的端口映射管理，请求端口走类型默认/详情回填（内部提交）
        }
    }

    /// 启动命令占位（按类型，对齐 Web 端默认 EXEC_SCRIPT）
    private var scriptPrompt: String {
        switch selectedType {
        case .python: return "python server.py"
        case .go: return "./main"
        case .java: return "jwebserver"
        case .dotnet: return "dotnet run"
        default: return ""
        }
    }

    private var scriptNameBinding: Binding<String> {
        Binding(
            get: { nodeScripts.first(where: { $0.script == execScript })?.displayName ?? execScript },
            set: { newName in
                if let s = nodeScripts.first(where: { $0.displayName == newName }) {
                    execScript = s.script ?? ""
                }
            }
        )
    }

    private var scriptLabels: [String: String] {
        var map: [String: String] = [:]
        for s in nodeScripts {
            map[s.displayName] = "\(s.displayName)【\(s.script ?? "")】"
        }
        return map
    }

    private var packageManagerOptions: [String] {
        // Node 版本 > 18 才有 pnpm（面板行为；保守按主版本判断）
        if majorVersion > 18 {
            return ["npm", "yarn", "pnpm"]
        }
        return ["npm", "yarn"]
    }

    private var majorVersion: Int {
        Int(selectedVersion.split(separator: ".").first ?? "0") ?? 0
    }

    private let npmSourceValues = [
        "https://registry.npmjs.org/",
        "https://registry.npmmirror.com",
        "https://mirrors.cloud.tencent.com/npm/",
    ]
    private var npmSourceLabels: [String: String] {
        [
            npmSourceValues[0]: L10n.t("默认 (npmjs)"),
            npmSourceValues[1]: L10n.t("淘宝镜像"),
            npmSourceValues[2]: L10n.t("腾讯镜像"),
        ]
    }

    private var defaultPort: Int {
        selectedType == .node ? 4004 : 8080
    }

    // MARK: - 容器高级配置

    private var advancedSection: some View {
        Section(L10n.t("高级设置")) {
            NavigationLink {
                RuntimePortsEditView(ports: $exposedPorts)
            } label: {
                advancedLinkLabel(L10n.t("端口映射"), count: exposedPorts.count)
            }
            NavigationLink {
                RuntimeEnvsEditView(environments: $envRows)
            } label: {
                advancedLinkLabel(L10n.t("环境变量"), count: envRows.count)
            }
            NavigationLink {
                RuntimeVolumesEditView(volumes: $volumeRows, client: client)
            } label: {
                advancedLinkLabel(L10n.t("挂载"), count: volumeRows.count)
            }
            NavigationLink {
                RuntimeHostsEditView(hosts: $hostRows)
            } label: {
                advancedLinkLabel(L10n.t("主机映射"), count: hostRows.count)
            }
        }
    }

    private func advancedLinkLabel(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            if count == 0 {
                Text(L10n.t("未设置")).foregroundStyle(.secondary)
            } else {
                Text(L10n.f("%ld 条", count)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 初始加载

    private func initialLoad() async {
        if var entry = editingEntry {
            // 编辑回填用详情：列表快照可能缺 port/exposedPorts（Web 编辑页端口值来自详情）
            if let fresh: RuntimeEntry = try? await client.send(
                path: APIEndpoint.runtimesGet.path
                    .replacingOccurrences(of: ":id", with: String(entry.id)),
                method: APIEndpoint.runtimesGet.method,
                as: RuntimeEntry.self
            ) {
                entry = fresh
            }
            selectedType = entry.runtimeType ?? .php
            name = entry.displayName
            containerName = entry.containerName
            remark = entry.remark ?? ""
            codeDir = entry.codeDir ?? ""
            if let p = entry.params?["EXEC_SCRIPT"]?.stringValue { execScript = p }
            customScript = (entry.params?["CUSTOM_SCRIPT"]?.stringValue ?? "0") == "1"
            if let pm = entry.params?["PACKAGE_MANAGER"]?.stringValue { packageManager = pm }
            installDeps = entry.installDependencies
            source = entry.source ?? ""
            // 端口回填链：php.ini 参数 → 暴露端口首条 → 顶层 port → 类型默认
            if let p = entry.params?["PANEL_APP_PORT_HTTP"], let v = p.intValue ?? Int(p.stringValue) {
                portText = String(v)
            } else if let hp = entry.exposedPorts?.first?.hostPort, hp > 0 {
                portText = String(hp)
            } else if let port = entry.port, let v = Int(port), v > 0 {
                portText = String(v)
            } else {
                portText = String(defaultPort)
            }
            if let exts = entry.params?["PHP_EXTENSIONS"] {
                if case .array(let list) = exts {
                    extensionSelection = list
                } else if !exts.stringValue.isEmpty {
                    extensionSelection = exts.stringValue.split(separator: ",").map(String.init)
                }
            }
            for f in entry.appParams ?? [] {
                if let key = f.key, let v = f.value {
                    fieldValues[key] = v.stringValue
                }
            }
            // 扩展源：params.CONTAINER_PACKAGE_URL 优先，缺省用清华源
            packageSource = entry.params?["CONTAINER_PACKAGE_URL"]?.stringValue.isEmpty == false
                ? entry.params!["CONTAINER_PACKAGE_URL"]!.stringValue
                : "https://mirrors.tuna.tsinghua.edu.cn"
            // 高级数组回填（编辑态）
            exposedPorts = (entry.exposedPorts ?? []).map {
                RuntimePortRow(hostPort: String($0.hostPort),
                               containerPort: String($0.containerPort),
                               hostIP: $0.hostIP, protocol: $0.`protocol`)
            }
            envRows = (entry.environments ?? []).map {
                RuntimeEnvRow(key: $0.key, value: $0.value)
            }
            volumeRows = (entry.volumes ?? []).map {
                RuntimeVolumeRow(source: $0.source, target: $0.target, mode: $0.mode)
            }
            hostRows = (entry.extraHosts ?? []).map {
                RuntimeHostRow(hostname: $0.hostname, ip: $0.ip)
            }
            // 详情接口即完整回填；再拉应用元数据补版本下拉
            await loadAppMeta(editAppID: entry.appID, editVersion: entry.version,
                              editAppDetailID: entry.appDetailID)
            await loadTemplates()
        } else {
            selectedType = initialType ?? .php
            portText = String(defaultPort)
            if selectedType == .node { source = npmSourceValues[0] }
            if selectedType == .php { packageSource = "https://mirrors.tuna.tsinghua.edu.cn" }
            await loadAppMeta()
            await loadTemplates()
        }
    }

    /// 应用商店元数据：apps/search → apps/:key(versions) → apps/detail(runtime)
    private func loadAppMeta(editAppID: Int? = nil, editVersion: String? = nil,
                             editAppDetailID: Int? = nil) async {
        isLoadingMeta = true
        metaError = nil
        defer { isLoadingMeta = false }
        do {
            let search: RuntimeAppSearchResponse = try await client.send(
                path: APIEndpoint.appsStoreSearch.path,
                body: RuntimeAppSearchRequest(type: selectedType.searchKey),
                as: RuntimeAppSearchResponse.self
            )
            guard let app = (search.items ?? []).first else {
                metaError = L10n.t("应用商店未提供该类型的运行环境应用")
                return
            }
            appID = editAppID ?? (app.id ?? 0)

            let detailPath = APIEndpoint.appsStoreDetail.path
                .replacingOccurrences(of: ":key", with: app.key ?? selectedType.searchKey)
            let appInfo: RuntimeAppVersions = try await client.send(
                path: detailPath, method: APIEndpoint.appsStoreDetail.method,
                as: RuntimeAppVersions.self
            )
            appVersions = appInfo.versions ?? []

            if let v = editVersion, appVersions.contains(v) {
                selectedVersion = v
            } else {
                selectedVersion = appVersions.first ?? ""
            }

            if let detailID = editAppDetailID, isEdit,
               selectedVersion == (editVersion ?? "") {
                // 编辑：详情已回填 appParams，版本未变时无需再拉
                appDetailID = detailID
                if dynFields.isEmpty {
                    await loadAppDetail()
                }
            } else {
                await loadAppDetail()
            }
        } catch {
            if !APIError.isCancellation(error) {
                metaError = error.localizedDescription
            }
        }
    }

    /// apps/detail/{appID}/{version}/runtime：表单定义 + appDetailId
    private func loadAppDetail() async {
        guard !selectedVersion.isEmpty, appID > 0 else { return }
        do {
            let path = APIEndpoint.appsDetailRuntime.path
                .replacingOccurrences(of: ":id", with: String(appID))
                .replacingOccurrences(of: ":version", with: selectedVersion)
            let detail: AppDetail = try await client.send(
                path: path, method: APIEndpoint.appsDetailRuntime.method,
                as: AppDetail.self
            )
            appDetailID = detail.id
            dynFields = (detail.params?.formFields ?? []).map { f in
                RuntimeDynField(
                    key: f.envKey ?? "",
                    label: f.displayLabel,
                    type: f.type ?? "text",
                    multiple: f.multiple ?? false,
                    options: (f.values ?? []).map { ($0.displayLabel, $0.actualValue) },
                    defaultValue: f.default?.stringValue
                )
            }
            // 单值字段未回填时用服务端默认
            if !isEdit || fieldValues.isEmpty {
                for f in dynFields where !f.multiple {
                    if fieldValues[f.key] == nil {
                        fieldValues[f.key] = f.defaultValue ?? f.options.first?.value ?? ""
                    }
                }
            }
        } catch {
            if !APIError.isCancellation(error) {
                metaError = error.localizedDescription
            }
        }
    }

    private func loadTemplates() async {
        guard isPHP else { return }
        do {
            let resp: RuntimePHPTemplateListResponse = try await client.send(
                path: APIEndpoint.runtimesPhpTplSearch.path,
                body: RuntimePHPTemplateSearchRequest(),
                as: RuntimePHPTemplateListResponse.self
            )
            templates = resp.items ?? []
        } catch {
            // 模版加载失败不阻断创建
            templates = []
        }
    }

    /// 填目录后解析 package.json scripts（仅 Node 创建态）。
    /// 防抖 + 代号：连续键入只发最后一次请求，晚到的旧响应不覆盖新结果
    private func scheduleLoadNodeScripts() {
        nodeScriptsGeneration += 1
        let gen = nodeScriptsGeneration
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard gen == nodeScriptsGeneration else { return }
            await loadNodeScripts(gen: gen)
        }
    }

    private func loadNodeScripts(gen: Int? = nil) async {
        guard selectedType == .node, !isEdit, !codeDir.isEmpty else { return }
        do {
            let scripts: [RuntimeNodeScript] = try await client.send(
                path: APIEndpoint.runtimesNodePackage.path,
                body: RuntimeNodePackageRequest(codeDir: codeDir),
                as: [RuntimeNodeScript].self
            )
            if let gen, gen != nodeScriptsGeneration { return }
            nodeScripts = scripts
            nodePackageMissing = false
            // 自动带入首个运行命令（目录解析成功即回填，对齐 Web 端）
            if !customScript, execScript.isEmpty, let first = scripts.first?.script, !first.isEmpty {
                execScript = first
            }
        } catch APIError.businessError(_, let message) where message.contains("package.json") {
            // 目录下无 package.json：标记缺失卡下一步（服务端创建同样会拒绝）
            if let gen, gen != nodeScriptsGeneration { return }
            nodeScripts = []
            nodePackageMissing = true
        } catch {
            if let gen, gen != nodeScriptsGeneration { return }
            nodeScripts = []
        }
    }

    // MARK: - 提交

    private var canSubmit: Bool {
        guard !name.isEmpty, !containerName.isEmpty, appDetailID > 0,
              !selectedVersion.isEmpty else { return false }
        if selectedType != .php {
            guard !codeDir.isEmpty, !execScript.isEmpty else { return false }
        }
        if selectedType == .node, nodePackageMissing { return false }
        if let port = Int(portText), port < 1 || port > 65535 { return false }
        return true
    }

    private func submit() async {
        // 高级行校验（PHP 无容器高级配置；校验含行号提示，全空行静默丢弃）
        let activePorts = isPHP ? [] : exposedPorts
        let activeEnvRows = isPHP ? [] : envRows
        let activeVolRows = isPHP ? [] : volumeRows
        let activeHostRows = isPHP ? [] : hostRows
        if let err = RuntimeAdvancedArrays.validationError(
            ports: activePorts, envs: activeEnvRows, volumes: activeVolRows, hosts: activeHostRows
        ) {
            validationToast = err
            return
        }

        isSubmitting = true
        defer { isSubmitting = false }

        var params: [String: RuntimeParamValue] = ["CONTAINER_NAME": .string(containerName)]

        switch selectedType {
        case .php:
            for f in dynFields where !f.multiple {
                let v = fieldValues[f.key] ?? f.defaultValue ?? ""
                // 面板创建体口径：数字字段（PANEL_APP_PORT_HTTP）发数字而非字符串
                if let n = Int(v), f.key == "PANEL_APP_PORT_HTTP" {
                    params[f.key] = .int(n)
                } else {
                    params[f.key] = .string(v)
                }
            }
            if let extField = dynFields.first(where: \.multiple) {
                params[extField.key] = .array(extensionSelection)
            }
            // 扩展源：params 与顶层 source 同口径（source 空 → 服务端 500）
            params["CONTAINER_PACKAGE_URL"] = .string(packageSource)
            // 面板创建体会带的固定默认（formFields 无此键，服务端有同名默认，补齐对齐）
            if params["TZ"] == nil { params["TZ"] = .string(TimeZone.current.identifier) }
            if params["PANEL_WEBSITE_DIR"] == nil {
                params["PANEL_WEBSITE_DIR"] = .string("/opt/1panel/www")
            }
        case .node:
            params["PACKAGE_MANAGER"] = .string(packageManager)
            params["HOST_IP"] = .string("0.0.0.0")
            params["CUSTOM_SCRIPT"] = .string(customScript ? "1" : "0")
            params["EXEC_SCRIPT"] = .string(execScript)
        case .python, .go, .java, .dotnet:
            params["HOST_IP"] = .string("0.0.0.0")
            params["EXEC_SCRIPT"] = .string(execScript)
        }

        let port = Int(portText) ?? defaultPort
        // PHP 请求不带顶层 port（抓包 L363/L240 均无），端口由 PANEL_APP_PORT_HTTP 参数承载；
        // node/python/go 创建走类型默认、编辑用详情回填值（端口由容器配置端口映射管理）
        let requestPort: Int? = isPHP ? nil : port
        let phpImage = isPHP
            ? "1panel-php-fpm:\(fieldValues["PHP_VERSION"] ?? dynFields.first(where: { $0.key == "PHP_VERSION" })?.defaultValue ?? "")"
            : ""
        // 顶层 source：PHP = 扩展源；Node/Python/Go = 各自镜像源状态
        let requestSource = isPHP ? packageSource : source

        // PHP 无容器高级配置：抓包口径仅携带 environments 空数组，四组数组仅非 PHP
        let exposed: [RuntimeExposedPort]? = isPHP ? nil : activePorts.filter { !$0.isBlank }.map {
            RuntimeExposedPort(hostPort: Int($0.hostPort) ?? 0,
                               containerPort: Int($0.containerPort) ?? 0,
                               hostIP: $0.hostIP,
                               protocol: $0.`protocol`)
        }
        let envs: [RuntimeEnvironment] = isPHP ? [] : activeEnvRows.filter { !$0.isBlank }.map {
            RuntimeEnvironment(key: $0.key, value: $0.value)
        }
        let vols: [RuntimeVolume]? = isPHP ? nil : activeVolRows.filter { !$0.isBlank }.map {
            RuntimeVolume(source: $0.source, target: $0.target,
                          mode: $0.mode.isEmpty ? "rw" : $0.mode)
        }
        let hosts: [RuntimeExtraHost]? = isPHP ? nil : activeHostRows.filter { !$0.isBlank }.map {
            RuntimeExtraHost(hostname: $0.hostname, ip: $0.ip)
        }

        if isEdit, let entry = editingEntry {
            var request = RuntimeUpdateRequest(
                id: entry.id, name: name, appDetailID: appDetailID,
                image: phpImage.isEmpty ? (entry.image ?? "") : phpImage,
                params: params, type: selectedType.searchKey,
                codeDir: codeDir, port: requestPort, source: requestSource,
                exposedPorts: exposed, environments: envs, volumes: vols, extraHosts: hosts,
                remark: remark, appID: appID, version: selectedVersion
            )
            request.install = selectedType == .node ? installDeps : nil
            // 面板原始请求同时携带 versionn（与 version 同值）
            request.versionn = selectedVersion
            // 编辑保留 PHP-FPM 端口等原有参数（服务端按 params 整组覆盖，回填原值）
            if isPHP, let old = entry.params {
                for (k, v) in old where params[k] == nil && !v.isNull {
                    request.params[k] = v
                }
                // PHP 版本变更时镜像名同步（IMAGE_NAME 与顶层 image 同口径）
                if !phpImage.isEmpty {
                    request.params["IMAGE_NAME"] = .string(phpImage)
                }
            }
            if let taskID = await listVM.submitUpdate(request, name: name) {
                activeTask = RuntimeTaskTarget(taskID: taskID, title: L10n.f("重建 %@", name))
            } else {
                dismiss()
            }
        } else {
            let request = RuntimeCreateRequest(
                name: name, appDetailID: appDetailID, image: phpImage, params: params,
                type: selectedType.searchKey,
                install: selectedType == .node ? installDeps : nil,
                codeDir: codeDir, port: requestPort, source: requestSource,
                exposedPorts: exposed, environments: envs, volumes: vols, extraHosts: hosts,
                remark: remark, appID: appID, version: selectedVersion,
                taskID: UUID().uuidString.lowercased()
            )
            if let taskID = await listVM.submitCreate(request) {
                activeTask = RuntimeTaskTarget(
                    taskID: taskID, title: L10n.f("创建运行环境 %@", name)
                )
            }
        }
    }

}

// MARK: - PHP 扩展多选 Sheet

struct RuntimeExtensionPickerSheet: View {
    let options: [String]
    @Binding var selection: [String]

    @Environment(\.dismiss) private var dismiss
    /// 打开时的原选择：取消时恢复
    @State private var initialSelection: [String] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(role: .destructive) {
                        selection = []
                    } label: {
                        Label(L10n.t("清空"), systemImage: "trash")
                    }
                }
                Section {
                    ForEach(options, id: \.self) { opt in
                        Button {
                            if let idx = selection.firstIndex(of: opt) {
                                selection.remove(at: idx)
                            } else {
                                selection.append(opt)
                            }
                        } label: {
                            HStack {
                                Text(opt)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selection.contains(opt) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.t("默认扩展"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) {
                        selection = initialSelection
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("完成")) { dismiss() }
                }
            }
            .onAppear { initialSelection = selection }
        }
        .bottomSheetDetents([.medium, .large])
    }
}

// MARK: - 端口映射编辑（轻量版，参照容器创建）

struct RuntimePortRow: Identifiable, Hashable {
    var id = UUID()
    var hostPort = ""
    var containerPort = ""
    var hostIP = ""
    var `protocol` = "tcp"

    /// 未填任何内容的「添加」行（提交时静默丢弃）
    var isBlank: Bool {
        hostPort.trimmingCharacters(in: .whitespaces).isEmpty
            && containerPort.trimmingCharacters(in: .whitespaces).isEmpty
            && hostIP.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// MARK: - 高级数组行校验（创建向导与 PHP 容器配置共用）

enum RuntimeAdvancedArrays {

    /// 非空行逐行校验；返回首条错误（带用户可见的行号），全部合法返回 nil
    static func validationError(ports: [RuntimePortRow], envs: [RuntimeEnvRow],
                                volumes: [RuntimeVolumeRow],
                                hosts: [RuntimeHostRow]) -> String? {
        for (idx, row) in ports.enumerated() {
            guard !row.isBlank else { continue }
            guard let hp = Int(row.hostPort), (1...65535).contains(hp),
                  let cp = Int(row.containerPort), (1...65535).contains(cp) else {
                return L10n.f("端口映射第 %ld 行：主机端口与容器端口需为 1-65535 的整数", idx + 1)
            }
        }
        for (idx, row) in envs.enumerated() {
            guard !row.isBlank else { continue }
            if row.key.trimmingCharacters(in: .whitespaces).isEmpty {
                return L10n.f("环境变量第 %ld 行：变量名不能为空", idx + 1)
            }
        }
        for (idx, row) in volumes.enumerated() {
            guard !row.isBlank else { continue }
            if row.source.trimmingCharacters(in: .whitespaces).isEmpty
                || row.target.trimmingCharacters(in: .whitespaces).isEmpty {
                return L10n.f("挂载第 %ld 行：主机目录与容器目录不能为空", idx + 1)
            }
        }
        for (idx, row) in hosts.enumerated() {
            guard !row.isBlank else { continue }
            if row.hostname.trimmingCharacters(in: .whitespaces).isEmpty
                || row.ip.trimmingCharacters(in: .whitespaces).isEmpty {
                return L10n.f("主机映射第 %ld 行：主机名与 IP 不能为空", idx + 1)
            }
        }
        return nil
    }
}

struct RuntimePortsEditView: View {
    @Binding var ports: [RuntimePortRow]

    private let protocols = ["tcp", "udp"]

    var body: some View {
        Form {
            ForEach($ports) { $port in
                Section {
                    OutlinedTextField(label: L10n.t("主机端口"), text: $port.hostPort,
                                      keyboardType: .numberPad)
                    OutlinedTextField(label: L10n.t("容器端口"), text: $port.containerPort,
                                      keyboardType: .numberPad)
                    OutlinedTextField(label: L10n.t("主机 IP"), prompt: L10n.t("可选"),
                                      text: $port.hostIP)
                    OutlinedPicker(label: L10n.t("协议"), options: protocols,
                                   selection: $port.`protocol`)
                } header: {
                    HStack {
                        Text(L10n.f("端口-%ld", (ports.firstIndex(where: { $0.id == port.id }) ?? 0) + 1))
                        Spacer()
                        Button {
                            ports.removeAll { $0.id == port.id }
                        } label: {
                            Label(L10n.t("删除"), systemImage: "trash")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            Section {
                Button {
                    ports.append(RuntimePortRow())
                } label: {
                    Label(L10n.t("添加"), systemImage: "plus.circle")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .navigationTitle(L10n.t("端口映射"))
        .navigationBarTitleDisplayMode(.inline)
    }
}


// MARK: - 环境变量行编辑（KEY=VALUE 结构化）

struct RuntimeEnvRow: Identifiable, Hashable {
    var id = UUID()
    var key = ""
    var value = ""

    var isBlank: Bool {
        key.trimmingCharacters(in: .whitespaces).isEmpty
            && value.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

struct RuntimeEnvsEditView: View {
    @Binding var environments: [RuntimeEnvRow]

    var body: some View {
        Form {
            ForEach($environments) { $env in
                Section {
                    OutlinedTextField(label: L10n.t("变量名"), prompt: "TZ",
                                      text: $env.key)
                    OutlinedTextField(label: L10n.t("值"), prompt: "Asia/Shanghai",
                                      text: $env.value)
                } header: {
                    HStack {
                        Text(L10n.f("环境变量-%ld",
                                    (environments.firstIndex(where: { $0.id == env.id }) ?? 0) + 1))
                        Spacer()
                        Button {
                            environments.removeAll { $0.id == env.id }
                        } label: {
                            Label(L10n.t("删除"), systemImage: "trash")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            Section {
                Button {
                    environments.append(RuntimeEnvRow())
                } label: {
                    Label(L10n.t("添加"), systemImage: "plus.circle")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .navigationTitle(L10n.t("环境变量"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 挂载行编辑（源目录 + 容器目录 + 模式 rw/ro）

struct RuntimeVolumeRow: Identifiable, Hashable {
    var id = UUID()
    var source = ""
    var target = ""
    var mode = "rw"

    var isBlank: Bool {
        source.trimmingCharacters(in: .whitespaces).isEmpty
            && target.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

struct RuntimeVolumesEditView: View {
    @Binding var volumes: [RuntimeVolumeRow]
    let client: APIClient

    @State private var showBrowse = false
    @State private var browseRowID: RuntimeVolumeRow.ID?

    private let modes = ["rw", "ro"]
    private var modeLabels: [String: String] {
        ["rw": L10n.t("读写"), "ro": L10n.t("只读")]
    }

    var body: some View {
        Form {
            ForEach($volumes) { $vol in
                Section {
                    OutlinedTextField(label: L10n.t("主机目录"), prompt: "/tmp/1",
                                      text: $vol.source,
                                      browseAction: {
                                          browseRowID = vol.id
                                          showBrowse = true
                                      })
                    OutlinedTextField(label: L10n.t("容器目录"), prompt: "/tmp/1",
                                      text: $vol.target)
                    OutlinedPicker(label: L10n.t("模式"), options: modes,
                                   selection: $vol.mode, optionLabels: modeLabels)
                } header: {
                    HStack {
                        Text(L10n.f("挂载-%ld",
                                    (volumes.firstIndex(where: { $0.id == vol.id }) ?? 0) + 1))
                        Spacer()
                        Button {
                            volumes.removeAll { $0.id == vol.id }
                        } label: {
                            Label(L10n.t("删除"), systemImage: "trash")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            Section {
                Button {
                    volumes.append(RuntimeVolumeRow())
                } label: {
                    Label(L10n.t("添加"), systemImage: "plus.circle")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .navigationTitle(L10n.t("挂载"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showBrowse) {
            DirectoryPickerSheet(client: client) { path in
                if let id = browseRowID,
                   let idx = volumes.firstIndex(where: { $0.id == id }) {
                    volumes[idx].source = path
                }
            }
        }
    }
}

// MARK: - 主机映射行编辑（hostname + IP）

struct RuntimeHostRow: Identifiable, Hashable {
    var id = UUID()
    var hostname = ""
    var ip = ""

    var isBlank: Bool {
        hostname.trimmingCharacters(in: .whitespaces).isEmpty
            && ip.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

struct RuntimeHostsEditView: View {
    @Binding var hosts: [RuntimeHostRow]

    var body: some View {
        Form {
            ForEach($hosts) { $host in
                Section {
                    OutlinedTextField(label: L10n.t("主机名"), prompt: "test.local.vm",
                                      text: $host.hostname)
                    OutlinedTextField(label: "IP", prompt: "172.18.0.100",
                                      text: $host.ip)
                } header: {
                    HStack {
                        Text(L10n.f("主机映射-%ld",
                                    (hosts.firstIndex(where: { $0.id == host.id }) ?? 0) + 1))
                        Spacer()
                        Button {
                            hosts.removeAll { $0.id == host.id }
                        } label: {
                            Label(L10n.t("删除"), systemImage: "trash")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            Section {
                Button {
                    hosts.append(RuntimeHostRow())
                } label: {
                    Label(L10n.t("添加"), systemImage: "plus.circle")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .navigationTitle(L10n.t("主机映射"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
