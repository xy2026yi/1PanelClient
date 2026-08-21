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
                ProgressView(L10n.t("加载参数…"))
            } else if let resp = paramsResp {
                paramsForm(resp)
            } else {
                ContentUnavailableView {
                    Label(L10n.t("无法加载参数"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError ?? L10n.t("请稍后重试"))
                } actions: {
                    Button(L10n.t("重试")) { Task { await load() } }
                }
            }
        }
        .navigationTitle(L10n.t("更新参数"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.t("更新")) {
                    Task { await performUpdate() }
                }
                .disabled(!hasLoaded || vm.isUpdatingParams)
            }
        }
        .task { await load() }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
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
                    Text(L10n.t("参数"))
                } footer: {
                    Text(L10n.t("修改后将重建容器使参数生效。"))
                }
            }

            // 容器配置
            Section {
                HStack {
                    Text(L10n.t("容器名")).foregroundStyle(.secondary)
                    Spacer()
                    TextField("", text: $containerName)
                        .multilineTextAlignment(.trailing)
                }
                Toggle(L10n.t("端口外部访问"), isOn: $allowPort)
                Picker(L10n.t("重启规则"), selection: $restartPolicy) {
                    ForEach(restartPolicies, id: \.self) { Text($0).tag($0) }
                }
            } header: {
                Text(L10n.t("容器配置"))
            }

            // 资源限制
            Section {
                HStack {
                    Text(L10n.t("CPU 核心")).foregroundStyle(.secondary)
                    Spacer()
                    TextField("0", value: $cpuQuota, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    Text(L10n.t("核")).foregroundStyle(.secondary).font(.caption)
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

            // docker-compose
            Section {
                Toggle(L10n.t("编辑 docker-compose.yml"), isOn: $editCompose)
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
                    Text(L10n.t("编辑后将使用自定义内容覆盖默认编排文件"))
                }
            }

            // 当前 compose 预览（只读）
            if !editCompose, let raw = resp.rawCompose, !raw.isEmpty {
                Section {
                    CodePreview(text: raw, color: .secondary)
                        .frame(minHeight: 140)
                } header: {
                    Text(L10n.t("当前 docker-compose.yml"))
                }
            }

            if vm.isUpdatingParams {
                Section {
                    HStack {
                        ProgressView()
                        Text(L10n.t("正在更新…"))
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
    /// 对比模式下已采纳「采用旧配置」的差异块（hunk 下标集合）
    @State private var adoptedHunks: Set<Int> = []

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

    private var diff: ComposeDiff {
        ComposeDiff(old: ComposeDiff.lines(of: oldCompose), new: ComposeDiff.lines(of: newCompose))
    }

    /// 按采纳块生成的合并结果（未采纳任何块时与新版默认值一致）
    private var mergedCompose: String {
        ComposeDiff.text(of: diff.applying(adoption: adoptedHunks))
    }

    var body: some View {
        List {
            // 模式切换
            Section {
                Toggle(isOn: $useCustom) {
                    Label(useCustom ? L10n.t("使用自定义配置") : L10n.t("使用默认配置"),
                          systemImage: useCustom ? "wand.and.stars" : "doc")
                }
                .tint(.orange)

                if useCustom {
                    Text(L10n.t("已启用自定义 docker-compose.yml，请仔细检查内容"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text(L10n.t("配置模式"))
            }

            Section {
                Toggle(L10n.t("升级后删除旧镜像"), isOn: $deleteOldImage)
                    .tint(.orange)
            } header: {
                Text(L10n.t("升级选项"))
            } footer: {
                Text(L10n.t("默认关闭。开启后升级请求会删除旧镜像以释放存储空间"))
            }

            // 操作按钮
            Section {
                Button {
                    Task {
                        // 对比模式采纳了差异块时提交合并结果；否则提交默认（nil）
                        let compose: String?
                        if useCustom {
                            compose = editedCompose
                        } else if adoptedHunks.isEmpty {
                            compose = nil
                        } else {
                            compose = mergedCompose
                        }
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
                        Label(upgradeButtonTitle, systemImage: "arrow.up.circle.fill")
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(vm.upgradingVersionId != nil)

                if vm.upgradingVersionId != nil {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text(L10n.t("正在升级…"))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            // 当前版本（只读，差异行红底）
            Section {
                DiffOldComposeView(diff: diff)
                    .frame(minHeight: 160)
            } header: {
                HStack {
                    Text(L10n.t("当前版本"))
                    Spacer()
                    Text("v\(app.version ?? "?")")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            // 新版本（对比模式：可按块采用旧配置；自定义模式：文本编辑）
            Section {
                if useCustom {
                    TextEditor(text: $editedCompose)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 240)
                        .scrollContentBackground(.hidden)
                        .background(Color(.secondarySystemBackground))
                } else if newCompose.isEmpty {
                    ContentUnavailableView(
                        L10n.t("未获取到新版本配置"),
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(L10n.t("请返回后重新打开升级对比，或检查版本接口是否返回 dockerCompose 字段"))
                    )
                    .frame(minHeight: 160)
                } else {
                    if !adoptedHunks.isEmpty {
                        Text(L10n.f("已选择 %ld 处差异采用旧配置，将按此内容升级", adoptedHunks.count))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    DiffNewComposeView(diff: diff, adopted: $adoptedHunks)
                        .frame(minHeight: 240)
                }
            } header: {
                HStack {
                    Text(useCustom ? L10n.t("自定义配置（可编辑）") : L10n.t("新版本"))
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
                        Label(L10n.t("重置为新版本默认值"), systemImage: "arrow.counterclockwise")
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
        // 开启自定义编辑时以当前合并结果为起点（含已采纳的旧配置块）
        .onChange(of: useCustom) { _, enabled in
            if enabled {
                editedCompose = mergedCompose
            }
        }
    }

    private var upgradeButtonTitle: String {
        if useCustom { return L10n.t("使用自定义配置升级") }
        return adoptedHunks.isEmpty ? L10n.t("使用默认配置升级") : L10n.t("使用合并配置升级")
    }
}

// MARK: - 差异展示

/// 旧配置只读展示：差异行红底，相同行灰
struct DiffOldComposeView: View {
    let diff: ComposeDiff

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.oldLines.enumerated()), id: \.offset) { idx, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(diff.oldKinds[idx] == .changed ? .primary : .secondary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            diff.oldKinds[idx] == .changed ? Color.red.opacity(0.12) : Color.clear
                        )
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// 新配置交互展示：差异块可整体「采用旧配置」（再次点击切回），位置不变
struct DiffNewComposeView: View {
    let diff: ComposeDiff
    @Binding var adopted: Set<Int>

    /// 渲染行（拍平后的稳定 id，避免多个 ForEach 的 id 冲突）
    private struct Row: Identifiable {
        enum Kind {
            case plain(String)
            case hunkButton(index: Int, hunk: ComposeDiff.Hunk)
            case hunkLine(String, bg: Bg)
        }

        enum Bg {
            case fresh      // 新版本内容（绿）
            case adoptedOld // 采纳后使用的旧内容（橙）
            case excluded   // 不带入的内容（淡红）
        }

        let id: Int
        let kind: Kind
    }

    private var rows: [Row] {
        var result: [Row] = []
        var nextID = 0
        func add(_ kind: Row.Kind) {
            result.append(Row(id: nextID, kind: kind))
            nextID += 1
        }
        for seg in diff.segments {
            switch seg {
            case .equal(_, let newRange):
                for i in newRange {
                    add(.plain(diff.newLines[i]))
                }
            case .hunk(let index, let hunk):
                let isAdopted = adopted.contains(index)
                add(.hunkButton(index: index, hunk: hunk))
                if hunk.newRange.isEmpty {
                    // 仅删除块：显示旧内容（幽灵行），采纳后转橙
                    for i in hunk.oldRange {
                        add(.hunkLine(diff.oldLines[i], bg: isAdopted ? .adoptedOld : .excluded))
                    }
                } else if isAdopted {
                    for i in hunk.oldRange {
                        add(.hunkLine(diff.oldLines[i], bg: .adoptedOld))
                    }
                } else {
                    for i in hunk.newRange {
                        add(.hunkLine(diff.newLines[i], bg: .fresh))
                    }
                }
            }
        }
        return result
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    switch row.kind {
                    case .plain(let line):
                        lineView(line, bg: .clear, dimmed: true)
                    case .hunkButton(let index, let hunk):
                        hunkButton(index: index, hunk: hunk)
                    case .hunkLine(let line, let bg):
                        lineView(line, bg: bgColor(bg), dimmed: bg == .excluded)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func bgColor(_ bg: Row.Bg) -> Color {
        switch bg {
        case .fresh: return .green.opacity(0.12)
        case .adoptedOld: return .orange.opacity(0.18)
        case .excluded: return .red.opacity(0.06)
        }
    }

    private func lineView(_ line: String, bg: Color, dimmed: Bool) -> some View {
        Text(line.isEmpty ? " " : line)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(dimmed ? Color.secondary : Color.primary)
            .textSelection(.enabled)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bg)
    }

    private func hunkButton(index: Int, hunk: ComposeDiff.Hunk) -> some View {
        let isAdopted = adopted.contains(index)
        return Button {
            if isAdopted {
                adopted.remove(index)
            } else {
                adopted.insert(index)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isAdopted ? "arrow.uturn.backward.circle.fill" : "arrow.uturn.backward.circle")
                Text(buttonLabel(hunk, adopted: isAdopted))
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(isAdopted ? Color.orange : Color.blue)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func buttonLabel(_ hunk: ComposeDiff.Hunk, adopted isAdopted: Bool) -> String {
        if hunk.isDeletionOnly {
            return isAdopted ? L10n.t("移除此段") : L10n.t("恢复此段")
        }
        if hunk.isInsertionOnly {
            return isAdopted ? L10n.t("保留新增段") : L10n.t("移除新增段")
        }
        return isAdopted ? L10n.t("改用新配置") : L10n.t("采用旧配置")
    }
}

/// 只读代码预览
struct CodePreview: View {
    let text: String
    let color: Color

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? L10n.t("(空)") : text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

