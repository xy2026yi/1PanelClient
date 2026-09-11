//
//  AIAgentChannelViews.swift
//  1PanelClient
//
//  智能体 · 消息频道（/api/v2/ai/agents/channel/*）：
//  频道列表（并行读取 enabled）/ 各频道配置表单 / 微信扫码对接（任务日志提取二维码）
//  保存端点 /channel/:type/update 为推测（抓包缺失），策略取值见 AIChannelPolicy
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

/// 私聊策略 Picker（配队码 / 开放 / 禁用）
private struct DmPolicyPicker: View {
    @Binding var value: String

    var body: some View {
        Picker(L10n.t("私聊策略"), selection: $value) {
            ForEach(AIChannelPolicy.dmPolicies, id: \.value) { p in
                Text(p.label).tag(p.value)
            }
        }
    }
}

/// 群组策略 Picker（开放 / 禁用）
private struct GroupPolicyPicker: View {
    @Binding var value: String

    var body: some View {
        Picker(L10n.t("群组策略"), selection: $value) {
            ForEach(AIChannelPolicy.groupPolicies, id: \.value) { p in
                Text(p.label).tag(p.value)
            }
        }
    }
}

/// 配对码输入（私聊策略=配队码时显示）
private struct PairCodeRow: View {
    @Binding var allowFrom: [String]

    var body: some View {
        HStack {
            Text(L10n.t("配队码")).foregroundStyle(.secondary)
            Spacer()
            TextField(L10n.t("输入配队码"), text: Binding(
                get: { allowFrom.first ?? "" },
                set: { allowFrom = $0.isEmpty ? [] : [$0] }
            ))
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 180)
        }
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
    @State private var config: AIChannelQQBot?
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
            } else if var c = config {
                Section {
                    Toggle(L10n.t("启用"), isOn: Binding(
                        get: { c.enabled ?? false },
                        set: { c.enabled = $0; config = c }
                    ))
                    TextField("App ID", text: Binding(
                        get: { c.appId ?? "" }, set: { c.appId = $0; config = c }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    SecureField("App Secret", text: Binding(
                        get: { c.appSecret ?? "" }, set: { c.appSecret = $0; config = c }))
                    .textInputAutocapitalization(.never)
                    DmPolicyPicker(value: Binding(
                        get: { c.dmPolicy ?? "" }, set: { c.dmPolicy = $0; config = c }))
                    if c.dmPolicy == "paircode" {
                        PairCodeRow(allowFrom: Binding(
                            get: { c.allowFrom ?? [] }, set: { c.allowFrom = $0; config = c }))
                    }
                    GroupPolicyPicker(value: Binding(
                        get: { c.groupPolicy ?? "" }, set: { c.groupPolicy = $0; config = c }))
                } footer: {
                    Text(L10n.t("保存后智能体即可在 QQ 平台对话"))
                }
            } else {
                Section {
                    LoadErrorStateView(message: loadError ?? "") {
                        Task { await load() }
                    }
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
                .disabled(config == nil || isSaving)
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
            config = try await client.send(
                path: APIEndpoint.aiAgentChannelGet.path.replacingOccurrences(of: ":type", with: "qqbot"),
                body: AIAgentChannelRequest(agentId: agentId),
                as: AIChannelQQBot.self)
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        guard var c = config else { return }
        c.agentId = agentId
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "qqbot"),
                body: c,
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
    @State private var config: AIChannelWecom?
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
            } else if var c = config {
                Section {
                    Toggle(L10n.t("启用"), isOn: Binding(
                        get: { c.enabled ?? false }, set: { c.enabled = $0; config = c }))
                    TextField(L10n.t("Bot ID"), text: Binding(
                        get: { c.botId ?? "" }, set: { c.botId = $0; config = c }))
                    .textInputAutocapitalization(.never)
                    SecureField(L10n.t("密钥"), text: Binding(
                        get: { c.secret ?? "" }, set: { c.secret = $0; config = c }))
                    DmPolicyPicker(value: Binding(
                        get: { c.dmPolicy ?? "" }, set: { c.dmPolicy = $0; config = c }))
                    if c.dmPolicy == "paircode" {
                        PairCodeRow(allowFrom: Binding(
                            get: { c.allowFrom ?? [] }, set: { c.allowFrom = $0; config = c }))
                    }
                    GroupPolicyPicker(value: Binding(
                        get: { c.groupPolicy ?? "" }, set: { c.groupPolicy = $0; config = c }))
                }
            } else {
                Section {
                    LoadErrorStateView(message: loadError ?? "") {
                        Task { await load() }
                    }
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
                .disabled(config == nil || isSaving)
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
            config = try await client.send(
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
        guard var c = config else { return }
        c.agentId = agentId
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "wecom"),
                body: c,
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
    @State private var config: AIChannelDingtalk?
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
            } else if var c = config {
                Section {
                    Toggle(L10n.t("启用"), isOn: Binding(
                        get: { c.enabled ?? false }, set: { c.enabled = $0; config = c }))
                    TextField("Client ID", text: Binding(
                        get: { c.clientId ?? "" }, set: { c.clientId = $0; config = c }))
                    .textInputAutocapitalization(.never)
                    SecureField("Client Secret", text: Binding(
                        get: { c.clientSecret ?? "" }, set: { c.clientSecret = $0; config = c }))
                    DmPolicyPicker(value: Binding(
                        get: { c.dmPolicy ?? "" }, set: { c.dmPolicy = $0; config = c }))
                    if c.dmPolicy == "paircode" {
                        PairCodeRow(allowFrom: Binding(
                            get: { c.allowFrom ?? [] }, set: { c.allowFrom = $0; config = c }))
                    }
                    GroupPolicyPicker(value: Binding(
                        get: { c.groupPolicy ?? "" }, set: { c.groupPolicy = $0; config = c }))
                }
            } else {
                Section {
                    LoadErrorStateView(message: loadError ?? "") {
                        Task { await load() }
                    }
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
                .disabled(config == nil || isSaving)
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
            config = try await client.send(
                path: APIEndpoint.aiAgentChannelGet.path.replacingOccurrences(of: ":type", with: "dingtalk"),
                body: AIAgentChannelRequest(agentId: agentId),
                as: AIChannelDingtalk.self)
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        guard var c = config else { return }
        c.agentId = agentId
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "dingtalk"),
                body: c,
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
    @State private var config: AIChannelFeishu?
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
            } else if var c = config {
                Section {
                    Toggle(L10n.t("启用"), isOn: Binding(
                        get: { c.enabled ?? false }, set: { c.enabled = $0; config = c }))
                    TextField("App ID", text: Binding(
                        get: { c.appId ?? "" }, set: { c.appId = $0; config = c }))
                    .textInputAutocapitalization(.never)
                    SecureField("App Secret", text: Binding(
                        get: { c.appSecret ?? "" }, set: { c.appSecret = $0; config = c }))
                    DmPolicyPicker(value: Binding(
                        get: { c.dmPolicy ?? AIChannelPolicy.dmPolicies[0].value },
                        set: { c.dmPolicy = $0; config = c }))
                    GroupPolicyPicker(value: Binding(
                        get: { c.groupPolicy ?? "" }, set: { c.groupPolicy = $0; config = c }))
                } footer: {
                    Text(L10n.t("飞书私聊策略支持配队码与开放"))
                }
            } else {
                Section {
                    LoadErrorStateView(message: loadError ?? "") {
                        Task { await load() }
                    }
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
                .disabled(config == nil || isSaving)
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
            config = try await client.send(
                path: APIEndpoint.aiAgentChannelGet.path.replacingOccurrences(of: ":type", with: "feishu"),
                body: AIAgentChannelRequest(agentId: agentId),
                as: AIChannelFeishu.self)
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        guard var c = config else { return }
        c.agentId = agentId
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "feishu"),
                body: c,
                as: EmptyResponse.self)
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Telegram

struct AIAgentTelegramChannelView: View {
    let server: ServerConfig
    let agentId: Int

    @Environment(\.dismiss) private var dismiss
    @State private var config: AIChannelTelegram?
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
            } else if var c = config {
                Section {
                    Toggle(L10n.t("启用"), isOn: Binding(
                        get: { c.enabled ?? false }, set: { c.enabled = $0; config = c }))
                    SecureField(L10n.t("Bot Token"), text: Binding(
                        get: { c.botToken ?? "" }, set: { c.botToken = $0; config = c }))
                    .textInputAutocapitalization(.never)
                    DmPolicyPicker(value: Binding(
                        get: { c.dmPolicy ?? AIChannelPolicy.dmPolicies[0].value },
                        set: { c.dmPolicy = $0; config = c }))
                    if c.dmPolicy == "paircode" {
                        PairCodeRow(allowFrom: Binding(
                            get: { c.allowFrom ?? [] }, set: { c.allowFrom = $0; config = c }))
                    }
                } footer: {
                    Text(L10n.t("私聊策略支持配队码与开放"))
                }
            } else {
                Section {
                    LoadErrorStateView(message: loadError ?? "") {
                        Task { await load() }
                    }
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
                .disabled(config == nil || isSaving)
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
            config = try await client.send(
                path: APIEndpoint.aiAgentChannelGet.path.replacingOccurrences(of: ":type", with: "telegram"),
                body: AIAgentChannelRequest(agentId: agentId),
                as: AIChannelTelegram.self)
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        guard var c = config else { return }
        c.agentId = agentId
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "telegram"),
                body: c,
                as: EmptyResponse.self)
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Discord

struct AIAgentDiscordChannelView: View {
    let server: ServerConfig
    let agentId: Int

    @Environment(\.dismiss) private var dismiss
    @State private var config: AIChannelDiscord?
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
            } else if var c = config {
                Section {
                    Toggle(L10n.t("启用"), isOn: Binding(
                        get: { c.enabled ?? false }, set: { c.enabled = $0; config = c }))
                    SecureField("Token", text: Binding(
                        get: { c.token ?? "" }, set: { c.token = $0; config = c }))
                    .textInputAutocapitalization(.never)
                    DmPolicyPicker(value: Binding(
                        get: { c.dmPolicy ?? AIChannelPolicy.dmPolicies[0].value },
                        set: { c.dmPolicy = $0; config = c }))
                    if c.dmPolicy == "paircode" {
                        PairCodeRow(allowFrom: Binding(
                            get: { c.allowFrom ?? [] }, set: { c.allowFrom = $0; config = c }))
                    }
                } footer: {
                    Text(L10n.t("私聊策略支持配队码与开放"))
                }
            } else {
                Section {
                    LoadErrorStateView(message: loadError ?? "") {
                        Task { await load() }
                    }
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
                .disabled(config == nil || isSaving)
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
            config = try await client.send(
                path: APIEndpoint.aiAgentChannelGet.path.replacingOccurrences(of: ":type", with: "discord"),
                body: AIAgentChannelRequest(agentId: agentId),
                as: AIChannelDiscord.self)
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        guard var c = config else { return }
        c.agentId = agentId
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "discord"),
                body: c,
                as: EmptyResponse.self)
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
