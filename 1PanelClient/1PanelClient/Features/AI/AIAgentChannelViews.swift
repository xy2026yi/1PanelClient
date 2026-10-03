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

/// Bot 行内批准配对输入弹层（长按菜单进入；配对码为自由输入数字，
/// 区别于 TextInputConfirmSheet 的「输入确认文本」场景）。
/// 不用 alert 内嵌输入框：自定义视图会被横向挤压渲染成按钮行，
/// 原生 TextField 在 iOS 26 上同样贴右，改为标准表单 sheet
struct PairingApproveSheet: View {
    /// Bot 显示名（标题下方提示「为 Bot「xx」批准配对」）
    let botName: String
    let onApprove: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L10n.f("为 Bot「%@」批准配对", botName))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    OutlinedTextField(label: L10n.t("配对码"), text: $code, keyboardType: .numberPad)
                } footer: {
                    Text(L10n.t("私聊策略为配队码时，用户发起对话后在对应平台提交配对码，在此批准完成对接"))
                }
            }
            .navigationTitle(L10n.t("批准配对"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard !isSubmitting else { return }
                        isSubmitting = true
                        let pairingCode = code
                        // 先收 sheet 再执行请求：结果提示是 alert，与 sheet 关闭
                        // 同事务并发呈现会偶发丢失（与 ActionBottomSheet 同款时序）
                        let approve = onApprove
                        dismiss()
                        Task { await approve(pairingCode) }
                    } label: {
                        Text(L10n.t("批准配对"))
                    }
                    .disabled(code.isEmpty || isSubmitting)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.medium])
    }
}

/// 配对码批准（私聊策略=配队码时显示；POST channel/pairing/approve）
struct PairingApproveSection: View {    let client: APIClient
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

// MARK: - 频道插件区（OpenClaw 频道为插件：版本 / 升级 / 卸载带进度）

/// 插件任务（安装/升级/卸载提交成功后由页面推入进度页）。
/// 状态由页面持有、navigationDestination 挂在 List 外——挂进 List 行内
/// 会触发 misplaced navigationDestination 警告（未来版本将被忽略），
/// 状态加载同理不能依赖 List 内条件视图上的 .task（条件分支为空时
/// task 可能不执行，微信无频道 GET 兜底曾因此连安装区都不出现）
struct ChannelPluginTask: Identifiable, Hashable {
    let taskID: String
    let title: String
    let isUninstall: Bool
    var id: String { taskID }
}

/// 插件状态两段式查询（页面级 .task 调用，抓包 2026-10-02 确认协议）：
/// checkLatest:false 对已装/未装都可用，先定安装态；未装不再发
/// checkLatest:true（网页端同样确认已装后才发起，未装直发会报错）；
/// 已装再查一次拿最新版本与 upgradable
func loadChannelPluginStatus(client: APIClient, agentId: Int, type: String) async -> AIAgentPluginStatus? {
    guard let base = await checkChannelPlugin(client: client, agentId: agentId, type: type, latest: false) else {
        return nil
    }
    guard base.installed == true else { return base }
    return await checkChannelPlugin(client: client, agentId: agentId, type: type, latest: true) ?? base
}

private func checkChannelPlugin(client: APIClient, agentId: Int, type: String, latest: Bool) async -> AIAgentPluginStatus? {
    do {
        return try await client.send(
            path: APIEndpoint.aiAgentPluginCheck.path,
            body: AIAgentPluginCheckRequest(agentId: agentId, type: type, checkLatest: latest),
            as: AIAgentPluginStatus.self)
    } catch {
        return nil
    }
}

/// 频道页顶部插件信息区（纯渲染：状态由页面加载传入）。
/// 已安装 → 版本/新版本两段描边行（行尾卸载/升级图标）；
/// 未安装 → FTP 未安装页同款居中安装入口（页面门控此时已隐藏全部配置区，
/// 整页仅剩此安装块）
struct ChannelPluginSection: View {
    let client: APIClient
    let agentId: Int
    let type: String
    /// 页面加载的插件状态
    let status: AIAgentPluginStatus?
    /// check 彻底失败时的兜底安装态（频道 GET 的 installed，与列表徽标同源）：
    /// false 时仍渲染安装入口
    var fallbackInstalled: Bool? = nil
    /// 动作请求失败提示（页面 alert 展示）
    var onError: (String) -> Void = { _ in }
    /// 动作提交成功：进度页推入由页面处理
    var onTask: (ChannelPluginTask) -> Void

    @State private var confirmUninstall = false
    @State private var isInstalling = false

    private var kind: AIChannelKind? { AIChannelKind(rawValue: type) }

    var body: some View {
        Group {
            if let s = status, s.installed == true {
                // 无标题分组：版本/新版本作为浮动标签嵌在描边框顶线
                //（OutlinedShape，与表单描边控件同一视觉语言）
                Section {
                    versionRow(
                        label: L10n.t("版本"),
                        version: s.currentVersion ?? "-",
                        actionTitle: L10n.t("卸载插件"),
                        actionIcon: "trash",
                        actionColor: .red
                    ) {
                        confirmUninstall = true
                    }
                    .listRowSeparator(.hidden)

                    if let latest = Self.displayVersion(s.latestVersion),
                       !latest.isEmpty, latest != s.currentVersion {
                        if s.upgradable == true {
                            versionRow(
                                label: L10n.t("新版本"),
                                version: latest,
                                actionTitle: L10n.t("升级插件"),
                                actionIcon: "arrow.up.circle",
                                actionColor: .orange
                            ) {
                                Task { await upgrade() }
                            }
                            .listRowSeparator(.hidden)
                        } else {
                            // 有新版本号但 upgradable 缺失：仅展示版本
                            versionRow(label: L10n.t("新版本"), version: latest,
                                       actionTitle: "", actionIcon: "", actionColor: .accentColor) {}
                                .listRowSeparator(.hidden)
                        }
                    }
                }
            } else if status?.installed == false || fallbackInstalled == false {
                notInstalledBlock
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
    }

    /// 未安装：FTP/数据库未安装页同款居中安装块（无 section 头，整页仅此一块）
    @ViewBuilder
    private var notInstalledBlock: some View {
        if let kind {
            Section {
                VStack(spacing: 20) {
                    IconBadge(systemName: kind.icon, color: kind.iconColor,
                              size: 72, cornerRadius: Radius.large)
                        .opacity(0.5)

                    VStack(spacing: 8) {
                        Text(L10n.f("%@插件未安装", kind.displayName))
                            .font(.headline)
                        Text(L10n.t("安装频道插件后即可配置并使用该频道"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        Task { await install() }
                    } label: {
                        if isInstalling {
                            ProgressView()
                                .tint(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        } else {
                            // List 行环境会把 Label 图标染成 tint 色（蓝底蓝图标
                            // 不可见，FTP 同款按钮不在 List 内故无此问题），
                            // 显式白色前景与 borderedProminent 底色匹配
                            Label(L10n.t("安装插件"), systemImage: "arrow.down.circle.fill")
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isInstalling)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 32)
                .padding(.bottom, 24)
                .listRowBackground(Color.clear)
            }
        }
    }

    /// 版本信息行：描边包裹（浮动标签 版本/新版本 + 版本号 + 行尾动作图标），
    /// 复用表单描边控件的 OutlinedShape（标签跨顶线、背景截断边框）
    private func versionRow(
        label: String,
        version: String,
        actionTitle: String,
        actionIcon: String,
        actionColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        OutlinedShape(label: label, isFocused: false, hasValue: true) {
            if !actionIcon.isEmpty {
                Button(action: action) {
                    Image(systemName: actionIcon)
                        .font(.title3)
                        .foregroundStyle(actionColor)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(actionTitle)
            }
        } content: {
            Text(version)
                .font(.body.monospacedDigit())
        }
    }

    /// latestVersion 为 JSON 数组字符串（抓包："[\"0.8.26\"]"），
    /// 解析取首个版本号展示；解析失败按原样返回
    static func displayVersion(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let versions = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)) {
            return versions.first ?? raw
        }
        return raw
    }

    private func install() async {
        isInstalling = true
        defer { isInstalling = false }
        let taskID = UUID().uuidString
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentPluginInstall.path,
                body: AIAgentPluginInstallRequest(agentId: agentId, type: type, taskID: taskID),
                as: EmptyResponse.self)
            onTask(ChannelPluginTask(taskID: taskID, title: L10n.t("安装插件"), isUninstall: false))
        } catch {
            guard !APIError.isCancellation(error) else { return }
            onError(error.localizedDescription)
        }
    }

    private func upgrade() async {
        let taskID = UUID().uuidString
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentPluginUpgrade.path,
                body: AIAgentPluginUpgradeRequest(agentId: agentId, type: type, taskID: taskID),
                as: EmptyResponse.self)
            onTask(ChannelPluginTask(taskID: taskID, title: L10n.t("升级插件"), isUninstall: false))
        } catch {
            guard !APIError.isCancellation(error) else { return }
            onError(error.localizedDescription)
        }
    }

    private func uninstall() async {
        let taskID = UUID().uuidString
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentPluginUninstall.path,
                body: AIAgentPluginUninstallRequest(agentId: agentId, type: type, taskID: taskID),
                as: EmptyResponse.self)
            onTask(ChannelPluginTask(taskID: taskID, title: L10n.t("卸载插件"), isUninstall: true))
        } catch {
            guard !APIError.isCancellation(error) else { return }
            onError(error.localizedDescription)
        }
    }
}

