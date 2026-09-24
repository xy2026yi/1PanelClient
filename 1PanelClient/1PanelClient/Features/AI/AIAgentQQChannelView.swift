//
//  AIAgentQQChannelView.swift
//  1PanelClient
//
//  QQ 频道（含 Bot 表单 Sheet）（自 AIAgentChannelViews.swift 拆出，内容未改动）
//

import SwiftUI

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
    /// 已配置（快照里任一 Bot 凭证非空）才显示删除入口；未配置只有保存
    private var isConfigured: Bool {
        (savedC.bots ?? []).contains {
            !($0.appId ?? "").isEmpty || !($0.clientSecret ?? "").isEmpty
        }
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
                    OutlinedTextField(label: "App ID", text: Binding(
                        get: { bot.appId ?? "" }, set: { bot.appId = $0 }))
                    OutlinedPasswordField(label: "App Secret", text: Binding(
                        get: { bot.clientSecret ?? "" }, set: { bot.clientSecret = $0 }))
                    ChannelPolicyPicker(title: L10n.t("私聊策略"), options: AIChannelPolicy.dmPoliciesBasic,
                                         value: Binding(get: { c.dmPolicy ?? "pairing" }, set: { c.dmPolicy = $0 }))
                    ChannelPolicyPicker(title: L10n.t("群组策略"), options: AIChannelPolicy.groupPoliciesBasic,
                                         value: Binding(get: { c.groupPolicy ?? "open" }, set: { c.groupPolicy = $0 }))
                } footer: {
                    Text(L10n.t("保存后智能体即可在 QQ 平台对话"))
                }

                if (c.dmPolicy ?? "").isEmpty || c.dmPolicy == "pairing" {
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
            client: client, agentId: agentId, type: "qqbot",
            isEnabled: isHermes && isConfigured))
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
                    OutlinedTextField(label: L10n.t("名称"), text: Binding(
                        get: { bot.name ?? "" }, set: { bot.name = $0 }))
                    OutlinedTextField(label: L10n.t("账户 ID"), text: Binding(
                        get: { bot.accountId ?? "" }, set: { bot.accountId = $0 }))
                        .disabled(lockAccountID)
                    OutlinedTextField(label: "App ID", text: Binding(
                        get: { bot.appId ?? "" }, set: { bot.appId = $0 }))
                    OutlinedPasswordField(label: "App Secret", text: Binding(
                        get: { bot.clientSecret ?? "" }, set: { bot.clientSecret = $0 }))
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
                    OutlinedMultiLineField(label: L10n.t("系统提示词"), text: Binding(
                        get: { bot.systemPrompt ?? "" },
                        set: { bot.systemPrompt = $0 }))
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

