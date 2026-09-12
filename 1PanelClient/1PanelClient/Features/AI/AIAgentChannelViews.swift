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

    @State private var enabledMap: [String: Bool] = [:]
    @State private var isLoading = true

    private let client: APIClient

    init(server: ServerConfig, agentId: Int, agentName: String) {
        self.server = server
        self.agentId = agentId
        self.agentName = agentName
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
            AIAgentWeixinChannelView(server: server, agentId: agentId, initialEnabled: enabledMap[kind.rawValue] ?? false)
        case .qqbot:
            AIAgentQQChannelView(server: server, agentId: agentId)
        case .wecom:
            AIAgentWecomChannelView(server: server, agentId: agentId)
        case .dingtalk:
            AIAgentDingtalkChannelView(server: server, agentId: agentId)
        case .feishu:
            AIAgentFeishuChannelView(server: server, agentId: agentId)
        case .telegram:
            AIAgentTelegramChannelView(server: server, agentId: agentId)
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

    /// 并行读取 7 个频道 enabled 状态（单条失败不影响其他）
    private func loadAllStatus() async {
        await withTaskGroup(of: (String, Bool?).self) { group in
            for kind in AIChannelKind.allCases {
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
                if let enabled {
                    enabledMap[key] = enabled
                }
            }
        }
        isLoading = false
    }
}

// MARK: - 通用小组件

/// 策略 Picker（选项集按频道传入：pairing / open / allowlist / disabled）
private struct ChannelPolicyPicker: View {
    let title: String
    let options: [(value: String, label: String)]
    @Binding var value: String

    var body: some View {
        Picker(title, selection: $value) {
            ForEach(options, id: \.value) { p in
                Text(p.label).tag(p.value)
            }
        }
    }
}

/// 白名单编辑（策略=白名单时显示，一行一个）
private struct WhitelistEditor: View {
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

// MARK: - 微信（扫码对接 + 任务日志二维码）

struct AIAgentWeixinChannelView: View {
    let server: ServerConfig
    let agentId: Int
    let initialEnabled: Bool

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

    init(server: ServerConfig, agentId: Int, initialEnabled: Bool) {
        self.server = server
        self.agentId = agentId
        self.initialEnabled = initialEnabled
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        List {
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

    /// 发起扫码对接：login 成功后轮询任务日志，从行中提取二维码 URL
    private func startLogin() async {
        isLoggingIn = true
        defer { isLoggingIn = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentWeixinLogin.path,
                body: AIAgentChannelRequest(agentId: agentId),
                as: EmptyResponse.self)
            startPolling()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// 轮询任务日志（weixin 任务按 AI 类型 + 智能体资源过滤 [推测：抓包 post 体缺失]），
    /// 提取 liteapp 二维码链接渲染；视图退出即停止
    private func startPolling() {
        isPolling = true
        Task {
            while isPolling && !Task.isCancelled {
                do {
                    let resp: TaskLogResponse = try await client.send(
                        path: APIEndpoint.logsTaskRead.path,
                        body: TaskLogReadRequest(
                            id: 0, type: "task", name: "weixin",
                            page: 1, pageSize: 500, latest: true,
                            taskID: "", taskType: "AI", taskOperate: "weixin",
                            resourceID: agentId),
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

    @Environment(\.dismiss) private var dismiss
    @State private var c = AIChannelQQBot()
    /// 凭证与私聊白名单在 bots[0]（抓包确认）；其余 bots 原样保留
    @State private var bot = AIChannelQQBotItem(accountId: "default", name: "Default", enabled: true, isDefault: true)
    @State private var extraBots: [AIChannelQQBotItem] = []
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
    }

    private func load() async {
        do {
            let resp: AIChannelQQBot = try await client.send(
                path: APIEndpoint.aiAgentChannelGet.path.replacingOccurrences(of: ":type", with: "qqbot"),
                body: AIAgentChannelRequest(agentId: agentId),
                as: AIChannelQQBot.self)
            c = resp
            bot = resp.bots?.first ?? bot
            extraBots = Array((resp.bots ?? []).dropFirst())
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
        var bot = bot
        bot.enabled = c.enabled ?? true
        out.bots = [bot] + extraBots
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "qqbot"),
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

// MARK: - 企业微信

struct AIAgentWecomChannelView: View {
    let server: ServerConfig
    let agentId: Int

    @Environment(\.dismiss) private var dismiss
    @State private var c = AIChannelWecom()
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
                    TextField(L10n.t("Bot ID"), text: Binding(
                        get: { c.botId ?? "" }, set: { c.botId = $0 }))
                        .textInputAutocapitalization(.never)
                    SecureField(L10n.t("密钥"), text: Binding(
                        get: { c.secret ?? "" }, set: { c.secret = $0 }))
                    ChannelPolicyPicker(title: L10n.t("私聊策略"), options: AIChannelPolicy.dmPoliciesBasic,
                                         value: Binding(get: { c.dmPolicy ?? "pairing" }, set: { c.dmPolicy = $0 }))
                    ChannelPolicyPicker(title: L10n.t("群组策略"), options: AIChannelPolicy.groupPoliciesBasic,
                                         value: Binding(get: { c.groupPolicy ?? "open" }, set: { c.groupPolicy = $0 }))
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
            c = resp
            bot = resp.bots?.first ?? bot
            extraBots = Array((resp.bots ?? []).dropFirst())
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
        var bot = bot
        bot.enabled = c.enabled ?? true
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

// MARK: - 飞书

struct AIAgentFeishuChannelView: View {
    let server: ServerConfig
    let agentId: Int

    @Environment(\.dismiss) private var dismiss
    @State private var c = AIChannelFeishu()
    /// 飞书的私聊策略与凭证在 bots[0]（顶层无 dmPolicy，抓包确认）
    @State private var bot = AIChannelFeishuBotItem(accountId: "default", name: "Default", enabled: true, isDefault: true)
    @State private var extraBots: [AIChannelFeishuBotItem] = []
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
                    TextField("App ID", text: Binding(
                        get: { bot.appId ?? "" }, set: { bot.appId = $0 }))
                        .textInputAutocapitalization(.never)
                    SecureField("App Secret", text: Binding(
                        get: { bot.appSecret ?? "" }, set: { bot.appSecret = $0 }))
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
    }

    private func load() async {
        do {
            let resp: AIChannelFeishu = try await client.send(
                path: APIEndpoint.aiAgentChannelGet.path.replacingOccurrences(of: ":type", with: "feishu"),
                body: AIAgentChannelRequest(agentId: agentId),
                as: AIChannelFeishu.self)
            c = resp
            bot = resp.bots?.first ?? bot
            extraBots = Array((resp.bots ?? []).dropFirst())
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
        var bot = bot
        bot.enabled = c.enabled ?? true
        out.bots = [bot] + extraBots
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "feishu"),
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

// MARK: - Telegram（完整策略 + 多 Bot 管理）

struct AIAgentTelegramChannelView: View {
    let server: ServerConfig
    let agentId: Int

    @Environment(\.dismiss) private var dismiss
    @State private var c = AIChannelTelegram()
    @State private var bots: [AIChannelTelegramBotItem] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var loadError: String?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var editingBot: AIChannelTelegramBotItem?
    @State private var showAddBot = false

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
                    Toggle(L10n.t("群聊需@机器人"), isOn: Binding(
                        get: { c.requireMention ?? true }, set: { c.requireMention = $0 }))
                    ChannelPolicyPicker(title: L10n.t("私聊策略"), options: AIChannelPolicy.dmPoliciesFull,
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
                        get: { c.streaming ?? "partial" }, set: { c.streaming = $0 })) {
                        ForEach(AIChannelStreaming.options, id: \.value) { o in
                            Text(o.label).tag(o.value)
                        }
                    }
                }

                botListSection

                if c.dmPolicy == "pairing" {
                    PairingApproveSection(client: client, agentId: agentId, type: "telegram",
                                          accountId: c.defaultAccount)
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
            AITelegramBotFormSheet(bot: bot, isEdit: true) { updated in
                if let idx = bots.firstIndex(where: { $0.id == updated.id }) {
                    bots[idx] = updated
                }
            }
        }
        .sheet(isPresented: $showAddBot) {
            AITelegramBotFormSheet(
                bot: AIChannelTelegramBotItem(enabled: true, isDefault: false, dmPolicy: "open", groupPolicy: "open", streaming: c.streaming ?? "partial"),
                isEdit: false) { newBot in
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

    /// 变更 bots 后整体保存（删除/设为默认共用，抓包均为全量 update）
    private func saveBots(_ updated: [AIChannelTelegramBotItem], defaultAccount: String? = nil) async {
        bots = updated
        var out = c
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
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func removeBot(_ bot: AIChannelTelegramBotItem) async {
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
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

/// Telegram Bot 新建/编辑表单（名称/账户ID/状态/Token/策略/流式）
private struct AITelegramBotFormSheet: View {
    @State var bot: AIChannelTelegramBotItem
    let isEdit: Bool
    let onConfirm: (AIChannelTelegramBotItem) -> Void

    @Environment(\.dismiss) private var dismiss

    private var canSubmit: Bool {
        !(bot.name ?? "").isEmpty && !(bot.accountId ?? "").isEmpty && !(bot.botToken ?? "").isEmpty
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
                }

                Section {
                    ChannelPolicyPicker(title: L10n.t("私聊策略"), options: AIChannelPolicy.dmPoliciesFull,
                                         value: Binding(get: { bot.dmPolicy ?? "open" }, set: { bot.dmPolicy = $0 }))
                    ChannelPolicyPicker(title: L10n.t("群组策略"), options: AIChannelPolicy.groupPoliciesFull,
                                         value: Binding(get: { bot.groupPolicy ?? "open" }, set: { bot.groupPolicy = $0 }))
                    Picker(L10n.t("流式传输"), selection: Binding(
                        get: { bot.streaming ?? "partial" }, set: { bot.streaming = $0 })) {
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

// MARK: - Discord

struct AIAgentDiscordChannelView: View {
    let server: ServerConfig
    let agentId: Int

    @Environment(\.dismiss) private var dismiss
    @State private var c = AIChannelDiscord()
    @State private var bot = AIChannelDiscordBotItem(accountId: "default", name: "Default", enabled: true, isDefault: true)
    @State private var extraBots: [AIChannelDiscordBotItem] = []
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
                    SecureField("Token", text: Binding(
                        get: { bot.token ?? "" }, set: { bot.token = $0 }))
                        .textInputAutocapitalization(.never)
                    Toggle(L10n.t("群聊需@机器人"), isOn: Binding(
                        get: { c.requireMention ?? true }, set: { c.requireMention = $0 }))
                    ChannelPolicyPicker(title: L10n.t("私聊策略"),
                                         options: AIChannelPolicy.dmPoliciesFull.filter { $0.value != "allowlist" },
                                         value: Binding(get: { c.dmPolicy ?? "pairing" }, set: { c.dmPolicy = $0 }))
                    ChannelPolicyPicker(title: L10n.t("群组策略"), options: AIChannelPolicy.groupPoliciesFull,
                                         value: Binding(get: { c.groupPolicy ?? "open" }, set: { c.groupPolicy = $0 }))
                }

                if c.dmPolicy == "pairing" {
                    PairingApproveSection(client: client, agentId: agentId, type: "discord")
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
    }

    private func load() async {
        do {
            let resp: AIChannelDiscord = try await client.send(
                path: APIEndpoint.aiAgentChannelGet.path.replacingOccurrences(of: ":type", with: "discord"),
                body: AIAgentChannelRequest(agentId: agentId),
                as: AIChannelDiscord.self)
            c = resp
            bot = resp.bots?.first ?? bot
            extraBots = Array((resp.bots ?? []).dropFirst())
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
        var bot = bot
        bot.enabled = c.enabled ?? true
        out.bots = [bot] + extraBots
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "discord"),
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
