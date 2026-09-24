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

/// 策略选择（选项集按频道传入：pairing / open / allowlist / disabled），描边菜单（形态 2）。
/// get 可能返回空串/未知值（如钉钉 groupPolicy:""）：不在选项集内时折叠到首个选项，
/// 避免空 selection 告警与空白行（提交仍走 state，用户不改动即保持折叠值）
struct ChannelPolicyPicker: View {
    let title: String
    let options: [(value: String, label: String)]
    @Binding var value: String

    var body: some View {
        OutlinedPicker(label: title,
                       options: options.map(\.value),
                       selection: Binding(
                           get: {
                               options.contains(where: { $0.value == value })
                                   ? value : (options.first?.value ?? value)
                           },
                           set: { value = $0 }
                       ),
                       optionLabels: Dictionary(uniqueKeysWithValues:
                           options.map { ($0.value, $0.label) }))
    }
}

/// Hermes 频道删除（toolbar trash + 确认弹窗 + POST channel/delete {agentId,type}）。
/// 成功后 dismiss，频道列表 onAppear 会重拉状态对齐徽标（抓包 2026-09-15）
struct HermesChannelDeleteModifier: ViewModifier {
    let client: APIClient
    let agentId: Int
    /// 频道类型（qqbot / wecom / dingtalk / feishu / telegram / discord）
    let type: String
    /// false 时不显示删除入口：非 Hermes 智能体不挂删除；
    /// Hermes 也须已配置（凭证非空）才显示——未配置的频道只有保存
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

/// 白名单编辑（策略=白名单时显示，一行一个；设置页 allowedOrigins 复用），
/// 形态 7.1 多行描边框
struct WhitelistEditor: View {
    let title: String
    @Binding var list: [String]

    var body: some View {
        OutlinedMultiLineField(label: title, prompt: "example.com", text: Binding(
            get: { list.joined(separator: "\n") },
            set: { raw in
                // 保留空行（含键入行尾换行产生的尾部空行）：丢弃会让回写内容
                // 与输入框当前文本不一致，任何重渲染都会把换行吞掉，
                // 表现为无法换行输入。空行原样进提交，与网页端 textarea 行为一致
                let items = raw.split(
                    omittingEmptySubsequences: false,
                    whereSeparator: \.isNewline
                ).map(String.init)
                if items != list { list = items }
            }
        ))
    }
}

/// 配对码批准（私聊策略=配队码时显示；POST channel/pairing/approve）
struct PairingApproveSection: View {
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
            OutlinedTextField(label: L10n.t("配对码"), text: $pairingCode, keyboardType: .numberPad)
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

