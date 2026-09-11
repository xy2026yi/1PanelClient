//
//  AIAgentDetailView.swift
//  1PanelClient
//
//  智能体详情：状态抽屉（启停/重启）+ 基本信息 + 配置入口
//  （频道/模型/技能/设置/日志/绑定网站）+ 删除（先检查绑定资源）
//

import SwiftUI

struct AIAgentDetailView: View {
    let server: ServerConfig
    let agentId: Int
    @ObservedObject var listVM: AIAgentsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var agent: AIAgent?
    @State private var isLoading = true
    @State private var isStatusExpanded = false
    @State private var isOperating = false
    @State private var pendingOperate: String?

    // 配置入口
    @State private var showChannels = false
    @State private var showModelConfig = false
    @State private var showSkills = false
    @State private var showSettings = false
    @State private var showLog = false
    @State private var showWebsiteBind = false

    // 删除
    @State private var showDeleteSheet = false
    @State private var forceDelete = false
    @State private var boundResources: [AIAgentBoundResource] = []
    @State private var showBoundAlert = false
    @State private var showDeleteProgress = false
    @State private var deleteTaskID = ""

    private let client: APIClient

    init(server: ServerConfig, agentId: Int, listVM: AIAgentsViewModel) {
        self.server = server
        self.agentId = agentId
        self.listVM = listVM
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        Group {
            if isLoading && agent == nil {
                LoadingStateView()
            } else if let a = agent {
                detailList(a)
            } else {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } actions: {
                    Button(L10n.t("重试")) { Task { await loadDetail() } }
                }
            }
        }
        .navigationTitle(agent?.name ?? L10n.t("智能体"))
        .navigationBarTitleDisplayMode(.inline)
        .toastOverlay(message: $listVM.toastMessage)
        .task { await loadDetail() }
        .refreshable { await loadDetail() }
        .navigationDestination(isPresented: $showChannels) {
            AIAgentChannelsView(server: server, agentId: agentId, agentName: agent?.name ?? "")
        }
        .navigationDestination(isPresented: $showModelConfig) {
            AIAgentModelConfigView(server: server, agentId: agentId)
        }
        .navigationDestination(isPresented: $showSkills) {
            AIAgentSkillsView(server: server, agentId: agentId, agentName: agent?.name ?? "")
        }
        .navigationDestination(isPresented: $showSettings) {
            AIAgentSettingsView(server: server, agentId: agentId)
        }
        .navigationDestination(isPresented: $showLog) {
            ComposeLogView(
                title: L10n.t("日志"),
                composePath: Self.composePath(for: agent),
                client: client
            )
        }
        .navigationDestination(isPresented: $showWebsiteBind) {
            AIAgentWebsiteBindView(server: server, agentId: agentId, current: agent)
        }
        .navigationDestination(isPresented: $showDeleteProgress) {
            TaskProgressView(taskID: deleteTaskID, title: L10n.f("删除 %@", agent?.name ?? "")) { isDone in
                if isDone {
                    Task {
                        await listVM.load()
                        // 分步收栈：进度页自行 dismiss 后再收详情页
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            dismiss()
                        }
                    }
                }
                return false
            }
        }
        .alert(
            pendingOperate.map { operateDisplayName($0) } ?? "",
            isPresented: Binding(
                get: { pendingOperate != nil },
                set: { if !$0 { pendingOperate = nil } }
            )
        ) {
            Button(L10n.t("取消"), role: .cancel) { pendingOperate = nil }
            Button(L10n.t("确认"), role: .destructive) {
                Haptic.warning()
                let op = pendingOperate
                pendingOperate = nil
                if let op { Task { await operate(op) } }
            }
        } message: {
            if let a = agent, let op = pendingOperate {
                Text(L10n.f("将对智能体「%@」进行 %@ 操作，是否继续？", a.name, operateDisplayName(op)))
            }
        }
        .alert(L10n.t("无法删除"), isPresented: $showBoundAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(boundResourceMessage)
        }
        .sheet(isPresented: $showDeleteSheet) {
            TextInputConfirmSheet(
                title: L10n.t("删除智能体"),
                message: L10n.f("此操作将卸载对应应用与数据，不可恢复。请输入名称「%@」以确认删除。", agent?.name ?? ""),
                expectedText: agent?.name ?? "",
                onConfirm: {
                    guard let a = agent else { return }
                    if let taskID = await listVM.delete(agent: a, forceDelete: forceDelete) {
                        deleteTaskID = taskID
                        showDeleteProgress = true
                    }
                },
                options: {
                    Section(L10n.t("选项")) {
                        Toggle(L10n.t("强制删除"), isOn: $forceDelete)
                    }
                }
            )
        }
    }

    // MARK: - 详情列表

    private func detailList(_ a: AIAgent) -> some View {
        List {
            Section {
                drawerHeaderRow(a)
                if isStatusExpanded {
                    operationsRow(a)
                        .padding(.top, 4)
                        .padding(.bottom, 2)
                }
            }

            Section {
                InfoRow(L10n.t("类型"), value: a.agentType ?? "-")
                InfoRow(L10n.t("应用版本"), value: a.appVersion ?? "-")
                if let remark = a.remark, !remark.isEmpty {
                    InfoRow(L10n.t("备注"), value: remark)
                }
                InfoRow(L10n.t("模型供应商"), value: a.providerName ?? a.provider ?? "-")
                InfoRow(L10n.t("模型"), value: a.model ?? "-", monospaced: true)
                if let container = a.containerName, !container.isEmpty {
                    InfoRow(L10n.t("容器名称"), value: container, monospaced: true)
                }
                if let port = a.webUIPort, port > 0 {
                    InfoRow("WebUI " + L10n.t("端口"), value: String(port), monospaced: true)
                }
                if let path = a.path, !path.isEmpty {
                    InfoRow(L10n.t("安装目录"), value: path, monospaced: true)
                }
                if let message = a.message, !message.isEmpty {
                    InfoRow(L10n.t("消息"), value: message)
                }
                InfoRow(L10n.t("创建时间"), value: a.displayCreatedAt)
            } header: {
                SectionLabel(title: L10n.t("基本信息"), systemImage: "doc.text")
            }

            Section {
                configLink(L10n.t("频道"), icon: "bubble.left.and.bubble.right") { showChannels = true }
                configLink(L10n.t("技能"), icon: "wand.and.stars") { showSkills = true }
                configLink(L10n.t("日志"), icon: "doc.text.magnifyingglass") { showLog = true }
            } header: {
                SectionLabel(title: L10n.t("配置"), systemImage: "slider.horizontal.3")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func configLink(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 状态抽屉

    private var drawerStatusColor: Color {
        switch (agent?.status ?? "").lowercased() {
        case "running": return .statusRunning
        case "installing": return .blue
        case "stopped", "exited": return .statusStopped
        case "error", "failed": return .statusError
        default: return .secondary
        }
    }

    private func drawerHeaderRow(_ a: AIAgent) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(a.name)
                    .font(.body.bold())
                    .lineLimit(1)
                Text(a.agentType ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                StatusDot(color: drawerStatusColor)
                Text(a.status ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                withAnimation(Motion.standard) {
                    isStatusExpanded.toggle()
                }
            } label: {
                Image(systemName: isStatusExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(isOperating)
        }
        .padding(.vertical, 2)
    }

    private func operationsRow(_ a: AIAgent) -> some View {
        // 三列两行：操作（停止/重启/删除）+ 配置入口（模型/设置/绑定网站）
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            CardActionButton(
                title: a.isRunning ? L10n.t("停止") : L10n.t("启动"),
                icon: a.isRunning ? "stop.fill" : "play.fill",
                color: a.isRunning ? .orange : .green,
                busy: isOperating,
                disabled: isOperating
            ) {
                pendingOperate = a.isRunning ? "stop" : "start"
            }
            CardActionButton(
                title: L10n.t("重启"),
                icon: "arrow.triangle.2.circlepath",
                color: .blue,
                busy: isOperating,
                disabled: isOperating
            ) {
                pendingOperate = "restart"
            }
            CardActionButton(
                title: L10n.t("删除"),
                icon: "trash",
                color: .red,
                busy: false,
                disabled: isOperating
            ) {
                Task { await startDelete() }
            }
            CardActionButton(
                title: L10n.t("模型"),
                icon: "brain",
                color: .purple,
                busy: false,
                disabled: false
            ) {
                showModelConfig = true
            }
            CardActionButton(
                title: L10n.t("设置"),
                icon: "gearshape",
                color: .teal,
                busy: false,
                disabled: false
            ) {
                showSettings = true
            }
            CardActionButton(
                title: L10n.t("绑定网站"),
                icon: "globe",
                color: .indigo,
                busy: false,
                disabled: false
            ) {
                showWebsiteBind = true
            }
        }
    }

    // MARK: - 操作

    private func operateDisplayName(_ op: String) -> String {
        switch op {
        case "stop": return L10n.t("停止")
        case "start": return L10n.t("启动")
        case "restart": return L10n.t("重启")
        default: return op
        }
    }

    private func operate(_ op: String) async {
        guard let a = agent else { return }
        isOperating = true
        defer { isOperating = false }
        await listVM.operate(agent: a, operate: op)
        await loadDetail()
    }

    private func loadDetail() async {
        // 后端无单条查询接口：拉列表后按 id 匹配
        if let matched = await findAgent() {
            agent = matched
        }
        isLoading = false
    }

    private func findAgent() async -> AIAgent? {
        do {
            let resp: PageResponse<AIAgent> = try await client.send(
                path: APIEndpoint.aiAgentsSearch.path,
                body: AISearchPageRequest(page: 1, pageSize: 200),
                as: PageResponse<AIAgent>.self)
            return (resp.items ?? []).first { $0.id == agentId }
        } catch {
            return nil
        }
    }

    // MARK: - 删除

    private func startDelete() async {
        guard let a = agent else { return }
        let resources = await listVM.checkDelete(agentId: a.id)
        if resources.isEmpty {
            forceDelete = false
            showDeleteSheet = true
        } else {
            boundResources = resources
            showBoundAlert = true
        }
    }

    private var boundResourceMessage: String {
        let list = boundResources
            .map { "\($0.name ?? "-")（\($0.type ?? "-")）" }
            .joined(separator: "\n")
        return L10n.f("该智能体已绑定以下资源，需先解绑后才能删除：\n%@", list)
    }

    /// compose 路径（容器日志用）
    static func composePath(for agent: AIAgent?) -> String {
        var p = agent?.path ?? ""
        if !p.hasSuffix("/") { p += "/" }
        return p + "docker-compose.yml"
    }
}

// MARK: - 绑定 / 解绑网站

/// 网站下拉选择 → POST /agents/website/bind；已绑定时提供解绑
struct AIAgentWebsiteBindView: View {
    let server: ServerConfig
    let agentId: Int
    let current: AIAgent?

    @Environment(\.dismiss) private var dismiss
    @State private var websites: [Website] = []
    @State private var selectedWebsiteId: Int?
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var showError = false

    private let client: APIClient

    init(server: ServerConfig, agentId: Int, current: AIAgent?) {
        self.server = server
        self.agentId = agentId
        self.current = current
        self.client = APIClient.shared(for: server)
    }

    private var isBound: Bool { (current?.websiteId ?? 0) > 0 }

    var body: some View {
        Form {
            if isBound {
                Section {
                    InfoRow(L10n.t("已绑定网站"), value: current?.websitePrimaryDomain ?? "-")
                    InfoRow(L10n.t("网站类型"), value: current?.websiteType ?? "-")
                    InfoRow(L10n.t("协议"), value: current?.websiteProtocol ?? "-")
                } header: {
                    SectionLabel(title: L10n.t("当前绑定"), systemImage: "link")
                }
                Section {
                    Button(role: .destructive) {
                        Task { await unbind() }
                    } label: {
                        HStack {
                            if isSubmitting { ProgressView() }
                            Text(L10n.t("解绑网站"))
                        }
                    }
                    .disabled(isSubmitting)
                } footer: {
                    Text(L10n.t("解绑后智能体将不再通过该网站对外提供服务"))
                }
            } else {
                Section {
                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else if let err = loadError {
                        LoadErrorStateView(message: err) {
                            Task { await loadWebsites() }
                        }
                    } else if websites.isEmpty {
                        Text(L10n.t("暂无可用网站，请先创建网站"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(L10n.t("网站"), selection: $selectedWebsiteId) {
                            ForEach(websites) { site in
                                Text(site.displayName).tag(Optional(site.id))
                            }
                        }
                    }
                } header: {
                    SectionLabel(title: L10n.t("绑定网站"), systemImage: "link")
                } footer: {
                    Text(L10n.t("绑定后可通过该网站域名访问智能体"))
                }

                Section {
                    Button {
                        Task { await bind() }
                    } label: {
                        HStack {
                            if isSubmitting { ProgressView() }
                            Text(L10n.t("绑定"))
                        }
                    }
                    .disabled(selectedWebsiteId == nil || isSubmitting)
                }
            }
        }
        .navigationTitle(L10n.t("绑定网站"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadWebsites() }
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    private func loadWebsites() async {
        do {
            let resp: WebsiteListResponse = try await client.send(
                path: APIEndpoint.websitesSearch.path,
                body: WebsiteSearchRequest(name: "", page: 1, pageSize: 200, orderBy: "created_at", order: "null", websiteGroupId: 0, type: ""),
                as: WebsiteListResponse.self)
            websites = resp.items ?? []
            selectedWebsiteId = websites.first?.id
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func bind() async {
        guard let websiteId = selectedWebsiteId else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentWebsiteBind.path,
                body: AIAgentWebsiteBindRequest(agentId: agentId, websiteId: websiteId),
                as: EmptyResponse.self)
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            actionError = error.localizedDescription
            showError = true
        }
    }

    private func unbind() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentWebsiteUnbind.path,
                body: AIAgentWebsiteUnbindRequest(agentId: agentId),
                as: EmptyResponse.self)
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            actionError = error.localizedDescription
            showError = true
        }
    }
}
