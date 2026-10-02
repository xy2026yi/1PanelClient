//
//  AIAgentWecomChannelView.swift
//  1PanelClient
//
//  企业微信频道（自 AIAgentChannelViews.swift 拆出，内容未改动）
//

import SwiftUI

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
    /// 页面级插件状态（List 外 .task 加载，两段式查询）；
    /// check 失败时以频道 GET 的 installed 兜底（与列表徽标同源）
    @State private var pluginStatus: AIAgentPluginStatus?
    /// 频道 GET 的 installed：check 未知时的兜底信号
    @State private var channelInstalled: Bool?
    /// 插件任务进度（List 外 navigationDestination 推入）
    @State private var pluginTask: ChannelPluginTask?
    /// 有效安装态：check 结果优先，GET 兜底；false 时频道页只显示插件安装区
    private var pluginInstalledEffective: Bool? {
        pluginStatus?.installed ?? channelInstalled
    }

    private let client: APIClient

    private var isOpenClaw: Bool { agentType == "openclaw" }
    /// Hermes 网页端频道无启用开关（核对隐藏），保存恒传 enabled:true（抓包确认）
    private var isHermes: Bool { agentType == "hermes-agent" }
    /// 已配置（快照里凭证非空）才显示删除入口；未配置只有保存
    private var isConfigured: Bool {
        !(savedC.botId ?? "").isEmpty || !(savedC.secret ?? "").isEmpty
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
                if isOpenClaw {
                    ChannelPluginSection(
                        client: client, agentId: agentId, type: "wecom",
                        status: pluginStatus,
                        fallbackInstalled: channelInstalled,
                        onError: { errorMessage = $0; showError = true },
                        onTask: { pluginTask = $0 })
                }

                // OpenClaw 插件未安装时只显示安装区（对齐网页端），配置区隐藏；
                // nil=两路信号都未知（check 与 GET 均失败）不吞配置，按原样兜底显示
                if !(isOpenClaw && pluginInstalledEffective == false) {
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
                        OutlinedTextField(label: L10n.t("Bot ID"), text: Binding(
                            get: { c.botId ?? "" }, set: { c.botId = $0 }))
                        OutlinedPasswordField(label: L10n.t("密钥"), text: Binding(
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

                    if (c.dmPolicy ?? "").isEmpty || c.dmPolicy == "pairing" {
                        PairingApproveSection(client: client, agentId: agentId, type: "wecom")
                    }
                }
            }
        }
        .navigationTitle(L10n.t("企业微信"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // 插件未安装时无配置可保存，随配置区一并隐藏
                if !(isOpenClaw && pluginInstalledEffective == false) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                    }
                    .disabled(isLoading || loadError != nil || isSaving)
                }
            }
        }
        .task {
            await load()
            // 插件状态在页面级加载：List 内条件视图上的 .task 可能不执行
            if isOpenClaw {
                pluginStatus = await loadChannelPluginStatus(client: client, agentId: agentId, type: "wecom")
            }
        }
        .refreshable { await load() }
        // 插件任务进度（挂在 List 外，避免 misplaced navigationDestination 警告）；
        // 完成/后台运行均刷新：插件状态重查 + 频道配置重载
        .navigationDestination(item: $pluginTask) { task in
            TaskProgressView(taskID: task.taskID, title: task.title, latest: false, node: "local") { _ in
                Task {
                    pluginStatus = await loadChannelPluginStatus(client: client, agentId: agentId, type: "wecom")
                    await load()
                }
                return false
            }
        }
        .modifier(HermesChannelDeleteModifier(
            client: client, agentId: agentId, type: "wecom",
            isEnabled: isHermes && isConfigured))
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
            if isOpenClaw {
                // 频道 GET 的插件标记（列表徽标同源），驱动未安装时隐藏配置区
                channelInstalled = loaded.installed
            }
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

