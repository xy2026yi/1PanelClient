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
    @State private var dnsInput = ""
    @State private var hostEntries: [DeviceHostItem] = []
    /// 新增 hosts 行的输入（非 nil 时显示输入行）
    @State private var addingHost = false
    @State private var newHostIP = ""
    @State private var newHostName = ""
    @State private var ntpInput = ""
    @State private var localTime = ""
    @State private var isDeviceBusy = false

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
                dnsSection
                hostsSection
                ntpSection
                serverTimeSection
            }
        }
        .navigationTitle(L10n.t("基础设置"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
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
                HStack {
                    TextField(L10n.t("面板别名"), text: $nameInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    saveButton(
                        key: "PanelName",
                        current: core?.panelName ?? "",
                        input: nameInput.trimmingCharacters(in: .whitespaces)
                    )
                }

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
            HStack {
                TextField(L10n.t("IP 或域名"), text: $ipInput)
                    .keyboardType(.asciiCapable)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                saveButton(
                    key: "SystemIP",
                    current: systemIP ?? "",
                    input: ipInput.trimmingCharacters(in: .whitespaces),
                    validate: { Self.isValidHostOrIP($0) },
                    onInvalid: { ipInvalid = true }
                )
            }
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

    // MARK: DNS（换行输入；测试可用性 / 保存为逗号拼接）

    /// 输入按行拆分去空（保存与测试共用；服务器格式为逗号拼接）
    private var dnsList: [String] {
        dnsInput
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var dnsSection: some View {
        Section {
            TextField(L10n.t("每行一个 DNS 地址"), text: $dnsInput, axis: .vertical)
                .lineLimit(3...6)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
            HStack {
                Button(L10n.t("测试可用性")) {
                    Task { await testDNS() }
                }
                .buttonStyle(.bordered)
                .disabled(isDeviceBusy || dnsList.isEmpty)
                Spacer()
                Button(L10n.t("保存")) {
                    Task { await saveDNS() }
                }
                .buttonStyle(.bordered)
                .disabled(isDeviceBusy || dnsList.isEmpty)
            }
        } header: {
            SectionLabel(title: "DNS", systemImage: "dot.radiowaves.up.forward")
        } footer: {
            Text(L10n.t("换行输入，每行一个；保存为全量覆盖。"))
        }
    }

    // MARK: Hosts（一行一条，可单删；添加在下方展开输入行）

    private var hostsSection: some View {
        Section {
            ForEach(Array(hostEntries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.ip)
                            .font(.system(.subheadline, design: .monospaced).bold())
                        Text(entry.host)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await updateHosts(hostEntries.filter { $0 != entry }) }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isDeviceBusy)
                }
            }

            if addingHost {
                VStack(spacing: 8) {
                    TextField(L10n.t("IP 地址"), text: $newHostIP)
                        .font(.system(.body, design: .monospaced))
                        .keyboardType(.asciiCapable)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField(L10n.t("域名（可多个，空格分隔）"), text: $newHostName)
                        .font(.system(.body, design: .monospaced))
                        .keyboardType(.asciiCapable)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    HStack {
                        Button(L10n.t("取消")) {
                            addingHost = false
                            newHostIP = ""
                            newHostName = ""
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Button(L10n.t("添加")) {
                            addHostEntry()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newHostIP.trimmingCharacters(in: .whitespaces).isEmpty
                                  || newHostName.trimmingCharacters(in: .whitespaces).isEmpty
                                  || isDeviceBusy)
                    }
                }
            } else {
                Button {
                    addingHost = true
                } label: {
                    Label(L10n.t("添加 Hosts 记录"), systemImage: "plus.circle")
                }
                .disabled(isDeviceBusy)
            }
        } header: {
            SectionLabel(title: "Hosts", systemImage: "square.grid.2x2")
        } footer: {
            Text(L10n.t("增删均为全量覆盖提交，系统默认条目请谨慎移除。"))
        }
    }

    /// 校验输入并提交（原数组 + 新条目）
    private func addHostEntry() {
        let ip = newHostIP.trimmingCharacters(in: .whitespaces)
        let host = newHostName.trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty, !host.isEmpty else { return }
        addingHost = false
        newHostIP = ""
        newHostName = ""
        Task { await updateHosts(hostEntries + [DeviceHostItem(ip: ip, host: host)]) }
    }

    // MARK: NTP（预置三快捷 + 自定义输入）

    private var ntpSection: some View {
        Section {
            HStack(spacing: 8) {
                ForEach(Self.ntpPresets, id: \.url) { preset in
                    Button(preset.name) {
                        ntpInput = preset.url
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDeviceBusy)
                }
                Spacer()
            }
            HStack {
                TextField("pool.ntp.org", text: $ntpInput)
                    .font(.system(.body, design: .monospaced))
                    .keyboardType(.asciiCapable)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button(L10n.t("保存")) {
                    Task { await updateConf("Ntp", ntpInput.trimmingCharacters(in: .whitespaces)) }
                }
                .buttonStyle(.bordered)
                .disabled(isDeviceBusy || ntpInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            SectionLabel(title: L10n.t("NTP 服务器"), systemImage: "clock.badge")
        } footer: {
            Text(L10n.t("点击预置项自动填入，也可自定义输入。"))
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

    // MARK: 保存按钮（值变化才可用，可选校验）

    @ViewBuilder
    private func saveButton(
        key: String,
        current: String,
        input: String,
        validate: ((String) -> Bool)? = nil,
        onInvalid: (() -> Void)? = nil
    ) -> some View {
        let changed = !(input.isEmpty && current.isEmpty) && input != current
        Button(L10n.t("保存")) {
            if let validate, !validate(input) {
                onInvalid?()
                return
            }
            ipInvalid = false
            Task { await updateCore(key, input, endpoint: key == "SystemIP" ? .panel : .core) }
        }
        .buttonStyle(.bordered)
        .disabled(!changed || savingKey != nil)
    }

    // MARK: 数据

    private func load() async {
        isLoading = true
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
        if let coreValue {
            core = coreValue
            nameInput = coreValue.panelName ?? ""
            loadError = nil
        } else {
            loadError = L10n.t("面板设置加载失败，请重试")
        }
        systemIP = panelValue?.systemIP ?? ""
        ipInput = systemIP ?? ""
        if let deviceValue {
            dnsInput = (deviceValue.dns ?? []).joined(separator: "\n")
            hostEntries = deviceValue.hosts ?? []
            ntpInput = deviceValue.ntp ?? ""
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

    /// 测试 DNS 可用性（check/dns，key=form，value 逗号拼接）
    private func testDNS() async {
        isDeviceBusy = true
        defer { isDeviceBusy = false }
        let req = SettingsKeyValueRequest(key: "form", value: dnsList.joined(separator: ","))
        do {
            let ok: Bool = try await client.send(
                path: APIEndpoint.deviceCheckDns.path, body: req, as: Bool.self
            )
            toast = ok ? L10n.t("DNS 可用") : L10n.t("DNS 不可用")
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// 保存 DNS（update/conf，key=DNS，value 逗号拼接全量覆盖）
    private func saveDNS() async {
        await updateConf("DNS", dnsList.joined(separator: ","))
    }

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

    /// 设备配置项通用更新（DNS / Ntp / LocalTime）
    private func updateConf(_ key: String, _ value: String) async {
        isDeviceBusy = true
        defer { isDeviceBusy = false }
        let req = SettingsKeyValueRequest(key: key, value: value)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.deviceUpdateConf.path, body: req, as: EmptyResponse.self
            )
            toast = L10n.t("已保存")
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// 覆盖提交 hosts 完整数组（update/host）
    private func updateHosts(_ entries: [DeviceHostItem]) async {
        isDeviceBusy = true
        defer { isDeviceBusy = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.deviceUpdateHost.path, body: entries, as: EmptyResponse.self
            )
            hostEntries = entries
            toast = L10n.t("已保存")
        } catch {
            errorText = error.localizedDescription
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
