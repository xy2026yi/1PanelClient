//
//  AppParamsViews.swift
//  1PanelClient
//

import SwiftUI

// MARK: - 更新参数（重建应用）push 导航

struct UpdateParamsView: View {
    let app: AppInstall
    @ObservedObject var vm: AppsViewModel

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
            ToolbarItem(placement: .confirmationAction) {
                Button("更新") {
                    Task { await performUpdate() }
                }
                .disabled(!hasLoaded || vm.isUpdatingParams)
            }
        }
        .task { await load() }
        .alert("提示", isPresented: $vm.showAlert) {
            Button("好的", role: .cancel) {}
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
    @State private var deleteOldImage: Bool

    init(
        app: AppInstall,
        version: AppVersion,
        vm: AppsViewModel,
        initialDeleteOldImage: Bool,
        onBack: @escaping () -> Void
    ) {
        self.app = app
        self.version = version
        self.vm = vm
        self.onBack = onBack
        _deleteOldImage = State(initialValue: initialDeleteOldImage)
    }

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

            Section {
                Toggle("升级后删除旧镜像", isOn: $deleteOldImage)
                    .tint(.orange)
            } header: {
                Text("升级选项")
            } footer: {
                Text("默认关闭。开启后升级请求会删除旧镜像以释放存储空间")
            }

            // 操作按钮
            Section {
                Button {
                    Task {
                        let compose = useCustom ? editedCompose : nil
                        let taskID = UUID().uuidString
                        await vm.confirmUpgrade(
                            app: app,
                            to: version,
                            customCompose: compose,
                            deleteOldImage: deleteOldImage,
                            taskID: taskID
                        )
                        if vm.upgradeSuccess {
                            onBack()
                            // 编辑器返回后，UpgradeSheetView 的进度导航目标会接管，
                            // 显示升级任务进度（vm.showUpgradeProgress 已由 confirmUpgrade 置位）
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
                } else if newCompose.isEmpty {
                    ContentUnavailableView(
                        "未获取到新版本配置",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("请返回后重新打开升级对比，或检查版本接口是否返回 dockerCompose 字段")
                    )
                    .frame(minHeight: 160)
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

