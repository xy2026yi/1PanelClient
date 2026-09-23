//
//  AIAgentDiscordChannelView.swift
//  1PanelClient
//
//  Discord 频道（多 Bot 管理）（自 AIAgentChannelViews.swift 拆出，内容未改动）
//

import SwiftUI

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
                        OutlinedPasswordField(label: "Token", text: Binding(
                            get: { bot.token ?? "" }, set: { bot.token = $0 }))
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
                        OutlinedTextField(label: L10n.t("代理服务器"), text: Binding(
                            get: { c.proxy ?? "" }, set: { c.proxy = $0 }))
                            .keyboardType(.URL)
                    }
                }

                if !isHermes {
                    botListSection
                }

                if (c.dmPolicy ?? "").isEmpty || c.dmPolicy == "pairing" {
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
                    OutlinedTextField(label: L10n.t("名称"), text: Binding(
                        get: { bot.name ?? "" }, set: { bot.name = $0 }))
                    OutlinedTextField(label: L10n.t("账户 ID"), text: Binding(
                        get: { bot.accountId ?? "" }, set: { bot.accountId = $0 }))
                    if showEnabledToggle {
                        Toggle(L10n.t("启用"), isOn: Binding(
                            get: { bot.enabled ?? true }, set: { bot.enabled = $0 }))
                    }
                    OutlinedPasswordField(label: "Token", text: Binding(
                        get: { bot.token ?? "" }, set: { bot.token = $0 }))
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
