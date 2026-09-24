//
//  AIAgentTelegramChannelView.swift
//  1PanelClient
//
//  Telegram 频道（完整策略 + 多 Bot）（自 AIAgentChannelViews.swift 拆出，内容未改动）
//

import SwiftUI

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
    /// 已配置（快照里任一 Bot Token 非空）才显示删除入口；未配置只有保存
    private var isConfigured: Bool {
        (savedC.bots ?? []).contains { !($0.botToken ?? "").isEmpty }
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
                        OutlinedPasswordField(label: L10n.t("Bot Token"), text: Binding(
                            get: { bot.botToken ?? "" }, set: { bot.botToken = $0 }))
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
                        OutlinedTextField(label: L10n.t("代理服务器"), text: Binding(
                            get: { c.proxy ?? "" }, set: { c.proxy = $0 }))
                            .keyboardType(.URL)
                        OutlinedPicker(label: L10n.t("流式传输"),
                                       options: AIChannelStreaming.options.map(\.value),
                                       selection: Binding(
                                           get: { let v = c.streaming ?? ""; return v.isEmpty ? "partial" : v },
                                           set: { c.streaming = $0 }),
                                       optionLabels: Dictionary(uniqueKeysWithValues:
                                           AIChannelStreaming.options.map { ($0.value, $0.label) }))
                    }
                }

                if !isHermes {
                    botListSection
                }

                if (c.dmPolicy ?? "").isEmpty || c.dmPolicy == "pairing" {
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
            client: client, agentId: agentId, type: "telegram",
            isEnabled: isHermes && isConfigured))
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
                    OutlinedTextField(label: L10n.t("名称"), text: Binding(
                        get: { bot.name ?? "" }, set: { bot.name = $0 }))
                    OutlinedTextField(label: L10n.t("账户 ID"), text: Binding(
                        get: { bot.accountId ?? "" }, set: { bot.accountId = $0 }))
                    if showEnabledToggle {
                        Toggle(L10n.t("启用"), isOn: Binding(
                            get: { bot.enabled ?? true }, set: { bot.enabled = $0 }))
                    }
                    OutlinedPasswordField(label: L10n.t("Bot Token"), text: Binding(
                        get: { bot.botToken ?? "" }, set: { bot.botToken = $0 }))
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
                    OutlinedPicker(label: L10n.t("流式传输"),
                                   options: AIChannelStreaming.options.map(\.value),
                                   selection: Binding(
                                       get: { let v = bot.streaming ?? ""; return v.isEmpty ? "partial" : v },
                                       set: { bot.streaming = $0 }),
                                   optionLabels: Dictionary(uniqueKeysWithValues:
                                       AIChannelStreaming.options.map { ($0.value, $0.label) }))
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

