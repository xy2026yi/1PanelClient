//
//  AIAgentFeishuChannelView.swift
//  1PanelClient
//
//  飞书频道（OpenClaw 多 Bot）（自 AIAgentChannelViews.swift 拆出，内容未改动）
//

import SwiftUI

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
                    OutlinedPicker(label: L10n.t("群聊需@机器人"),
                                   options: mentionModes.map(\.value),
                                   selection: Binding(
                                       get: {
                                           let v = c.requireMention ?? ""
                                           return mentionModes.contains(where: { $0.value == v }) ? v : "true"
                                       },
                                       set: { c.requireMention = $0 }),
                                   optionLabels: Dictionary(uniqueKeysWithValues:
                                       mentionModes.map { ($0.value, $0.label) }))
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
                    OutlinedTextField(label: "App ID", text: Binding(
                        get: { bot.appId ?? "" }, set: { bot.appId = $0 }))
                    OutlinedPasswordField(label: "App Secret", text: Binding(
                        get: { bot.appSecret ?? "" }, set: { bot.appSecret = $0 }))
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
            OutlinedTextField(label: L10n.t("配对码"), text: $pairingCode, keyboardType: .numberPad)
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
                    OutlinedTextField(label: L10n.t("名称"), text: Binding(
                        get: { bot.name ?? "" }, set: { bot.name = $0 }))
                    OutlinedTextField(label: L10n.t("账户 ID"), text: Binding(
                        get: { bot.accountId ?? "" }, set: { bot.accountId = $0 }))
                        .disabled(lockAccountID)
                    OutlinedTextField(label: "App ID", text: Binding(
                        get: { bot.appId ?? "" }, set: { bot.appId = $0 }))
                    OutlinedPasswordField(label: "App Secret", text: Binding(
                        get: { bot.appSecret ?? "" }, set: { bot.appSecret = $0 }))
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

