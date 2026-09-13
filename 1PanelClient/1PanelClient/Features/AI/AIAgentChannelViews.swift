//
//  AIAgentChannelViews.swift
//  1PanelClient
//
//  智能体 · 消息频道（/api/v2/ai/agents/channel/*，logs/增加和修正.md 抓包确认）：
//  频道列表（并行读取 enabled）/ 各频道配置表单 / 微信扫码对接 /
//  配对码批准（channel/pairing/approve）/ Telegram 多 Bot 管理
//  凭证字段在 bots 数组内（各频道 Bot 结构不同），保存为 get 响应整体回传
//

import SwiftUI

// MARK: - 频道定义

enum AIChannelKind: String, CaseIterable, Identifiable {
    case weixin, qqbot, wecom, dingtalk, feishu, telegram, discord

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .weixin: return L10n.t("微信")
        case .qqbot: return "QQ"
        case .wecom: return L10n.t("企业微信")
        case .dingtalk: return L10n.t("钉钉")
        case .feishu: return L10n.t("飞书")
        case .telegram: return "Telegram"
        case .discord: return "Discord"
        }
    }

    var icon: String {
        switch self {
        case .weixin: return "message.fill"
        case .qqbot: return "bubble.left.and.bubble.right.fill"
        case .wecom: return "person.2.fill"
        case .dingtalk: return "bubble.middle.bottom.fill"
        case .feishu: return "text.bubble.fill"
        case .telegram: return "paperplane.fill"
        case .discord: return "gamecontroller.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .weixin: return .green
        case .qqbot: return .blue
        case .wecom: return .blue
        case .dingtalk: return .blue
        case .feishu: return .teal
        case .telegram: return .cyan
        case .discord: return .indigo
        }
    }
}

/// 频道列表行读取的 enabled 状态（各频道 get 响应首个字段一致）
nonisolated struct AIChannelEnabledStatus: Decodable {
    let enabled: Bool?
}

// MARK: - 频道列表页

struct AIAgentChannelsView: View {
    let server: ServerConfig
    let agentId: Int
    let agentName: String
    /// 智能体类型：Telegram 等频道的策略选项集随类型不同（抓包确认）
    var agentType: String? = nil

    @State private var enabledMap: [String: Bool] = [:]
    @State private var isLoading = true

    private let client: APIClient

    init(server: ServerConfig, agentId: Int, agentName: String, agentType: String? = nil) {
        self.server = server
        self.agentId = agentId
        self.agentName = agentName
        self.agentType = agentType
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        List {
            Section {
                ForEach(AIChannelKind.allCases) { kind in
                    NavigationLink {
                        channelDestination(kind)
                    } label: {
                        HStack(spacing: 12) {
                            IconBadge(systemName: kind.icon, color: kind.iconColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.displayName)
                                Text(channelSubtitle(kind))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let enabled = enabledMap[kind.rawValue] {
                                StatusBadge(
                                    text: enabled ? L10n.t("已启用") : L10n.t("未启用"),
                                    color: enabled ? .statusRunning : .secondary
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text(L10n.t("配置消息平台接入，使智能体可在对应平台对话"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("频道"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadAllStatus() }
        .refreshable { await loadAllStatus() }
    }

    @ViewBuilder
    private func channelDestination(_ kind: AIChannelKind) -> some View {
        switch kind {
        case .weixin:
            AIAgentWeixinChannelView(server: server, agentId: agentId, initialEnabled: enabledMap[kind.rawValue] ?? false,
                                     agentType: agentType)
        case .qqbot:
            AIAgentQQChannelView(server: server, agentId: agentId, agentType: agentType)
        case .wecom:
            AIAgentWecomChannelView(server: server, agentId: agentId, agentType: agentType)
        case .dingtalk:
            AIAgentDingtalkChannelView(server: server, agentId: agentId)
        case .feishu:
            AIAgentFeishuChannelView(server: server, agentId: agentId, agentType: agentType)
        case .telegram:
            AIAgentTelegramChannelView(server: server, agentId: agentId, agentType: agentType)
        case .discord:
            AIAgentDiscordChannelView(server: server, agentId: agentId)
        }
    }

    private func channelSubtitle(_ kind: AIChannelKind) -> String {
        switch kind {
        case .weixin: return L10n.t("扫码对接")
        case .qqbot: return L10n.t("App ID / App Secret")
        case .wecom: return L10n.t("Bot ID / 密钥")
        case .dingtalk: return "Client ID / Client Secret"
        case .feishu: return "App ID / App Secret"
        case .telegram: return L10n.t("Bot Token")
        case .discord: return "Token"
        }
    }

    /// 并行读取频道 enabled 状态（微信无 get 接口，跳过；单条失败不影响其他）
    private func loadAllStatus() async {
        await withTaskGroup(of: (String, Bool?).self) { group in
            for kind in AIChannelKind.allCases where kind != .weixin {
                let path = APIEndpoint.aiAgentChannelGet.path
                    .replacingOccurrences(of: ":type", with: kind.rawValue)
                group.addTask { [client] in
                    do {
                        let resp: AIChannelEnabledStatus = try await client.send(
                            path: path,
                            body: AIAgentChannelRequest(agentId: agentId),
                            as: AIChannelEnabledStatus.self)
                        return (kind.rawValue, resp.enabled)
                    } catch {
                        return (kind.rawValue, nil)
                    }
                }
            }
            for await (key, enabled) in group {
                // get 失败（如频道刚被删除）时置 nil 清掉旧徽标，
                // 不再残留上一次的「已启用」
                enabledMap[key] = enabled
            }
        }
        isLoading = false
    }
}

// MARK: - 通用小组件

/// 策略 Picker（选项集按频道传入：pairing / open / allowlist / disabled）。
/// get 可能返回空串/未知值（如钉钉 groupPolicy:""）：不在选项集内时折叠到首个选项，
/// 避免 Picker 空 selection 告警与空白行（提交仍走 state，用户不改动即保持折叠值）
private struct ChannelPolicyPicker: View {
    let title: String
    let options: [(value: String, label: String)]
    @Binding var value: String

    var body: some View {
        Picker(title, selection: Binding(
            get: {
                options.contains(where: { $0.value == value })
                    ? value : (options.first?.value ?? value)
            },
            set: { value = $0 }
        )) {
            ForEach(options, id: \.value) { p in
                Text(p.label).tag(p.value)
            }
        }
    }
}

/// 白名单编辑（策略=白名单时显示，一行一个；设置页 allowedOrigins 复用）
struct WhitelistEditor: View {
    let title: String
    @Binding var list: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { list.joined(separator: "\n") },
                set: { list = $0.split(whereSeparator: \.isNewline).map(String.init) }
            ))
            .font(.system(.caption, design: .monospaced))
            .frame(minHeight: 64)
            .scrollContentBackground(.hidden)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// 配对码批准（私聊策略=配队码时显示；POST channel/pairing/approve）
private struct PairingApproveSection: View {
    let client: APIClient
    let agentId: Int
    let type: String
    /// 多 Bot 频道（Telegram）传默认账号 id
    var accountId: String? = nil

    @State private var pairingCode = ""
    @State private var isSubmitting = false
    @State private var message: String?
    @State private var showError = false

    var body: some View {
        Section {
            TextField(L10n.t("配对码"), text: $pairingCode)
                .keyboardType(.numberPad)
            Button {
                Task { await approve() }
            } label: {
                if isSubmitting {
                    ProgressView()
                } else {
                    Label(L10n.t("批准配对"), systemImage: "checkmark.seal")
                }
            }
            .disabled(pairingCode.isEmpty || isSubmitting)
        } header: {
            SectionLabel(title: L10n.t("配对"), systemImage: "link")
        } footer: {
            Text(L10n.t("私聊策略为配队码时，用户发起对话后在对应平台提交配对码，在此批准完成对接"))
        }
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private func approve() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelPairingApprove.path,
                body: AIAgentChannelPairingApproveRequest(
                    agentId: agentId,
                    type: type,
                    pairingCode: pairingCode,
                    accountId: accountId),
                as: EmptyResponse.self)
            message = L10n.t("已批准配对")
            pairingCode = ""
        } catch {
            guard !APIError.isCancellation(error) else { return }
            message = error.localizedDescription
        }
        showError = true
    }
}

// MARK: - 频道插件区（OpenClaw 频道为插件：版本 / 卸载带进度）

/// 频道页顶部插件状态区：plugin/check（checkLatest=true 取最新版本）；
/// 已安装 → 版本 + 卸载；未安装 → 安装（plugin/install，taskID 驱动进度页）；
/// 检查失败时整区隐藏
struct ChannelPluginSection: View {
    let client: APIClient
    let agentId: Int
    let type: String
    var onUninstalled: () -> Void = {}
    var onInstalled: () -> Void = {}

    @State private var status: AIAgentPluginStatus?
    @State private var isLoading = true
    @State private var confirmUninstall = false
    @State private var progressTaskID = ""
    @State private var showProgress = false
    @State private var progressTitle = ""
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        if let s = status {
            Section {
                if s.installed == true {
                    LabeledContent(L10n.t("插件版本"), value: s.currentVersion ?? "-")
                    if let latest = s.latestVersion, !latest.isEmpty, latest != s.currentVersion {
                        LabeledContent(L10n.t("最新版本"), value: latest)
                    }
                    Button(role: .destructive) {
                        confirmUninstall = true
                    } label: {
                        Label(L10n.t("卸载插件"), systemImage: "trash")
                    }
                } else {
                    LabeledContent(L10n.t("插件版本"), value: L10n.t("未安装"))
                    Button {
                        Task { await install() }
                    } label: {
                        Label(L10n.t("安装插件"), systemImage: "arrow.down.circle")
                    }
                }
            } header: {
                SectionLabel(title: L10n.t("频道插件"), systemImage: "puzzlepiece")
            }
            .alert(L10n.t("卸载插件"), isPresented: $confirmUninstall) {
                Button(L10n.t("取消"), role: .cancel) {}
                Button(L10n.t("卸载"), role: .destructive) {
                    Task { await uninstall() }
                }
            } message: {
                Text(L10n.t("卸载后该频道将不可用，需重新安装插件"))
            }
            .alert(L10n.t("提示"), isPresented: $showError) {
                Button(L10n.t("好的"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .background(
                NavigationLink(isActive: $showProgress) {
                    TaskProgressView(taskID: progressTaskID, title: progressTitle, latest: false, node: "local") { isDone in
                        if isDone {
                            Task {
                                await load()
                                await MainActor.run {
                                    // 卸载/安装完成后回调刷新频道配置（get 的 installed 会变化）
                                    onUninstalled()
                                    onInstalled()
                                }
                            }
                        }
                        return false
                    }
                } label: { EmptyView() }
                .hidden()
            )
        }
    }

    private func load() async {
        do {
            status = try await client.send(
                path: APIEndpoint.aiAgentPluginCheck.path,
                body: AIAgentPluginCheckRequest(agentId: agentId, type: type, checkLatest: true),
                as: AIAgentPluginStatus.self)
        } catch {
            // 检查失败隐藏整区（不影响频道配置）
            status = nil
        }
        isLoading = false
    }

    private func install() async {
        let taskID = UUID().uuidString
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentPluginInstall.path,
                body: AIAgentPluginInstallRequest(agentId: agentId, type: type, taskID: taskID),
                as: EmptyResponse.self)
            progressTaskID = taskID
            progressTitle = L10n.t("安装插件")
            showProgress = true
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func uninstall() async {
        let taskID = UUID().uuidString
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentPluginUninstall.path,
                body: AIAgentPluginUninstallRequest(agentId: agentId, type: type, taskID: taskID),
                as: EmptyResponse.self)
            progressTaskID = taskID
            progressTitle = L10n.t("卸载插件")
            showProgress = true
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - 微信（扫码对接 + 任务日志二维码）

struct AIAgentWeixinChannelView: View {
    let server: ServerConfig
    let agentId: Int
    let initialEnabled: Bool
    /// OpenClaw 的频道为插件（版本/卸载），抓包确认
    var agentType: String? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var enabled = false
    @State private var isLoggingIn = false
    @State private var logLines: [String] = []
    @State private var qrURL: String?
    @State private var isPolling = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var confirmDelete = false

    private let client: APIClient

    init(server: ServerConfig, agentId: Int, initialEnabled: Bool, agentType: String? = nil) {
        self.server = server
        self.agentId = agentId
        self.initialEnabled = initialEnabled
        self.agentType = agentType
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        List {
            if agentType == "openclaw" {
                ChannelPluginSection(client: client, agentId: agentId, type: "weixin") {
                    enabled = false
                    qrURL = nil
                }
            }

            Section {
                Toggle(L10n.t("启用"), isOn: Binding(
                    get: { enabled },
                    set: { newValue in
                        if !newValue { return } // 微信经扫码对接启用，关闭走删除
                        enabled = newValue
                    }
                ))
                .disabled(true)
            } footer: {
                Text(L10n.t("微信频道通过扫码对接启用，关闭需删除对接"))
            }

            Section {
                if let url = qrURL {
                    VStack(spacing: 14) {
                        QRCodeView(text: url, side: 200)
                        Text(L10n.t("请使用微信扫描二维码"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } else if isLoggingIn || isPolling {
                    HStack {
                        Spacer()
                        ProgressView()
                        Text(L10n.t("正在生成二维码…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    Button {
                        Task { await startLogin() }
                    } label: {
                        Label(L10n.t("扫码对接"), systemImage: "qrcode.viewfinder")
                    }
                    .disabled(isLoggingIn)
                }
            } header: {
                SectionLabel(title: L10n.t("扫码对接"), systemImage: "qrcode")
            }

            if !logLines.isEmpty {
                Section {
                    ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } header: {
                    SectionLabel(title: L10n.t("对接日志"), systemImage: "doc.text")
                }
            }

            if enabled {
                Section {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label(L10n.t("删除对接"), systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(L10n.t("微信"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            enabled = initialEnabled || enabled
        }
        .onDisappear { isPolling = false }
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(L10n.t("删除对接"), isPresented: $confirmDelete) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("删除"), role: .destructive) {
                Task { await deleteChannel() }
            }
        } message: {
            Text(L10n.t("确定删除微信频道对接吗？"))
        }
    }

    /// 发起扫码对接：login 返回 taskID（[推测：响应体未抓包]），按 taskID 轮询任务日志
    private func startLogin() async {
        isLoggingIn = true
        defer { isLoggingIn = false }
        do {
            let resp: AIAgentWeixinLoginResponse = try await client.send(
                path: APIEndpoint.aiAgentWeixinLogin.path,
                body: AIAgentChannelRequest(agentId: agentId),
                as: AIAgentWeixinLoginResponse.self)
            startPolling(taskID: resp.taskID)
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// 轮询任务日志：网页端仅按 taskID 查询（taskType/taskOperate/name/resourceID
    /// 均为空、latest=false 从头读，抓包确认）；响应未携带 taskID 时回退旧过滤参数
    private func startPolling(taskID: String?) {
        isPolling = true
        Task {
            while isPolling && !Task.isCancelled {
                do {
                    let resp: TaskLogResponse = try await client.send(
                        path: APIEndpoint.logsTaskRead.path,
                        body: TaskLogReadRequest(
                            id: 0, type: "task", name: "",
                            page: 1, pageSize: 500, latest: false,
                            taskID: taskID ?? "",
                            taskType: taskID == nil ? "AI" : "",
                            taskOperate: taskID == nil ? "weixin" : "",
                            resourceID: taskID == nil ? agentId : 0),
                        queryItems: [URLQueryItem(name: "operateNode", value: "local")],
                        as: TaskLogResponse.self)
                    let lines = (resp.lines ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
                    await MainActor.run {
                        logLines = lines
                        if qrURL == nil {
                            qrURL = Self.extractQRURL(from: lines)
                            if qrURL != nil {
                                enabled = true
                            }
                        }
                    }
                    // 任务结束（Success/Failed）停止轮询
                    let status = (resp.taskStatus ?? "").lowercased()
                    if resp.end == true && status != "executing" { break }
                } catch {
                    // 轮询失败静默重试
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            await MainActor.run { isPolling = false }
        }
    }

    /// 从日志行提取二维码链接（优先微信 liteapp，兜底任意 http 链接）
    static func extractQRURL(from lines: [String]) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        var candidates: [String] = []
        for line in lines {
            guard let detector else { break }
            let range = NSRange(line.startIndex..., in: line)
            for match in detector.matches(in: line, range: range) {
                if let url = match.url?.absoluteString {
                    candidates.append(url)
                }
            }
        }
        return candidates.first { $0.contains("liteapp.weixin.qq.com") }
            ?? candidates.first { !$0.contains("1panel") }
    }

    private func deleteChannel() async {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelDelete.path,
                body: AIAgentChannelDeleteRequest(agentId: agentId, type: AIChannelKind.weixin.rawValue),
                as: EmptyResponse.self)
            enabled = false
            qrURL = nil
            logLines = []
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - QQ

struct AIAgentQQChannelView: View {
    let server: ServerConfig
    let agentId: Int
    /// OpenClaw 的 QQ 为插件 + 多 Bot（更新体无顶层策略，抓包确认）；
    /// 基础类型（Hermes/QwenPaw）为单默认 Bot + 顶层策略表单
    var agentType: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var c = AIChannelQQBot()
    /// 基础类型：凭证与私聊白名单在 bots[0]（抓包确认）；其余 bots 原样保留
    @State private var bot = AIChannelQQBotItem(accountId: "default", name: "Default", enabled: true, isDefault: true)
    @State private var extraBots: [AIChannelQQBotItem] = []
    /// OpenClaw：Bot 列表整列编辑
    @State private var bots: [AIChannelQQBotItem] = []
    @State private var savedC = AIChannelQQBot()
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var loadError: String?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var editingBot: AIChannelQQBotItem?
    @State private var showAddBot = false

    private let client: APIClient

    private var isOpenClaw: Bool { agentType == "openclaw" }

    init(server: ServerConfig, agentId: Int, agentType: String? = nil) {
        self.server = server
        self.agentId = agentId
        self.agentType = agentType
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        Form {
            if isLoading {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            } else if loadError != nil {
                Section {
                    LoadErrorStateView(message: loadError ?? "") {
                        Task { await load() }
                    }
                }
            } else if isOpenClaw {
                ChannelPluginSection(client: client, agentId: agentId, type: "qqbot") {
                    Task { await load() }
                }

                Section {
                    Toggle(L10n.t("启用"), isOn: Binding(
                        get: { c.enabled ?? false }, set: { c.enabled = $0 }))
                }

                openclawBotList

                if (savedC.dmPolicy ?? "").isEmpty == false {
                    // OpenClaw 抓包 update 体无顶层策略，但 get 带值时不丟字段：
                    // 私聊策略=配队码时仍提供批准配对（带默认账户）
                    if savedC.dmPolicy == "pairing" {
                        PairingApproveSection(client: client, agentId: agentId, type: "qqbot",
                                              accountId: bots.first(where: { $0.isDefault == true })?.accountId)
                    }
                }
            } else {
                Section {
                    Toggle(L10n.t("启用"), isOn: Binding(
                        get: { c.enabled ?? false }, set: { c.enabled = $0 }))
                    TextField("App ID", text: Binding(
                        get: { bot.appId ?? "" }, set: { bot.appId = $0 }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("App Secret", text: Binding(
                        get: { bot.clientSecret ?? "" }, set: { bot.clientSecret = $0 }))
                        .textInputAutocapitalization(.never)
                    ChannelPolicyPicker(title: L10n.t("私聊策略"), options: AIChannelPolicy.dmPoliciesBasic,
                                         value: Binding(get: { c.dmPolicy ?? "pairing" }, set: { c.dmPolicy = $0 }))
                    ChannelPolicyPicker(title: L10n.t("群组策略"), options: AIChannelPolicy.groupPoliciesBasic,
                                         value: Binding(get: { c.groupPolicy ?? "open" }, set: { c.groupPolicy = $0 }))
                } footer: {
                    Text(L10n.t("保存后智能体即可在 QQ 平台对话"))
                }

                if c.dmPolicy == "pairing" {
                    PairingApproveSection(client: client, agentId: agentId, type: "qqbot")
                }
            }
        }
        .navigationTitle("QQ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                }
                .disabled(isLoading || loadError != nil || isSaving)
            }
        }
        .task { await load() }
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $editingBot) { bot in
            AIQQBotFormSheet(
                bot: bot, isEdit: true,
                existingAccountIDs: bots.compactMap(\.accountId),
                selfOriginalID: bot.accountId) { updated in
                // 按打开弹窗时的行身份匹配（允许修改账户 ID）
                if let idx = bots.firstIndex(where: { $0.id == bot.id }) {
                    bots[idx] = updated
                }
            }
        }
        .sheet(isPresented: $showAddBot) {
            AIQQBotFormSheet(
                bot: AIChannelQQBotItem(accountId: bots.isEmpty ? "default" : "",
                                        name: "Default", enabled: true,
                                        isDefault: bots.isEmpty),
                isEdit: false,
                lockAccountID: bots.isEmpty,
                existingAccountIDs: bots.compactMap(\.accountId)) { newBot in
                bots.append(newBot)
            }
        }
    }

    // MARK: OpenClaw Bot 列表

    private var openclawBotList: some View {
        Section {
            ForEach(bots) { bot in
                Button {
                    editingBot = bot
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(bot.name ?? bot.accountId ?? "-")
                                    .font(.body.bold())
                                    .foregroundStyle(.primary)
                                if bot.isDefault == true {
                                    StatusBadge(text: L10n.t("默认"), color: .blue)
                                }
                                if bot.enabled != true {
                                    StatusBadge(text: L10n.t("未启用"), color: .secondary)
                                }
                            }
                            Text(bot.accountId ?? "-")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        Task { await saveBots(bots.filter { $0.id != bot.id }) }
                    } label: {
                        Label(L10n.t("删除"), systemImage: "trash")
                    }
                }
            }

            Button {
                showAddBot = true
            } label: {
                Label(L10n.t("新增 Bot"), systemImage: "plus.circle")
            }
        } header: {
            SectionLabel(title: L10n.f("Bot 列表 · 共 %d 个", bots.count), systemImage: "person.2")
        } footer: {
            Text(L10n.t("点击 Bot 编辑凭证与策略；删除将立即保存"))
        }
    }

    /// OpenClaw：Bot 删除即时全量保存（顶层取已保存快照，不含草稿）
    private func saveBots(_ updated: [AIChannelQQBotItem]) async {
        guard !isSaving, !updated.isEmpty else { return }
        let previousBots = bots
        bots = updated
        var out = savedC
        out.agentId = agentId
        out.installed = nil
        // OpenClaw 抓包 update 体无顶层策略字段
        out.dmPolicy = nil
        out.groupPolicy = nil
        out.allowFrom = nil
        out.groupAllowFrom = nil
        out.bots = updated
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "qqbot"),
                body: out,
                as: EmptyResponse.self)
            savedC = out
        } catch {
            guard !APIError.isCancellation(error) else { return }
            bots = previousBots
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func load() async {
        do {
            let resp: AIChannelQQBot = try await client.send(
                path: APIEndpoint.aiAgentChannelGet.path.replacingOccurrences(of: ":type", with: "qqbot"),
                body: AIAgentChannelRequest(agentId: agentId),
                as: AIChannelQQBot.self)
            c = resp
            savedC = resp
            if isOpenClaw {
                bots = resp.bots ?? []
            } else {
                bot = resp.bots?.first ?? bot
                extraBots = Array((resp.bots ?? []).dropFirst())
            }
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        var out = c
        out.agentId = agentId
        // update 体不含 get 回传的 installed 标记（抓包确认）
        out.installed = nil
        if isOpenClaw {
            // OpenClaw 抓包 update 体：{agentId, enabled, bots}（无顶层策略）；
            // Bot 编辑走草稿 + 保存按钮（删除/插件即时保存）
            out.dmPolicy = nil
            out.groupPolicy = nil
            out.allowFrom = nil
            out.groupAllowFrom = nil
            out.bots = bots
        } else {
            // bot.enabled 与顶层开关相互独立（抓包确认：bot 开启 + 顶层关闭同体保存）
            out.bots = [bot] + extraBots
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "qqbot"),
                body: out,
                as: EmptyResponse.self)
            savedC = out
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

/// OpenClaw QQ Bot 新建/编辑表单（名称/账户ID/状态/AppID/AppSecret/
/// 私聊白名单/系统提示词；首个 Bot 账户 ID 固定 default，抓包确认）
private struct AIQQBotFormSheet: View {
    @State var bot: AIChannelQQBotItem
    let isEdit: Bool
    /// 首个 Bot 的账户 ID 固定为 default（不可修改，网页端行为）
    var lockAccountID: Bool = false
    var existingAccountIDs: [String] = []
    var selfOriginalID: String? = nil
    let onConfirm: (AIChannelQQBotItem) -> Void

    @Environment(\.dismiss) private var dismiss

    private var isDuplicateAccount: Bool {
        let id = (bot.accountId ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return false }
        return existingAccountIDs.filter { $0 != selfOriginalID }.contains(id)
    }

    private var canSubmit: Bool {
        !(bot.accountId ?? "").isEmpty && !(bot.appId ?? "").isEmpty
            && !(bot.clientSecret ?? "").isEmpty && !isDuplicateAccount
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.t("名称"), text: Binding(
                        get: { bot.name ?? "" }, set: { bot.name = $0 }))
                        .textInputAutocapitalization(.never)
                    TextField(L10n.t("账户 ID"), text: Binding(
                        get: { bot.accountId ?? "" }, set: { bot.accountId = $0 }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(lockAccountID)
                    Toggle(L10n.t("启用"), isOn: Binding(
                        get: { bot.enabled ?? true }, set: { bot.enabled = $0 }))
                    TextField("App ID", text: Binding(
                        get: { bot.appId ?? "" }, set: { bot.appId = $0 }))
                        .textInputAutocapitalization(.never)
                    SecureField("App Secret", text: Binding(
                        get: { bot.clientSecret ?? "" }, set: { bot.clientSecret = $0 }))
                        .textInputAutocapitalization(.never)
                } header: {
                    SectionLabel(title: isEdit ? L10n.t("编辑 Bot") : L10n.t("新增 Bot"), systemImage: "person.crop.circle")
                } footer: {
                    if isDuplicateAccount {
                        Text(L10n.t("账户 ID 与现有 Bot 重复"))
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    WhitelistEditor(title: L10n.t("私聊白名单"), list: Binding(
                        get: { bot.allowFrom ?? [] },
                        set: { bot.allowFrom = $0.isEmpty ? nil : $0 }))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.t("系统提示词"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: Binding(
                            get: { bot.systemPrompt ?? "" },
                            set: { bot.systemPrompt = $0 }))
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 72)
                            .scrollContentBackground(.hidden)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                } header: {
                    SectionLabel(title: L10n.t("策略"), systemImage: "slider.horizontal.3")
                } footer: {
                    Text(L10n.t("白名单一行一个；系统提示词随每个 Bot 生效"))
                }
            }
            .navigationTitle(isEdit ? L10n.t("编辑 Bot") : L10n.t("新增 Bot"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("确定")) {
                        onConfirm(bot)
                        dismiss()
                    }
                    .disabled(!canSubmit)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.large])
    }
}

// MARK: - 企业微信

struct AIAgentWecomChannelView: View {
    let server: ServerConfig
    let agentId: Int
    /// OpenClaw 策略为全集（含白名单）+ 插件区；基础类型为 配队码/开放/禁用
    var agentType: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var c = AIChannelWecom()
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var loadError: String?
    @State private var errorMessage: String?
    @State private var showError = false

    private let client: APIClient

    private var isOpenClaw: Bool { agentType == "openclaw" }

    init(server: ServerConfig, agentId: Int, agentType: String? = nil) {
        self.server = server
        self.agentId = agentId
        self.agentType = agentType
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        Form {
            if isLoading {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            } else if loadError != nil {
                Section {
                    LoadErrorStateView(message: loadError ?? "") {
                        Task { await load() }
                    }
                }
            } else {
                if isOpenClaw {
                    ChannelPluginSection(client: client, agentId: agentId, type: "wecom") {
                        Task { await load() }
                    }
                }

                Section {
                    Toggle(L10n.t("启用"), isOn: Binding(
                        get: { c.enabled ?? false }, set: { c.enabled = $0 }))
                    TextField(L10n.t("Bot ID"), text: Binding(
                        get: { c.botId ?? "" }, set: { c.botId = $0 }))
                        .textInputAutocapitalization(.never)
                    SecureField(L10n.t("密钥"), text: Binding(
                        get: { c.secret ?? "" }, set: { c.secret = $0 }))
                    ChannelPolicyPicker(title: L10n.t("私聊策略"),
                                         options: isOpenClaw ? AIChannelPolicy.dmPoliciesFull : AIChannelPolicy.dmPoliciesBasic,
                                         value: Binding(get: { c.dmPolicy ?? "pairing" }, set: { c.dmPolicy = $0 }))
                    if isOpenClaw, c.dmPolicy == "allowlist" {
                        WhitelistEditor(title: L10n.t("私聊白名单"), list: Binding(
                            get: { c.allowFrom ?? [] }, set: { c.allowFrom = $0 }))
                    }
                    ChannelPolicyPicker(title: L10n.t("群组策略"),
                                         options: isOpenClaw ? AIChannelPolicy.groupPoliciesFull : AIChannelPolicy.groupPoliciesBasic,
                                         value: Binding(get: { c.groupPolicy ?? "open" }, set: { c.groupPolicy = $0 }))
                    if isOpenClaw, c.groupPolicy == "allowlist" {
                        WhitelistEditor(title: L10n.t("群组白名单"), list: Binding(
                            get: { c.groupAllowFrom ?? [] }, set: { c.groupAllowFrom = $0 }))
                    }
                }

                if c.dmPolicy == "pairing" {
                    PairingApproveSection(client: client, agentId: agentId, type: "wecom")
                }
            }
        }
        .navigationTitle(L10n.t("企业微信"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                }
                .disabled(isLoading || loadError != nil || isSaving)
            }
        }
        .task { await load() }
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func load() async {
        do {
            c = try await client.send(
                path: APIEndpoint.aiAgentChannelGet.path.replacingOccurrences(of: ":type", with: "wecom"),
                body: AIAgentChannelRequest(agentId: agentId),
                as: AIChannelWecom.self)
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        var out = c
        out.agentId = agentId
        out.installed = nil
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "wecom"),
                body: out,
                as: EmptyResponse.self)
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - 钉钉

struct AIAgentDingtalkChannelView: View {
    let server: ServerConfig
    let agentId: Int

    @Environment(\.dismiss) private var dismiss
    @State private var c = AIChannelDingtalk()
    @State private var bot = AIChannelDingtalkBotItem(accountId: "default", name: "Default", enabled: true, isDefault: true)
    @State private var extraBots: [AIChannelDingtalkBotItem] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var loadError: String?
    @State private var errorMessage: String?
    @State private var showError = false

    private let client: APIClient

    init(server: ServerConfig, agentId: Int) {
        self.server = server
        self.agentId = agentId
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        Form {
            if isLoading {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            } else if loadError != nil {
                Section {
                    LoadErrorStateView(message: loadError ?? "") {
                        Task { await load() }
                    }
                }
            } else {
                Section {
                    Toggle(L10n.t("启用"), isOn: Binding(
                        get: { c.enabled ?? false }, set: { c.enabled = $0 }))
                    TextField("Client ID", text: Binding(
                        get: { bot.clientId ?? "" }, set: { bot.clientId = $0 }))
                        .textInputAutocapitalization(.never)
                    SecureField("Client Secret", text: Binding(
                        get: { bot.clientSecret ?? "" }, set: { bot.clientSecret = $0 }))
                    ChannelPolicyPicker(title: L10n.t("私聊策略"), options: AIChannelPolicy.dmPoliciesBasic,
                                         value: Binding(get: { c.dmPolicy ?? "pairing" }, set: { c.dmPolicy = $0 }))
                    ChannelPolicyPicker(title: L10n.t("群组策略"), options: AIChannelPolicy.groupPoliciesBasic,
                                         value: Binding(get: { c.groupPolicy ?? "open" }, set: { c.groupPolicy = $0 }))
                }

                Section {
                    Toggle(L10n.t("会话独立"), isOn: Binding(
                        get: { c.separateSessionByConversation ?? false },
                        set: { c.separateSessionByConversation = $0 }))
                    Toggle(L10n.t("跨会话共享记忆"), isOn: Binding(
                        get: { c.sharedMemoryAcrossConversations ?? false },
                        set: { c.sharedMemoryAcrossConversations = $0 }))
                    Toggle(L10n.t("异步模式"), isOn: Binding(
                        get: { c.asyncMode ?? false }, set: { c.asyncMode = $0 }))
                    TextField(L10n.t("异步回执文案"), text: Binding(
                        get: { c.ackText ?? "" }, set: { c.ackText = $0 }))
                } header: {
                    SectionLabel(title: L10n.t("会话设置"), systemImage: "bubble.left.and.bubble.right")
                }

                if c.dmPolicy == "pairing" {
                    PairingApproveSection(client: client, agentId: agentId, type: "dingtalk")
                }
            }
        }
        .navigationTitle(L10n.t("钉钉"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                }
                .disabled(isLoading || loadError != nil || isSaving)
            }
        }
        .task { await load() }
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func load() async {
        do {
            let resp: AIChannelDingtalk = try await client.send(
                path: APIEndpoint.aiAgentChannelGet.path.replacingOccurrences(of: ":type", with: "dingtalk"),
                body: AIAgentChannelRequest(agentId: agentId),
                as: AIChannelDingtalk.self)
            var loaded = resp
            // 群组策略空串折叠为默认值，避免 Picker 空 selection
            if (loaded.groupPolicy ?? "").isEmpty { loaded.groupPolicy = "open" }
            // 未配置（作用域与回执全空）时按网页端默认值回显：
            // 会话独立=true、作用域 group_sender、默认回执文案（对齐网页端首次保存体）
            if (loaded.groupSessionScope ?? "").isEmpty && (loaded.ackText ?? "").isEmpty {
                loaded.separateSessionByConversation = true
                loaded.groupSessionScope = "group_sender"
                loaded.ackText = "任务已接收，处理中..."
            }
            c = loaded
            bot = loaded.bots?.first ?? bot
            extraBots = Array((loaded.bots ?? []).dropFirst())
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        var out = c
        out.agentId = agentId
        out.installed = nil
        out.bots = [bot] + extraBots
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "dingtalk"),
                body: out,
                as: EmptyResponse.self)
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - 飞书（OpenClaw 多 Bot；基础类型单默认 Bot）

struct AIAgentFeishuChannelView: View {
    let server: ServerConfig
    let agentId: Int
    /// OpenClaw：插件 + 多 Bot（Bot 内私聊策略全集）+ @机器人三态；
    /// 基础类型（Hermes/QwenPaw）为单默认 Bot 表单
    var agentType: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var c = AIChannelFeishu()
    /// 基础类型：私聊策略与凭证在 bots[0]（顶层无 dmPolicy，抓包确认）
    @State private var bot = AIChannelFeishuBotItem(accountId: "default", name: "Default", enabled: true, isDefault: true)
    @State private var extraBots: [AIChannelFeishuBotItem] = []
    /// OpenClaw：Bot 列表整列编辑
    @State private var bots: [AIChannelFeishuBotItem] = []
    @State private var savedC = AIChannelFeishu()
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var loadError: String?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var editingBot: AIChannelFeishuBotItem?
    @State private var showAddBot = false
    /// 行内批准配对（Bot 私聊策略=配队码时）
    @State private var pairingBot: AIChannelFeishuBotItem?
    @State private var pairingCode = ""
    @State private var isApproving = false

    private let client: APIClient

    private var isOpenClaw: Bool { agentType == "openclaw" }

    /// @机器人三态：需要@ / 无需@ / 按群组配置（抓包取值 true/false/open）
    private let mentionModes: [(value: String, label: String)] = [
        ("true", L10n.t("需要@")),
        ("false", L10n.t("无需@")),
        ("open", L10n.t("按群组配置")),
    ]

    init(server: ServerConfig, agentId: Int, agentType: String? = nil) {
        self.server = server
        self.agentId = agentId
        self.agentType = agentType
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        Form {
            if isLoading {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            } else if loadError != nil {
                Section {
                    LoadErrorStateView(message: loadError ?? "") {
                        Task { await load() }
                    }
                }
            } else if isOpenClaw {
                ChannelPluginSection(client: client, agentId: agentId, type: "feishu") {
                    Task { await load() }
                }

                Section {
                    Toggle(L10n.t("启用"), isOn: Binding(
                        get: { c.enabled ?? false }, set: { c.enabled = $0 }))
                    Toggle(L10n.t("线程会话"), isOn: Binding(
                        get: { c.threadSession ?? true }, set: { c.threadSession = $0 }))
                    Toggle(L10n.t("流式传输"), isOn: Binding(
                        get: { c.streaming ?? false }, set: { c.streaming = $0 }))
                    TextField(L10n.t("回复模式"), text: Binding(
                        get: { c.replyMode ?? "auto" }, set: { c.replyMode = $0 }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    Picker(L10n.t("群聊需@机器人"), selection: Binding(
                        get: {
                            let v = c.requireMention ?? ""
                            return mentionModes.contains(where: { $0.value == v }) ? v : "true"
                        },
                        set: { c.requireMention = $0 })) {
                        ForEach(mentionModes, id: \.value) { m in
                            Text(m.label).tag(m.value)
                        }
                    }
                    ChannelPolicyPicker(title: L10n.t("群组策略"), options: AIChannelPolicy.groupPoliciesFull,
                                         value: Binding(get: { c.groupPolicy ?? "open" }, set: { c.groupPolicy = $0 }))
                    if c.groupPolicy == "allowlist" {
                        WhitelistEditor(title: L10n.t("群组白名单"), list: Binding(
                            get: { c.groupAllowFrom ?? [] }, set: { c.groupAllowFrom = $0 }))
                    }
                } header: {
                    SectionLabel(title: L10n.t("会话设置"), systemImage: "bubble.left.and.bubble.right")
                }

                openclawBotList
            } else {
                Section {
                    Toggle(L10n.t("启用"), isOn: Binding(
                        get: { c.enabled ?? false }, set: { c.enabled = $0 }))
                    TextField("App ID", text: Binding(
                        get: { bot.appId ?? "" }, set: { bot.appId = $0 }))
                        .textInputAutocapitalization(.never)
                    SecureField("App Secret", text: Binding(
                        get: { bot.appSecret ?? "" }, set: { bot.appSecret = $0 }))
                        .textInputAutocapitalization(.never)
                    ChannelPolicyPicker(title: L10n.t("私聊策略"), options: AIChannelPolicy.dmPoliciesBasic,
                                         value: Binding(get: { bot.dmPolicy ?? "open" }, set: { bot.dmPolicy = $0 }))
                    ChannelPolicyPicker(title: L10n.t("群组策略"), options: AIChannelPolicy.groupPoliciesBasic,
                                         value: Binding(get: { c.groupPolicy ?? "open" }, set: { c.groupPolicy = $0 }))
                }

                Section {
                    Toggle(L10n.t("话题式会话"), isOn: Binding(
                        get: { c.threadSession ?? false }, set: { c.threadSession = $0 }))
                    Toggle(L10n.t("流式输出"), isOn: Binding(
                        get: { c.streaming ?? false }, set: { c.streaming = $0 }))
                    Toggle(L10n.t("群聊需@机器人"), isOn: Binding(
                        get: { (c.requireMention ?? "") == "true" },
                        set: { c.requireMention = $0 ? "true" : "false" }))
                } header: {
                    SectionLabel(title: L10n.t("会话设置"), systemImage: "bubble.left.and.bubble.right")
                }

                if (bot.dmPolicy ?? "") == "pairing" {
                    PairingApproveSection(client: client, agentId: agentId, type: "feishu")
                }
            }
        }
        .navigationTitle(L10n.t("飞书"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                }
                .disabled(isLoading || loadError != nil || isSaving)
            }
        }
        .task { await load() }
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $editingBot) { bot in
            AIFeishuBotFormSheet(
                bot: bot, isEdit: true,
                existingAccountIDs: bots.compactMap(\.accountId),
                selfOriginalID: bot.accountId) { updated in
                // 按打开弹窗时的行身份匹配（允许修改账户 ID）
                if let idx = bots.firstIndex(where: { $0.id == bot.id }) {
                    bots[idx] = updated
                }
            }
        }
        .sheet(isPresented: $showAddBot) {
            AIFeishuBotFormSheet(
                bot: AIChannelFeishuBotItem(accountId: bots.isEmpty ? "default" : "",
                                            name: "Default", enabled: true,
                                            isDefault: bots.isEmpty, dmPolicy: "pairing"),
                isEdit: false,
                lockAccountID: bots.isEmpty,
                existingAccountIDs: bots.compactMap(\.accountId)) { newBot in
                bots.append(newBot)
            }
        }
        // 行内批准配对（私聊策略=配队码的 Bot）
        .alert(L10n.t("批准配对"), isPresented: Binding(
            get: { pairingBot != nil },
            set: { if !$0 { pairingBot = nil; pairingCode = "" } }
        )) {
            TextField(L10n.t("配对码"), text: $pairingCode)
                .keyboardType(.numberPad)
            Button(L10n.t("批准配对")) {
                if let bot = pairingBot {
                    Task { await approvePairing(bot) }
                }
            }
            .disabled(pairingCode.isEmpty || isApproving)
            Button(L10n.t("取消"), role: .cancel) {
                pairingBot = nil
                pairingCode = ""
            }
        } message: {
            Text(L10n.f("为 Bot「%@」批准配对", pairingBot?.name ?? pairingBot?.accountId ?? ""))
        }
    }

    // MARK: OpenClaw Bot 列表

    private var openclawBotList: some View {
        Section {
            ForEach(bots) { bot in
                Button {
                    editingBot = bot
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(bot.name ?? bot.accountId ?? "-")
                                    .font(.body.bold())
                                    .foregroundStyle(.primary)
                                if bot.isDefault == true {
                                    StatusBadge(text: L10n.t("默认"), color: .blue)
                                }
                                if bot.enabled != true {
                                    StatusBadge(text: L10n.t("未启用"), color: .secondary)
                                }
                            }
                            Text(bot.accountId ?? "-")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if (bot.dmPolicy ?? "") == "pairing" {
                        Button {
                            pairingBot = bot
                        } label: {
                            Label(L10n.t("批准配对"), systemImage: "link")
                        }
                        .tint(.teal)
                    }
                    Button(role: .destructive) {
                        Task { await saveBots(bots.filter { $0.id != bot.id }) }
                    } label: {
                        Label(L10n.t("删除"), systemImage: "trash")
                    }
                }
            }

            Button {
                showAddBot = true
            } label: {
                Label(L10n.t("新增 Bot"), systemImage: "plus.circle")
            }
        } header: {
            SectionLabel(title: L10n.f("Bot 列表 · 共 %d 个", bots.count), systemImage: "person.2")
        } footer: {
            Text(L10n.t("点击 Bot 编辑凭证与策略；批准配对与删除将立即保存"))
        }
    }

    /// OpenClaw：Bot 删除即时全量保存（顶层取已保存快照，不含草稿）
    private func saveBots(_ updated: [AIChannelFeishuBotItem]) async {
        guard !isSaving, !updated.isEmpty else { return }
        let previousBots = bots
        bots = updated
        var out = savedC
        out.agentId = agentId
        out.installed = nil
        out.domain = nil
        out.connectionMode = nil
        out.dmPolicy = nil
        out.bots = updated
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "feishu"),
                body: out,
                as: EmptyResponse.self)
            savedC = out
        } catch {
            guard !APIError.isCancellation(error) else { return }
            bots = previousBots
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// 行内批准配对（带该 Bot 的 accountId）
    private func approvePairing(_ bot: AIChannelFeishuBotItem) async {
        isApproving = true
        defer { isApproving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelPairingApprove.path,
                body: AIAgentChannelPairingApproveRequest(
                    agentId: agentId, type: "feishu",
                    pairingCode: pairingCode, accountId: bot.accountId),
                as: EmptyResponse.self)
            pairingBot = nil
            pairingCode = ""
            errorMessage = L10n.t("已批准配对")
            showError = true
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func load() async {
        do {
            let resp: AIChannelFeishu = try await client.send(
                path: APIEndpoint.aiAgentChannelGet.path.replacingOccurrences(of: ":type", with: "feishu"),
                body: AIAgentChannelRequest(agentId: agentId),
                as: AIChannelFeishu.self)
            var loaded = resp
            // 空值归一（未配置时 replyMode/requireMention 可能为空串，抓包默认 auto/true）
            if (loaded.replyMode ?? "").isEmpty { loaded.replyMode = "auto" }
            if (loaded.requireMention ?? "").isEmpty { loaded.requireMention = "true" }
            c = loaded
            savedC = loaded
            if isOpenClaw {
                bots = loaded.bots ?? []
            } else {
                bot = loaded.bots?.first ?? bot
                extraBots = Array((loaded.bots ?? []).dropFirst())
            }
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        var out = c
        out.agentId = agentId
        // update 体不含 get 回传的 installed / domain / connectionMode（抓包确认）；
        // 顶层无私聊策略（dmPolicy 在各 Bot 内）
        out.installed = nil
        out.domain = nil
        out.connectionMode = nil
        out.dmPolicy = nil
        if isOpenClaw {
            out.bots = bots
        } else {
            out.bots = [bot] + extraBots
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "feishu"),
                body: out,
                as: EmptyResponse.self)
            savedC = out
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

/// OpenClaw 飞书 Bot 新建/编辑表单（名称/账户ID[首个固定 default]/状态/
/// AppID/AppSecret/私聊策略全集/私聊白名单）
private struct AIFeishuBotFormSheet: View {
    @State var bot: AIChannelFeishuBotItem
    let isEdit: Bool
    var lockAccountID: Bool = false
    var existingAccountIDs: [String] = []
    var selfOriginalID: String? = nil
    let onConfirm: (AIChannelFeishuBotItem) -> Void

    @Environment(\.dismiss) private var dismiss

    private var isDuplicateAccount: Bool {
        let id = (bot.accountId ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return false }
        return existingAccountIDs.filter { $0 != selfOriginalID }.contains(id)
    }

    private var canSubmit: Bool {
        !(bot.accountId ?? "").isEmpty && !(bot.appId ?? "").isEmpty
            && !(bot.appSecret ?? "").isEmpty && !isDuplicateAccount
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.t("名称"), text: Binding(
                        get: { bot.name ?? "" }, set: { bot.name = $0 }))
                        .textInputAutocapitalization(.never)
                    TextField(L10n.t("账户 ID"), text: Binding(
                        get: { bot.accountId ?? "" }, set: { bot.accountId = $0 }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(lockAccountID)
                    Toggle(L10n.t("启用"), isOn: Binding(
                        get: { bot.enabled ?? true }, set: { bot.enabled = $0 }))
                    TextField("App ID", text: Binding(
                        get: { bot.appId ?? "" }, set: { bot.appId = $0 }))
                        .textInputAutocapitalization(.never)
                    SecureField("App Secret", text: Binding(
                        get: { bot.appSecret ?? "" }, set: { bot.appSecret = $0 }))
                        .textInputAutocapitalization(.never)
                } header: {
                    SectionLabel(title: isEdit ? L10n.t("编辑 Bot") : L10n.t("新增 Bot"), systemImage: "person.crop.circle")
                } footer: {
                    if isDuplicateAccount {
                        Text(L10n.t("账户 ID 与现有 Bot 重复"))
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    ChannelPolicyPicker(title: L10n.t("私聊策略"), options: AIChannelPolicy.dmPoliciesFull,
                                         value: Binding(get: { bot.dmPolicy ?? "pairing" }, set: { bot.dmPolicy = $0 }))
                    if bot.dmPolicy == "allowlist" {
                        WhitelistEditor(title: L10n.t("私聊白名单"), list: Binding(
                            get: { bot.allowFrom ?? [] },
                            set: { bot.allowFrom = $0.isEmpty ? nil : $0 }))
                    }
                } header: {
                    SectionLabel(title: L10n.t("策略"), systemImage: "slider.horizontal.3")
                }
            }
            .navigationTitle(isEdit ? L10n.t("编辑 Bot") : L10n.t("新增 Bot"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("确定")) {
                        onConfirm(bot)
                        dismiss()
                    }
                    .disabled(!canSubmit)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.large])
    }
}

// MARK: - Telegram（完整策略 + 多 Bot 管理）

struct AIAgentTelegramChannelView: View {
    let server: ServerConfig
    let agentId: Int
    /// 私聊策略选项集随智能体类型不同：OpenClaw 全集（含白名单/禁用），
    /// Hermes/QwenPaw 仅 配队码/开放（抓包确认）
    var agentType: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var c = AIChannelTelegram()
    /// 上次已保存的顶层配置快照：滑动操作的立即保存从快照组装，
    /// 不携带用户未保存的顶层草稿
    @State private var savedC = AIChannelTelegram()
    @State private var bots: [AIChannelTelegramBotItem] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var loadError: String?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var editingBot: AIChannelTelegramBotItem?
    @State private var showAddBot = false

    private let client: APIClient

    init(server: ServerConfig, agentId: Int, agentType: String? = nil) {
        self.server = server
        self.agentId = agentId
        self.agentType = agentType
        self.client = APIClient.shared(for: server)
    }

    /// 私聊策略选项集：OpenClaw 全集，基础类型（Hermes/QwenPaw）仅 配队码/开放
    private var dmPolicies: [(value: String, label: String)] {
        agentType == "openclaw"
            ? AIChannelPolicy.dmPoliciesFull
            : AIChannelPolicy.dmPoliciesFull.filter { $0.value == "pairing" || $0.value == "open" }
    }

    /// 批准配对携带的账户：defaultAccount 空串（基础版 get）回退默认 Bot；
    /// 基础类型抓包 approve 不携带 accountId，仅 OpenClaw 传
    private var pairingAccountID: String? {
        guard agentType == "openclaw" else { return nil }
        if let id = c.defaultAccount, !id.isEmpty { return id }
        return bots.first(where: { $0.isDefault == true })?.accountId
    }

    var body: some View {
        Form {
            if isLoading {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            } else if loadError != nil {
                Section {
                    LoadErrorStateView(message: loadError ?? "") {
                        Task { await load() }
                    }
                }
            } else {
                Section {
                    Toggle(L10n.t("启用"), isOn: Binding(
                        get: { c.enabled ?? false }, set: { c.enabled = $0 }))
                    Toggle(L10n.t("群聊需@机器人"), isOn: Binding(
                        get: { c.requireMention ?? true }, set: { c.requireMention = $0 }))
                    ChannelPolicyPicker(title: L10n.t("私聊策略"), options: dmPolicies,
                                         value: Binding(get: { c.dmPolicy ?? "pairing" }, set: { c.dmPolicy = $0 }))
                    if c.dmPolicy == "allowlist" {
                        WhitelistEditor(title: L10n.t("私聊白名单"), list: Binding(
                            get: { c.allowFrom ?? [] }, set: { c.allowFrom = $0 }))
                    }
                    ChannelPolicyPicker(title: L10n.t("群组策略"), options: AIChannelPolicy.groupPoliciesFull,
                                         value: Binding(get: { c.groupPolicy ?? "open" }, set: { c.groupPolicy = $0 }))
                    if c.groupPolicy == "allowlist" {
                        WhitelistEditor(title: L10n.t("群组白名单"), list: Binding(
                            get: { c.groupAllowFrom ?? [] }, set: { c.groupAllowFrom = $0 }))
                    }
                    TextField(L10n.t("代理服务器"), text: Binding(
                        get: { c.proxy ?? "" }, set: { c.proxy = $0 }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Picker(L10n.t("流式传输"), selection: Binding(
                        get: { let v = c.streaming ?? ""; return v.isEmpty ? "partial" : v },
                        set: { c.streaming = $0 })) {
                        ForEach(AIChannelStreaming.options, id: \.value) { o in
                            Text(o.label).tag(o.value)
                        }
                    }
                }

                botListSection

                if c.dmPolicy == "pairing" {
                    PairingApproveSection(client: client, agentId: agentId, type: "telegram",
                                          accountId: pairingAccountID)
                }
            }
        }
        .navigationTitle("Telegram")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                }
                .disabled(isLoading || loadError != nil || isSaving)
            }
        }
        .task { await load() }
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $editingBot) { bot in
            AITelegramBotFormSheet(
                bot: bot, isEdit: true, dmOptions: dmPolicies,
                existingAccountIDs: bots.compactMap(\.accountId),
                selfOriginalID: bot.accountId) { updated in
                // 按打开弹窗时的行身份匹配（sheet 闭包捕获的 bot 快照）：
                // 允许修改账户 ID——updated.id 已是新值，按它找必然失配、编辑被静默丢弃
                if let idx = bots.firstIndex(where: { $0.id == bot.id }) {
                    bots[idx] = updated
                }
            }
        }
        .sheet(isPresented: $showAddBot) {
            AITelegramBotFormSheet(
                bot: AIChannelTelegramBotItem(enabled: true, isDefault: false, dmPolicy: "open", groupPolicy: "open", streaming: c.streaming ?? "partial"),
                isEdit: false,
                dmOptions: dmPolicies,
                existingAccountIDs: bots.compactMap(\.accountId)) { newBot in
                bots.append(newBot)
            }
        }
    }

    private var botListSection: some View {
        Section {
            ForEach(bots) { bot in
                Button {
                    editingBot = bot
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(bot.name ?? bot.accountId ?? "-")
                                    .font(.body.bold())
                                    .foregroundStyle(.primary)
                                if bot.isDefault == true {
                                    StatusBadge(text: L10n.t("默认"), color: .blue)
                                }
                                if bot.enabled != true {
                                    StatusBadge(text: L10n.t("未启用"), color: .secondary)
                                }
                            }
                            Text(bot.accountId ?? "-")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        Task { await removeBot(bot) }
                    } label: {
                        Label(L10n.t("删除"), systemImage: "trash")
                    }
                    if bot.isDefault != true {
                        Button {
                            Task { await setDefaultBot(bot) }
                        } label: {
                            Label(L10n.t("设为默认"), systemImage: "star")
                        }
                        .tint(.blue)
                    }
                }
            }

            Button {
                showAddBot = true
            } label: {
                Label(L10n.t("新增 Bot"), systemImage: "plus.circle")
            }
        } header: {
            SectionLabel(title: L10n.f("Bot 列表 · 共 %d 个", bots.count), systemImage: "person.2")
        } footer: {
            Text(L10n.t("点击 Bot 编辑凭证与策略；删除与设为默认将立即保存"))
        }
    }

    /// 变更 bots 后整体保存（删除/设为默认共用，抓包均为全量 update）。
    /// 顶层字段取「上次已保存快照」组装——滑动操作的立即保存不得把
    /// 用户改到一半的顶层草稿（代理/开关等）提前持久化；
    /// 成功后回写本地 defaultAccount 与快照，失败回滚
    private func saveBots(_ updated: [AIChannelTelegramBotItem], defaultAccount: String? = nil) async {
        guard !isSaving else { return }
        let previousBots = bots
        let previousDefault = c.defaultAccount
        bots = updated
        if let defaultAccount {
            c.defaultAccount = defaultAccount
        }
        var out = savedC
        out.agentId = agentId
        out.bots = updated
        if let defaultAccount {
            out.defaultAccount = defaultAccount
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "telegram"),
                body: out,
                as: EmptyResponse.self)
            savedC = out
        } catch {
            guard !APIError.isCancellation(error) else { return }
            // 回滚本地状态，避免与服务端分叉
            bots = previousBots
            c.defaultAccount = previousDefault
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func removeBot(_ bot: AIChannelTelegramBotItem) async {
        // 至少保留一个 Bot：删空会让 defaultAccount 悬空（网页端不允许删到最后一个）
        guard bots.count > 1 else {
            errorMessage = L10n.t("至少保留一个 Bot")
            showError = true
            return
        }
        var remaining = bots.filter { $0.id != bot.id }
        // 删除默认 Bot 时把默认让给第一个
        if bot.isDefault == true, !remaining.isEmpty {
            remaining[0].isDefault = true
            await saveBots(remaining, defaultAccount: remaining[0].accountId)
        } else {
            await saveBots(remaining)
        }
    }

    private func setDefaultBot(_ bot: AIChannelTelegramBotItem) async {
        let updated = bots.map { item in
            var copy = item
            copy.isDefault = (item.id == bot.id)
            return copy
        }
        await saveBots(updated, defaultAccount: bot.accountId)
    }

    private func load() async {
        do {
            let resp: AIChannelTelegram = try await client.send(
                path: APIEndpoint.aiAgentChannelGet.path.replacingOccurrences(of: ":type", with: "telegram"),
                body: AIAgentChannelRequest(agentId: agentId),
                as: AIChannelTelegram.self)
            c = resp
            savedC = resp
            bots = resp.bots ?? []
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        var out = c
        out.agentId = agentId
        out.bots = bots
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "telegram"),
                body: out,
                as: EmptyResponse.self)
            savedC = out
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

/// Telegram Bot 新建/编辑表单（名称/账户ID/状态/Token/策略/流式）；
/// 私聊策略选项集随智能体类型由调用方传入，账户 ID 在现有 Bot 内查重
private struct AITelegramBotFormSheet: View {
    @State var bot: AIChannelTelegramBotItem
    let isEdit: Bool
    let dmOptions: [(value: String, label: String)]
    /// 现有 Bot 的账户 ID（查重用）
    var existingAccountIDs: [String] = []
    /// 编辑时的自身原账户 ID（查重排除）
    var selfOriginalID: String? = nil
    let onConfirm: (AIChannelTelegramBotItem) -> Void

    @Environment(\.dismiss) private var dismiss

    private var isDuplicateAccount: Bool {
        let id = (bot.accountId ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return false }
        return existingAccountIDs.filter { $0 != selfOriginalID }.contains(id)
    }

    private var canSubmit: Bool {
        !(bot.name ?? "").isEmpty && !(bot.accountId ?? "").isEmpty && !(bot.botToken ?? "").isEmpty
            && !isDuplicateAccount
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.t("名称"), text: Binding(
                        get: { bot.name ?? "" }, set: { bot.name = $0 }))
                        .textInputAutocapitalization(.never)
                    TextField(L10n.t("账户 ID"), text: Binding(
                        get: { bot.accountId ?? "" }, set: { bot.accountId = $0 }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle(L10n.t("启用"), isOn: Binding(
                        get: { bot.enabled ?? true }, set: { bot.enabled = $0 }))
                    SecureField(L10n.t("Bot Token"), text: Binding(
                        get: { bot.botToken ?? "" }, set: { bot.botToken = $0 }))
                        .textInputAutocapitalization(.never)
                } header: {
                    SectionLabel(title: isEdit ? L10n.t("编辑 Bot") : L10n.t("新增 Bot"), systemImage: "person.crop.circle")
                } footer: {
                    if isDuplicateAccount {
                        Text(L10n.t("账户 ID 与现有 Bot 重复"))
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    ChannelPolicyPicker(title: L10n.t("私聊策略"), options: dmOptions,
                                         value: Binding(get: { bot.dmPolicy ?? "open" }, set: { bot.dmPolicy = $0 }))
                    ChannelPolicyPicker(title: L10n.t("群组策略"), options: AIChannelPolicy.groupPoliciesFull,
                                         value: Binding(get: { bot.groupPolicy ?? "open" }, set: { bot.groupPolicy = $0 }))
                    Picker(L10n.t("流式传输"), selection: Binding(
                        get: { let v = bot.streaming ?? ""; return v.isEmpty ? "partial" : v },
                        set: { bot.streaming = $0 })) {
                        ForEach(AIChannelStreaming.options, id: \.value) { o in
                            Text(o.label).tag(o.value)
                        }
                    }
                } header: {
                    SectionLabel(title: L10n.t("策略"), systemImage: "slider.horizontal.3")
                }
            }
            .navigationTitle(isEdit ? L10n.t("编辑 Bot") : L10n.t("新增 Bot"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("确定")) {
                        onConfirm(bot)
                        dismiss()
                    }
                    .disabled(!canSubmit)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.large])
    }
}

// MARK: - Discord（多 Bot 管理，logs/修正3 抓包确认）

struct AIAgentDiscordChannelView: View {
    let server: ServerConfig
    let agentId: Int

    @Environment(\.dismiss) private var dismiss
    @State private var c = AIChannelDiscord()
    /// 上次已保存的顶层配置快照（滑动操作立即保存的组装基准，不含未保存草稿）
    @State private var savedC = AIChannelDiscord()
    @State private var bots: [AIChannelDiscordBotItem] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var loadError: String?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var editingBot: AIChannelDiscordBotItem?
    @State private var showAddBot = false

    private let client: APIClient

    /// 私聊策略仅 配队码 / 开放；群组策略 开放 / 禁用（抓包确认，无白名单）
    private var dmPolicies: [(value: String, label: String)] {
        AIChannelPolicy.dmPoliciesFull.filter { $0.value == "pairing" || $0.value == "open" }
    }

    /// 批准配对携带的账户：defaultAccount 空串回退默认 Bot
    /// （QwenPaw / OpenClaw 的 Discord approve 抓包均携带 accountId）
    private var pairingAccountID: String? {
        if let id = c.defaultAccount, !id.isEmpty { return id }
        return bots.first(where: { $0.isDefault == true })?.accountId
    }

    init(server: ServerConfig, agentId: Int) {
        self.server = server
        self.agentId = agentId
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        Form {
            if isLoading {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            } else if loadError != nil {
                Section {
                    LoadErrorStateView(message: loadError ?? "") {
                        Task { await load() }
                    }
                }
            } else {
                Section {
                    Toggle(L10n.t("启用"), isOn: Binding(
                        get: { c.enabled ?? false }, set: { c.enabled = $0 }))
                    Toggle(L10n.t("群聊需@机器人"), isOn: Binding(
                        get: { c.requireMention ?? true }, set: { c.requireMention = $0 }))
                    ChannelPolicyPicker(title: L10n.t("私聊策略"), options: dmPolicies,
                                         value: Binding(get: { c.dmPolicy ?? "pairing" }, set: { c.dmPolicy = $0 }))
                    ChannelPolicyPicker(title: L10n.t("群组策略"), options: AIChannelPolicy.groupPoliciesBasic,
                                         value: Binding(get: { c.groupPolicy ?? "open" }, set: { c.groupPolicy = $0 }))
                    TextField(L10n.t("代理服务器"), text: Binding(
                        get: { c.proxy ?? "" }, set: { c.proxy = $0 }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                botListSection

                if c.dmPolicy == "pairing" {
                    PairingApproveSection(client: client, agentId: agentId, type: "discord",
                                          accountId: pairingAccountID)
                }
            }
        }
        .navigationTitle("Discord")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                }
                .disabled(isLoading || loadError != nil || isSaving)
            }
        }
        .task { await load() }
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $editingBot) { bot in
            AIDiscordBotFormSheet(
                bot: bot, isEdit: true,
                existingAccountIDs: bots.compactMap(\.accountId),
                selfOriginalID: bot.accountId) { updated in
                // 按打开弹窗时的行身份匹配（sheet 闭包捕获的 bot 快照），允许修改账户 ID
                if let idx = bots.firstIndex(where: { $0.id == bot.id }) {
                    bots[idx] = updated
                }
            }
        }
        .sheet(isPresented: $showAddBot) {
            AIDiscordBotFormSheet(
                bot: AIChannelDiscordBotItem(enabled: true, isDefault: false),
                isEdit: false,
                existingAccountIDs: bots.compactMap(\.accountId)) { newBot in
                bots.append(newBot)
            }
        }
    }

    private var botListSection: some View {
        Section {
            ForEach(bots) { bot in
                Button {
                    editingBot = bot
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(bot.name ?? bot.accountId ?? "-")
                                    .font(.body.bold())
                                    .foregroundStyle(.primary)
                                if bot.isDefault == true {
                                    StatusBadge(text: L10n.t("默认"), color: .blue)
                                }
                                if bot.enabled != true {
                                    StatusBadge(text: L10n.t("未启用"), color: .secondary)
                                }
                            }
                            Text(bot.accountId ?? "-")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        Task { await removeBot(bot) }
                    } label: {
                        Label(L10n.t("删除"), systemImage: "trash")
                    }
                    if bot.isDefault != true {
                        Button {
                            Task { await setDefaultBot(bot) }
                        } label: {
                            Label(L10n.t("设为默认"), systemImage: "star")
                        }
                        .tint(.blue)
                    }
                }
            }

            Button {
                showAddBot = true
            } label: {
                Label(L10n.t("新增 Bot"), systemImage: "plus.circle")
            }
        } header: {
            SectionLabel(title: L10n.f("Bot 列表 · 共 %d 个", bots.count), systemImage: "person.2")
        } footer: {
            Text(L10n.t("点击 Bot 编辑凭证与状态；删除与设为默认将立即保存"))
        }
    }

    /// 变更 bots 后整体保存（与 Telegram 同款：从已保存快照组装、
    /// 成功回写 defaultAccount 与快照，失败回滚）
    private func saveBots(_ updated: [AIChannelDiscordBotItem], defaultAccount: String? = nil) async {
        guard !isSaving else { return }
        let previousBots = bots
        let previousDefault = c.defaultAccount
        bots = updated
        if let defaultAccount {
            c.defaultAccount = defaultAccount
        }
        var out = savedC
        out.agentId = agentId
        out.bots = updated
        if let defaultAccount {
            out.defaultAccount = defaultAccount
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "discord"),
                body: out,
                as: EmptyResponse.self)
            savedC = out
        } catch {
            guard !APIError.isCancellation(error) else { return }
            bots = previousBots
            c.defaultAccount = previousDefault
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func removeBot(_ bot: AIChannelDiscordBotItem) async {
        // 至少保留一个 Bot：删空会让 defaultAccount 悬空
        guard bots.count > 1 else {
            errorMessage = L10n.t("至少保留一个 Bot")
            showError = true
            return
        }
        var remaining = bots.filter { $0.id != bot.id }
        if bot.isDefault == true, !remaining.isEmpty {
            remaining[0].isDefault = true
            await saveBots(remaining, defaultAccount: remaining[0].accountId)
        } else {
            await saveBots(remaining)
        }
    }

    private func setDefaultBot(_ bot: AIChannelDiscordBotItem) async {
        let updated = bots.map { item in
            var copy = item
            copy.isDefault = (item.id == bot.id)
            return copy
        }
        await saveBots(updated, defaultAccount: bot.accountId)
    }

    private func load() async {
        do {
            let resp: AIChannelDiscord = try await client.send(
                path: APIEndpoint.aiAgentChannelGet.path.replacingOccurrences(of: ":type", with: "discord"),
                body: AIAgentChannelRequest(agentId: agentId),
                as: AIChannelDiscord.self)
            c = resp
            savedC = resp
            bots = resp.bots ?? []
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        var out = c
        out.agentId = agentId
        out.bots = bots
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "discord"),
                body: out,
                as: EmptyResponse.self)
            savedC = out
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

/// Discord Bot 新建/编辑表单（名称/账户ID/状态/Token，抓包确认无策略项；账户 ID 查重）
private struct AIDiscordBotFormSheet: View {
    @State var bot: AIChannelDiscordBotItem
    let isEdit: Bool
    /// 现有 Bot 的账户 ID（查重用）
    var existingAccountIDs: [String] = []
    /// 编辑时的自身原账户 ID（查重排除）
    var selfOriginalID: String? = nil
    let onConfirm: (AIChannelDiscordBotItem) -> Void

    @Environment(\.dismiss) private var dismiss

    private var isDuplicateAccount: Bool {
        let id = (bot.accountId ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return false }
        return existingAccountIDs.filter { $0 != selfOriginalID }.contains(id)
    }

    private var canSubmit: Bool {
        !(bot.name ?? "").isEmpty && !(bot.accountId ?? "").isEmpty && !(bot.token ?? "").isEmpty
            && !isDuplicateAccount
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.t("名称"), text: Binding(
                        get: { bot.name ?? "" }, set: { bot.name = $0 }))
                        .textInputAutocapitalization(.never)
                    TextField(L10n.t("账户 ID"), text: Binding(
                        get: { bot.accountId ?? "" }, set: { bot.accountId = $0 }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle(L10n.t("启用"), isOn: Binding(
                        get: { bot.enabled ?? true }, set: { bot.enabled = $0 }))
                    SecureField("Token", text: Binding(
                        get: { bot.token ?? "" }, set: { bot.token = $0 }))
                        .textInputAutocapitalization(.never)
                } header: {
                    SectionLabel(title: isEdit ? L10n.t("编辑 Bot") : L10n.t("新增 Bot"), systemImage: "person.crop.circle")
                } footer: {
                    if isDuplicateAccount {
                        Text(L10n.t("账户 ID 与现有 Bot 重复"))
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isEdit ? L10n.t("编辑 Bot") : L10n.t("新增 Bot"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("确定")) {
                        onConfirm(bot)
                        dismiss()
                    }
                    .disabled(!canSubmit)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.medium])
    }
}
