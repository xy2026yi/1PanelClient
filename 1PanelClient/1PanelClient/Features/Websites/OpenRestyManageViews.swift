//
//  OpenRestyManageViews.swift
//  1PanelClient
//
//  OpenResty 管理增强（网站页 OpenResty 卡展开区入口）：
//    状态     - GET  /openresty/status  运行指标
//    性能调整 - POST /openresty/scope   读取 http-per 参数，/openresty/update 保存
//    模块     - GET  /openresty/modules 列表/详情/开关，/openresty/build 构建（任务进度）
//    其他     - GET/POST /openresty/https  HTTPS防窜站 / 拒绝默认SSL握手
//

import SwiftUI
import OSLog

// MARK: - 状态

struct OpenRestyStatusView: View {
    @ObservedObject var vm: WebsitesViewModel

    @State private var status: OpenRestyStatus?
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        Group {
            if isLoading && status == nil {
                LoadingStateView()
            } else if let s = status {
                List {
                    Section {
                        InfoRow(L10n.t("活动连接"), value: "\(s.active)", monospaced: true)
                        InfoRow(L10n.t("总连接次数"), value: "\(s.accepts)", monospaced: true)
                        InfoRow(L10n.t("总握手次数"), value: "\(s.handled)", monospaced: true)
                        InfoRow(L10n.t("总请求数"), value: "\(s.requests)", monospaced: true)
                        InfoRow(L10n.t("请求数"), value: "\(s.reading)", monospaced: true)
                        InfoRow(L10n.t("响应数"), value: "\(s.writing)", monospaced: true)
                        InfoRow(L10n.t("驻留进程"), value: "\(s.waiting)", monospaced: true)
                    }
                }
                .listStyle(.insetGrouped)
            } else {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage ?? L10n.t("未知错误"))
                } actions: {
                    Button(L10n.t("重试")) {
                        Task { await load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(L10n.t("状态"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(L10n.t("刷新"))
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            status = try await vm.client.send(
                path: APIEndpoint.openrestyStatus.path,
                method: APIEndpoint.openrestyStatus.method,
                as: OpenRestyStatus.self
            )
            errorMessage = nil
        } catch let err as APIError {
            errorMessage = err.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 性能调整

struct OpenRestyPerformanceView: View {
    @ObservedObject var vm: WebsitesViewModel

    /// 数值字段定义（gzip 单独用开关展示，不在此列）
    private struct PerfField {
        let key: String
        let desc: String
        let unit: String?
    }

    private static let fields: [PerfField] = [
        PerfField(key: "server_names_hash_bucket_size", desc: "服务器名字的hash表大小", unit: nil),
        PerfField(key: "client_header_buffer_size", desc: "客户端请求的头buffer大小", unit: "K"),
        PerfField(key: "client_max_body_size", desc: "最大上传文件", unit: "MB"),
        PerfField(key: "keepalive_timeout", desc: "连接超时时间", unit: nil),
        PerfField(key: "gzip_min_length", desc: "最小压缩文件", unit: "KB"),
        PerfField(key: "gzip_comp_level", desc: "压缩率", unit: nil),
    ]

    /// 数字部分（原始值去掉字母后缀）
    @State private var values: [String: String] = [:]
    /// 原始值的字母后缀（32k → k），保存时拼回
    @State private var suffixes: [String: String] = [:]
    @State private var gzipOn = true
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var loadError: String?

    var body: some View {
        Group {
            if isLoading && values.isEmpty {
                LoadingStateView()
            } else if let err = loadError {
                LoadErrorStateView(message: err) {
                    Task { await load() }
                }
            } else {
                Form {
                    Section {
                        ForEach(Self.fields, id: \.key) { field in
                            perfRow(field)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("gzip")
                                Spacer()
                                Picker("", selection: $gzipOn) {
                                    Text("on").tag(true)
                                    Text("off").tag(false)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 120)
                            }
                            Text(L10n.t("是否开启压缩传输"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text(L10n.t("性能调整"))
                    }
                }
            }
        }
        .navigationTitle(L10n.t("性能调整"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text(L10n.t("保存")).bold()
                    }
                }
                .disabled(isSaving || isLoading || values.isEmpty)
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .toastOverlay(message: $vm.toastMessage)
    }

    private func perfRow(_ field: PerfField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(field.key)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer()
                TextField("—", text: Binding(
                    get: { values[field.key] ?? "" },
                    set: { values[field.key] = $0 }
                ))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 110)
                if let unit = field.unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .leading)
                }
            }
            Text(L10n.t(field.desc))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// "32k" → ("32", "k")；"512" → ("512", "")
    private static func splitValue(_ raw: String) -> (num: String, suffix: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let num = String(trimmed.prefix { !$0.isLetter })
        let suffix = String(trimmed.dropFirst(num.count))
        return (num, suffix)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let items: [OpenRestyScopeItem] = try await vm.client.send(
                path: APIEndpoint.openrestyScope.path,
                body: OpenRestyScopeRequest(scope: "http-per"),
                as: [OpenRestyScopeItem].self
            )
            var nums: [String: String] = [:]
            var sfxs: [String: String] = [:]
            for item in items {
                let raw = item.params?.first ?? ""
                if item.name == "gzip" {
                    gzipOn = raw.lowercased() != "off"
                    continue
                }
                let (num, suffix) = Self.splitValue(raw)
                nums[item.name] = num
                sfxs[item.name] = suffix
            }
            values = nums
            suffixes = sfxs
            loadError = nil
        } catch let err as APIError {
            loadError = err.errorDescription ?? L10n.t("未知错误")
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() async {
        var params: [String: String] = ["gzip": gzipOn ? "on" : "off"]
        for field in Self.fields {
            let num = (values[field.key] ?? "").trimmingCharacters(in: .whitespaces)
            guard !num.isEmpty, Double(num) != nil else { continue }
            params[field.key] = num + (suffixes[field.key] ?? "")
        }
        guard params.count == Self.fields.count + 1 else {
            vm.alertMessage = L10n.t("请填写完整的性能参数")
            vm.showAlert = true
            return
        }

        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await vm.client.send(
                path: APIEndpoint.openrestyUpdate.path,
                body: OpenRestyParamsUpdateRequest(scope: "http-per", operate: "update", params: params),
                as: EmptyResponse.self
            )
            vm.showToast(L10n.t("性能参数已保存"))
        } catch let err as APIError {
            vm.alertMessage = L10n.f("保存失败：%@", err.errorDescription ?? L10n.t("未知错误"))
            vm.showAlert = true
        } catch {
            vm.alertMessage = L10n.f("保存失败：%@", error.localizedDescription)
            vm.showAlert = true
        }
    }
}

// MARK: - 其他（HTTPS 防窜站 / 拒绝默认 SSL 握手）

struct OpenRestyOtherView: View {
    @ObservedObject var vm: WebsitesViewModel

    @State private var httpsOn = true
    @State private var rejectHandshake = true
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var loaded = false
    @State private var loadError: String?

    var body: some View {
        Group {
            if isLoading && !loaded {
                LoadingStateView()
            } else if let err = loadError {
                LoadErrorStateView(message: err) {
                    Task { await load() }
                }
            } else {
                settingsForm
            }
        }
        .navigationTitle(L10n.t("其他"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text(L10n.t("保存")).bold()
                    }
                }
                .disabled(isSaving || !loaded)
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .toastOverlay(message: $vm.toastMessage)
    }

    private var settingsForm: some View {
        Form {
            Section {
                Toggle(L10n.t("HTTPS防窜站"), isOn: $httpsOn)
                    .disabled(!loaded)
                Toggle(L10n.t("拒绝默认SSL握手"), isOn: $rejectHandshake)
                    .disabled(!loaded)
            } header: {
                Text(L10n.t("其他"))
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let config: OpenRestyHTTPSConfig = try await vm.client.send(
                path: APIEndpoint.openrestyHttps.path,
                method: APIEndpoint.openrestyHttps.method,
                as: OpenRestyHTTPSConfig.self
            )
            httpsOn = config.https ?? true
            rejectHandshake = config.sslRejectHandshake ?? true
            loaded = true
            loadError = nil
        } catch let err as APIError {
            loadError = err.errorDescription ?? L10n.t("未知错误")
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        // operate 由 HTTPS 开关决定（on=enable / off=disable），握手开关作为字段回传
        let req = OpenRestyHTTPSUpdateRequest(
            operate: httpsOn ? "enable" : "disable",
            sslRejectHandshake: rejectHandshake
        )
        do {
            let _: EmptyResponse = try await vm.client.send(
                path: APIEndpoint.openrestyHttps.path,
                body: req,
                as: EmptyResponse.self
            )
            vm.showToast(L10n.t("已保存"))
        } catch let err as APIError {
            vm.alertMessage = L10n.f("保存失败：%@", err.errorDescription ?? L10n.t("未知错误"))
            vm.showAlert = true
        } catch {
            vm.alertMessage = L10n.f("保存失败：%@", error.localizedDescription)
            vm.showAlert = true
        }
    }
}

// MARK: - 模块

struct OpenRestyModulesView: View {
    @ObservedObject var vm: WebsitesViewModel

    @State private var resp: OpenRestyModulesResponse?
    @State private var errorMessage: String?
    @State private var isLoading = false
    /// 开关请求中的模块名（防重复提交）
    @State private var togglingModule: String?
    @State private var showBuild = false
    /// 构建任务 ID（非 nil 时 push 任务进度页）
    @State private var buildTaskID: String?
    /// 当前查看详情的模块
    @State private var selectedModule: OpenRestyModule?

    private var modules: [OpenRestyModule] { resp?.modules ?? [] }
    /// 构建目标：所有已开启的模块
    private var enabledModules: [OpenRestyModule] { modules.filter { $0.enable == true } }

    var body: some View {
        Group {
            if isLoading && resp == nil {
                LoadingStateView()
            } else if let err = errorMessage, resp == nil {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button(L10n.t("重试")) {
                        Task { await load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if modules.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无模块"),
                    systemImage: "puzzlepiece",
                    description: Text(L10n.t("服务器未返回模块列表，请确认 OpenResty 已安装且面板版本支持模块功能"))
                )
            } else {
                moduleList
            }
        }
        .navigationTitle(L10n.t("模块"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showBuild = true
                } label: {
                    Label(L10n.t("构建"), systemImage: "hammer")
                }
                .disabled(enabledModules.isEmpty)
                .accessibilityLabel(L10n.t("构建模块"))
            }
        }
        .sheet(isPresented: $showBuild) {
            OpenRestyBuildSheet(
                enabledModules: enabledModules,
                defaultMirror: resp?.mirror ?? ""
            ) { mirror, force in
                Task { await build(mirror: mirror, force: force) }
            }
            .bottomSheetDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .navigationDestination(isPresented: Binding(
            get: { buildTaskID != nil },
            set: { if !$0 { buildTaskID = nil } }
        )) {
            if let taskID = buildTaskID {
                TaskProgressView(taskID: taskID, title: L10n.t("构建模块")) { _ in
                    Task { await load() }
                    return false
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private var moduleList: some View {
        List {
            Section {
                ForEach(modules) { module in
                    // 整行点击进详情；开关是独立控件，手势优先于行级 tap，互不干扰
                    HStack(spacing: 12) {
                        moduleRowLabel(module)

                        if module.isDynamic {
                            if togglingModule == module.name {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Toggle("", isOn: Binding(
                                    get: { module.enable ?? false },
                                    set: { on in
                                        Task { await toggle(module: module, on: on) }
                                    }
                                ))
                                .labelsHidden()
                                // 一次只发一个开关请求：其余行禁用，避免视觉已翻转但请求被丢弃
                                .disabled(togglingModule != nil)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selectedModule = module }
                }
            } footer: {
                if resp?.dynamicSupported != true {
                    Text(L10n.t("当前环境不支持动态模块，构建将全量重建镜像并重启容器"))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(isPresented: Binding(
            get: { selectedModule != nil },
            set: { if !$0 { selectedModule = nil } }
        )) {
            if let module = selectedModule {
                OpenRestyModuleDetailView(module: module)
            }
        }
    }

    private func moduleRowLabel(_ module: OpenRestyModule) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(module.name)
                    .font(.body.bold())
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if module.isDynamic {
                        StatusBadge(text: L10n.t("动态模块"), color: .indigo)
                    } else {
                        StatusBadge(text: L10n.t("静态模块"), color: .secondary)
                    }
                    if module.buildStatus?.lowercased() == "ready" {
                        StatusBadge(text: L10n.t("已构建"), color: .green)
                    } else {
                        StatusBadge(text: L10n.t("待构建"), color: .secondary)
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    /// 开启/关闭动态模块：完整对象 + operate=update 回传，成功后重拉列表
    private func toggle(module: OpenRestyModule, on: Bool) async {
        guard togglingModule == nil else { return }
        togglingModule = module.name
        defer { togglingModule = nil }
        do {
            let _: EmptyResponse = try await vm.client.send(
                path: APIEndpoint.openrestyModulesUpdate.path,
                body: OpenRestyModuleUpdateRequest(module: module, enable: on),
                as: EmptyResponse.self
            )
            await load()
        } catch let err as APIError {
            vm.alertMessage = L10n.f("操作失败：%@", err.errorDescription ?? L10n.t("未知错误"))
            vm.showAlert = true
        } catch {
            vm.alertMessage = L10n.f("操作失败：%@", error.localizedDescription)
            vm.showAlert = true
        }
    }

    /// 提交构建：成功后进入任务进度页
    private func build(mirror: String, force: Bool) async {
        let taskID = UUID().uuidString
        let req = OpenRestyBuildRequest(
            taskID: taskID,
            mirror: mirror,
            modules: enabledModules.map(\.name),
            force: force
        )
        do {
            let _: EmptyResponse = try await vm.client.send(
                path: APIEndpoint.openrestyBuild.path,
                body: req,
                as: EmptyResponse.self
            )
            buildTaskID = taskID
        } catch let err as APIError {
            vm.alertMessage = L10n.f("构建请求失败：%@", err.errorDescription ?? L10n.t("未知错误"))
            vm.showAlert = true
        } catch {
            vm.alertMessage = L10n.f("构建请求失败：%@", error.localizedDescription)
            vm.showAlert = true
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result: OpenRestyModulesResponse = try await vm.client.send(
                path: APIEndpoint.openrestyModules.path,
                method: APIEndpoint.openrestyModules.method,
                as: OpenRestyModulesResponse.self
            )
            resp = result
            errorMessage = nil
            #if DEBUG
            Logger(subsystem: "com.xy.1PanelClient.debug", category: "openresty")
                .warning("[Modules] mirror=\(result.mirror ?? "nil", privacy: .public) dynamicSupported=\(result.dynamicSupported.map(String.init) ?? "nil", privacy: .public) modules=\(result.modules?.count.description ?? "null", privacy: .public)")
            #endif
        } catch let err as APIError {
            errorMessage = err.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 模块详情

struct OpenRestyModuleDetailView: View {
    let module: OpenRestyModule

    var body: some View {
        List {
            Section(L10n.t("模块详情")) {
                InfoRow(L10n.t("名称"), value: module.name)
                InfoRow(L10n.t("构建方式"), value: buildModeDisplay)
                InfoRow(L10n.t("参数"), value: module.params ?? "—")
                InfoRow(L10n.t("软件包"), value: module.packages?.isEmpty == false ? module.packages! : "—")
                InfoRow(L10n.t("脚本"), value: module.script?.isEmpty == false ? module.script! : "—")
                InfoRow(L10n.t("加载顺序"), value: module.loadOrder.map(String.init) ?? "—")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(module.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var buildModeDisplay: String {
        if module.isDynamic {
            return L10n.f("%@（动态模块）", module.buildMode ?? "")
        }
        return module.buildMode ?? "—"
    }
}

// MARK: - 构建确认 Sheet

struct OpenRestyBuildSheet: View {
    let enabledModules: [OpenRestyModule]
    let defaultMirror: String
    let onConfirm: (_ mirror: String, _ force: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mirror = ""
    @State private var force = false
    @State private var showConfirm = false

    private static let mirrors = [
        "http://archive.ubuntu.com/ubuntu/",
        "http://mirrors.aliyun.com/ubuntu/",
        "http://mirrors.tuna.tsinghua.edu.cn/ubuntu/",
        "http://mirrors.ustc.edu.cn/ubuntu/",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L10n.t("软件源"), selection: $mirror) {
                        ForEach(Self.mirrors, id: \.self) { m in
                            Text(m.replacingOccurrences(of: "http://", with: ""))
                                .lineLimit(1)
                                .tag(m)
                        }
                    }
                    .font(.system(.caption, design: .monospaced))

                    Toggle(L10n.t("忽略缓存重新构建"), isOn: $force)
                } header: {
                    Text(L10n.t("构建选项"))
                } footer: {
                    Text(L10n.t("动态模块构建后热加载生效（容器不重启）；包含静态模块时将全量重建镜像并重建容器"))
                }

                Section {
                    ForEach(enabledModules) { module in
                        HStack(spacing: 8) {
                            Image(systemName: module.isDynamic ? "puzzlepiece.extension" : "puzzlepiece")
                                .foregroundStyle(module.isDynamic ? Color.indigo : Color.secondary)
                                .font(.caption)
                            Text(module.name)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                        }
                    }
                } header: {
                    Text(L10n.t("动态模块(构建后热加载，容器不重启)"))
                }
            }
            .navigationTitle(L10n.t("构建模块"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("确认")) {
                        showConfirm = true
                    }
                    .bold()
                }
            }
            .alert(L10n.t("构建"), isPresented: $showConfirm) {
                Button(L10n.t("取消"), role: .cancel) {}
                Button(L10n.t("确认"), role: .destructive) {
                    Haptic.warning()
                    dismiss()
                    onConfirm(mirror, force)
                }
            } message: {
                Text(L10n.t("本地构建模块需要占用一定的 CPU 和内存，静态模块还会重建并重启 OpenResty，是否继续？"))
            }
            .onAppear {
                if mirror.isEmpty {
                    mirror = Self.mirrors.contains(defaultMirror) ? defaultMirror : Self.mirrors[0]
                }
            }
        }
    }
}
