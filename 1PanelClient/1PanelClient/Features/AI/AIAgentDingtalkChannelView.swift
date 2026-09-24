//
//  AIAgentDingtalkChannelView.swift
//  1PanelClient
//
//  钉钉频道（OpenClaw 多 Bot）（自 AIAgentChannelViews.swift 拆出，内容未改动）
//

import SwiftUI

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
    /// 已配置（快照里任一 Bot 凭证非空）才显示删除入口；未配置只有保存
    private var isConfigured: Bool {
        (savedC.bots ?? []).contains {
            !($0.clientId ?? "").isEmpty || !($0.clientSecret ?? "").isEmpty
        }
    }

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
                    OutlinedTextField(label: "Client ID", text: Binding(
                        get: { bot.clientId ?? "" }, set: { bot.clientId = $0 }))
                    OutlinedPasswordField(label: "Client Secret", text: Binding(
                        get: { bot.clientSecret ?? "" }, set: { bot.clientSecret = $0 }))
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

                if (c.dmPolicy ?? "").isEmpty || c.dmPolicy == "pairing" {
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
            client: client, agentId: agentId, type: "dingtalk",
            isEnabled: isHermes && isConfigured))
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
            OutlinedPicker(label: L10n.t("群会话范围"),
                           options: groupScopes.map(\.value),
                           selection: Binding(
                               get: {
                                   let v = c.groupSessionScope ?? ""
                                   return groupScopes.contains(where: { $0.value == v }) ? v : "group_sender"
                               },
                               set: { c.groupSessionScope = $0 }),
                           optionLabels: Dictionary(uniqueKeysWithValues:
                               groupScopes.map { ($0.value, $0.label) }))
            Toggle(L10n.t("跨会话共享记忆"), isOn: Binding(
                get: { c.sharedMemoryAcrossConversations ?? false },
                set: { c.sharedMemoryAcrossConversations = $0 }))
            Toggle(L10n.t("异步模式"), isOn: Binding(
                get: { c.asyncMode ?? false }, set: { c.asyncMode = $0 }))
            if c.asyncMode == true {
                OutlinedTextField(label: L10n.t("确认消息"), text: Binding(
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
            OutlinedTextField(label: L10n.t("异步回执文案"), text: Binding(
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
                    OutlinedTextField(label: L10n.t("账户 ID"), text: Binding(
                        get: { bot.accountId ?? "" },
                        set: { raw in
                            bot.accountId = raw
                            bot.name = raw
                        }))
                    OutlinedTextField(label: "Client ID", text: Binding(
                        get: { bot.clientId ?? "" }, set: { bot.clientId = $0 }))
                    OutlinedPasswordField(label: "Client Secret", text: Binding(
                        get: { bot.clientSecret ?? "" }, set: { bot.clientSecret = $0 }))
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

