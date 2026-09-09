//
//  PanelBasicSettingsView.swift
//  1PanelClient
//
//  基础设置（设置 Hub 子页）：面板别名 / 超时时间 / 默认访问地址 /
//  代理服务器 / 预览体验计划 / 运行环境。接口对齐网页端抓包（0909）：
//  - 读：POST core/settings/search（别名/超时/体验计划/运行环境/代理）
//        POST settings/search（默认访问地址 systemIP）
//  - 写：POST core/settings/update（PanelName/SessionTimeout/DeveloperMode/
//        Edition/DocSource）、settings/update（SystemIP）、
//        core/settings/proxy/update（代理五项）
//

import SwiftUI

// MARK: - 请求模型

struct SettingsKeyValueRequest: Encodable {
    let key: String
    let value: String
}

/// 代理服务器更新（proxy/update）
struct ProxyUpdateRequest: Encodable {
    let proxyType: String
    let proxyUrl: String
    let proxyPort: String
    let proxyUser: String
    let proxyPasswd: String
    /// Enable/Disable（是否记住密码）
    let proxyPasswdKeep: String
    let proxyDocker: Bool
    let withDockerRestart: Bool
}

// MARK: - 响应模型

/// core/settings/search 需要的字段（var：单项保存后本地回写快照）
nonisolated struct PanelCoreSettings: Decodable {
    var panelName: String?
    var sessionTimeout: String?
    /// Enable/Disable
    var developerMode: String?
    /// cn=中国大陆 / intl=全球
    var edition: String?
    /// withByRegion=跟随运行区域 / withByLang=跟随系统语言
    var docSource: String?
    /// ""=关闭 / socks5 / http / https
    var proxyType: String?
    var proxyUrl: String?
    var proxyPort: String?
    var proxyUser: String?
    var proxyPasswd: String?
    /// Enable/Disable
    var proxyPasswdKeep: String?
}

/// settings/search 需要的字段
nonisolated struct PanelSystemSettings: Decodable {
    let systemIP: String?
}

/// toolbox/device/base 需要的字段（swap/磁盘等忽略）
nonisolated struct DeviceBaseInfo: Decodable {
    let dns: [String]?
    let hosts: [DeviceHostItem]?
    let hostname: String?
    let timeZone: String?
    let localTime: String?
    let ntp: String?
}

/// hosts 单条（update/host 覆盖提交用，需 Encodable；Equatable 供单条删除过滤）
nonisolated struct DeviceHostItem: Decodable, Encodable, Equatable {
    var ip: String
    var host: String
}

// MARK: - 基础设置页

struct PanelBasicSettingsView: View {
    let server: ServerConfig

    // 服务器值（加载后填充）
    @State private var core: PanelCoreSettings?
    @State private var systemIP: String?
    @State private var isLoading = true
    @State private var loadError: String?

    // 编辑中的值
    @State private var nameInput = ""
    @State private var ipInput = ""
    @State private var savingKey: String?

    // 设备配置（device/base）
    @State private var hostEntries: [DeviceHostItem] = []
    @State private var ntpInput = ""
    @State private var localTime = ""
    @State private var isDeviceBusy = false
    /// 加载时的原始值（DNS 跳转编辑的初始值与摘要 / NTP 失焦比对基线）
    @State private var originalDNS: [String] = []
    @State private var originalNtp = ""

    /// 即时保存的输入焦点：回车或切换焦点（失焦）时提交对应项
    enum InputField: Hashable {
        case name, ip, ntp
    }
    @FocusState private var focusedField: InputField?

    @State private var toast: String?
    @State private var errorText: String?
    @State private var ipInvalid = false

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient.shared(for: server)
    }

    /// 超时下拉选项（秒）
    private static let timeoutOptions: [(label: String, seconds: Int)] = [
        ("30 " + L10n.t("分钟"), 1800),
        ("1 " + L10n.t("小时"), 3600),
        ("2 " + L10n.t("小时"), 7200),
        ("6 " + L10n.t("小时"), 21600),
        ("12 " + L10n.t("小时"), 43200),
        ("1 " + L10n.t("天"), 86400),
        ("7 " + L10n.t("天"), 604800),
    ]

    private var currentTimeout: Int {
        Int(core?.sessionTimeout ?? "") ?? 86400
    }

    /// 当前超时值是否在预设选项中（不在则补一项显示原始秒数）
    private var timeoutInOptions: Bool {
        Self.timeoutOptions.contains { $0.seconds == currentTimeout }
    }

    var body: some View {
        Form {
            if isLoading {
                Section { HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 24) }
            } else if let loadError {
                Section {
                    ContentUnavailableView {
                        Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button(L10n.t("重试")) { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                panelSection
                accessSection
                proxySection
                runtimeSection
                deviceEntrySection
                ntpSection
                serverTimeSection
            }
        }
        .navigationTitle(L10n.t("基础设置"))
        .navigationBarTitleDisplayMode(.inline)
        // 焦点切换（含收起键盘）即提交刚离开的输入项
        .onChange(of: focusedField) { old, new in
            guard old != new, let old else { return }
            commit(old)
        }
        .task { await load() }
        .refreshable { await load() }
        // 手势返回时焦点变更事件不保证派发：兜底提交三个输入项（无变化则空操作）
        .onDisappear {
            commit(.name)
            commit(.ip)
            commit(.ntp)
        }
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .toastOverlay(message: $toast)
    }

    // MARK: 面板（别名 / 超时 / 体验计划）

    private var panelSection: some View {
        Group {
            Section {
                TextField(L10n.t("面板别名"), text: $nameInput)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focusedField, equals: .name)
                    .onSubmit { commit(.name) }

                Picker(L10n.t("面板超时时间"), selection: Binding(
                    get: { currentTimeout },
                    set: { seconds in Task { await updateCore("SessionTimeout", String(seconds)) } }
                )) {
                    ForEach(Self.timeoutOptions, id: \.seconds) { opt in
                        Text(opt.label).tag(opt.seconds)
                    }
                    if !timeoutInOptions {
                        Text(L10n.f("%ld 秒", currentTimeout)).tag(currentTimeout)
                    }
                }
            } header: {
                SectionLabel(title: L10n.t("面板"), systemImage: "square.grid.2x2")
            } footer: {
                Text(L10n.t("超时时间内无操作将自动退出登录。"))
            }

            Section {
                Toggle(L10n.t("预览体验计划"), isOn: Binding(
                    get: { core?.developerMode == "Enable" },
                    set: { on in Task { await updateCore("DeveloperMode", on ? "Enable" : "Disable") } }
                ))
            } footer: {
                Text(L10n.t("启用后将优先体验未正式发布的新功能，稳定性可能降低。"))
            }
        }
    }

    // MARK: 访问（默认访问地址）

    private var accessSection: some View {
        Section {
            TextField(L10n.t("IP 或域名"), text: $ipInput)
                .keyboardType(.asciiCapable)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focusedField, equals: .ip)
                .onSubmit { commit(.ip) }
        } header: {
            SectionLabel(title: L10n.t("默认访问地址"), systemImage: "globe")
        } footer: {
            if ipInvalid {
                Text(L10n.t("只允许 IP 或域名，不能带 http/https 或端口"))
                    .foregroundStyle(.red)
            } else {
                Text(L10n.t("面板对外访问地址（IP 或域名），留空表示未指定。"))
            }
        }
    }

    // MARK: 代理

    private var proxySection: some View {
        Section {
            NavigationLink {
                PanelProxyEditView(server: server, current: core) {
                    Task { await load() }
                }
            } label: {
                HStack {
                    Text(L10n.t("代理服务器"))
                    Spacer()
                    Text(proxySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            SectionLabel(title: L10n.t("代理"), systemImage: "network")
        }
    }

    private var proxySummary: String {
        let type = (core?.proxyType ?? "").uppercased()
        guard !type.isEmpty else { return L10n.t("关闭") }
        let host = core?.proxyUrl ?? ""
        let port = core?.proxyPort ?? ""
        return "\(type) \(host.isEmpty ? "" : host + ":")\(port)"
    }

    // MARK: 运行环境

    private var runtimeSection: some View {
        Section {
            Picker(L10n.t("运行区域"), selection: Binding(
                get: { (core?.edition ?? "cn") == "cn" ? "cn" : "intl" },
                set: { value in Task { await updateCore("Edition", value) } }
            )) {
                Text(L10n.t("中国大陆")).tag("cn")
                Text(L10n.t("全球")).tag("intl")
            }
            Picker(L10n.t("文档来源"), selection: Binding(
                get: { (core?.docSource ?? "withByRegion") == "withByLang" ? "withByLang" : "withByRegion" },
                set: { value in Task { await updateCore("DocSource", value) } }
            )) {
                Text(L10n.t("跟随运行区域")).tag("withByRegion")
                Text(L10n.t("跟随系统语言")).tag("withByLang")
            }
        } header: {
            SectionLabel(title: L10n.t("运行环境"), systemImage: "globe.asia.australia")
        }
    }

    // MARK: 设备配置入口（DNS / Hosts 跳转编辑，避免本页过长）

    private var deviceEntrySection: some View {
        Section {
            NavigationLink {
                DeviceDNSSettingsView(server: server, initial: originalDNS) { newList in
                    originalDNS = newList
                }
            } label: {
                HStack {
                    Text("DNS")
                    Spacer()
                    Text(dnsSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            NavigationLink {
                DeviceHostsSettingsView(server: server) { newEntries in
                    hostEntries = newEntries
                }
            } label: {
                HStack {
                    Text("Hosts")
                    Spacer()
                    Text(L10n.f("%ld 条", hostEntries.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            SectionLabel(title: L10n.t("设备配置"), systemImage: "cpu")
        }
    }

    /// DNS 摘要：首个地址，多条时追加 +n
    private var dnsSummary: String {
        guard !originalDNS.isEmpty else { return L10n.t("未设置") }
        let first = originalDNS[0]
        return originalDNS.count > 1 ? "\(first) +\(originalDNS.count - 1)" : first
    }

    // MARK: NTP（预置三快捷 + 自定义输入）

    private var ntpSection: some View {
        Section {
            HStack(spacing: 8) {
                ForEach(Self.ntpPresets, id: \.url) { preset in
                    Button(preset.name) {
                        ntpInput = preset.url
                        Task { await updateConf("Ntp", preset.url) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDeviceBusy)
                }
                Spacer()
            }
            TextField("pool.ntp.org", text: $ntpInput)
                .font(.system(.body, design: .monospaced))
                .keyboardType(.asciiCapable)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focusedField, equals: .ntp)
                .onSubmit { commit(.ntp) }
        } header: {
            SectionLabel(title: L10n.t("NTP 服务器"), systemImage: "clock.badge")
        } footer: {
            Text(L10n.t("点击预置项立即应用，也可自定义输入（回车或失焦自动保存）。"))
        }
    }

    /// 预置 NTP：默认 / 阿里 / 谷歌
    private static let ntpPresets: [(name: String, url: String)] = [
        (L10n.t("默认"), "pool.ntp.org"),
        (L10n.t("阿里"), "ntp.aliyun.com"),
        (L10n.t("谷歌"), "time.google.com"),
    ]

    // MARK: 服务器时间

    private var serverTimeSection: some View {
        Section {
            HStack {
                Text(localTime.isEmpty ? "—" : localTime)
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(2)
                Spacer()
                Button(L10n.t("同步")) {
                    Task { await syncTime() }
                }
                .buttonStyle(.bordered)
                .disabled(isDeviceBusy)
            }
        } header: {
            SectionLabel(title: L10n.t("服务器时间"), systemImage: "clock")
        }
    }

    // MARK: 输入类即时保存（回车 / 失焦提交，值有变化才发请求）

    /// 提交指定输入项；地址类校验失败置红字提示且不保存
    private func commit(_ field: InputField) {
        switch field {
        case .name:
            let value = nameInput.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value != (core?.panelName ?? "") else { return }
            Task { await updateCore("PanelName", value) }
        case .ip:
            let value = ipInput.trimmingCharacters(in: .whitespaces)
            guard value != (systemIP ?? "") else {
                ipInvalid = false
                return
            }
            // 留空 = 未指定（footer 已注明），仅非空才做格式校验
            if !value.isEmpty {
                guard Self.isValidHostOrIP(value) else {
                    ipInvalid = true
                    return
                }
            }
            ipInvalid = false
            Task { await updateCore("SystemIP", value, endpoint: .panel) }
        case .ntp:
            let value = ntpInput.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value != originalNtp else { return }
            Task { await updateConf("Ntp", value) }
        }
    }

    // MARK: 数据

    private func load() async {
        // 已有数据时（下拉刷新/子页保存回调）不整页切 loading、
        // 不重置正在编辑的输入，只静默更新快照
        if core == nil { isLoading = true }
        defer { isLoading = false }
        // 三接口并行：core 为主（失败即错误态），settings 取 systemIP、
        // device/base 取 DNS/Hosts/NTP/时间（各自失败留空，可重新保存）
        async let coreResult = try? await client.send(
            path: APIEndpoint.settingsSearch.path, as: PanelCoreSettings.self
        )
        async let panelResult = try? await client.send(
            path: APIEndpoint.settingsSearchPanel.path,
            as: PanelSystemSettings.self
        )
        async let deviceResult = try? await client.send(
            path: APIEndpoint.deviceBase.path,
            as: DeviceBaseInfo.self
        )
        let (coreValue, panelValue, deviceValue) = await (coreResult, panelResult, deviceResult)
        // 离开页面/刷新被取消时不写错误态（try? 会把取消吞成 nil）
        guard !Task.isCancelled else { return }
        if let coreValue {
            core = coreValue
            if focusedField != .name { nameInput = coreValue.panelName ?? "" }
            loadError = nil
        } else {
            loadError = L10n.t("面板设置加载失败，请重试")
        }
        // panel 取失败时保留旧值：置空会让后续提交把服务器上的值覆盖掉
        if let panelValue {
            systemIP = panelValue.systemIP ?? ""
            if focusedField != .ip { ipInput = systemIP ?? "" }
        }
        if let deviceValue {
            originalDNS = deviceValue.dns ?? []
            hostEntries = deviceValue.hosts ?? []
            if focusedField != .ntp { ntpInput = deviceValue.ntp ?? "" }
            originalNtp = deviceValue.ntp ?? ""
            localTime = deviceValue.localTime ?? ""
        }
    }

    /// 更新单项：PanelName/SessionTimeout/DeveloperMode/Edition/DocSource 走
    /// core/settings/update；SystemIP 走 settings/update（网页端抓包路径）
    private func updateCore(_ key: String, _ value: String, endpoint: EndpointChoice = .core) async {
        savingKey = key
        defer { savingKey = nil }
        let path = endpoint == .core ? APIEndpoint.coreSettingsUpdate.path : APIEndpoint.settingsUpdate.path
        let req = SettingsKeyValueRequest(key: key, value: value)
        do {
            let _: EmptyResponse = try await client.send(path: path, body: req, as: EmptyResponse.self)
            // 回写本地快照，避免整页重载
            switch key {
            case "PanelName":
                core?.panelName = value
            case "SessionTimeout":
                core?.sessionTimeout = value
            case "DeveloperMode":
                core?.developerMode = value
            case "Edition":
                core?.edition = value
            case "DocSource":
                core?.docSource = value
            case "SystemIP":
                systemIP = value
            default: break
            }
            toast = L10n.t("已保存")
        } catch {
            errorText = error.localizedDescription
        }
    }

    enum EndpointChoice { case core, panel }

    // MARK: 设备配置操作（toolbox/device/*）

    /// 同步服务器时间（update/conf，key=LocalTime，value 固定空串）
    private func syncTime() async {
        await updateConf("LocalTime", "")
        // 重拉取同步后的时间展示
        if let device = try? await client.send(
            path: APIEndpoint.deviceBase.path, as: DeviceBaseInfo.self
        ) {
            localTime = device.localTime ?? localTime
        }
    }

    /// 设备配置项通用更新（Ntp / LocalTime）；成功返回 true 并回写 NTP 基线
    @discardableResult
    private func updateConf(_ key: String, _ value: String) async -> Bool {
        isDeviceBusy = true
        defer { isDeviceBusy = false }
        let req = SettingsKeyValueRequest(key: key, value: value)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.deviceUpdateConf.path, body: req, as: EmptyResponse.self
            )
            if key == "Ntp" { originalNtp = value }
            toast = L10n.t("已保存")
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    /// 默认访问地址格式：仅 IP 或域名，不允许协议头 / 端口 / 路径
    static func isValidHostOrIP(_ s: String) -> Bool {
        guard !s.isEmpty,
              !s.contains("://"), !s.contains(":"), !s.contains("/"), !s.contains(" ") else { return false }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        // IPv4：四段且各段 0-255
        if parts.count == 4 {
            return parts.allSatisfy { part in
                guard (1...3).contains(part.count),
                      part.allSatisfy(\.isNumber),
                      let n = Int(part), (0...255).contains(n) else { return false }
                return true
            }
        }
        // 域名：标签以字母数字开头结尾，至少两级
        let domain = #"^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$"#
        return s.range(of: domain, options: .regularExpression) != nil
    }
}

/// settings/search 的 POST body 由 APIClient 自动补 "{}"

// MARK: - 代理编辑页

/// 代理服务器编辑：类型（关闭/SOCKS5/HTTP/HTTPS）+ 地址/端口/用户名/密码/记住密码，
/// 保存走 core/settings/proxy/update
struct PanelProxyEditView: View {
    let server: ServerConfig
    /// 进入时的现有代理配置（core/settings/search 快照）
    let current: PanelCoreSettings?
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var proxyType = ""
    @State private var proxyUrl = ""
    @State private var proxyPort = ""
    @State private var proxyUser = ""
    @State private var proxyPasswd = ""
    @State private var passwdKeep = false
    @State private var isSaving = false
    @State private var errorText: String?

    private let client: APIClient
    private static let typeOptions = [("", "关闭"), ("socks5", "SOCKS5"), ("http", "HTTP"), ("https", "HTTPS")]

    init(server: ServerConfig, current: PanelCoreSettings?, onSaved: @escaping () -> Void) {
        self.server = server
        self.current = current
        self.onSaved = onSaved
        self.client = APIClient.shared(for: server)
    }

    private var typeDisplay: String {
        (Self.typeOptions.first { $0.0 == proxyType }?.1) ?? proxyType.uppercased()
    }

    var body: some View {
        Form {
            Section {
                Picker(L10n.t("代理类型"), selection: $proxyType) {
                    ForEach(Self.typeOptions, id: \.0) { opt in
                        Text(L10n.t(opt.1)).tag(opt.0)
                    }
                }
            } header: {
                SectionLabel(title: L10n.t("代理"), systemImage: "network")
            }

            if !proxyType.isEmpty {
                Section {
                    TextField(L10n.t("代理地址"), text: $proxyUrl)
                        .keyboardType(.asciiCapable)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField(L10n.t("代理端口"), text: $proxyPort)
                        .keyboardType(.numberPad)
                } header: {
                    Text(L10n.t("连接信息"))
                }

                Section {
                    TextField(L10n.t("用户名"), text: $proxyUser)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField(L10n.t("密码"), text: $proxyPasswd)
                    Toggle(L10n.t("记住密码"), isOn: $passwdKeep)
                } header: {
                    Text(L10n.t("认证（可选）"))
                }
            }
        }
        .navigationTitle(L10n.t("代理服务器"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSaving ? L10n.t("保存中…") : L10n.t("保存")) {
                    Task { await save() }
                }
                .disabled(isSaving)
            }
        }
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .onAppear {
            proxyType = current?.proxyType ?? ""
            proxyUrl = current?.proxyUrl ?? ""
            proxyPort = current?.proxyPort ?? ""
            proxyUser = current?.proxyUser ?? ""
            proxyPasswd = current?.proxyPasswd ?? ""
            passwdKeep = (current?.proxyPasswdKeep ?? "Disable") == "Enable"
        }
    }

    private func save() async {
        guard proxyType.isEmpty || (!proxyUrl.trimmingCharacters(in: .whitespaces).isEmpty
                && !proxyPort.trimmingCharacters(in: .whitespaces).isEmpty) else {
            errorText = L10n.t("请填写代理地址与端口")
            return
        }
        isSaving = true
        defer { isSaving = false }
        let req = ProxyUpdateRequest(
            proxyType: proxyType,
            proxyUrl: proxyUrl.trimmingCharacters(in: .whitespaces),
            proxyPort: proxyPort.trimmingCharacters(in: .whitespaces),
            proxyUser: proxyUser,
            proxyPasswd: proxyPasswd,
            proxyPasswdKeep: passwdKeep ? "Enable" : "Disable",
            proxyDocker: false,
            withDockerRestart: false
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.coreSettingsProxyUpdate.path, body: req, as: EmptyResponse.self
            )
            onSaved()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
