//
//  AppsTab.swift
//  1PanelClient
//

import SwiftUI
import Combine

struct AppsTab: View {
    @ObservedObject var manager: ServerManager
    @StateObject private var vm: AppsViewModel
    @State private var searchText = ""

    init(manager: ServerManager) {
        self.manager = manager
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: AppsViewModel(server: server))
    }

    var body: some View {
        NavigationStack {
            installedRootContent
        }
        .alert("提示", isPresented: $vm.showAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .task { await vm.refresh() }
    }

    /// 供统一外壳复用的根内容（不含 NavigationStack/alert/task）
    var installedRootContent: some View {
        Group {
            if vm.isLoading && vm.apps.isEmpty {
                ProgressView("加载中…")
            } else if vm.apps.isEmpty {
                ContentUnavailableView(
                    "暂无已安装应用",
                    systemImage: "shippingbox",
                    description: Text(vm.errorMessage ?? "这台服务器上没有已安装的应用")
                )
            } else {
                appList
            }
        }
        .navigationTitle("应用")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "搜索已安装应用")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await vm.refresh() }
                } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .onChange(of: searchText) { _, newValue in
            Task { await vm.search(query: newValue) }
        }
        .navigationDestination(for: AppInstall.self) { app in
            AppDetailView(app: app, vm: vm)
        }
    }

    private var appList: some View {
        List {
            if vm.updatableCount > 0 {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(vm.updatableCount) 个应用可更新")
                                .font(.subheadline.bold())
                            Text("点击应用进入详情查看升级选项")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                ForEach(vm.apps) { app in
                    NavigationLink(value: app) {
                        AppRow(
                            app: app,
                            isOperating: vm.operatingAppIds.contains(app.id)
                        )
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if app.isRunning {
                            Button {
                                Task { await vm.operate(app: app, op: .stop) }
                            } label: { Label("停止", systemImage: "stop.fill") }
                            .tint(.orange)
                        } else {
                            Button {
                                Task { await vm.operate(app: app, op: .start) }
                            } label: { Label("启动", systemImage: "play.fill") }
                            .tint(.green)
                        }
                        Button {
                            Task { await vm.operate(app: app, op: .restart) }
                        } label: { Label("重启", systemImage: "arrow.triangle.2.circlepath") }
                        .tint(.blue)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - 应用详情页

struct AppDetailView: View {
    let app: AppInstall
    @ObservedObject var vm: AppsViewModel
    @State private var showUninstallSheet = false
    @State private var showUpdateParamsSheet = false

    var body: some View {
        List {
            // 基本信息
            Section("应用信息") {
                LabeledRow("名称", value: app.displayName)
                if let n = app.name, !n.isEmpty {
                    LabeledRow("内部名称", value: n)
                }
                if let key = app.appKey, !key.isEmpty {
                    LabeledRow("App Key", value: key)
                }
                if let v = app.version, !v.isEmpty {
                    LabeledRow("版本", value: "v\(v)")
                }
                if let port = app.httpPort, port > 0 {
                    LabeledRow("HTTP 端口", value: "\(port)")
                }
                if let ports = app.httpsPort, ports > 0 {
                    LabeledRow("HTTPS 端口", value: "\(ports)")
                }
                if let container = app.container, !container.isEmpty {
                    LabeledRow("容器名", value: container)
                }
                if let created = app.createdAt, !created.isEmpty {
                    LabeledRow("安装时间", value: String(created.prefix(19)))
                }
            }

            // 状态
            Section("状态") {
                HStack {
                    Image(systemName: app.statusIcon)
                        .foregroundStyle(app.statusColor)
                    Text((app.status ?? "未知").capitalized)
                        .foregroundStyle(app.statusColor)
                }
                if let msg = app.message, !msg.isEmpty {
                    LabeledRow("消息", value: msg)
                }
            }

            // 操作
            Section("操作") {
                if app.isRunning {
                    Button {
                        Task { await vm.operate(app: app, op: .stop) }
                    } label: {
                        Label("停止应用", systemImage: "stop.fill")
                    }
                } else {
                    Button {
                        Task { await vm.operate(app: app, op: .start) }
                    } label: {
                        Label("启动应用", systemImage: "play.fill")
                    }
                }
                Button {
                    Task { await vm.operate(app: app, op: .restart) }
                } label: {
                    Label("重启应用", systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                    Task { await vm.operate(app: app, op: .rebuild) }
                } label: {
                    Label("重建应用", systemImage: "hammer")
                }
                Button {
                    showUpdateParamsSheet = true
                } label: {
                    Label("更新参数", systemImage: "slider.horizontal.3")
                }
                NavigationLink {
                    AppLogView(app: app, vm: vm)
                } label: {
                    Label("查看日志", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.plain)
            }

            // 升级区（有可更新 OR 已忽略升级时显示）
            if app.canUpdate == true || app.ignoredRecordID != nil {
                Section {
                    if app.canUpdate == true {
                        Button {
                            Task { await vm.loadVersions(for: app) }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.up.circle.fill")
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading) {
                                    Text("检查更新")
                                        .foregroundStyle(.primary)
                                    Text("查看可用的新版本")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            Task { await vm.ignoreUpgrade(app: app) }
                        } label: {
                            Label("忽略所有升级", systemImage: "eye.slash")
                        }
                    }

                    // 已忽略时显示「取消忽略升级」
                    if app.ignoredRecordID != nil {
                        Button {
                            Task { await vm.cancelIgnoreUpgrade(app: app) }
                        } label: {
                            Label("取消忽略升级", systemImage: "eye")
                        }
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("升级")
                        if app.canUpdate == true {
                            Text("NEW")
                                .font(.caption2.bold())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.2))
                                .clipShape(Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                } footer: {
                    if app.ignoredRecordID != nil && app.canUpdate != true {
                        Text("该应用的升级提示已被忽略，取消后可恢复更新检查。")
                    } else {
                        Text("升级将替换 docker-compose.yml，建议查看文件对比。")
                    }
                }
            }

            // 相关链接
            if let links = app.app {
                Section("相关链接") {
                    if let website = links.website, let url = URL(string: website) {
                        Link("官方网站", destination: url)
                    }
                    if let doc = links.document, let url = URL(string: doc) {
                        Link("文档", destination: url)
                    }
                    if let github = links.github, let url = URL(string: github) {
                        Link("GitHub", destination: url)
                    }
                }
            }

            // 危险区：卸载
            Section {
                Button {
                    showUninstallSheet = true
                } label: {
                    Label("卸载应用", systemImage: "trash")
                }
            } header: {
                Text("危险操作")
            } footer: {
                Text("卸载将删除容器及相关数据，请谨慎操作。")
            }
        }
        .navigationTitle(app.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $vm.showUpgradeSheet) {
            UpgradeSheetView(app: app, vm: vm)
        }
        .sheet(isPresented: $showUninstallSheet) {
            UninstallSheetView(app: app, vm: vm)
        }
        .sheet(isPresented: $showUpdateParamsSheet) {
            UpdateParamsSheetView(app: app, vm: vm)
        }
        .onDisappear {
            // 返回列表时，如有待刷新（忽略升级/升级完成），重新加载
            // 延迟到导航动画结束后执行，避免破坏 NavigationStack 环境树
            if vm.needsRefresh {
                vm.needsRefresh = false
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    await vm.refresh()
                }
            }
        }
    }
}

struct LabeledRow: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

// MARK: - 升级版本选择 Sheet

struct UpgradeSheetView: View {
    let app: AppInstall
    @ObservedObject var vm: AppsViewModel
    @State private var showComposeEditor = false

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoadingVersions {
                    ProgressView("查询可用版本…")
                } else if vm.availableVersions.isEmpty {
                    ContentUnavailableView(
                        "无可用版本",
                        systemImage: "arrow.up.circle.slash",
                        description: Text("该应用暂无更高版本可供升级")
                    )
                } else {
                    versionList
                }
            }
            .navigationTitle("升级 \(app.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { vm.showUpgradeSheet = false }
                }
            }
            .navigationDestination(isPresented: $showComposeEditor) {
                if let version = vm.selectedVersion {
                    ComposeEditorView(
                        app: app,
                        version: version,
                        vm: vm,
                        onBack: { showComposeEditor = false }
                    )
                }
            }
        }
    }

    private var versionList: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("升级将替换 docker-compose.yml，如有自定义修改请查看对比")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("当前版本")
            }

            Section("可升级到") {
                ForEach(vm.availableVersions) { ver in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ver.version ?? "v\(ver.detailId)")
                                    .font(.body.bold())
                                Text("ID: \(ver.detailId)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if vm.upgradingVersionId == ver.detailId {
                                ProgressView()
                            }
                        }

                        HStack(spacing: 8) {
                            Button {
                                Task { await vm.confirmUpgrade(app: app, to: ver, customCompose: nil) }
                            } label: {
                                Label("直接升级", systemImage: "arrow.up.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .disabled(vm.upgradingVersionId != nil)

                            Button {
                                vm.selectedVersion = ver
                                showComposeEditor = true
                            } label: {
                                Label("对比/编辑", systemImage: "doc.text.magnifyingglass")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(vm.upgradingVersionId != nil)
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task { await vm.ignoreUpgrade(app: app, version: ver) }
                        } label: {
                            Label("忽略此版本", systemImage: "eye.slash")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 卸载应用 Sheet

struct UninstallSheetView: View {
    let app: AppInstall
    @ObservedObject var vm: AppsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var deleteDB = true
    @State private var deleteImage = false
    @State private var deleteBackup = false
    @State private var forceDelete = false
    @State private var confirmName = ""

    private var nameMatches: Bool {
        confirmName == (app.name ?? "") || confirmName == app.displayName
    }

    private var canSubmit: Bool {
        nameMatches && !vm.isUninstalling
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("即将卸载 \(app.displayName)")
                                .font(.subheadline.bold())
                            Text("该操作不可撤销，容器和数据将被删除")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Section {
                    Toggle("同时删除数据库", isOn: $deleteDB)
                    Toggle("删除镜像", isOn: $deleteImage)
                    Toggle("删除备份", isOn: $deleteBackup)
                    Toggle("强制删除", isOn: $forceDelete)
                } header: {
                    Text("清理选项")
                } footer: {
                    Text("默认勾选「删除数据库」与网页端行为一致。")
                }

                Section {
                    TextField("输入应用名称以确认", text: $confirmName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("确认操作")
                } footer: {
                    Text("请输入 \(app.name ?? app.displayName) 以开启卸载按钮。")
                }

                if vm.isUninstalling {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在卸载…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("卸载应用")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("卸载", role: .destructive) {
                        Task { await performUninstall() }
                    }
                    .disabled(!canSubmit)
                }
            }
        }
    }

    private func performUninstall() async {
        await vm.uninstall(
            app: app,
            deleteDB: deleteDB,
            deleteImage: deleteImage,
            deleteBackup: deleteBackup,
            forceDelete: forceDelete
        )
        // 失败时 vm.alertMessage 已携带错误，成功时则携带成功消息
        // 无论成功失败都关闭 sheet，alert 会在详情页/列表上展示
        if vm.uninstallDone {
            dismiss()
        }
    }
}

// MARK: - 更新参数 Sheet（重建应用）

struct UpdateParamsSheetView: View {
    let app: AppInstall
    @ObservedObject var vm: AppsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var paramsResp: InstalledParamsResponse?
    @State private var isLoading = true
    @State private var loadError: String?

    // 表单值
    @State private var paramValues: [String: String] = [:]
    @State private var containerName = ""
    @State private var allowPort = false
    @State private var restartPolicy = "always"
    @State private var cpuQuota = 0
    @State private var memoryLimit = 0
    @State private var memoryUnit = "MB"
    @State private var editCompose = false
    @State private var customCompose = ""

    private let restartPolicies = ["no", "always", "on-failure", "unless-stopped"]
    private let memoryUnits = ["MB", "GB"]

    private var hasLoaded: Bool { paramsResp != nil }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("加载参数…")
                } else if let resp = paramsResp {
                    paramsForm(resp)
                } else {
                    ContentUnavailableView {
                        Label("无法加载参数", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError ?? "请稍后重试")
                    } actions: {
                        Button("重试") { Task { await load() } }
                    }
                }
            }
            .navigationTitle("更新参数")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("更新") {
                        Task { await performUpdate() }
                    }
                    .disabled(!hasLoaded || vm.isUpdatingParams)
                }
            }
        }
        .task { await load() }
        .alert("提示", isPresented: $vm.showAlert) {
            Button("好的", role: .cancel) {
                if vm.paramsUpdated { dismiss() }
            }
        } message: {
            Text(vm.alertMessage)
        }
    }

    @ViewBuilder
    private func paramsForm(_ resp: InstalledParamsResponse) -> some View {
        Form {
            // 参数列表
            if let fields = resp.params, !fields.isEmpty {
                Section {
                    ForEach(fields) { field in
                        if field.edit == true {
                            InstalledParamEditRow(field: field, value: binding(for: field))
                        } else {
                            InstalledParamReadRow(field: field)
                        }
                    }
                } header: {
                    Text("参数")
                } footer: {
                    Text("修改后将重建容器使参数生效。")
                }
            }

            // 容器配置
            Section {
                HStack {
                    Text("容器名").foregroundStyle(.secondary)
                    Spacer()
                    TextField("", text: $containerName)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("端口外部访问", isOn: $allowPort)
                Picker("重启规则", selection: $restartPolicy) {
                    ForEach(restartPolicies, id: \.self) { Text($0).tag($0) }
                }
            } header: {
                Text("容器配置")
            }

            // 资源限制
            Section {
                HStack {
                    Text("CPU 核心").foregroundStyle(.secondary)
                    Spacer()
                    TextField("0", value: $cpuQuota, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    Text("核").foregroundStyle(.secondary).font(.caption)
                }
                HStack {
                    Text("内存限制").foregroundStyle(.secondary)
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
                Text("资源限制")
            } footer: {
                Text("填 0 表示不限制")
            }

            // docker-compose
            Section {
                Toggle("编辑 docker-compose.yml", isOn: $editCompose)
                    .onChange(of: editCompose) { _, isOn in
                        if isOn && customCompose.isEmpty {
                            customCompose = resp.dockerCompose ?? resp.rawCompose ?? ""
                        }
                    }
            } header: {
                Text("docker-compose")
            }

            if editCompose {
                Section {
                    TextEditor(text: $customCompose)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 200)
                } footer: {
                    Text("编辑后将使用自定义内容覆盖默认编排文件")
                }
            }

            // 当前 compose 预览（只读）
            if !editCompose, let raw = resp.rawCompose, !raw.isEmpty {
                Section {
                    CodePreview(text: raw, color: .secondary)
                        .frame(minHeight: 140)
                } header: {
                    Text("当前 docker-compose.yml")
                }
            }

            if vm.isUpdatingParams {
                Section {
                    HStack {
                        ProgressView()
                        Text("正在更新…")
                    }
                }
            }
        }
    }

    private func binding(for field: InstalledParamField) -> Binding<String> {
        let key = field.key ?? ""
        return Binding(
            get: { paramValues[key] ?? field.value?.stringValue ?? "" },
            set: { paramValues[key] = $0 }
        )
    }

    private func load() async {
        isLoading = true
        loadError = nil
        guard let resp = await vm.loadParams(for: app) else {
            loadError = vm.alertMessage
            isLoading = false
            return
        }
        self.paramsResp = resp
        // 用接口返回的当前值初始化
        if let fields = resp.params {
            for f in fields {
                if let k = f.key {
                    paramValues[k] = f.value?.stringValue ?? ""
                }
            }
        }
        containerName = resp.containerName ?? ""
        allowPort = resp.allowPort ?? false
        restartPolicy = resp.restartPolicy ?? "always"
        cpuQuota = resp.cpuQuota ?? 0
        memoryLimit = resp.memoryLimit ?? 0
        memoryUnit = resp.memoryUnit ?? "MB"
        customCompose = resp.dockerCompose ?? resp.rawCompose ?? ""
        isLoading = false
    }

    private func performUpdate() async {
        guard let resp = paramsResp else { return }
        var params: [String: AnyCodableValue] = [:]
        for (k, v) in paramValues {
            if let intVal = Int(v) {
                params[k] = .int(intVal)
            } else {
                params[k] = .string(v)
            }
        }
        let compose = editCompose ? customCompose : (resp.dockerCompose ?? resp.rawCompose ?? "")
        let req = AppParamsUpdateRequest(
            webUI: resp.webUI ?? "",
            installId: app.id,
            params: params,
            advanced: true,
            memoryLimit: memoryLimit,
            cpuQuota: cpuQuota,
            memoryUnit: memoryUnit,
            allowPort: allowPort,
            containerName: containerName,
            editCompose: editCompose,
            dockerCompose: compose,
            restartPolicy: restartPolicy
        )
        await vm.updateParams(app: app, req: req)
    }
}

/// 已安装参数 - 可编辑行
struct InstalledParamEditRow: View {
    let field: InstalledParamField
    @Binding var value: String

    var body: some View {
        switch field.type ?? "text" {
        case "number":
            HStack {
                Text(field.displayLabel).foregroundStyle(.secondary)
                Spacer()
                TextField("", text: $value)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
            }
        case "select":
            Picker(field.displayLabel, selection: $value) {
                ForEach(field.values ?? [], id: \.self) { v in
                    Text(v).tag(v)
                }
            }
        default:
            HStack {
                Text(field.displayLabel).foregroundStyle(.secondary)
                Spacer()
                TextField("", text: $value)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

/// 已安装参数 - 只读行（edit=false）
struct InstalledParamReadRow: View {
    let field: InstalledParamField

    var body: some View {
        HStack {
            Text(field.displayLabel).foregroundStyle(.secondary)
            Spacer()
            Text(field.value?.stringValue ?? "—")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Compose 文件对比/编辑页

struct ComposeEditorView: View {
    let app: AppInstall
    let version: AppVersion
    @ObservedObject var vm: AppsViewModel
    let onBack: () -> Void

    @State private var useCustom = false
    @State private var editedCompose = ""
    @State private var showDiff = true

    private var newCompose: String {
        version.dockerCompose ?? ""
    }

    private var oldCompose: String {
        app.currentDockerCompose ?? app.dockerCompose ?? ""
    }

    var body: some View {
        List {
            // 模式切换
            Section {
                Toggle(isOn: $useCustom) {
                    Label(useCustom ? "使用自定义配置" : "使用默认配置",
                          systemImage: useCustom ? "wand.and.stars" : "doc")
                }
                .tint(.orange)

                if useCustom {
                    Text("已启用自定义 docker-compose.yml，请仔细检查内容")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("配置模式")
            }

            // 操作按钮
            Section {
                Button {
                    Task {
                        let compose = useCustom ? editedCompose : nil
                        await vm.confirmUpgrade(app: app, to: version, customCompose: compose)
                        if vm.upgradeSuccess {
                            onBack()
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        Label(useCustom ? "使用自定义配置升级" : "使用默认配置升级",
                              systemImage: "arrow.up.circle.fill")
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(vm.upgradingVersionId != nil)

                if vm.upgradingVersionId != nil {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text("正在升级…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            // 当前版本（只读）
            Section {
                CodePreview(text: oldCompose, color: .secondary)
                    .frame(minHeight: 160)
            } header: {
                HStack {
                    Text("当前版本")
                    Spacer()
                    Text("v\(app.version ?? "?")")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            // 新版本（可编辑）
            Section {
                if useCustom {
                    TextEditor(text: $editedCompose)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 240)
                        .scrollContentBackground(.hidden)
                        .background(Color(.secondarySystemBackground))
                } else {
                    CodePreview(text: newCompose, color: .primary)
                        .frame(minHeight: 200)
                }
            } header: {
                HStack {
                    Text(useCustom ? "自定义配置（可编辑）" : "新版本")
                    Spacer()
                    Text("v\(version.version ?? "?")")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            // 重置自定义编辑
            if useCustom {
                Section {
                    Button(role: .destructive) {
                        editedCompose = newCompose
                    } label: {
                        Label("重置为新版本默认值", systemImage: "arrow.counterclockwise")
                    }
                }
            }
        }
        .navigationTitle("docker-compose.yml")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if editedCompose.isEmpty {
                editedCompose = newCompose
            }
        }
    }
}

/// 只读代码预览
struct CodePreview: View {
    let text: String
    let color: Color

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "(空)" : text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

// MARK: - 应用行

struct AppRow: View {
    let app: AppInstall
    var isOperating: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(app.statusColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                if isOperating {
                    ProgressView()
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: app.statusIcon)
                        .font(.title3)
                        .foregroundStyle(app.statusColor)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(app.displayName)
                        .font(.body.bold())
                        .lineLimit(1)

                    if let v = app.version, !v.isEmpty {
                        Text("v\(v)")
                            .font(.caption2.monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                            .foregroundStyle(.secondary)
                    }

                    if app.canUpdate == true {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.up.circle.fill")
                            Text("可更新")
                        }
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .clipShape(Capsule())
                        .foregroundStyle(.orange)
                    }
                }

                if let container = app.container, !container.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "cylinder")
                            .font(.caption2)
                        Text(container)
                            .lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text((app.status ?? "未知").capitalized)
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(app.statusColor.opacity(0.15))
                        .foregroundStyle(app.statusColor)
                        .clipShape(Capsule())

                    if let port = app.httpPort, port > 0 {
                        Label("\(port)", systemImage: "network")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 应用日志查看（SSE 流式）

struct AppLogView: View {
    let app: AppInstall
    @ObservedObject var vm: AppsViewModel

    @State private var logLines: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isFollowing = true
    @State private var tail: Int = 200
    @State private var sinceMode = "all"
    @State private var streamTask: Task<Void, Never>?
    @State private var hasMoreAtTop = false

    /// 构造 compose 路径：path + /docker-compose.yml
    private var composePath: String {
        var p = app.path ?? ""
        if p.isEmpty {
            // 兜底：/opt/1panel/apps/<appKey>/<serviceName>/
            p = "/opt/1panel/apps/\(app.appKey ?? app.serviceName ?? "")/\(app.serviceName ?? "")"
        }
        if !p.hasSuffix("/") { p += "/" }
        return p + "docker-compose.yml"
    }

    private let sinceOptions: [(value: String, label: String)] = [
        ("all", "全部"),
        ("30m", "近30分钟"),
        ("2h", "近2小时"),
        ("24h", "近24小时"),
        ("7d", "近7天")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // 工具条
            controlBar
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))

            Divider()

            // 日志内容
            logContent

            Divider()

            // 跟随尾部开关
            followBar
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemBackground))
        }
        .navigationTitle("应用日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await startStreaming() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .task { await startStreaming() }
        .onDisappear { streamTask?.cancel() }
    }

    // 控制条
    private var controlBar: some View {
        HStack(spacing: 12) {
            // 时间范围
            Picker("", selection: $sinceMode) {
                ForEach(sinceOptions, id: \.value) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: sinceMode) { _, _ in
                Task { await startStreaming() }
            }

            Spacer()

            // 行数
            HStack(spacing: 4) {
                Text("行数")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $tail) {
                    Text("100").tag(100)
                    Text("200").tag(200)
                    Text("500").tag(500)
                    Text("1000").tag(1000)
                }
                .pickerStyle(.menu)
            }
        }
    }

    // 跟随开关条
    private var followBar: some View {
        HStack {
            if isLoading {
                ProgressView()
                    .scaleEffect(0.7)
                Text("流式接收中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text("已断开")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: $isFollowing) {
                Label("跟随最新", systemImage: "arrow.down")
                    .font(.caption)
            }
            .toggleStyle(.button)
            .tint(.blue)
        }
    }

    // 日志内容主体
    @ViewBuilder
    private var logContent: some View {
        if logLines.isEmpty && isLoading {
            ProgressView("加载日志…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if logLines.isEmpty {
            ContentUnavailableView(
                "暂无日志",
                systemImage: "doc.text",
                description: Text(errorMessage ?? "该应用暂未产生日志")
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: logLines.count) { _, _ in
                    if isFollowing {
                        withAnimation {
                            proxy.scrollTo(logLines.count - 1, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    if isFollowing && !logLines.isEmpty {
                        proxy.scrollTo(logLines.count - 1, anchor: .bottom)
                    }
                }
            }
        }
    }

    // 启动/重启流式拉取
    private func startStreaming() async {
        streamTask?.cancel()
        logLines.removeAll()
        errorMessage = nil
        isLoading = true

        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "compose", value: composePath),
            URLQueryItem(name: "since", value: sinceMode),
            URLQueryItem(name: "tail", value: String(tail)),
            URLQueryItem(name: "follow", value: "true"),
            URLQueryItem(name: "operateNode", value: "local")
        ]

        streamTask = Task {
            do {
                let stream = vm.client.streamSSELines(
                    path: "/api/v2/containers/search/log",
                    queryItems: queryItems
                )
                // 控制最大缓存行数，避免内存爆炸
                let maxLines = max(tail * 5, 1000)
                for try await line in stream {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        if logLines.count >= maxLines {
                            logLines.removeFirst(logLines.count - maxLines + 1)
                        }
                        logLines.append(line)
                    }
                }
                await MainActor.run { isLoading = false }
            } catch {
                await MainActor.run {
                    isLoading = false
                    if logLines.isEmpty {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }
}

// MARK: - ViewModel

@MainActor
final class AppsViewModel: ObservableObject {
    @Published var apps: [AppInstall] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var operatingAppIds: Set<Int> = []

    // 升级相关
    @Published var showUpgradeSheet = false
    @Published var availableVersions: [AppVersion] = []
    @Published var isLoadingVersions = false
    @Published var upgradingVersionId: Int?
    /// 当前选中的要升级到的版本（在 ComposeEditorView 里使用）
    @Published var selectedVersion: AppVersion?
    /// 标记升级是否成功完成（用于编辑器返回时的判断）
    @Published var upgradeSuccess = false

    // 操作提示
    @Published var showAlert = false
    @Published var alertMessage = ""

    // 卸载相关
    @Published var isUninstalling = false
    @Published var uninstallDone = false

    // 更新参数相关
    @Published var isLoadingParams = false
    @Published var loadedParams: InstalledParamsResponse?
    @Published var isUpdatingParams = false
    @Published var paramsUpdated = false

    /// 标记列表需要刷新（在详情页操作后置 true，返回列表时触发刷新）
    @Published var needsRefresh = false

    private(set) var client: APIClient

    var updatableCount: Int {
        apps.filter { $0.canUpdate == true }.count
    }

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    func refresh() async {
        await load(query: "")
    }

    func search(query: String) async {
        await load(query: query)
    }

    private func load(query: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // update=false 返回全部应用但 canUpdate 始终 false（后端不计算）
        // update=true  只返回可更新的应用，但正确计算 canUpdate
        // 通过 logs/输出20.log 验证：两者 total 不同
        // 解决方案：先拿全部应用，再并发拿可更新列表，用后者标记前者的 canUpdate
        let allReq = AppInstalledSearchRequest(
            page: 1, pageSize: 100, name: query, type: "", tags: [],
            update: false, all: false, unused: false, sync: false
        )
        // 查询可更新列表时不用 name 过滤，因为可能被搜索词过滤掉
        let updatableReq = AppInstalledSearchRequest(
            page: 1, pageSize: 100, name: "", type: "", tags: [],
            update: true, all: false, unused: false, sync: false
        )

        do {
            async let allResp: AppInstalledListResponse = client.send(
                path: APIEndpoint.appsInstalledSearch.path,
                body: allReq,
                as: AppInstalledListResponse.self
            )
            async let updatableResp: AppInstalledListResponse = client.send(
                path: APIEndpoint.appsInstalledSearch.path,
                body: updatableReq,
                as: AppInstalledListResponse.self
            )
            // 并发拉取已忽略列表（GET 接口，失败不阻断主流程）
            async let ignoredResp: [AppIgnoreUpgrade] = client.send(
                path: APIEndpoint.appsIgnoredList.path,
                method: APIEndpoint.appsIgnoredList.method,
                as: [AppIgnoreUpgrade].self
            )

            let (all, updatable) = try await (allResp, updatableResp)
            // ignored 拉取失败则降级为空数组（不阻断应用列表展示）
            let ignored = (try? await ignoredResp) ?? []
            var apps = all.items ?? []
            let updatableMap = Dictionary((updatable.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // 构建 appID → ignoredRecordID 映射
            let ignoredMap = Dictionary(ignored.compactMap { item -> (Int, Int)? in
                guard let appID = item.appID else { return nil }
                return (appID, item.id)
            }, uniquingKeysWith: { a, _ in a })

            // 合并可更新状态、dockerCompose、忽略记录 ID
            for i in apps.indices {
                if let updatableApp = updatableMap[apps[i].id] {
                    apps[i].canUpdate = true
                    apps[i].currentDockerCompose = updatableApp.dockerCompose
                } else {
                    apps[i].canUpdate = false
                }
                if let appID = apps[i].appID {
                    apps[i].ignoredRecordID = ignoredMap[appID]
                }
            }
            self.apps = apps
        } catch let err as APIError {
            self.errorMessage = err.errorDescription
            self.apps = []
        } catch {
            self.errorMessage = error.localizedDescription
            self.apps = []
        }
    }

    // MARK: - 启动/停止/重启

    func operate(app: AppInstall, op: AppOperation) async {
        operatingAppIds.insert(app.id)
        defer { operatingAppIds.remove(app.id) }

        let req = AppInstalledOperateRequest(installId: app.id, operate: op.rawValue)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledOperate.path,
                body: req,
                as: EmptyResponse.self
            )
            // rebuild 是异步操作，状态不会立即变化，需要明确反馈
            if op == .rebuild {
                showAlert(message: "\(app.displayName) 重建请求已提交，容器正在后台重建…")
                needsRefresh = true
            } else {
                try? await Task.sleep(for: .seconds(1))
                await load(query: "")
            }
        } catch let err as APIError {
            showAlert(message: "\(op.displayName)失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "\(op.displayName)失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 升级流程

    func loadVersions(for app: AppInstall) async {
        availableVersions = []
        isLoadingVersions = true
        showUpgradeSheet = true

        do {
            let versions: [AppVersion] = try await client.send(
                path: APIEndpoint.appsUpdateVersions.path,
                body: AppUpdateVersionsRequest(appInstallId: app.id),
                as: [AppVersion].self
            )
            let currentDetailId = app.appDetailID ?? -1
            self.availableVersions = versions.filter { $0.detailId != currentDetailId }
        } catch let err as APIError {
            showAlert(message: "查询版本失败：\(err.errorDescription ?? "未知错误")")
            showUpgradeSheet = false
        } catch {
            showAlert(message: "查询版本失败：\(error.localizedDescription)")
            showUpgradeSheet = false
        }
        isLoadingVersions = false
    }

    func confirmUpgrade(app: AppInstall, to version: AppVersion, customCompose: String?) async {
        upgradingVersionId = version.detailId
        upgradeSuccess = false
        defer { upgradingVersionId = nil }

        let req = AppInstalledOperateRequest(
            installId: app.id,
            operate: AppOperation.upgrade.rawValue,
            detailId: version.detailId,
            backup: false,
            pullImage: true,
            dockerCompose: customCompose
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledOperate.path,
                body: req,
                as: EmptyResponse.self
            )
            upgradeSuccess = true
            showUpgradeSheet = false
            // 延迟显示 alert，避免 sheet 关闭动画"吞掉" alert 状态
            try? await Task.sleep(for: .milliseconds(300))
            showAlert(message: "升级请求已提交，应用正在后台更新中…")
            try? await Task.sleep(for: .seconds(4))
            await load(query: "")
        } catch let err as APIError {
            showAlert(message: "升级失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "升级失败：\(error.localizedDescription)")
        }
    }

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }

    // MARK: - 忽略升级

    /// 忽略指定版本的升级（在版本列表里左滑）
    func ignoreUpgrade(app: AppInstall, version: AppVersion) async {
        let req = AppIgnoreUpgradeRequest(
            appID: app.appID ?? 0,
            scope: "version",
            appDetailID: version.detailId
        )
        await performIgnore(req: req, app: app, successMsg: "已忽略 v\(version.version ?? "") 的升级提示")
    }

    /// 忽略所有版本的升级（在详情页）
    func ignoreUpgrade(app: AppInstall) async {
        let req = AppIgnoreUpgradeRequest(
            appID: app.appID ?? 0,
            scope: "all",
            appDetailID: nil
        )
        await performIgnore(req: req, app: app, successMsg: "已忽略该应用的所有升级提示")
    }

    private func performIgnore(req: AppIgnoreUpgradeRequest, app: AppInstall, successMsg: String) async {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledIgnore.path,
                body: req,
                as: EmptyResponse.self
            )
            showUpgradeSheet = false
            // 延迟显示 alert，避免 sheet 关闭动画"吞掉" alert 状态
            try? await Task.sleep(for: .milliseconds(300))
            showAlert(message: successMsg)
            // 不立即修改 apps 数组（会破坏 NavigationStack），标记返回列表时再刷新
            needsRefresh = true
        } catch let err as APIError {
            showAlert(message: "操作失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "操作失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 取消忽略升级

    /// 取消指定应用的忽略升级（直接用已加载的 ignoredRecordID）
    func cancelIgnoreUpgrade(app: AppInstall) async {
        guard let recordID = app.ignoredRecordID else {
            showAlert(message: "该应用当前未在忽略列表中")
            return
        }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsIgnoredCancel.path,
                body: ReqWithID(id: recordID),
                as: EmptyResponse.self
            )
            showAlert(message: "已取消忽略升级，后续将正常检查更新")
            needsRefresh = true
        } catch let err as APIError {
            showAlert(message: "取消忽略失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "取消忽略失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 更新参数（重建应用）

    /// 加载已安装应用的当前参数（用于「更新参数」表单）
    @MainActor
    func loadParams(for app: AppInstall) async -> InstalledParamsResponse? {
        isLoadingParams = true
        defer { isLoadingParams = false }
        let path = APIEndpoint.appsInstalledParams.path
            .replacingOccurrences(of: ":installId", with: String(app.id))
        do {
            let resp: InstalledParamsResponse = try await client.send(
                path: path,
                method: APIEndpoint.appsInstalledParams.method,
                as: InstalledParamsResponse.self
            )
            self.loadedParams = resp
            return resp
        } catch let err as APIError {
            showAlert(message: "加载参数失败：\(err.errorDescription ?? "未知错误")")
            return nil
        } catch {
            showAlert(message: "加载参数失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 提交参数更新（重建应用）
    func updateParams(app: AppInstall, req: AppParamsUpdateRequest) async {
        isUpdatingParams = true
        paramsUpdated = false
        defer { isUpdatingParams = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledParamsUpdate.path,
                body: req,
                as: EmptyResponse.self
            )
            paramsUpdated = true
            showAlert(message: "参数更新请求已提交，应用正在后台重建中…")
            needsRefresh = true
        } catch let err as APIError {
            showAlert(message: "更新失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "更新失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 卸载应用

    /// 卸载应用（先做删除前检查，再调用 delete 操作）
    /// options: deleteDB（删除数据库） / deleteImage（删除镜像） / deleteBackup（删除备份） / forceDelete（强制删除）
    func uninstall(app: AppInstall,
                   deleteDB: Bool,
                   deleteImage: Bool,
                   deleteBackup: Bool,
                   forceDelete: Bool) async {
        isUninstalling = true
        uninstallDone = false
        defer { isUninstalling = false }

        // 0. 联动检查：查询是否存在一键部署类网站引用了该应用
        do {
            let searchReq = WebsiteSearchRequest(
                name: "", page: 1, pageSize: 200,
                orderBy: "created_at", order: "descending",
                websiteGroupId: 0, type: ""
            )
            let resp: WebsiteListResponse = try await client.send(
                path: APIEndpoint.websitesSearch.path,
                body: searchReq,
                as: WebsiteListResponse.self
            )
            let linked = (resp.items ?? []).filter {
                ($0.appType?.lowercased() == "installed" || ($0.type ?? "").lowercased() == "deployment")
                && ($0.appName ?? "").lowercased() == (app.appName ?? app.name ?? "").lowercased()
            }
            if !linked.isEmpty {
                let names = linked.map { $0.displayName }.joined(separator: "、")
                showAlert(message: "该应用被以下网站使用：\(names)。请先在「工具箱 → 网站」中删除对应网站（删除时可勾选删除关联应用），再卸载此应用。")
                return
            }
        } catch {
            // 网站查询失败时不阻塞卸载，继续走原有流程
        }

        // 1. 删除前检查（若后端返回错误，会在 catch 里展示；返回 null 视为允许删除）
        let checkPath = APIEndpoint.appsInstalledDeleteCheck.path
            .replacingOccurrences(of: ":installId", with: String(app.id))
        do {
            // 后端 data 为 null，使用 EmptyResponse 解析（APIClient 对其容忍 null）
            let _: EmptyResponse = try await client.send(
                path: checkPath,
                method: "GET",
                as: EmptyResponse.self
            )
        } catch let err as APIError {
            showAlert(message: "无法卸载：\(err.errorDescription ?? "未知错误")")
            return
        } catch {
            showAlert(message: "无法卸载：\(error.localizedDescription)")
            return
        }
        // 2. 执行删除
        let req = AppInstalledOperateRequest(
            installId: app.id,
            operate: "delete",
            deleteDB: deleteDB,
            deleteImage: deleteImage,
            forceDelete: forceDelete,
            deleteBackup: deleteBackup
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledOperate.path,
                body: req,
                as: EmptyResponse.self
            )
            uninstallDone = true
            showAlert(message: "卸载请求已提交，应用正在后台清理…")
            needsRefresh = true
        } catch let err as APIError {
            showAlert(message: "卸载失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "卸载失败：\(error.localizedDescription)")
        }
    }
}

extension AppOperation {
    var displayName: String {
        switch self {
        case .start: return "启动"
        case .stop: return "停止"
        case .restart: return "重启"
        case .upgrade: return "升级"
        case .rebuild: return "重建"
        }
    }
}
