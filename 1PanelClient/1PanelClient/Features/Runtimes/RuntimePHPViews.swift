//
//  RuntimePHPViews.swift
//  1PanelClient
//
//  PHP 专属配置子页：配置修改（含禁用函数/上传限制/超时）、性能调整、
//  负载状态、慢日志、配置文件（php.ini / php-fpm.conf）、容器配置。
//

import SwiftUI

// MARK: - 配置修改（11 项 + 禁用函数 + 上传限制 + 超时时间）

struct RuntimePHPSettingsView: View {
    let entry: RuntimeEntry
    let client: APIClient

    @State private var config: RuntimePHPConfig?
    @State private var paramEdits: [String: String] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var toast: String?
    @State private var isSaving = false

    // 禁用函数
    @State private var disableFunctions: [String] = []
    /// 服务端已保存的禁用函数（乐观更新失败时回滚）
    @State private var savedDisableFunctions: [String] = []
    @State private var isSavingFunctions = false
    @State private var newFunction = ""
    // 上传限制 / 超时
    @State private var uploadMaxSize = ""
    @State private var maxExecutionTime = ""

    var body: some View {
        Form {
            if isLoading {
                Section { LoadingStateView(compact: true).padding(.vertical, 20) }
            } else if let err = errorMessage {
                Section {
                    Text(err).font(.footnote).foregroundStyle(.red)
                    Button(L10n.t("重试")) { Task { await load() } }
                }
            } else if config != nil {
                paramsSection
                disableFunctionsSection
                limitsSection
            }
        }
        .navigationTitle(L10n.t("配置修改"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .toastOverlay(message: $toast)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let path = APIEndpoint.runtimesPhpConfigGet.path
                .replacingOccurrences(of: ":id", with: String(entry.id))
            let cfg: RuntimePHPConfig = try await client.send(
                path: path, method: APIEndpoint.runtimesPhpConfigGet.method,
                as: RuntimePHPConfig.self
            )
            config = cfg
            paramEdits = cfg.params ?? [:]
            disableFunctions = cfg.disableFunctions ?? []
            savedDisableFunctions = disableFunctions
            uploadMaxSize = cfg.uploadMaxSize ?? ""
            maxExecutionTime = cfg.maxExecutionTime ?? ""
        } catch {
            if !APIError.isCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    // MARK: 11 项 php.ini 参数（整组保存）

    private var paramsSection: some View {
        Section {
            ForEach(RuntimePHPParamKey.allCases) { key in
                if key.isToggle {
                    // On/Off（形态 3）
                    OutlinedPicker(label: key.title, options: ["On", "Off"],
                                   selection: toggleBinding(key))
                } else if key.isSize {
                    // 尺寸值拆单位（右侧固定）：8M → 数值 8 + 单位 M
                    OutlinedUnitField(label: key.title, unit: sizeUnit(key),
                                      text: sizeValueBinding(key))
                } else {
                    OutlinedTextField(label: key.title, text: textBinding(key),
                                      keyboardType: key.isNumeric ? .numberPad : .default)
                }
            }
            Button {
                Task { await saveParams() }
            } label: {
                if isSaving {
                    HStack(spacing: 8) { ProgressView().scaleEffect(0.8); Text(L10n.t("保存中…")) }
                } else {
                    Label(L10n.t("保存配置"), systemImage: "checkmark.circle")
                }
            }
            .disabled(isSaving)
        } header: {
            Text("php.ini")
        } footer: {
            Text(L10n.t("整组覆盖保存：未展示项沿用服务端默认值"))
        }
    }

    private func toggleBinding(_ key: RuntimePHPParamKey) -> Binding<String> {
        Binding(
            get: { paramEdits[key.rawValue] ?? "Off" },
            set: { paramEdits[key.rawValue] = $0 }
        )
    }

    private func textBinding(_ key: RuntimePHPParamKey) -> Binding<String> {
        Binding(
            get: { paramEdits[key.rawValue] ?? "" },
            set: { paramEdits[key.rawValue] = $0 }
        )
    }

    /// 尺寸字段拆分（128M → 数值 128 + 单位 M；无 K/M/G 后缀则单位为空）
    private static func sizeParts(_ raw: String) -> (value: String, unit: String) {
        guard let last = raw.last, last.isLetter,
              ["K", "M", "G"].contains(String(last).uppercased()) else {
            return (raw, "")
        }
        return (String(raw.dropLast()), String(last).uppercased())
    }

    private func sizeUnit(_ key: RuntimePHPParamKey) -> String {
        Self.sizeParts(paramEdits[key.rawValue] ?? "").unit
    }

    private func sizeValueBinding(_ key: RuntimePHPParamKey) -> Binding<String> {
        Binding(
            get: { Self.sizeParts(paramEdits[key.rawValue] ?? "").value },
            set: { newValue in
                let unit = Self.sizeParts(paramEdits[key.rawValue] ?? "").unit
                paramEdits[key.rawValue] = newValue + unit
            }
        )
    }

    private func saveParams() async {
        // 逐键校验：尺寸 = 数字 + 可选 K/M/G；数字键 = 纯数字（0 合法，如超时 0 = 不限）
        for key in RuntimePHPParamKey.allCases {
            let raw = (paramEdits[key.rawValue] ?? "").trimmingCharacters(in: .whitespaces)
            if key.isSize {
                guard raw.range(of: #"^\d+([KMG])?$"#, options: .regularExpression) != nil else {
                    toast = L10n.f("「%@」需为数字，可带 K/M/G 单位", key.title)
                    return
                }
            } else if key.isNumeric {
                guard raw.range(of: #"^\d+$"#, options: .regularExpression) != nil else {
                    toast = L10n.f("「%@」需为非负整数", key.title)
                    return
                }
            }
        }
        isSaving = true
        defer { isSaving = false }
        // 只提交 11 项固定键（服务端按 params 整组覆盖）
        let params = Dictionary(uniqueKeysWithValues:
            RuntimePHPParamKey.allCases.map { ($0.rawValue, paramEdits[$0.rawValue] ?? "") })
        let ok = await save(
            RuntimePHPConfigUpdateRequest(id: entry.id, params: params, scope: "params"),
            successMessage: L10n.t("配置已保存")
        )
        if ok {
            // 双状态互回写：php.ini 组保存后同步「上传与超时」区，
            // 防止另一侧残留旧值在后续整组保存时静默回滚
            uploadMaxSize = paramEdits[RuntimePHPParamKey.uploadMaxFilesize.rawValue] ?? ""
            maxExecutionTime = paramEdits[RuntimePHPParamKey.maxExecutionTime.rawValue] ?? ""
        }
    }

    // MARK: 禁用函数（全量数组覆盖）

    private var disableFunctionsSection: some View {
        Section {
            if disableFunctions.isEmpty {
                Text(L10n.t("未设置禁用函数"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(disableFunctions, id: \.self) { fn in
                    HStack {
                        Text(fn).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button {
                            guard !isSavingFunctions else { return }
                            disableFunctions.removeAll { $0 == fn }
                            Task { await saveDisableFunctions() }
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .disabled(isSavingFunctions)
                    }
                }
            }
            HStack {
                OutlinedTextField(label: L10n.t("添加函数"), prompt: "exec",
                                  text: $newFunction)
                Button(L10n.t("添加")) {
                    let fn = newFunction.trimmingCharacters(in: .whitespaces)
                    guard !fn.isEmpty, !disableFunctions.contains(fn), !isSavingFunctions else { return }
                    disableFunctions.append(fn)
                    newFunction = ""
                    Task { await saveDisableFunctions() }
                }
                .disabled(newFunction.trimmingCharacters(in: .whitespaces).isEmpty
                          || isSavingFunctions)
            }
        } header: {
            Text(L10n.t("禁用函数"))
        } footer: {
            Text(L10n.t("多个函数以数组提交，删除即从列表移除后保存"))
        }
    }

    private func saveDisableFunctions() async {
        isSavingFunctions = true
        defer { isSavingFunctions = false }
        let ok = await save(RuntimePHPConfigUpdateRequest(
            id: entry.id, scope: "disable_functions", disableFunctions: disableFunctions
        ), successMessage: L10n.t("禁用函数已保存"))
        // 乐观更新失败回滚到服务端已保存的数组，避免页面停留期间显示与实际不一致
        if ok {
            savedDisableFunctions = disableFunctions
        } else {
            disableFunctions = savedDisableFunctions
        }
    }

    // MARK: 上传限制 / 超时时间

    private var limitsSection: some View {
        Section(L10n.t("上传与超时")) {
            // 2M → 数值 2 + 右侧固定单位（沿用读取到的 K/M/G）
            OutlinedUnitField(label: L10n.t("上传限制"),
                              unit: Self.sizeParts(uploadMaxSize).unit,
                              prompt: "2",
                              text: uploadSizeValueBinding)
            Button(L10n.t("保存")) {
                Task {
                    let raw = uploadMaxSize.trimmingCharacters(in: .whitespaces)
                    guard raw.range(of: #"^\d+([KMG])?$"#, options: .regularExpression) != nil else {
                        toast = L10n.t("上传限制需为数字，可带 K/M/G 单位")
                        return
                    }
                    let ok = await save(RuntimePHPConfigUpdateRequest(
                        id: entry.id, scope: "upload_max_filesize", uploadMaxSize: uploadMaxSize
                    ), successMessage: L10n.t("上传限制已保存"))
                    if ok {
                        // 回写 php.ini 组内同键，防止后续整组保存用旧值覆盖
                        paramEdits[RuntimePHPParamKey.uploadMaxFilesize.rawValue] = uploadMaxSize
                    }
                }
            }
            OutlinedUnitField(label: L10n.t("超时时间"), unit: L10n.t("秒"),
                              prompt: "30", text: $maxExecutionTime)
            Button(L10n.t("保存")) {
                Task {
                    let raw = maxExecutionTime.trimmingCharacters(in: .whitespaces)
                    guard raw.range(of: #"^\d+$"#, options: .regularExpression) != nil else {
                        toast = L10n.t("超时时间需为非负整数")
                        return
                    }
                    let ok = await save(RuntimePHPConfigUpdateRequest(
                        id: entry.id, scope: "max_execution_time", maxExecutionTime: maxExecutionTime
                    ), successMessage: L10n.t("超时时间已保存"))
                    if ok {
                        paramEdits[RuntimePHPParamKey.maxExecutionTime.rawValue] = maxExecutionTime
                    }
                }
            }
        }
    }

    private var uploadSizeValueBinding: Binding<String> {
        Binding(
            get: { Self.sizeParts(uploadMaxSize).value },
            set: { uploadMaxSize = $0 + Self.sizeParts(uploadMaxSize).unit }
        )
    }

    @discardableResult
    private func save(_ request: RuntimePHPConfigUpdateRequest,
                      successMessage: String) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.runtimesPhpConfigUpdate.path,
                body: request, as: EmptyResponse.self
            )
            toast = successMessage
            return true
        } catch {
            toast = L10n.f("保存失败：%@", error.localizedDescription)
            return false
        }
    }
}

// MARK: - 性能调整（pm + 并发方案预设）

struct RuntimePHPFpmTuneView: View {
    let entry: RuntimeEntry
    let client: APIClient

    @State private var pm = "dynamic"
    @State private var maxChildren = ""
    @State private var startServers = ""
    @State private var minSpare = ""
    @State private var maxSpare = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var toast: String?
    @State private var isSaving = false

    private let pmModes = ["dynamic", "static", "ondemand"]
    /// 运行模式值/显示分离（形态 3）
    private var pmLabels: [String: String] {
        [
            "dynamic": L10n.t("动态"),
            "static": L10n.t("静态"),
            "ondemand": L10n.t("按需"),
        ]
    }

    var body: some View {
        Form {
            if isLoading {
                Section { LoadingStateView(compact: true).padding(.vertical, 20) }
            } else if let err = errorMessage {
                Section {
                    Text(err).font(.footnote).foregroundStyle(.red)
                    Button(L10n.t("重试")) { Task { await load() } }
                }
            } else {
                Section(L10n.t("运行模式")) {
                    OutlinedPicker(label: L10n.t("模式"), options: pmModes,
                                   selection: $pm, optionLabels: pmLabels)
                }
                Section(L10n.t("进程参数")) {
                    OutlinedTextField(label: "max_children", text: $maxChildren,
                                      keyboardType: .numberPad)
                    OutlinedTextField(label: "start_servers", text: $startServers,
                                      keyboardType: .numberPad)
                    OutlinedTextField(label: "min_spare_servers", text: $minSpare,
                                      keyboardType: .numberPad)
                    OutlinedTextField(label: "max_spare_servers", text: $maxSpare,
                                      keyboardType: .numberPad)
                }
                Section {
                    Picker(L10n.t("并发方案"), selection: presetApplyBinding) {
                        Text(L10n.t("选择预设")).tag(RuntimeFPMPreset?.none)
                        ForEach(RuntimeFPMPreset.allCases) { p in
                            Text(p.rawValue).tag(RuntimeFPMPreset?.some(p))
                        }
                    }
                } header: {
                    Text(L10n.t("并发方案"))
                } footer: {
                    Text(L10n.t("按服务器内存选择预设，自动回填上方进程参数"))
                }
            }
        }
        .navigationTitle(L10n.t("性能调整"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                }
                .disabled(isSaving)
            }
        }
        .task { await load() }
        .toastOverlay(message: $toast)
    }

    /// 选预设 → 回填四个参数后回到「选择预设」占位
    private var presetApplyBinding: Binding<RuntimeFPMPreset?> {
        Binding(
            get: { .none },
            set: { sel in
                guard let p = sel else { return }
                maxChildren = String(p.values.maxChildren)
                startServers = String(p.values.startServers)
                minSpare = String(p.values.minSpare)
                maxSpare = String(p.values.maxSpare)
            }
        )
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let path = APIEndpoint.runtimesPhpFpmConfigGet.path
                .replacingOccurrences(of: ":id", with: String(entry.id))
            let cfg: RuntimeFPMConfig = try await client.send(
                path: path, method: APIEndpoint.runtimesPhpFpmConfigGet.method,
                as: RuntimeFPMConfig.self
            )
            let p = cfg.params ?? [:]
            pm = p["pm"]?.stringValue ?? "dynamic"
            maxChildren = p["pm.max_children"]?.stringValue ?? ""
            startServers = p["pm.start_servers"]?.stringValue ?? ""
            minSpare = p["pm.min_spare_servers"]?.stringValue ?? ""
            maxSpare = p["pm.max_spare_servers"]?.stringValue ?? ""
        } catch {
            if !APIError.isCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    private func save() async {
        guard let mc = Int(maxChildren), let ss = Int(startServers),
              let mn = Int(minSpare), let mx = Int(maxSpare) else {
            toast = L10n.t("进程参数需为数字")
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.runtimesPhpFpmConfigUpdate.path,
                body: RuntimeFPMConfigUpdateRequest(
                    id: entry.id,
                    params: [
                        "pm": .string(pm),
                        "pm.max_children": .int(mc),
                        "pm.start_servers": .int(ss),
                        "pm.min_spare_servers": .int(mn),
                        "pm.max_spare_servers": .int(mx),
                    ]
                ),
                as: EmptyResponse.self
            )
            toast = L10n.t("已保存")
        } catch {
            toast = L10n.f("保存失败：%@", error.localizedDescription)
        }
    }
}

// MARK: - 负载状态

struct RuntimeFPMStatusView: View {
    let entry: RuntimeEntry
    let client: APIClient

    @State private var items: [RuntimeFPMStatusItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isLoading && items.isEmpty {
                LoadingStateView(compact: true).padding(.vertical, 20)
            } else if let err = errorMessage, items.isEmpty {
                Text(err).font(.footnote).foregroundStyle(.red)
            } else if items.isEmpty {
                Text(L10n.t("暂无数据"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    LabeledContent(item.key ?? "—",
                                   value: item.value?.stringValue ?? "—")
                        .font(.system(.subheadline, design: .monospaced))
                }
            }
        }
        .navigationTitle(L10n.t("负载状态"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = items.isEmpty
        errorMessage = nil
        defer { isLoading = false }
        do {
            let path = APIEndpoint.runtimesPhpFpmStatus.path
                .replacingOccurrences(of: ":id", with: String(entry.id))
            let data: [RuntimeFPMStatusItem] = try await client.send(
                path: path, method: APIEndpoint.runtimesPhpFpmStatus.method,
                as: [RuntimeFPMStatusItem].self
            )
            items = data
        } catch {
            if !APIError.isCancellation(error) { errorMessage = error.localizedDescription }
        }
    }
}

// MARK: - 慢日志

struct RuntimeSlowLogView: View {
    let entry: RuntimeEntry
    let client: APIClient

    @State private var lines: [String] = []
    @State private var logPath = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let logType = "php-fpm-slow-logs"

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if !logPath.isEmpty {
                    Text(logPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 4)
                }
                if isLoading && lines.isEmpty {
                    LoadingStateView(compact: true).padding(.vertical, 30)
                } else if let err = errorMessage {
                    Text(err).font(.footnote).foregroundStyle(.red).padding()
                } else if lines.isEmpty {
                    Text(L10n.t("暂无日志"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 30)
                        .frame(maxWidth: .infinity)
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding()
        }
        .navigationTitle(L10n.t("慢日志"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = lines.isEmpty
        errorMessage = nil
        defer { isLoading = false }
        do {
            let resp: RuntimeLogReadResponse = try await client.send(
                path: APIEndpoint.runtimesBuildLog.path
                    .replacingOccurrences(of: ":type", with: logType),
                body: RuntimeLogReadRequest(id: entry.id, type: logType),
                as: RuntimeLogReadResponse.self
            )
            lines = resp.lines ?? []
            logPath = resp.path ?? ""
        } catch {
            if !APIError.isCancellation(error) { errorMessage = error.localizedDescription }
        }
    }
}

// MARK: - 配置文件（php.ini / php-fpm.conf）

struct RuntimePHPFileView: View {
    let entry: RuntimeEntry
    let client: APIClient
    /// "php" → php.ini；"fpm" → php-fpm.conf
    let fileType: String

    @State private var content = ""
    @State private var original = ""
    @State private var isEditing = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var toast: String?
    @State private var isSaving = false

    private var title: String { fileType == "fpm" ? "php-fpm.conf" : "php.ini" }

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView().padding(.top, 60)
            } else if let err = errorMessage {
                VStack(spacing: 12) {
                    Text(err).font(.footnote).foregroundStyle(.red)
                    Button(L10n.t("重试")) { Task { await load() } }
                }
            } else if isEditing {
                // 编辑：TextEditor 自滚动独占剩余空间（全 App 标准模式，
                // 避免「滚动容器包自滚动编辑器」的嵌套滚动/手势冲突与整页布局开销）
                VStack(spacing: 12) {
                    pathCaption
                    CodeEditorArea(text: $content)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.small))
                }
                .padding(.vertical)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        pathCaption
                        if lineCount <= Self.perRowRenderLimit {
                            CodeEditorArea(text: $content, readOnly: true)
                        } else {
                            // 大文件（php.ini 两千余行）：单 Text 一次成型，
                            // 逐行视图（行号+选择）一次性构建首帧可达数秒
                            Text(content)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical)
                }
                .background(Color(.systemGroupedBackground))
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .contentWidthLimit(860)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isEditing {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                    }
                    .disabled(isSaving || content == original)
                } else {
                    Button(L10n.t("编辑")) { isEditing = true }
                }
            }
        }
        .task { await load() }
        .toastOverlay(message: $toast)
        .onDisappear {
            if isEditing { content = original; isEditing = false }
        }
    }

    @State private var filePath = ""
    /// 只读渲染方式分界：超过则整块 Text 快速渲染（无行号）
    private static let perRowRenderLimit = 400
    @State private var lineCount = 0

    private var pathCaption: some View {
        Group {
            if !filePath.isEmpty {
                Text(filePath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let resp: RuntimeFileInfo = try await client.send(
                path: APIEndpoint.runtimesPhpFile.path,
                body: RuntimePHPFileRequest(id: entry.id, type: fileType),
                as: RuntimeFileInfo.self
            )
            content = resp.content ?? ""
            original = content
            filePath = resp.path ?? ""
            lineCount = content.split(omittingEmptySubsequences: false,
                                      whereSeparator: { $0.isNewline }).count
        } catch {
            if !APIError.isCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    /// 保存并重载（面板行为：保存后服务端自动 reload）
    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.runtimesPhpFileUpdate.path,
                body: RuntimePHPFileUpdateRequest(id: entry.id, content: content, type: fileType),
                as: EmptyResponse.self
            )
            original = content
            isEditing = false
            toast = L10n.t("已保存并重载")
        } catch {
            toast = L10n.f("保存失败：%@", error.localizedDescription)
        }
    }
}

// MARK: - 容器配置（名称 / 端口映射）

struct RuntimePHPContainerView: View {
    let entry: RuntimeEntry
    let client: APIClient

    @State private var containerName = ""
    @State private var ports: [RuntimePortRow] = []
    @State private var envs: [RuntimeEnvRow] = []
    @State private var volumes: [RuntimeVolumeRow] = []
    @State private var hosts: [RuntimeHostRow] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var toast: String?
    @State private var isSaving = false

    var body: some View {
        Form {
            if isLoading {
                Section { LoadingStateView(compact: true).padding(.vertical, 20) }
            } else if let err = errorMessage {
                Section {
                    Text(err).font(.footnote).foregroundStyle(.red)
                    Button(L10n.t("重试")) { Task { await load() } }
                }
            } else {
                Section {
                    OutlinedTextField(label: L10n.t("容器名称"), text: $containerName)
                    NavigationLink {
                        RuntimePortsEditView(ports: $ports)
                    } label: {
                        entryLinkLabel(L10n.t("端口映射"), count: ports.count)
                    }
                    NavigationLink {
                        RuntimeEnvsEditView(environments: $envs)
                    } label: {
                        entryLinkLabel(L10n.t("环境变量"), count: envs.count)
                    }
                    NavigationLink {
                        RuntimeVolumesEditView(volumes: $volumes, client: client)
                    } label: {
                        entryLinkLabel(L10n.t("挂载"), count: volumes.count)
                    }
                    NavigationLink {
                        RuntimeHostsEditView(hosts: $hosts)
                    } label: {
                        entryLinkLabel(L10n.t("主机映射"), count: hosts.count)
                    }
                } footer: {
                    Text(L10n.t("保存后重建容器使配置生效"))
                }
            }
        }
        .navigationTitle(L10n.t("容器配置"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                }
                .disabled(isSaving || containerName.isEmpty)
            }
        }
        .task { await load() }
        .toastOverlay(message: $toast)
    }

    private func entryLinkLabel(_ title: String, count: Int) -> some View {
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

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let path = APIEndpoint.runtimesPhpContainerGet.path
                .replacingOccurrences(of: ":id", with: String(entry.id))
            let cfg: RuntimePHPContainerConfig = try await client.send(
                path: path, method: APIEndpoint.runtimesPhpContainerGet.method,
                as: RuntimePHPContainerConfig.self
            )
            containerName = cfg.containerName ?? ""
            ports = (cfg.exposedPorts ?? []).map {
                RuntimePortRow(hostPort: String($0.hostPort),
                               containerPort: String($0.containerPort),
                               hostIP: $0.hostIP, protocol: $0.protocol)
            }
            envs = (cfg.environments ?? []).map {
                RuntimeEnvRow(key: $0.key, value: $0.value)
            }
            volumes = (cfg.volumes ?? []).map {
                RuntimeVolumeRow(source: $0.source, target: $0.target,
                                 mode: $0.mode.isEmpty ? "rw" : $0.mode)
            }
            hosts = (cfg.extraHosts ?? []).map {
                RuntimeHostRow(hostname: $0.hostname, ip: $0.ip)
            }
        } catch {
            if !APIError.isCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    private func save() async {
        // 行级校验（含行号提示）；全空行静默丢弃。保存即重建生效，不能带进垃圾配置
        if let err = RuntimeAdvancedArrays.validationError(
            ports: ports, envs: envs, volumes: volumes, hosts: hosts
        ) {
            toast = err
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.runtimesPhpContainerUpdate.path,
                body: RuntimePHPContainerUpdateRequest(
                    id: entry.id,
                    containerName: containerName,
                    exposedPorts: ports.filter { !$0.isBlank }.map {
                        RuntimeExposedPort(hostPort: Int($0.hostPort) ?? 0,
                                           containerPort: Int($0.containerPort) ?? 0,
                                           hostIP: $0.hostIP,
                                           protocol: $0.protocol)
                    },
                    environments: envs.filter { !$0.isBlank }.map {
                        RuntimeEnvironment(key: $0.key, value: $0.value)
                    },
                    volumes: volumes.filter { !$0.isBlank }.map {
                        RuntimeVolume(source: $0.source, target: $0.target,
                                      mode: $0.mode.isEmpty ? "rw" : $0.mode)
                    },
                    extraHosts: hosts.filter { !$0.isBlank }.map {
                        RuntimeExtraHost(hostname: $0.hostname, ip: $0.ip)
                    }
                ),
                as: EmptyResponse.self
            )
            toast = L10n.t("已保存")
        } catch {
            toast = L10n.f("保存失败：%@", error.localizedDescription)
        }
    }
}
