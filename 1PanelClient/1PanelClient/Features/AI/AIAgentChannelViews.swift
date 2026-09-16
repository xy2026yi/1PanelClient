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

/// 频道列表行读取的状态（各频道 get 响应首字段一致；installed 为 OpenClaw 插件标记）
nonisolated struct AIChannelEnabledStatus: Decodable {
    let enabled: Bool?
    let installed: Bool?
}

// MARK: - 频道列表页

struct AIAgentChannelsView: View {
    let server: ServerConfig
    let agentId: Int
    let agentName: String
    /// 智能体类型：Telegram 等频道的策略选项集随类型不同（抓包确认）
    var agentType: String? = nil

    @State private var statusMap: [String: AIChannelEnabledStatus] = [:]
    /// OpenClaw 的微信无 get 接口：plugin/check(weixin) 补齐的插件安装状态
    @State private var pluginInstalledMap: [String: Bool] = [:]
    /// 首次加载是否完成（onAppear 返回本页时据此刷新徽标，首次交给 .task）
    @State private var hasLoadedOnce = false

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
                            channelBadge(kind)
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
        .task {
            await loadAllStatus()
            hasLoadedOnce = true
        }
        // 从具体频道页返回时刷新：安装/卸载插件后徽标需与频道页插件区重新对齐
        .onAppear {
            guard hasLoadedOnce else { return }
            Task { await loadAllStatus() }
        }
        .refreshable { await loadAllStatus() }
    }

    /// 行尾状态徽标：OpenClaw 频道为插件，仅显示 未安装 / 已安装 两态
    /// （QQ/企微/钉钉/飞书 get 带 installed；微信无 get、按 plugin/check(weixin)
    /// 结果）；Telegram/Discord 为内置连接器、无插件概念（plugin/check 的 Type
    /// oneof 校验不含这两类，请求会 400），不显示徽标；Hermes 网页端频道列表
    /// 无状态列，同样不显示；其余（QwenPaw）按 enabled
    @ViewBuilder
    private func channelBadge(_ kind: AIChannelKind) -> some View {
        if agentType == "openclaw" {
            if kind != .telegram, kind != .discord,
               let installed = statusMap[kind.rawValue]?.installed ?? pluginInstalledMap[kind.rawValue] {
                StatusBadge(
                    text: installed ? L10n.t("已安装") : L10n.t("未安装"),
                    color: installed ? .statusRunning : .secondary
                )
            }
        } else if agentType != "hermes-agent", let enabled = statusMap[kind.rawValue]?.enabled {
            StatusBadge(
                text: enabled ? L10n.t("已启用") : L10n.t("未启用"),
                color: enabled ? .statusRunning : .secondary
            )
        }
    }

    @ViewBuilder
    private func channelDestination(_ kind: AIChannelKind) -> some View {
        switch kind {
        case .weixin:
            AIAgentWeixinChannelView(server: server, agentId: agentId,
                                     initialEnabled: statusMap[kind.rawValue]?.enabled ?? false,
                                     agentType: agentType)
        case .qqbot:
            AIAgentQQChannelView(server: server, agentId: agentId, agentType: agentType)
        case .wecom:
            AIAgentWecomChannelView(server: server, agentId: agentId, agentType: agentType)
        case .dingtalk:
            AIAgentDingtalkChannelView(server: server, agentId: agentId, agentType: agentType)
        case .feishu:
            AIAgentFeishuChannelView(server: server, agentId: agentId, agentType: agentType)
        case .telegram:
            AIAgentTelegramChannelView(server: server, agentId: agentId, agentType: agentType)
        case .discord:
            AIAgentDiscordChannelView(server: server, agentId: agentId, agentType: agentType)
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

    /// 并行读取频道状态（微信无 get 接口，跳过；单条失败不影响其他）。
    /// OpenClaw 的微信无 get——再按 plugin/check(weixin) 补齐安装态；
    /// Telegram/Discord 为内置连接器，plugin/check 的 Type oneof 校验不含
    /// 这两类（2026-09-16 反馈 400 参数错误），不发起请求
    private func loadAllStatus() async {
        await withTaskGroup(of: (String, AIChannelEnabledStatus?).self) { group in
            for kind in AIChannelKind.allCases where kind != .weixin {
                let path = APIEndpoint.aiAgentChannelGet.path
                    .replacingOccurrences(of: ":type", with: kind.rawValue)
                group.addTask { [client] in
                    do {
                        let resp: AIChannelEnabledStatus = try await client.send(
                            path: path,
                            body: AIAgentChannelRequest(agentId: agentId),
                            as: AIChannelEnabledStatus.self)
                        return (kind.rawValue, resp)
                    } catch {
                        return (kind.rawValue, nil)
                    }
                }
            }
            for await (key, status) in group {
                // get 失败（如频道刚被删除）时置 nil 清掉旧徽标，
                // 不再残留上一次的「已安装」
                statusMap[key] = status
            }
        }
        if agentType == "openclaw" {
            await withTaskGroup(of: (String, Bool?).self) { group in
                for kind in [AIChannelKind.weixin] {
                    group.addTask { [client] in
                        do {
                            let resp: AIAgentPluginStatus = try await client.send(
                                path: APIEndpoint.aiAgentPluginCheck.path,
                                body: AIAgentPluginCheckRequest(
                                    agentId: agentId, type: kind.rawValue, checkLatest: false),
                                as: AIAgentPluginStatus.self)
                            return (kind.rawValue, resp.installed)
                        } catch {
                            return (kind.rawValue, nil)
                        }
                    }
                }
                for await (key, installed) in group {
                    // check 失败也写入（nil）：与 get 侧同口径清残留，
                    // 避免下次刷新继续显示上一次的「已安装」
                    pluginInstalledMap[key] = installed
                }
            }
        }
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

/// Hermes 频道删除（toolbar trash + 确认弹窗 + POST channel/delete {agentId,type}）。
/// 成功后 dismiss，频道列表 onAppear 会重拉状态对齐徽标（抓包 2026-09-15）
private struct HermesChannelDeleteModifier: ViewModifier {
    let client: APIClient
    let agentId: Int
    /// 频道类型（qqbot / wecom / dingtalk / feishu / telegram）
    let type: String
    /// false 时不显示删除入口（非 Hermes 智能体不挂删除）
    var isEnabled: Bool = true

    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @State private var showError = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if isEnabled {
                        if isDeleting {
                            ProgressView()
                        } else {
                            Button(role: .destructive) {
                                confirmDelete = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel(L10n.t("删除频道"))
                        }
                    }
                }
            }
            .alert(L10n.t("删除频道"), isPresented: $confirmDelete) {
                Button(L10n.t("取消"), role: .cancel) {}
                Button(L10n.t("删除"), role: .destructive) {
                    Haptic.warning()
                    Task { await deleteChannel() }
                }
            } message: {
                Text(L10n.t("确定删除该频道的配置吗？删除后需要重新配置才能使用。"))
            }
            .alert(L10n.t("提示"), isPresented: $showError) {
                Button(L10n.t("好的"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func deleteChannel() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelDelete.path,
                body: AIAgentChannelDeleteRequest(agentId: agentId, type: type),
                as: EmptyResponse.self)
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
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
                set: { raw in
                    // 保留空行（含键入行尾换行产生的尾部空行）：丢弃会让回写内容
                    // 与 TextEditor 当前文本不一致，任何重渲染都会把换行吞掉，
                    // 表现为无法换行输入。空行原样进提交，与网页端 textarea 行为一致
                    let items = raw.split(
                        omittingEmptySubsequences: false,
                        whereSeparator: \.isNewline
                    ).map(String.init)
                    if items != list { list = items }
                }
            ))
            .font(.dataMonospacedCaption)
            .frame(minHeight: 64)
            .scrollContentBackground(.hidden)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: Radius.small))
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
/// 已安装 → 版本 + 升级 + 卸载；未安装 → 安装（plugin/install，taskID 驱动进度页）；
/// 检查失败时整区隐藏
struct ChannelPluginSection: View {
    let client: APIClient
    let agentId: Int
    let type: String
    /// 任一插件动作（安装/升级/卸载）完成后的通用刷新
    var onChanged: () -> Void = {}
    /// 卸载完成后额外回调（微信：清空本地对接状态）
    var onUninstalled: () -> Void = {}
    /// 状态加载后回调（微信：用 installed 驱动「删除对接」入口——该频道无 get 接口）
    var onStatus: (AIAgentPluginStatus?) -> Void = { _ in }

    @State private var status: AIAgentPluginStatus?
    @State private var confirmUninstall = false
    @State private var progressTaskID = ""
    @State private var showProgress = false
    @State private var progressTitle = ""
    /// 进度页对应的动作（uninstall：完成时分派 onUninstalled）
    @State private var progressIsUninstall = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        Group {
            if let s = status {
                Section {
                    if s.installed == true {
                        LabeledContent(L10n.t("插件版本"), value: s.currentVersion ?? "-")
                        if let latest = s.latestVersion, !latest.isEmpty, latest != s.currentVersion {
                            LabeledContent(L10n.t("最新版本"), value: latest)
                            if s.upgradable == true {
                                Button {
                                    Task { await upgrade() }
                                } label: {
                                    Label(L10n.t("升级插件"), systemImage: "arrow.up.circle")
                                }
                            }
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
            }
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
        .navigationDestination(isPresented: $showProgress) {
            TaskProgressView(taskID: progressTaskID, title: progressTitle, latest: false, node: "local") { _ in
                // 完成 or 用户选后台运行都刷新（后台运行后插件状态同样变化）
                let wasUninstall = progressIsUninstall
                Task {
                    await load()
                    await MainActor.run {
                        // 插件动作完成后：通用刷新；卸载额外回调（get 的 installed 会变化）
                        onChanged()
                        if wasUninstall { onUninstalled() }
                    }
                }
                return false
            }
        }
        // task 必须挂在条件块外：status 初始为 nil，挂在 Section 上时
        // 视图不存在 → load 永不执行 → 插件区从不显示（含未安装时的安装按钮）
        .task { await load() }
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
        onStatus(status)
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
            progressIsUninstall = false
            showProgress = true
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func upgrade() async {
        let taskID = UUID().uuidString
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentPluginUpgrade.path,
                body: AIAgentPluginUpgradeRequest(agentId: agentId, type: type, taskID: taskID),
                as: EmptyResponse.self)
            progressTaskID = taskID
            progressTitle = L10n.t("升级插件")
            progressIsUninstall = false
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
            progressIsUninstall = true
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

    @State private var enabled = false
    /// 微信频道无 get 接口：插件 installed 作为对接状态的替代信号，
    /// 驱动「删除对接」入口（否则重进页面后入口消失）
    @State private var pluginInstalled = false
    @State private var isLoggingIn = false
    @State private var logLines: [String] = []
    @State private var qrURL: String?
    @State private var isPolling = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var confirmDelete = false

    private let client: APIClient

    /// Hermes 网页端频道无启用开关（核对隐藏）
    private var isHermes: Bool { agentType == "hermes-agent" }

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
                ChannelPluginSection(client: client, agentId: agentId, type: "weixin",
                                     onUninstalled: {
                                         enabled = false
                                         pluginInstalled = false
                                         qrURL = nil
                                     },
                                     onStatus: { status in
                                         pluginInstalled = (status?.installed == true)
                                     })
            }

            // 顶层状态开关仅 QwenPaw 显示；Hermes（网页无开关）与
            // OpenClaw（网页核对：仅插件区信息，无顶层开关）均隐藏
            if agentType != "openclaw", !isHermes {
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

            if enabled || pluginInstalled {
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
        .formWidthLimit()
        .task {
            enabled = initialEnabled || enabled
        }
        // 微信无 get 接口：下拉刷新插件安装状态（驱动「删除对接」入口可见性）
        .refreshable {
            if let resp: AIAgentPluginStatus = try? await client.send(
                path: APIEndpoint.aiAgentPluginCheck.path,
                body: AIAgentPluginCheckRequest(agentId: agentId, type: "weixin", checkLatest: false),
                as: AIAgentPluginStatus.self) {
                pluginInstalled = (resp.installed == true)
            }
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

    /// 发起扫码对接：taskID 由客户端生成随请求体发出（抓包确认响应 data 为 null），
    /// 按该 taskID 轮询任务日志提取二维码
    private func startLogin() async {
        isLoggingIn = true
        defer { isLoggingIn = false }
        let taskID = UUID().uuidString
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentWeixinLogin.path,
                body: AIAgentWeixinLoginRequest(agentId: agentId, taskID: taskID),
                as: EmptyResponse.self)
            startPolling(taskID: taskID)
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// 轮询任务日志：仅按 taskID 查询（taskType/taskOperate/name/resourceID
    /// 均为空、latest=false 从头读，抓包确认）
    private func startPolling(taskID: String) {
        isPolling = true
        Task {
            while isPolling && !Task.isCancelled {
                do {
                    let resp: TaskLogResponse = try await client.send(
                        path: APIEndpoint.logsTaskRead.path,
                        body: TaskLogReadRequest(
                            id: 0, type: "task", name: "",
                            page: 1, pageSize: 500, latest: false,
                            taskID: taskID,
                            taskType: "", taskOperate: "",
                            resourceID: 0),
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
    /// 上次已保存的 Bot 列表快照（滑动删除的组装基准，不含表单草稿）
    @State private var savedBots: [AIChannelQQBotItem] = []
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
    /// Hermes 网页端频道无启用开关（核对隐藏），保存恒传 enabled:true（抓包确认）
    private var isHermes: Bool { agentType == "hermes-agent" }

    init(server: ServerConfig, agentId: Int, agentType: String? = nil) {
        self.server = server
        self.agentId = agentId
        self.agentType = agentType
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        Form {
            if isLoading {
                Section { LoadingStateView(compact: true) }
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
                    // OpenClaw 顶层插件状态开关：切换即提交；服务端把默认 Bot 的
                    // enabled 与顶层 enabled 联动落库（顶层关→默认 Bot 关；
                    // 顶层开→默认 Bot 开），行内默认 Bot 开关镜像顶层开关
                    Toggle(L10n.t("启用"), isOn: Binding(
                        get: { c.enabled ?? false },
                        set: { on in
                            c.enabled = on
                            Task { await toggleTopEnabled(on) }
                        }))
                        .disabled(isSaving)
                }

                openclawBotList

            } else {
                Section {
                    // Hermes 网页端无启用开关（核对隐藏），保存恒传 enabled:true
                    if !isHermes {
                        Toggle(L10n.t("启用"), isOn: Binding(
                            get: { c.enabled ?? false }, set: { c.enabled = $0 }))
                    }
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
        .formWidthLimit()
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
        .refreshable { await load() }
        .modifier(HermesChannelDeleteModifier(
            client: client, agentId: agentId, type: "qqbot", isEnabled: isHermes))
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
                HStack(spacing: 12) {
                    Button {
                        editingBot = bot
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(bot.name ?? bot.accountId ?? "-")
                                    .font(.body.bold())
                                    .foregroundStyle(.primary)
                                if bot.isDefault == true {
                                    StatusBadge(text: L10n.t("默认"), color: .blue)
                                }
                            }
                            Text(bot.accountId ?? "-")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    // Bot 状态开关：默认 Bot 镜像顶层开关，其余行内即时提交
                    Toggle("", isOn: botEnabledBinding(bot))
                        .labelsHidden()
                        .disabled(isSaving)
                        .accessibilityLabel(L10n.t("启用"))
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        Task { await removeBot(bot) }
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
            Text(L10n.t("点击 Bot 编辑凭证与策略；状态开关与删除将立即保存。默认 Bot 随顶部启用开关联动"))
        }
    }

    /// 行内 Bot 状态开关绑定：默认 Bot 与顶层启用开关联动（显示与提交均镜像
    /// 顶层开关，切换走同一条顶层 update）；其余 Bot 显示取当前列表，
    /// 切换走即时保存（失败由 saveBots 回滚）
    private func botEnabledBinding(_ bot: AIChannelQQBotItem) -> Binding<Bool> {
        if bot.id == defaultBotID() {
            return Binding(
                get: { c.enabled ?? false },
                set: { on in
                    c.enabled = on
                    Task { await toggleTopEnabled(on) }
                })
        }
        return Binding(
            get: { bots.first(where: { $0.id == bot.id })?.enabled ?? false },
            set: { on in Task { await toggleBotEnabled(bot, on: on) } }
        )
    }

    /// 默认 Bot：isDefault 标记优先，缺失时回退首个（钉钉服务端不回 isDefault）。
    /// 服务端将其 enabled 与顶层 enabled 联动：顶层关会一并把默认 Bot 持久化为关，
    /// 顶层关时单独开默认 Bot 会被忽略，只有开顶层开关才能把默认 Bot 带开
    private func defaultBotID() -> String? {
        (bots.first(where: { $0.isDefault == true }) ?? bots.first)?.id
    }

    /// 顶层开关保存成功后同步默认 Bot 的本地显示与快照（对齐服务端联动落库）
    private func syncDefaultBotEnabled(_ on: Bool) {
        guard let id = defaultBotID() else { return }
        for idx in bots.indices where bots[idx].id == id { bots[idx].enabled = on }
        for idx in savedBots.indices where savedBots[idx].id == id { savedBots[idx].enabled = on }
    }

    /// OpenClaw 非默认 Bot 状态开关即时提交：基于已保存快照仅翻转该 Bot 的
    /// enabled（顶层 enabled 与其余 Bot 不动，抓包确认；默认 Bot 走顶层开关联动）
    private func toggleBotEnabled(_ bot: AIChannelQQBotItem, on: Bool) async {
        var updated = savedBots
        guard let idx = updated.firstIndex(where: { $0.id == bot.id }) else { return }
        updated[idx].enabled = on
        await saveBots(updated)
    }

    /// 删除 Bot：基于已保存快照组装（不携带表单未保存草稿），
    /// 删除默认 Bot 时默认让位第一个；至少保留一个（抓包从未出现空 bots 数组）
    private func removeBot(_ bot: AIChannelQQBotItem) async {
        guard savedBots.count > 1 else {
            errorMessage = L10n.t("至少保留一个 Bot")
            showError = true
            return
        }
        var updated = savedBots.filter { $0.id != bot.id }
        if bot.isDefault == true, !updated.isEmpty {
            updated[0].isDefault = true
        }
        await saveBots(updated)
    }

    /// OpenClaw：Bot 删除即时全量保存（顶层与 bots 均取已保存快照，不含草稿）
    private func saveBots(_ updated: [AIChannelQQBotItem]) async {
        guard !isSaving, !updated.isEmpty else { return }
        let previousBots = bots
        let previousSavedBots = savedBots
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
            savedBots = updated
        } catch {
            guard !APIError.isCancellation(error) else { return }
            bots = previousBots
            savedBots = previousSavedBots
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// OpenClaw 顶层插件状态开关即时提交：基于已保存快照（不含 Bot 草稿），
    /// 仅改 enabled（抓包：{agentId,enabled,bots}，策略字段不带）；失败回滚 UI。
    /// 成功后同步默认 Bot 的 enabled（服务端随顶层开关联动落库）
    private func toggleTopEnabled(_ on: Bool) async {
        guard !isSaving else { return }
        var out = savedC
        out.agentId = agentId
        out.installed = nil
        out.dmPolicy = nil
        out.groupPolicy = nil
        out.allowFrom = nil
        out.groupAllowFrom = nil
        out.enabled = on
        out.bots = savedBots
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "qqbot"),
                body: out,
                as: EmptyResponse.self)
            savedC = out
            syncDefaultBotEnabled(on)
        } catch {
            guard !APIError.isCancellation(error) else { return }
            c.enabled = !on
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
            var loaded = resp
            // Hermes：未配置时 dm/groupPolicy 为空串，Picker 折叠首项「配对码」
            // 会显示与实际不符（网页端默认/提交均为 open）；归一后显示与提交一致
            if isHermes {
                loaded.enabled = true
                if (loaded.dmPolicy ?? "").isEmpty { loaded.dmPolicy = "open" }
                if (loaded.groupPolicy ?? "").isEmpty { loaded.groupPolicy = "open" }
            }
            c = loaded
            savedC = loaded
            if isOpenClaw {
                bots = loaded.bots ?? []
                savedBots = bots
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
        // update 体不含 get 回传的 installed 标记（抓包确认）
        out.installed = nil
        // Hermes 网页端无启用开关：保存恒传 enabled:true（抓包确认）；
        // 策略空串按网页端提交口径回退 open（服务端 required 校验拒绝空）
        if isHermes {
            out.enabled = true
            if (out.dmPolicy ?? "").isEmpty { out.dmPolicy = "open" }
            if (out.groupPolicy ?? "").isEmpty { out.groupPolicy = "open" }
        }
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
            savedBots = out.bots ?? []
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

/// OpenClaw QQ Bot 新建/编辑表单（名称/账户ID/AppID/AppSecret/
/// 私聊白名单/系统提示词；启用状态由列表行内开关即时提交，不在表单内；
/// 首个 Bot 账户 ID 固定 default，抓包确认）
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
                            .font(.dataMonospacedCaption)
                            .frame(minHeight: 72)
                            .scrollContentBackground(.hidden)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: Radius.small))
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
    /// 上次已保存快照（顶层开关即时提交的基底，不携带未保存草稿）
    @State private var savedC = AIChannelWecom()
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var loadError: String?
    @State private var errorMessage: String?
    @State private var showError = false

    private let client: APIClient

    private var isOpenClaw: Bool { agentType == "openclaw" }
    /// Hermes 网页端频道无启用开关（核对隐藏），保存恒传 enabled:true（抓包确认）
    private var isHermes: Bool { agentType == "hermes-agent" }

    init(server: ServerConfig, agentId: Int, agentType: String? = nil) {
        self.server = server
        self.agentId = agentId
        self.agentType = agentType
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        Form {
            if isLoading {
                Section { LoadingStateView(compact: true) }
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
                    // Hermes 网页端无启用开关（核对隐藏），保存恒传 enabled:true；
                    // OpenClaw 企微仅此一个开关（网页核对）：切换即提交
                    if isOpenClaw {
                        Toggle(L10n.t("启用"), isOn: Binding(
                            get: { c.enabled ?? false },
                            set: { on in
                                c.enabled = on
                                Task { await toggleTopEnabled(on) }
                            }))
                            .disabled(isSaving)
                    } else if !isHermes {
                        Toggle(L10n.t("启用"), isOn: Binding(
                            get: { c.enabled ?? false }, set: { c.enabled = $0 }))
                    }
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
        .formWidthLimit()
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
        .refreshable { await load() }
        .modifier(HermesChannelDeleteModifier(
            client: client, agentId: agentId, type: "wecom", isEnabled: isHermes))
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func load() async {
        do {
            var loaded = try await client.send(
                path: APIEndpoint.aiAgentChannelGet.path.replacingOccurrences(of: ":type", with: "wecom"),
                body: AIAgentChannelRequest(agentId: agentId),
                as: AIChannelWecom.self)
            // Hermes 网页端无启用开关：保存恒传 enabled:true（抓包确认）；
            // 未配置时策略为空串（服务端 required 校验拒绝空），按网页端
            // 提交口径归一 open，避免 Picker 折叠首项显示与实际不符
            if isHermes {
                loaded.enabled = true
                if (loaded.dmPolicy ?? "").isEmpty { loaded.dmPolicy = "open" }
                if (loaded.groupPolicy ?? "").isEmpty { loaded.groupPolicy = "open" }
            }
            c = loaded
            savedC = loaded
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    /// OpenClaw 企微仅一个顶层插件状态开关（网页核对）：切换即提交，
    /// 基于已保存快照仅改 enabled；失败回滚 UI（保存中防连点并发 update）
    private func toggleTopEnabled(_ on: Bool) async {
        guard !isSaving else { return }
        var out = savedC
        out.agentId = agentId
        out.installed = nil
        out.enabled = on
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "wecom"),
                body: out,
                as: EmptyResponse.self)
            savedC = out
        } catch {
            guard !APIError.isCancellation(error) else { return }
            c.enabled = !on
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func save() async {
        var out = c
        out.agentId = agentId
        out.installed = nil
        // Hermes：策略空串按网页端提交口径回退 open（AgentWecomConfig-UpdateReq
        // 对 DmPolicy/GroupPolicy required，抓包 update 恒传 open）
        if isHermes {
            out.enabled = true
            if (out.dmPolicy ?? "").isEmpty { out.dmPolicy = "open" }
            if (out.groupPolicy ?? "").isEmpty { out.groupPolicy = "open" }
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "wecom"),
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

// MARK: - 钉钉（OpenClaw 多 Bot；基础类型单默认 Bot）

struct AIAgentDingtalkChannelView: View {
    let server: ServerConfig
    let agentId: Int
    /// OpenClaw：插件 + 多 Bot + 白名单策略 + 群会话范围（抓包确认）；
    /// 基础类型（Hermes/QwenPaw）为单默认 Bot + 基础策略表单
    var agentType: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var c = AIChannelDingtalk()
    /// 基础类型：凭证在 bots[0]；其余 bots 原样保留
    @State private var bot = AIChannelDingtalkBotItem(accountId: "default", name: "Default", enabled: true, isDefault: true)
    @State private var extraBots: [AIChannelDingtalkBotItem] = []
    /// OpenClaw：Bot 列表整列编辑
    @State private var bots: [AIChannelDingtalkBotItem] = []
    /// 上次已保存的 Bot 列表快照（滑动删除的组装基准，不含表单草稿）
    @State private var savedBots: [AIChannelDingtalkBotItem] = []
    @State private var savedC = AIChannelDingtalk()
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var loadError: String?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var editingBot: AIChannelDingtalkBotItem?
    @State private var showAddBot = false

    private let client: APIClient

    private var isOpenClaw: Bool { agentType == "openclaw" }
    /// Hermes：未配置频道启用开关默认开；网页核对无 会话设置 与 群组策略
    private var isHermes: Bool { agentType == "hermes-agent" }

    /// OpenClaw 私聊策略无配队码（抓包确认）：白名单 / 开放 / 禁用
    private var dmPolicies: [(value: String, label: String)] {
        AIChannelPolicy.dmPoliciesFull.filter { $0.value != "pairing" }
    }

    /// 群会话范围：整群共享 group / 群内按人隔离 group_sender（抓包确认）
    private let groupScopes: [(value: String, label: String)] = [
        ("group", L10n.t("整群共享")),
        ("group_sender", L10n.t("群内按人隔离")),
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
                Section { LoadingStateView(compact: true) }
            } else if loadError != nil {
                Section {
                    LoadErrorStateView(message: loadError ?? "") {
                        Task { await load() }
                    }
                }
            } else if isOpenClaw {
                ChannelPluginSection(client: client, agentId: agentId, type: "dingtalk") {
                    Task { await load() }
                }

                Section {
                    // OpenClaw 顶层插件状态开关：切换即提交；服务端把默认 Bot 的
                    // enabled 与顶层 enabled 联动落库，行内默认 Bot 开关镜像顶层开关
                    Toggle(L10n.t("启用"), isOn: Binding(
                        get: { c.enabled ?? false },
                        set: { on in
                            c.enabled = on
                            Task { await toggleTopEnabled(on) }
                        }))
                        .disabled(isSaving)
                    ChannelPolicyPicker(title: L10n.t("私聊策略"), options: dmPolicies,
                                         value: Binding(get: { c.dmPolicy ?? "open" }, set: { c.dmPolicy = $0 }))
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
                }

                sessionSection

                openclawBotList
            } else {
                Section {
                    // Hermes 网页端无启用开关（核对隐藏），保存恒传 enabled:true
                    if !isHermes {
                        Toggle(L10n.t("启用"), isOn: Binding(
                            get: { c.enabled ?? false }, set: { c.enabled = $0 }))
                    }
                    TextField("Client ID", text: Binding(
                        get: { bot.clientId ?? "" }, set: { bot.clientId = $0 }))
                        .textInputAutocapitalization(.never)
                    SecureField("Client Secret", text: Binding(
                        get: { bot.clientSecret ?? "" }, set: { bot.clientSecret = $0 }))
                        .textInputAutocapitalization(.never)
                    ChannelPolicyPicker(title: L10n.t("私聊策略"), options: AIChannelPolicy.dmPoliciesBasic,
                                         value: Binding(get: { c.dmPolicy ?? "pairing" }, set: { c.dmPolicy = $0 }))
                    // Hermes 网页端无群组策略（核对隐藏，保存仍回传服务端值）
                    if !isHermes {
                        ChannelPolicyPicker(title: L10n.t("群组策略"), options: AIChannelPolicy.groupPoliciesBasic,
                                             value: Binding(get: { c.groupPolicy ?? "open" }, set: { c.groupPolicy = $0 }))
                    }
                }

                if !isHermes {
                    basicSessionSection
                }

                if c.dmPolicy == "pairing" {
                    PairingApproveSection(client: client, agentId: agentId, type: "dingtalk")
                }
            }
        }
        .navigationTitle(L10n.t("钉钉"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
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
        .refreshable { await load() }
        .modifier(HermesChannelDeleteModifier(
            client: client, agentId: agentId, type: "dingtalk", isEnabled: isHermes))
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $editingBot) { bot in
            AIDingtalkBotFormSheet(
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
            AIDingtalkBotFormSheet(
                bot: AIChannelDingtalkBotItem(enabled: true, isDefault: false),
                isEdit: false,
                existingAccountIDs: bots.compactMap(\.accountId)) { newBot in
                bots.append(newBot)
            }
        }
    }

    /// OpenClaw 会话设置：会话隔离 / 群会话范围 / 共享记忆 / 异步模式 + 确认消息
    private var sessionSection: some View {
        Section {
            Toggle(L10n.t("按会话隔离"), isOn: Binding(
                get: { c.separateSessionByConversation ?? true },
                set: { c.separateSessionByConversation = $0 }))
            Picker(L10n.t("群会话范围"), selection: Binding(
                get: {
                    let v = c.groupSessionScope ?? ""
                    return groupScopes.contains(where: { $0.value == v }) ? v : "group_sender"
                },
                set: { c.groupSessionScope = $0 })) {
                ForEach(groupScopes, id: \.value) { s in
                    Text(s.label).tag(s.value)
                }
            }
            Toggle(L10n.t("跨会话共享记忆"), isOn: Binding(
                get: { c.sharedMemoryAcrossConversations ?? false },
                set: { c.sharedMemoryAcrossConversations = $0 }))
            Toggle(L10n.t("异步模式"), isOn: Binding(
                get: { c.asyncMode ?? false }, set: { c.asyncMode = $0 }))
            if c.asyncMode == true {
                TextField(L10n.t("确认消息"), text: Binding(
                    get: { c.ackText ?? "" }, set: { c.ackText = $0 }))
            }
        } header: {
            SectionLabel(title: L10n.t("会话设置"), systemImage: "bubble.left.and.bubble.right")
        } footer: {
            if c.asyncMode == true {
                Text(L10n.t("异步模式下先回复确认消息，任务完成后再次回复"))
            }
        }
    }

    /// 基础类型会话设置（抓包无群会话范围下拉，保持既有四项）
    private var basicSessionSection: some View {
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
    }

    // MARK: OpenClaw Bot 列表

    private var openclawBotList: some View {
        Section {
            ForEach(bots) { bot in
                HStack(spacing: 12) {
                    Button {
                        editingBot = bot
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(bot.name ?? bot.accountId ?? "-")
                                    .font(.body.bold())
                                    .foregroundStyle(.primary)
                                // 服务端不回 isDefault，首个 Bot 即联动的默认 Bot
                                if bot.id == defaultBotID() {
                                    StatusBadge(text: L10n.t("默认"), color: .blue)
                                }
                            }
                            Text(bot.accountId ?? "-")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    // Bot 状态开关：默认 Bot 镜像顶层开关，其余行内即时提交
                    Toggle("", isOn: botEnabledBinding(bot))
                        .labelsHidden()
                        .disabled(isSaving)
                        .accessibilityLabel(L10n.t("启用"))
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        Task { await removeBot(bot) }
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
            Text(L10n.t("点击 Bot 编辑凭证；状态开关与删除将立即保存。默认 Bot 随顶部启用开关联动"))
        }
    }

    /// 行内 Bot 状态开关绑定：默认 Bot 与顶层启用开关联动（显示与提交均镜像
    /// 顶层开关，切换走同一条顶层 update）；其余 Bot 显示取当前列表，
    /// 切换走即时保存（失败由 saveBots 回滚）
    private func botEnabledBinding(_ bot: AIChannelDingtalkBotItem) -> Binding<Bool> {
        if bot.id == defaultBotID() {
            return Binding(
                get: { c.enabled ?? false },
                set: { on in
                    c.enabled = on
                    Task { await toggleTopEnabled(on) }
                })
        }
        return Binding(
            get: { bots.first(where: { $0.id == bot.id })?.enabled ?? false },
            set: { on in Task { await toggleBotEnabled(bot, on: on) } }
        )
    }

    /// 默认 Bot：isDefault 标记优先，缺失时回退首个（钉钉抓包服务端不回
    /// isDefault=true，首个 Bot 即服务端联动的默认账户）。
    /// 服务端将其 enabled 与顶层 enabled 联动：顶层关会一并把默认 Bot 持久化为关，
    /// 顶层关时单独开默认 Bot 会被忽略，只有开顶层开关才能把默认 Bot 带开
    private func defaultBotID() -> String? {
        (bots.first(where: { $0.isDefault == true }) ?? bots.first)?.id
    }

    /// 顶层开关保存成功后同步默认 Bot 的本地显示与快照（对齐服务端联动落库）
    private func syncDefaultBotEnabled(_ on: Bool) {
        guard let id = defaultBotID() else { return }
        for idx in bots.indices where bots[idx].id == id { bots[idx].enabled = on }
        for idx in savedBots.indices where savedBots[idx].id == id { savedBots[idx].enabled = on }
    }

    /// OpenClaw 非默认 Bot 状态开关即时提交：基于已保存快照仅翻转该 Bot 的
    /// enabled（顶层 enabled 与其余 Bot 不动，抓包确认；默认 Bot 走顶层开关联动）
    private func toggleBotEnabled(_ bot: AIChannelDingtalkBotItem, on: Bool) async {
        var updated = savedBots
        guard let idx = updated.firstIndex(where: { $0.id == bot.id }) else { return }
        updated[idx].enabled = on
        await saveBots(updated)
    }

    /// 删除 Bot：基于已保存快照组装（不含表单草稿）；抓包从未出现空 bots
    /// 数组，至少保留一个（与 QQ/飞书/Telegram/Discord 一致）
    private func removeBot(_ bot: AIChannelDingtalkBotItem) async {
        guard savedBots.count > 1 else {
            errorMessage = L10n.t("至少保留一个 Bot")
            showError = true
            return
        }
        await saveBots(savedBots.filter { $0.id != bot.id })
    }

    /// OpenClaw：Bot 删除即时全量保存（顶层与 bots 均取已保存快照，不含草稿）
    private func saveBots(_ updated: [AIChannelDingtalkBotItem]) async {
        guard !isSaving, !updated.isEmpty else { return }
        let previousBots = bots
        let previousSavedBots = savedBots
        bots = updated
        var out = savedC
        out.agentId = agentId
        out.installed = nil
        out.bots = updated
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "dingtalk"),
                body: out,
                as: EmptyResponse.self)
            savedC = out
            savedBots = updated
        } catch {
            guard !APIError.isCancellation(error) else { return }
            bots = previousBots
            savedBots = previousSavedBots
            errorMessage = error.localizedDescription
            showError = true
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
            if isOpenClaw {
                if (loaded.dmPolicy ?? "").isEmpty { loaded.dmPolicy = "open" }
                if (loaded.groupSessionScope ?? "").isEmpty { loaded.groupSessionScope = "group_sender" }
                // allowFrom 遗留的 ["*"]（open 策略下服务端保存的默认值）不是白名单
                // 内容：切到白名单时输入框应为空（2026-09-15 反馈核对）
                if loaded.allowFrom == ["*"] { loaded.allowFrom = [] }
            } else {
                if isHermes {
                    // Hermes 未配置时 dmPolicy 为空串（UpdateReq required 拒绝空），
                    // 表单无群组策略控件但 update 恒传 open（抓包），归一显示与提交一致
                    loaded.enabled = true
                    if (loaded.dmPolicy ?? "").isEmpty { loaded.dmPolicy = "open" }
                }
                if (loaded.groupSessionScope ?? "").isEmpty {
                    // 未配置（scope 为空，网页端保存必带有效值）时按默认值回显；
                    // 不以 ackText 空串判定——用户主动清空回执保存后重进不应被回填
                    loaded.separateSessionByConversation = true
                    loaded.groupSessionScope = "group_sender"
                    loaded.ackText = L10n.t("任务已接收，处理中...")
                }
            }
            c = loaded
            savedC = loaded
            if isOpenClaw {
                bots = loaded.bots ?? []
                savedBots = bots
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

    /// OpenClaw 顶层插件状态开关即时提交：基于已保存快照（不含 Bot 草稿），
    /// 仅改 enabled；失败回滚 UI。策略取已保存值。
    /// 成功后同步默认 Bot 的 enabled（服务端随顶层开关联动落库）
    private func toggleTopEnabled(_ on: Bool) async {
        guard !isSaving else { return }
        var out = savedC
        out.agentId = agentId
        out.installed = nil
        out.enabled = on
        out.bots = savedBots
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "dingtalk"),
                body: out,
                as: EmptyResponse.self)
            savedC = out
            syncDefaultBotEnabled(on)
        } catch {
            guard !APIError.isCancellation(error) else { return }
            c.enabled = !on
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func save() async {
        var out = c
        out.agentId = agentId
        // update 体不含 get 回传的 installed 标记（抓包确认）
        out.installed = nil
        // Hermes 网页端无启用开关：保存恒传 enabled:true（抓包确认）；
        // AgentDingTalkConfig-UpdateReq 对 DmPolicy required，表单无群组策略
        // 控件但 update 恒传 open（抓包），空串按网页端口径回退
        if isHermes {
            out.enabled = true
            if (out.dmPolicy ?? "").isEmpty { out.dmPolicy = "open" }
            if (out.groupPolicy ?? "").isEmpty { out.groupPolicy = "open" }
        }
        if isOpenClaw {
            out.bots = bots
        } else {
            out.bots = [bot] + extraBots
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "dingtalk"),
                body: out,
                as: EmptyResponse.self)
            savedC = out
            savedBots = out.bots ?? []
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

/// OpenClaw 钉钉 Bot 新建/编辑表单（名称/账户ID/状态/Client ID/Client Secret）
private struct AIDingtalkBotFormSheet: View {
    @State var bot: AIChannelDingtalkBotItem
    let isEdit: Bool
    var existingAccountIDs: [String] = []
    var selfOriginalID: String? = nil
    let onConfirm: (AIChannelDingtalkBotItem) -> Void

    @Environment(\.dismiss) private var dismiss

    private var isDuplicateAccount: Bool {
        let id = (bot.accountId ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return false }
        return existingAccountIDs.filter { $0 != selfOriginalID }.contains(id)
    }

    private var canSubmit: Bool {
        !(bot.accountId ?? "").isEmpty && !(bot.clientId ?? "").isEmpty
            && !(bot.clientSecret ?? "").isEmpty && !isDuplicateAccount
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // 名称不可编辑（网页核对）：创建时自动与账户 ID 一致
                    TextField(L10n.t("账户 ID"), text: Binding(
                        get: { bot.accountId ?? "" },
                        set: { raw in
                            bot.accountId = raw
                            bot.name = raw
                        }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Client ID", text: Binding(
                        get: { bot.clientId ?? "" }, set: { bot.clientId = $0 }))
                        .textInputAutocapitalization(.never)
                    SecureField("Client Secret", text: Binding(
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
    /// 上次已保存的 Bot 列表快照（滑动删除的组装基准，不含表单草稿）
    @State private var savedBots: [AIChannelFeishuBotItem] = []
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
    /// Hermes：未配置频道启用开关默认开；网页核对无 会话设置、私聊策略无禁用
    private var isHermes: Bool { agentType == "hermes-agent" }

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
                Section { LoadingStateView(compact: true) }
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
                    // OpenClaw 顶层插件状态开关：切换即提交；服务端把默认 Bot 的
                    // enabled 与顶层 enabled 联动落库，行内默认 Bot 开关镜像顶层开关
                    Toggle(L10n.t("启用"), isOn: Binding(
                        get: { c.enabled ?? false },
                        set: { on in
                            c.enabled = on
                            Task { await toggleTopEnabled(on) }
                        }))
                        .disabled(isSaving)
                    Toggle(L10n.t("线程会话"), isOn: Binding(
                        get: { c.threadSession ?? true }, set: { c.threadSession = $0 }))
                    Toggle(L10n.t("流式传输"), isOn: Binding(
                        get: { c.streaming ?? false }, set: { c.streaming = $0 }))
                    // 回复模式：网页端为带标签展示（值 auto），非自由输入
                    LabeledContent(L10n.t("回复模式"), value: c.replyMode ?? "auto")
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
                    // Hermes 网页端无启用开关（核对隐藏），保存恒传 enabled:true
                    if !isHermes {
                        Toggle(L10n.t("启用"), isOn: Binding(
                            get: { c.enabled ?? false }, set: { c.enabled = $0 }))
                    }
                    TextField("App ID", text: Binding(
                        get: { bot.appId ?? "" }, set: { bot.appId = $0 }))
                        .textInputAutocapitalization(.never)
                    SecureField("App Secret", text: Binding(
                        get: { bot.appSecret ?? "" }, set: { bot.appSecret = $0 }))
                        .textInputAutocapitalization(.never)
                    // Hermes 私聊策略无禁用（网页核对）：配队码 / 开放
                    ChannelPolicyPicker(title: L10n.t("私聊策略"),
                                         options: isHermes ? AIChannelPolicy.dmPoliciesPairingOpen : AIChannelPolicy.dmPoliciesBasic,
                                         value: Binding(get: { bot.dmPolicy ?? "open" }, set: { bot.dmPolicy = $0 }))
                    ChannelPolicyPicker(title: L10n.t("群组策略"), options: AIChannelPolicy.groupPoliciesBasic,
                                         value: Binding(get: { c.groupPolicy ?? "open" }, set: { c.groupPolicy = $0 }))
                }

                // Hermes 网页端无会话设置（核对隐藏，保存仍回传服务端值）
                if !isHermes {
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
                }

                if (bot.dmPolicy ?? "") == "pairing" {
                    PairingApproveSection(client: client, agentId: agentId, type: "feishu")
                }
            }
        }
        .navigationTitle(L10n.t("飞书"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
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
        .refreshable { await load() }
        .modifier(HermesChannelDeleteModifier(
            client: client, agentId: agentId, type: "feishu", isEnabled: isHermes))
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
            set: { if !$0 { pairingBot = nil } }
        )) {
            TextField(L10n.t("配对码"), text: $pairingCode)
                .keyboardType(.numberPad)
            Button(L10n.t("批准配对")) {
                // alert 关闭先于 Task 执行：配对码在 action 内捕获，避免发出空串
                if let bot = pairingBot {
                    let code = pairingCode
                    Task { await approvePairing(bot, code: code) }
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
                HStack(spacing: 12) {
                    Button {
                        editingBot = bot
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(bot.name ?? bot.accountId ?? "-")
                                    .font(.body.bold())
                                    .foregroundStyle(.primary)
                                if bot.isDefault == true {
                                    StatusBadge(text: L10n.t("默认"), color: .blue)
                                }
                            }
                            Text(bot.accountId ?? "-")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    // Bot 状态开关：默认 Bot 镜像顶层开关，其余行内即时提交
                    Toggle("", isOn: botEnabledBinding(bot))
                        .labelsHidden()
                        .disabled(isSaving)
                        .accessibilityLabel(L10n.t("启用"))
                }
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
                        Task { await removeBot(bot) }
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
            Text(L10n.t("点击 Bot 编辑凭证与策略；状态开关、批准配对与删除将立即保存。默认 Bot 随顶部启用开关联动"))
        }
    }

    /// 行内 Bot 状态开关绑定：默认 Bot 与顶层启用开关联动（显示与提交均镜像
    /// 顶层开关，切换走同一条顶层 update）；其余 Bot 显示取当前列表，
    /// 切换走即时保存（失败由 saveBots 回滚）
    private func botEnabledBinding(_ bot: AIChannelFeishuBotItem) -> Binding<Bool> {
        if bot.id == defaultBotID() {
            return Binding(
                get: { c.enabled ?? false },
                set: { on in
                    c.enabled = on
                    Task { await toggleTopEnabled(on) }
                })
        }
        return Binding(
            get: { bots.first(where: { $0.id == bot.id })?.enabled ?? false },
            set: { on in Task { await toggleBotEnabled(bot, on: on) } }
        )
    }

    /// 默认 Bot：isDefault 标记优先，缺失时回退首个（钉钉服务端不回 isDefault）。
    /// 服务端将其 enabled 与顶层 enabled 联动：顶层关会一并把默认 Bot 持久化为关，
    /// 顶层关时单独开默认 Bot 会被忽略，只有开顶层开关才能把默认 Bot 带开
    private func defaultBotID() -> String? {
        (bots.first(where: { $0.isDefault == true }) ?? bots.first)?.id
    }

    /// 顶层开关保存成功后同步默认 Bot 的本地显示与快照（对齐服务端联动落库）
    private func syncDefaultBotEnabled(_ on: Bool) {
        guard let id = defaultBotID() else { return }
        for idx in bots.indices where bots[idx].id == id { bots[idx].enabled = on }
        for idx in savedBots.indices where savedBots[idx].id == id { savedBots[idx].enabled = on }
    }

    /// OpenClaw 非默认 Bot 状态开关即时提交：基于已保存快照仅翻转该 Bot 的
    /// enabled（顶层 enabled 与其余 Bot 不动，抓包确认；默认 Bot 走顶层开关联动）
    private func toggleBotEnabled(_ bot: AIChannelFeishuBotItem, on: Bool) async {
        var updated = savedBots
        guard let idx = updated.firstIndex(where: { $0.id == bot.id }) else { return }
        updated[idx].enabled = on
        await saveBots(updated)
    }

    /// 删除 Bot：基于已保存快照组装（不含表单草稿）；至少保留一个，
    /// 删除默认 Bot 时默认让位第一个
    private func removeBot(_ bot: AIChannelFeishuBotItem) async {
        guard savedBots.count > 1 else {
            errorMessage = L10n.t("至少保留一个 Bot")
            showError = true
            return
        }
        var updated = savedBots.filter { $0.id != bot.id }
        if bot.isDefault == true, !updated.isEmpty {
            updated[0].isDefault = true
        }
        await saveBots(updated)
    }

    /// OpenClaw：Bot 删除即时全量保存（顶层与 bots 均取已保存快照，不含草稿）
    private func saveBots(_ updated: [AIChannelFeishuBotItem]) async {
        guard !isSaving, !updated.isEmpty else { return }
        let previousBots = bots
        let previousSavedBots = savedBots
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
            savedBots = updated
        } catch {
            guard !APIError.isCancellation(error) else { return }
            bots = previousBots
            savedBots = previousSavedBots
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// 行内批准配对（带该 Bot 的 accountId；配对码由调用方捕获传入）
    private func approvePairing(_ bot: AIChannelFeishuBotItem, code: String) async {
        isApproving = true
        defer { isApproving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelPairingApprove.path,
                body: AIAgentChannelPairingApproveRequest(
                    agentId: agentId, type: "feishu",
                    pairingCode: code, accountId: bot.accountId),
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
            if isHermes {
                // AgentFeishuConfig-UpdateReq 对顶层 GroupPolicy required（get 未配置
                // 返回空串）；私聊策略在各 Bot 内，同样空串归一 open（抓包提交口径）
                loaded.enabled = true
                if (loaded.groupPolicy ?? "").isEmpty { loaded.groupPolicy = "open" }
            }
            c = loaded
            savedC = loaded
            if isOpenClaw {
                bots = loaded.bots ?? []
                savedBots = bots
            } else {
                bot = loaded.bots?.first ?? bot
                if isHermes, (bot.dmPolicy ?? "").isEmpty { bot.dmPolicy = "open" }
                extraBots = Array((loaded.bots ?? []).dropFirst())
            }
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    /// OpenClaw 顶层插件状态开关即时提交：基于已保存快照（不含 Bot 草稿），
    /// 仅改 enabled；失败回滚 UI。
    /// update 体不含 get 回传的 installed/domain/connectionMode 与顶层 dmPolicy
    /// （与 saveBots/保存同口径，抓包确认）。
    /// 成功后同步默认 Bot 的 enabled（服务端随顶层开关联动落库）
    private func toggleTopEnabled(_ on: Bool) async {
        guard !isSaving else { return }
        var out = savedC
        out.agentId = agentId
        out.installed = nil
        out.domain = nil
        out.connectionMode = nil
        out.dmPolicy = nil
        out.enabled = on
        out.bots = savedBots
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "feishu"),
                body: out,
                as: EmptyResponse.self)
            savedC = out
            syncDefaultBotEnabled(on)
        } catch {
            guard !APIError.isCancellation(error) else { return }
            c.enabled = !on
            errorMessage = error.localizedDescription
            showError = true
        }
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
        // Hermes 网页端无启用开关：保存恒传 enabled:true（抓包确认）；
        // 顶层 GroupPolicy 与 bots[0] 的 DmPolicy 空串按网页端口径回退 open
        // （AgentFeishuConfig-UpdateReq required 拒绝空）
        if isHermes {
            out.enabled = true
            if (out.groupPolicy ?? "").isEmpty { out.groupPolicy = "open" }
            if (bot.dmPolicy ?? "").isEmpty { bot.dmPolicy = "open" }
        }
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
            savedBots = out.bots ?? []
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
    /// Hermes：单默认 Bot 表单（网页核对仅 Bot Token/私聊策略/群聊需@机器人）
    @State private var bot = AIChannelTelegramBotItem(accountId: "default", name: "Default", enabled: true, isDefault: true)
    @State private var extraBots: [AIChannelTelegramBotItem] = []
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
            : AIChannelPolicy.dmPoliciesPairingOpen
    }

    /// Hermes：未配置频道启用开关默认开；网页核对无 Bot 列表/群组策略/代理/流式
    private var isHermes: Bool { agentType == "hermes-agent" }
    /// OpenClaw：内置连接器（plugin/check 的 Type oneof 不含本类型，无插件区）；网页核对无群聊需@机器人
    private var isOpenClaw: Bool { agentType == "openclaw" }

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
                Section { LoadingStateView(compact: true) }
            } else if loadError != nil {
                Section {
                    LoadErrorStateView(message: loadError ?? "") {
                        Task { await load() }
                    }
                }
            } else {
                // Telegram 为 OpenClaw 内置连接器：plugin/check 的 Type oneof
                // 校验不含 telegram（400 参数错误，2026-09-16 反馈），无插件区

                Section {
                    // OpenClaw 顶层插件状态开关：切换即提交；服务端把默认 Bot 的
                    // enabled 与顶层 enabled 联动落库，行内默认 Bot 开关镜像顶层开关
                    if isOpenClaw {
                        Toggle(L10n.t("启用"), isOn: Binding(
                            get: { c.enabled ?? false },
                            set: { on in
                                c.enabled = on
                                Task { await toggleTopEnabled(on) }
                            }))
                            .disabled(isSaving)
                    } else if !isHermes {
                        // Hermes 网页端无启用开关（核对隐藏），保存恒传 enabled:true
                        Toggle(L10n.t("启用"), isOn: Binding(
                            get: { c.enabled ?? false }, set: { c.enabled = $0 }))
                    }
                    if isHermes {
                        // Hermes 网页核对：仅 Bot Token / 私聊策略（配队码、开放）/ 群聊需@机器人
                        SecureField(L10n.t("Bot Token"), text: Binding(
                            get: { bot.botToken ?? "" }, set: { bot.botToken = $0 }))
                            .textInputAutocapitalization(.never)
                        ChannelPolicyPicker(title: L10n.t("私聊策略"), options: dmPolicies,
                                             value: Binding(get: { c.dmPolicy ?? "pairing" }, set: { c.dmPolicy = $0 }))
                        Toggle(L10n.t("群聊需@机器人"), isOn: Binding(
                            get: { c.requireMention ?? true }, set: { c.requireMention = $0 }))
                    } else {
                        // OpenClaw 网页核对无群聊需@机器人（仅 Hermes 有）
                        if !isOpenClaw {
                            Toggle(L10n.t("群聊需@机器人"), isOn: Binding(
                                get: { c.requireMention ?? true }, set: { c.requireMention = $0 }))
                        }
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
                }

                if !isHermes {
                    botListSection
                }

                if c.dmPolicy == "pairing" {
                    PairingApproveSection(client: client, agentId: agentId, type: "telegram",
                                          accountId: pairingAccountID)
                }
            }
        }
        .navigationTitle("Telegram")
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
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
        .refreshable { await load() }
        .modifier(HermesChannelDeleteModifier(
            client: client, agentId: agentId, type: "telegram", isEnabled: isHermes))
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $editingBot) { bot in
            AITelegramBotFormSheet(
                bot: bot, isEdit: true, dmOptions: dmPolicies,
                existingAccountIDs: bots.compactMap(\.accountId),
                selfOriginalID: bot.accountId,
                showEnabledToggle: !isOpenClaw) { updated in
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
                existingAccountIDs: bots.compactMap(\.accountId),
                showEnabledToggle: !isOpenClaw) { newBot in
                bots.append(newBot)
            }
        }
    }

    private var botListSection: some View {
        Section {
            ForEach(bots) { bot in
                HStack(spacing: 12) {
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
                                    // OpenClaw 行尾有状态开关；基础类型保持未启用徽标
                                    if !isOpenClaw, bot.enabled != true {
                                        StatusBadge(text: L10n.t("未启用"), color: .secondary)
                                    }
                                }
                                Text(bot.accountId ?? "-")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !isOpenClaw {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // OpenClaw Bot 状态开关：默认 Bot 镜像顶层开关，其余行内即时提交
                    if isOpenClaw {
                        Toggle("", isOn: botEnabledBinding(bot))
                            .labelsHidden()
                            .disabled(isSaving)
                            .accessibilityLabel(L10n.t("启用"))
                    }
                }
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
            if isOpenClaw {
                Text(L10n.t("点击 Bot 编辑凭证与策略；状态开关、删除与设为默认将立即保存。默认 Bot 随顶部启用开关联动"))
            } else {
                Text(L10n.t("点击 Bot 编辑凭证与策略；删除与设为默认将立即保存"))
            }
        }
    }

    /// 行内 Bot 状态开关绑定：默认 Bot 与顶层启用开关联动（显示与提交均镜像
    /// 顶层开关，切换走同一条顶层 update）；其余 Bot 显示取当前列表，
    /// 切换走即时保存（失败由 saveBots 回滚）
    private func botEnabledBinding(_ bot: AIChannelTelegramBotItem) -> Binding<Bool> {
        if bot.id == defaultBotID() {
            return Binding(
                get: { c.enabled ?? false },
                set: { on in
                    c.enabled = on
                    Task { await toggleTopEnabled(on) }
                })
        }
        return Binding(
            get: { bots.first(where: { $0.id == bot.id })?.enabled ?? false },
            set: { on in Task { await toggleBotEnabled(bot, on: on) } }
        )
    }

    /// 默认 Bot：isDefault 标记优先，缺失时回退首个（钉钉服务端不回 isDefault）。
    /// 服务端将其 enabled 与顶层 enabled 联动：顶层关会一并把默认 Bot 持久化为关，
    /// 顶层关时单独开默认 Bot 会被忽略，只有开顶层开关才能把默认 Bot 带开
    private func defaultBotID() -> String? {
        (bots.first(where: { $0.isDefault == true }) ?? bots.first)?.id
    }

    /// 顶层开关保存成功后同步默认 Bot 的本地显示与快照（Telegram 无独立
    /// savedBots，快照在 savedC.bots；对齐服务端联动落库）
    private func syncDefaultBotEnabled(_ on: Bool) {
        guard let id = defaultBotID() else { return }
        for idx in bots.indices where bots[idx].id == id { bots[idx].enabled = on }
        var snapshot = savedC.bots ?? []
        for idx in snapshot.indices where snapshot[idx].id == id { snapshot[idx].enabled = on }
        savedC.bots = snapshot
    }

    /// OpenClaw 非默认 Bot 状态开关即时提交：仅翻转该 Bot 的 enabled（顶层
    /// enabled 不动，抓包确认；默认 Bot 走顶层开关联动），随 saveBots 全量提交并回滚
    private func toggleBotEnabled(_ bot: AIChannelTelegramBotItem, on: Bool) async {
        let updated = bots.map { item -> AIChannelTelegramBotItem in
            var copy = item
            if item.id == bot.id { copy.enabled = on }
            return copy
        }
        await saveBots(updated)
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
        // defaultAccount 必填：快照里为空串时回退默认 Bot，避免保存报参数错误
        if (out.defaultAccount ?? "").isEmpty,
           let first = updated.first(where: { $0.isDefault == true }) ?? updated.first {
            out.defaultAccount = first.accountId
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

    /// OpenClaw 顶层插件状态开关即时提交：基于已保存快照（不含草稿）仅改
    /// enabled；defaultAccount 必填，空时按保存口径回退默认 Bot（抓包确认）。
    /// 成功后同步默认 Bot 的 enabled（服务端随顶层开关联动落库）
    private func toggleTopEnabled(_ on: Bool) async {
        guard !isSaving else { return }
        var out = savedC
        out.agentId = agentId
        out.enabled = on
        if (out.defaultAccount ?? "").isEmpty,
           let first = out.bots?.first(where: { $0.isDefault == true }) ?? out.bots?.first {
            out.defaultAccount = first.accountId
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "telegram"),
                body: out,
                as: EmptyResponse.self)
            savedC = out
            syncDefaultBotEnabled(on)
        } catch {
            guard !APIError.isCancellation(error) else { return }
            c.enabled = !on
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func load() async {
        do {
            let resp: AIChannelTelegram = try await client.send(
                path: APIEndpoint.aiAgentChannelGet.path.replacingOccurrences(of: ":type", with: "telegram"),
                body: AIAgentChannelRequest(agentId: agentId),
                as: AIChannelTelegram.self)
            c = resp
            savedC = resp
            if isHermes {
                bot = resp.bots?.first ?? bot
                extraBots = Array((resp.bots ?? []).dropFirst())
            } else {
                bots = resp.bots ?? []
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
        // Hermes 网页端无启用开关：保存恒传 enabled:true（抓包确认）
        if isHermes {
            out.enabled = true
            // 抓包：顶层与 bots[0] 的 dmPolicy 同值；未配置（get 返回空串）时
            // 按网页端口径回退 open；其余字段回传服务端原值
            bot.dmPolicy = (c.dmPolicy?.isEmpty == false) ? c.dmPolicy : "open"
            out.dmPolicy = (out.dmPolicy?.isEmpty == false) ? out.dmPolicy : "open"
            // 服务端 required 校验拒绝空串：groupPolicy/streaming（表单无这两项
            // 控件，get 未配置返回空）空时按网页端提交值回退 allowlist/partial
            if (out.groupPolicy ?? "").isEmpty { out.groupPolicy = "allowlist" }
            if (out.streaming ?? "").isEmpty { out.streaming = "partial" }
            if (bot.groupPolicy ?? "").isEmpty { bot.groupPolicy = "allowlist" }
            if (bot.streaming ?? "").isEmpty { bot.streaming = "partial" }
            out.bots = [bot] + extraBots
            // 抓包：update 恒传 defaultAccount（get 未配置返回空串），空时回退
            // 默认 Bot 的账户 ID（Hermes 表单即默认 Bot），再兜底 "default"
            if (out.defaultAccount ?? "").isEmpty {
                out.defaultAccount = bot.accountId ?? "default"
            }
        } else {
            out.bots = bots
            // OpenClaw 抓包：defaultAccount 必填（新增 Bot 后直接保存会报参数错误），
            // 空时回退默认 Bot / 首个 Bot 的账户 ID
            if isOpenClaw, (out.defaultAccount ?? "").isEmpty {
                out.defaultAccount = bots.first(where: { $0.isDefault == true })?.accountId
                    ?? bots.first?.accountId ?? ""
            }
        }
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

/// Telegram Bot 新建/编辑表单（名称/账户ID/Token/策略/流式）；
/// 私聊策略选项集随智能体类型由调用方传入，账户 ID 在现有 Bot 内查重；
/// 启用开关仅基础类型显示（草稿随保存提交），OpenClaw 由列表行内开关即时提交
private struct AITelegramBotFormSheet: View {
    @State var bot: AIChannelTelegramBotItem
    let isEdit: Bool
    let dmOptions: [(value: String, label: String)]
    /// 现有 Bot 的账户 ID（查重用）
    var existingAccountIDs: [String] = []
    /// 编辑时的自身原账户 ID（查重排除）
    var selfOriginalID: String? = nil
    /// 是否显示启用开关（OpenClaw 传 false：行内开关即时提交）
    var showEnabledToggle: Bool = true
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
                    if showEnabledToggle {
                        Toggle(L10n.t("启用"), isOn: Binding(
                            get: { bot.enabled ?? true }, set: { bot.enabled = $0 }))
                    }
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
    /// Hermes：单默认 Bot 表单（网页核对仅 Token/私聊策略/群聊需@机器人）
    var agentType: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var c = AIChannelDiscord()
    /// 上次已保存的顶层配置快照（滑动操作立即保存的组装基准，不含未保存草稿）
    @State private var savedC = AIChannelDiscord()
    @State private var bots: [AIChannelDiscordBotItem] = []
    /// Hermes：单默认 Bot 表单
    @State private var bot = AIChannelDiscordBotItem(accountId: "default", name: "Default", enabled: true, isDefault: true)
    @State private var extraBots: [AIChannelDiscordBotItem] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var loadError: String?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var editingBot: AIChannelDiscordBotItem?
    @State private var showAddBot = false
    /// 行内批准配对（Bot 列表滑动操作，私聊策略=配队码时）
    @State private var pairingBot: AIChannelDiscordBotItem?
    @State private var pairingCode = ""
    @State private var isApproving = false

    private let client: APIClient

    /// 私聊策略仅 配队码 / 开放；群组策略 开放 / 禁用（抓包确认，无白名单）
    private var dmPolicies: [(value: String, label: String)] {
        AIChannelPolicy.dmPoliciesPairingOpen
    }

    /// Hermes：未配置频道启用开关默认开；网页核对无 Bot 列表/群组策略/代理
    private var isHermes: Bool { agentType == "hermes-agent" }
    /// OpenClaw：内置连接器（plugin/check 的 Type oneof 不含本类型，无插件区）；网页核对无群聊需@机器人
    private var isOpenClaw: Bool { agentType == "openclaw" }

    /// 批准配对携带的账户：defaultAccount 空串回退默认 Bot
    /// （QwenPaw / OpenClaw 的 Discord approve 抓包均携带 accountId）
    private var pairingAccountID: String? {
        if let id = c.defaultAccount, !id.isEmpty { return id }
        return bots.first(where: { $0.isDefault == true })?.accountId
    }

    init(server: ServerConfig, agentId: Int, agentType: String? = nil) {
        self.server = server
        self.agentId = agentId
        self.agentType = agentType
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        Form {
            if isLoading {
                Section { LoadingStateView(compact: true) }
            } else if loadError != nil {
                Section {
                    LoadErrorStateView(message: loadError ?? "") {
                        Task { await load() }
                    }
                }
            } else {
                // Discord 为 OpenClaw 内置连接器：plugin/check 的 Type oneof
                // 校验不含 discord（400 参数错误，2026-09-16 反馈），无插件区

                Section {
                    // OpenClaw 顶层插件状态开关：切换即提交；服务端把默认 Bot 的
                    // enabled 与顶层 enabled 联动落库，行内默认 Bot 开关镜像顶层开关
                    if isOpenClaw {
                        Toggle(L10n.t("启用"), isOn: Binding(
                            get: { c.enabled ?? false },
                            set: { on in
                                c.enabled = on
                                Task { await toggleTopEnabled(on) }
                            }))
                            .disabled(isSaving)
                    } else if !isHermes {
                        // Hermes 网页端无启用开关（核对隐藏），保存恒传 enabled:true
                        Toggle(L10n.t("启用"), isOn: Binding(
                            get: { c.enabled ?? false }, set: { c.enabled = $0 }))
                    }
                    if isHermes {
                        // Hermes 网页核对：仅 Token / 私聊策略（配队码、开放）/ 群聊需@机器人
                        SecureField("Token", text: Binding(
                            get: { bot.token ?? "" }, set: { bot.token = $0 }))
                            .textInputAutocapitalization(.never)
                        ChannelPolicyPicker(title: L10n.t("私聊策略"), options: dmPolicies,
                                             value: Binding(get: { c.dmPolicy ?? "pairing" }, set: { c.dmPolicy = $0 }))
                        Toggle(L10n.t("群聊需@机器人"), isOn: Binding(
                            get: { c.requireMention ?? true }, set: { c.requireMention = $0 }))
                    } else {
                        // OpenClaw 网页核对无群聊需@机器人（仅 Hermes 有）
                        if !isOpenClaw {
                            Toggle(L10n.t("群聊需@机器人"), isOn: Binding(
                                get: { c.requireMention ?? true }, set: { c.requireMention = $0 }))
                        }
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
                }

                if !isHermes {
                    botListSection
                }

                if c.dmPolicy == "pairing" {
                    PairingApproveSection(client: client, agentId: agentId, type: "discord",
                                          accountId: pairingAccountID)
                }
            }
        }
        .navigationTitle("Discord")
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
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
                selfOriginalID: bot.accountId,
                showEnabledToggle: !isOpenClaw) { updated in
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
                existingAccountIDs: bots.compactMap(\.accountId),
                showEnabledToggle: !isOpenClaw) { newBot in
                bots.append(newBot)
            }
        }
        // 行内批准配对（Bot 列表滑动操作）
        .alert(L10n.t("批准配对"), isPresented: Binding(
            get: { pairingBot != nil },
            set: { if !$0 { pairingBot = nil } }
        )) {
            TextField(L10n.t("配对码"), text: $pairingCode)
                .keyboardType(.numberPad)
            Button(L10n.t("批准配对")) {
                // alert 关闭先于 Task 执行：配对码在 action 内捕获，避免发出空串
                if let bot = pairingBot {
                    let code = pairingCode
                    Task { await approvePairing(bot, code: code) }
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

    private var botListSection: some View {
        Section {
            ForEach(bots) { bot in
                HStack(spacing: 12) {
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
                                    // OpenClaw 行尾有状态开关；基础类型保持未启用徽标
                                    if !isOpenClaw, bot.enabled != true {
                                        StatusBadge(text: L10n.t("未启用"), color: .secondary)
                                    }
                                }
                                Text(bot.accountId ?? "-")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !isOpenClaw {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // OpenClaw Bot 状态开关：默认 Bot 镜像顶层开关，其余行内即时提交
                    if isOpenClaw {
                        Toggle("", isOn: botEnabledBinding(bot))
                            .labelsHidden()
                            .disabled(isSaving)
                            .accessibilityLabel(L10n.t("启用"))
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if (c.dmPolicy ?? "") == "pairing" {
                        Button {
                            pairingBot = bot
                        } label: {
                            Label(L10n.t("批准配对"), systemImage: "link")
                        }
                        .tint(.teal)
                    }
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
            if isOpenClaw {
                Text(L10n.t("点击 Bot 编辑凭证；状态开关、批准配对与删除将立即保存。默认 Bot 随顶部启用开关联动"))
            } else {
                Text(L10n.t("点击 Bot 编辑凭证与状态；批准配对与删除将立即保存"))
            }
        }
    }

    /// 行内 Bot 状态开关绑定：默认 Bot 与顶层启用开关联动（显示与提交均镜像
    /// 顶层开关，切换走同一条顶层 update）；其余 Bot 显示取当前列表，
    /// 切换走即时保存（失败由 saveBots 回滚）
    private func botEnabledBinding(_ bot: AIChannelDiscordBotItem) -> Binding<Bool> {
        if bot.id == defaultBotID() {
            return Binding(
                get: { c.enabled ?? false },
                set: { on in
                    c.enabled = on
                    Task { await toggleTopEnabled(on) }
                })
        }
        return Binding(
            get: { bots.first(where: { $0.id == bot.id })?.enabled ?? false },
            set: { on in Task { await toggleBotEnabled(bot, on: on) } }
        )
    }

    /// 默认 Bot：isDefault 标记优先，缺失时回退首个（钉钉服务端不回 isDefault）。
    /// 服务端将其 enabled 与顶层 enabled 联动：顶层关会一并把默认 Bot 持久化为关，
    /// 顶层关时单独开默认 Bot 会被忽略，只有开顶层开关才能把默认 Bot 带开
    private func defaultBotID() -> String? {
        (bots.first(where: { $0.isDefault == true }) ?? bots.first)?.id
    }

    /// 顶层开关保存成功后同步默认 Bot 的本地显示与快照（Discord 无独立
    /// savedBots，快照在 savedC.bots；对齐服务端联动落库）
    private func syncDefaultBotEnabled(_ on: Bool) {
        guard let id = defaultBotID() else { return }
        for idx in bots.indices where bots[idx].id == id { bots[idx].enabled = on }
        var snapshot = savedC.bots ?? []
        for idx in snapshot.indices where snapshot[idx].id == id { snapshot[idx].enabled = on }
        savedC.bots = snapshot
    }

    /// OpenClaw 非默认 Bot 状态开关即时提交：仅翻转该 Bot 的 enabled（顶层
    /// enabled 不动，抓包确认；默认 Bot 走顶层开关联动），随 saveBots 全量提交并回滚
    private func toggleBotEnabled(_ bot: AIChannelDiscordBotItem, on: Bool) async {
        let updated = bots.map { item -> AIChannelDiscordBotItem in
            var copy = item
            if item.id == bot.id { copy.enabled = on }
            return copy
        }
        await saveBots(updated)
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
        // defaultAccount 必填：快照里为空串时回退默认 Bot，避免保存报参数错误
        if (out.defaultAccount ?? "").isEmpty,
           let first = updated.first(where: { $0.isDefault == true }) ?? updated.first {
            out.defaultAccount = first.accountId
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

    /// 行内批准配对（带该 Bot 的 accountId；配对码由调用方捕获传入）
    private func approvePairing(_ bot: AIChannelDiscordBotItem, code: String) async {
        isApproving = true
        defer { isApproving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelPairingApprove.path,
                body: AIAgentChannelPairingApproveRequest(
                    agentId: agentId, type: "discord",
                    pairingCode: code, accountId: bot.accountId),
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

    /// OpenClaw 顶层插件状态开关即时提交：基于已保存快照（不含草稿）仅改
    /// enabled；defaultAccount 必填，空时按保存口径回退默认 Bot（抓包确认）。
    /// 成功后同步默认 Bot 的 enabled（服务端随顶层开关联动落库）
    private func toggleTopEnabled(_ on: Bool) async {
        guard !isSaving else { return }
        var out = savedC
        out.agentId = agentId
        out.enabled = on
        if (out.defaultAccount ?? "").isEmpty,
           let first = out.bots?.first(where: { $0.isDefault == true }) ?? out.bots?.first {
            out.defaultAccount = first.accountId
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelUpdate.path.replacingOccurrences(of: ":type", with: "discord"),
                body: out,
                as: EmptyResponse.self)
            savedC = out
            syncDefaultBotEnabled(on)
        } catch {
            guard !APIError.isCancellation(error) else { return }
            c.enabled = !on
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func load() async {
        do {
            let resp: AIChannelDiscord = try await client.send(
                path: APIEndpoint.aiAgentChannelGet.path.replacingOccurrences(of: ":type", with: "discord"),
                body: AIAgentChannelRequest(agentId: agentId),
                as: AIChannelDiscord.self)
            c = resp
            savedC = resp
            if isHermes {
                bot = resp.bots?.first ?? bot
                extraBots = Array((resp.bots ?? []).dropFirst())
            } else {
                bots = resp.bots ?? []
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
        // Hermes：无启用开关（保存恒传 enabled:true），单默认 Bot 表单
        //（网页核对无 Bot 列表），其余 bots 原样保留
        if isHermes {
            out.enabled = true
            // 抓包：update 恒传 dmPolicy/defaultAccount/groupPolicy 具体值
            // （get 未配置返回空串，服务端 required 校验拒绝空）；空时回退
            // open / 默认 Bot 账户 ID / allowlist（Discord bot 无 dmPolicy/
            // groupPolicy/streaming 字段，不动 bot）
            if (out.dmPolicy ?? "").isEmpty { out.dmPolicy = "open" }
            if (out.groupPolicy ?? "").isEmpty { out.groupPolicy = "allowlist" }
            if (out.defaultAccount ?? "").isEmpty {
                out.defaultAccount = bot.accountId ?? "default"
            }
            out.bots = [bot] + extraBots
        } else {
            out.bots = bots
            // OpenClaw 抓包：defaultAccount 必填（新增 Bot 后直接保存会报参数错误），
            // 空时回退默认 Bot / 首个 Bot 的账户 ID
            if isOpenClaw, (out.defaultAccount ?? "").isEmpty {
                out.defaultAccount = bots.first(where: { $0.isDefault == true })?.accountId
                    ?? bots.first?.accountId ?? ""
            }
        }
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

/// Discord Bot 新建/编辑表单（名称/账户ID/Token，抓包确认无策略项；账户 ID 查重）；
/// 启用开关仅基础类型显示（草稿随保存提交），OpenClaw 由列表行内开关即时提交
private struct AIDiscordBotFormSheet: View {
    @State var bot: AIChannelDiscordBotItem
    let isEdit: Bool
    /// 现有 Bot 的账户 ID（查重用）
    var existingAccountIDs: [String] = []
    /// 编辑时的自身原账户 ID（查重排除）
    var selfOriginalID: String? = nil
    /// 是否显示启用开关（OpenClaw 传 false：行内开关即时提交）
    var showEnabledToggle: Bool = true
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
                    if showEnabledToggle {
                        Toggle(L10n.t("启用"), isOn: Binding(
                            get: { bot.enabled ?? true }, set: { bot.enabled = $0 }))
                    }
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
