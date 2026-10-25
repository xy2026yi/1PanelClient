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
    @State private var extensionSelection: [String] = []

    // 扩展模版（PHP）
    @State private var templates: [RuntimePHPTemplate] = []
    @State private var selectedTemplateID = 0

    // Node / Python / Go 字段
    @State private var codeDir = ""
    @State private var execScript = ""
    @State private var customScript = false
    @State private var nodeScripts: [RuntimeNodeScript] = []
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
        Form {
            if isEdit {
                editLockedSection
            } else {
                typeSection
            }
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
            if isPHP { phpSection }
            if selectedType != .php { scriptSection }
            advancedSection
        }
        .navigationTitle(isEdit ? L10n.t("编辑运行环境") : L10n.t("创建运行环境"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.t("取消")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isSubmitting {
                    ProgressView()
                } else {
                    Button(isEdit ? L10n.t("保存") : L10n.t("创建")) { Task { await submit() } }
                        .disabled(!canSubmit)
                }
            }
        }
        .task { await initialLoad() }
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
                    dismiss()
                }
                return true
            }
        }
        .alert(L10n.t("提示"), isPresented: $listVM.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(listVM.alertMessage)
        }
    }

    // MARK: - 类型选择（创建）

    private var typeSection: some View {
        Section(L10n.t("类型")) {
            Picker(L10n.t("类型"), selection: $selectedType) {
                ForEach(RuntimeType.allCases) { t in
                    Text(t.displayName).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .onChange(of: selectedType) { _, _ in
                Task { await loadAppMeta() }
            }
        }
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
                        Task { await loadNodeScripts() }
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
            // 扩展模版（可选；带入后仍可增删）
            if !templates.isEmpty {
                OutlinedPicker(label: L10n.t("扩展模版"),
                               options: [L10n.t("不使用")] + templates.map(\.displayName),
                               selection: templateSelectionBinding)
            }
            ForEach(dynFields) { field in
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
                OutlinedPicker(label: L10n.t("包管理器"),
                               options: packageManagerOptions,
                               selection: $packageManager)
                Toggle(L10n.t("安装 node_modules"), isOn: $installDeps)
                OutlinedPicker(label: L10n.t("镜像源"), options: npmSourceValues,
                               selection: $source, optionLabels: npmSourceLabels)
            } else {
                OutlinedTextField(label: L10n.t("运行脚本"),
                                  prompt: selectedType == .python ? "python server.py" : "./main",
                                  text: $execScript)
                if selectedType == .python {
                    OutlinedTextField(label: L10n.t("依赖源"), prompt: L10n.t("可选，如镜像站地址"),
                                      text: $source)
                }
            }
            OutlinedTextField(label: L10n.t("外部端口"), prompt: defaultPort.description,
                              text: $portText, keyboardType: .numberPad)
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
        if let entry = editingEntry {
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
            if let p = entry.params?["PANEL_APP_PORT_HTTP"], let v = p.intValue ?? Int(p.stringValue) {
                portText = String(v)
            } else if let port = entry.port, let v = Int(port) {
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

    /// 填目录后解析 package.json scripts（仅 Node 创建态）
    private func loadNodeScripts() async {
        guard selectedType == .node, !isEdit, !codeDir.isEmpty else { return }
        do {
            let scripts: [RuntimeNodeScript] = try await client.send(
                path: APIEndpoint.runtimesNodePackage.path,
                body: RuntimeNodePackageRequest(codeDir: codeDir),
                as: [RuntimeNodeScript].self
            )
            nodeScripts = scripts
        } catch {
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
        if let port = Int(portText), port < 1 || port > 65535 { return false }
        return true
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }

        var params: [String: RuntimeParamValue] = ["CONTAINER_NAME": .string(containerName)]

        switch selectedType {
        case .php:
            for f in dynFields where !f.multiple {
                params[f.key] = .string(fieldValues[f.key] ?? f.defaultValue ?? "")
            }
            if let extField = dynFields.first(where: \.multiple) {
                params[extField.key] = .array(extensionSelection)
            }
        case .node:
            params["PACKAGE_MANAGER"] = .string(packageManager)
            params["HOST_IP"] = .string("0.0.0.0")
            params["CUSTOM_SCRIPT"] = .string(customScript ? "1" : "0")
            params["EXEC_SCRIPT"] = .string(execScript)
        case .python, .go:
            params["HOST_IP"] = .string("0.0.0.0")
            params["EXEC_SCRIPT"] = .string(execScript)
        }

        let port = Int(portText) ?? defaultPort
        let phpImage = isPHP
            ? "1panel-php-fpm:\(fieldValues["PHP_VERSION"] ?? dynFields.first(where: { $0.key == "PHP_VERSION" })?.defaultValue ?? "")"
            : ""

        let exposed = exposedPorts.map {
            RuntimeExposedPort(hostPort: Int($0.hostPort) ?? 0,
                               containerPort: Int($0.containerPort) ?? 0,
                               hostIP: $0.hostIP,
                               protocol: $0.`protocol`)
        }
        let envs = envRows.map { RuntimeEnvironment(key: $0.key, value: $0.value) }
        let vols = volumeRows.map {
            RuntimeVolume(source: $0.source, target: $0.target,
                          mode: $0.mode.isEmpty ? "rw" : $0.mode)
        }
        let hosts = hostRows.map { RuntimeExtraHost(hostname: $0.hostname, ip: $0.ip) }

        if isEdit, let entry = editingEntry {
            var request = RuntimeUpdateRequest(
                id: entry.id, name: name, appDetailID: appDetailID,
                image: phpImage.isEmpty ? (entry.image ?? "") : phpImage,
                params: params, type: selectedType.searchKey,
                codeDir: codeDir, port: port, source: source,
                exposedPorts: exposed, environments: envs, volumes: vols, extraHosts: hosts,
                remark: remark, appID: appID, version: selectedVersion
            )
            request.install = selectedType == .node ? installDeps : nil
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
                codeDir: codeDir, port: port, source: source,
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

    var body: some View {
        NavigationStack {
            List {
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
            .navigationTitle(L10n.t("默认扩展"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("完成")) { dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("清空")) { selection = [] }
                }
            }
        }
    }
}

// MARK: - 端口映射编辑（轻量版，参照容器创建）

struct RuntimePortRow: Identifiable, Hashable {
    var id = UUID()
    var hostPort = ""
    var containerPort = ""
    var hostIP = ""
    var `protocol` = "tcp"
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
