//
//  AIAgentSkillsView.swift
//  1PanelClient
//
//  智能体 · 技能（/api/v2/ai/agents/skills）：
//  技能市场（来源 + 关键词搜索 + 安装进度）/ 已安装列表（分组 + 启停 + 卸载）。
//  来源与已安装分组按智能体类型区分：
//  - Hermes：official/skills-sh；已安装按 source 分 builtin 内置 / official 已安装（可卸载）
//  - OpenClaw：clawhub 中国/全球 + SkillHub 腾讯；已安装按 source 前缀分组
//

import SwiftUI

struct AIAgentSkillsView: View {
    let server: ServerConfig
    let agentId: Int
    let agentName: String
    /// hermes-agent / openclaw / copaw（来源与分组按类型区分）
    var agentType: String? = nil

    /// 市场来源：Hermes 抓包确认 official / skills-sh；
    /// OpenClaw 抓包确认 clawhub 中国/全球 + SkillHub 腾讯
    enum SkillSource: String, Identifiable {
        case official
        case skillsSh = "skills-sh"
        case clawhubCN = "clawhub-cn"
        case clawhubGlobal = "clawhub-global"
        case skillhub

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .official: return L10n.t("官方")
            case .skillsSh: return "skills.sh"
            case .clawhubCN: return "Clawhub（" + L10n.t("中国") + "）"
            case .clawhubGlobal: return "Clawhub（" + L10n.t("全球") + "）"
            case .skillhub: return "SkillHub（" + L10n.t("腾讯") + "）"
            }
        }

        /// 按智能体类型给出可选来源（互不混用）
        static func sources(for agentType: String?) -> [SkillSource] {
            agentType == "hermes-agent"
                ? [.official, .skillsSh]
                : [.clawhubCN, .clawhubGlobal, .skillhub]
        }
    }

    /// Hermes 专属（对话/技能来源抓包均按该类型区分）
    private var isHermes: Bool { agentType == "hermes-agent" }

    @State private var mode = 0 // 0 市场 / 1 已安装

    // 市场
    @State private var source: SkillSource = .clawhubCN
    @State private var keyword = ""
    @State private var marketItems: [AIAgentSkillItem] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var searchError: String?
    @State private var installingSlug: String?

    // 已安装
    @State private var installed: [AIAgentSkillInstalled] = []
    @State private var isLoadingInstalled = true
    /// 已安装列表加载失败（与「真无技能」区分，提供重试）
    @State private var installedLoadFailed = false
    @State private var installedLoadError: String?
    /// 启停操作中的技能名（行级防抖）
    @State private var updatingSkillNames: Set<String> = []
    /// 卸载确认弹窗挂起的技能 + 卸载中的技能名（Hermes，uninstallable 才显示）
    @State private var pendingUninstall: AIAgentSkillInstalled?
    @State private var uninstallingName: String?

    // 安装进度
    @State private var showProgress = false
    @State private var installTaskID = ""
    @State private var installingName = ""

    @State private var toastMessage: String?

    private let client: APIClient

    init(server: ServerConfig, agentId: Int, agentName: String, agentType: String? = nil) {
        self.server = server
        self.agentId = agentId
        self.agentName = agentName
        self.agentType = agentType
        self.client = APIClient.shared(for: server)
        // Hermes 默认官方来源（抓包默认项），其余保持 clawhub 中国
        _source = State(initialValue: agentType == "hermes-agent" ? .official : .clawhubCN)
    }

    var body: some View {
        List {
            Section {
                Picker(L10n.t("视图"), selection: $mode) {
                    Text(L10n.t("技能市场")).tag(0)
                    Text(L10n.t("已安装")).tag(1)
                }
                .pickerStyle(.segmented)
                .segmentedPickerRow()
                .onChange(of: mode) { _, newValue in
                    if newValue == 1 {
                        Task { await loadInstalled() }
                    }
                }
            }

            if mode == 0 {
                marketSection
            } else {
                installedSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("技能"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await search() }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel(L10n.t("搜索"))
            }
        }
        .toastOverlay(message: $toastMessage)
        .alert(
            L10n.t("卸载技能"),
            isPresented: Binding(
                get: { pendingUninstall != nil },
                set: { if !$0 { pendingUninstall = nil } }
            )
        ) {
            Button(L10n.t("取消"), role: .cancel) { pendingUninstall = nil }
            Button(L10n.t("卸载"), role: .destructive) {
                guard let skill = pendingUninstall else { return }
                pendingUninstall = nil
                Task { await uninstall(skill) }
            }
        } message: {
            Text(L10n.f("确定卸载技能「%@」？", pendingUninstall?.name ?? "-"))
        }
        .refreshable {
            if mode == 1 {
                await loadInstalled()
            } else if hasSearched {
                // 未搜索过不触发请求（避免空关键词误查询）
                await search()
            }
        }
        .navigationDestination(isPresented: $showProgress) {
            // 任务日志按 taskID 从头读（latest=false，operateNode=local），对齐网页端抓包
            TaskProgressView(taskID: installTaskID, title: L10n.f("安装技能 %@", installingName),
                             latest: false, node: "local") { isDone in
                if isDone {
                    Task { await loadInstalled() }
                }
                return false
            }
        }
    }

    // MARK: - 技能市场

    @ViewBuilder
    private var marketSection: some View {
        Section {
            Picker(L10n.t("来源"), selection: $source) {
                ForEach(SkillSource.sources(for: agentType)) { s in
                    Text(s.displayName).tag(s)
                }
            }
            .onChange(of: source) { _, _ in
                if hasSearched {
                    Task { await search() }
                }
            }

            FormTextField(label: L10n.t("输入关键词搜索"), text: $keyword)
                .onSubmit { Task { await search() } }
        } header: {
            SectionLabel(title: L10n.t("技能市场"), systemImage: "storefront")
        }

        Section {
            if isSearching && marketItems.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
                .listRowBackground(Color.clear)
            } else if let err = searchError, marketItems.isEmpty {
                LoadErrorStateView(message: err) {
                    Task { await search() }
                }
                .listRowBackground(Color.clear)
            } else if marketItems.isEmpty {
                ContentUnavailableView(
                    hasSearched ? L10n.t("未找到技能") : L10n.t("搜索技能"),
                    systemImage: "wand.and.stars",
                    description: Text(hasSearched ? L10n.t("尝试其他关键词或来源") : L10n.t("输入关键词后在技能市场搜索"))
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(marketItems) { item in
                    skillMarketRow(item)
                }
            }
        }
    }

    private func skillMarketRow(_ item: AIAgentSkillItem) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "wand.and.stars", color: .purple, size: 38, cornerRadius: 9)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name ?? item.slug ?? "-")
                    .font(.body.bold())
                    .lineLimit(1)
                if let desc = item.description ?? item.summary, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let slug = item.slug, !slug.isEmpty {
                    Text(slug)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                Task { await install(item) }
            } label: {
                if installingSlug == item.slug {
                    ProgressView()
                } else {
                    Text(L10n.t("安装"))
                        .font(.caption.bold())
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(installingSlug != nil)
        }
        .padding(.vertical, 3)
    }

    // MARK: - 已安装

    /// 已安装分组：
    /// - Hermes（抓包确认）：source=official 已安装（可卸载，显示在前）/
    ///   builtin 内置（不可卸载）；无启用/停用开关（网页核对）
    /// - OpenClaw（抓包确认）：按 source 前缀 openclaw-bundled 内置 / extra 扩展 / managed 外部
    /// - 旧值/未知归其他
    private var groupedInstalled: [(title: String, icon: String, items: [AIAgentSkillInstalled])] {
        let groups: [(match: String, byPrefix: Bool, title: String, icon: String)]
        if isHermes {
            groups = [
                ("official", false, L10n.t("已安装"), "arrow.down.circle.fill"),
                ("builtin", false, L10n.t("内置"), "seal.fill"),
            ]
        } else {
            // OpenClaw（网页核对）：外部 → 扩展 → 内置 依次展示
            groups = [
                ("openclaw-managed", true, L10n.t("外部技能"), "shippingbox.fill"),
                ("openclaw-extra", true, L10n.t("扩展技能"), "arrow.down.circle.fill"),
                ("openclaw-bundled", true, L10n.t("内置技能"), "seal.fill"),
            ]
        }
        var result: [(String, String, [AIAgentSkillInstalled])] = []
        for group in groups {
            let items = installed.filter { skill in
                guard let s = skill.source, !s.isEmpty else { return false }
                return group.byPrefix ? s.hasPrefix(group.match) : s == group.match
            }
            if !items.isEmpty {
                result.append((group.title, group.icon, items))
            }
        }
        let others = installed.filter { item in
            guard let s = item.source, !s.isEmpty else { return true }
            return !groups.contains { group in
                group.byPrefix ? s.hasPrefix(group.match) : s == group.match
            }
        }
        if !others.isEmpty {
            result.append((L10n.t("其他"), "circle.grid.cross", others))
        }
        return result
    }

    @ViewBuilder
    private var installedSection: some View {
        if isLoadingInstalled && installed.isEmpty {
            Section {
                HStack { Spacer(); ProgressView(); Spacer() }
                .listRowBackground(Color.clear)
            }
        } else if installedLoadFailed {
            Section {
                LoadErrorStateView(message: installedLoadError ?? "") {
                    Task { await loadInstalled() }
                }
                .listRowBackground(Color.clear)
            }
        } else if installed.isEmpty {
            Section {
                ContentUnavailableView(
                    L10n.t("暂无已安装技能"),
                    systemImage: "checkmark.seal",
                    description: Text(L10n.t("在技能市场搜索并安装技能"))
                )
                .listRowBackground(Color.clear)
            }
        } else {
            ForEach(Array(groupedInstalled.enumerated()), id: \.offset) { _, group in
                Section {
                    ForEach(group.items) { skill in
                        installedRow(skill, icon: group.icon)
                    }
                } header: {
                    SectionLabel(
                        title: L10n.f("%@ · 共 %d 个", group.title, group.items.count),
                        systemImage: group.icon
                    )
                }
            }
        }
    }

    private func installedRow(_ skill: AIAgentSkillInstalled, icon: String) -> some View {
        HStack(spacing: 12) {
            IconBadge(
                systemName: skill.disabled == true ? "moon.zzz.fill" : icon,
                color: skill.disabled == true ? .secondary : .statusRunning,
                size: 38,
                cornerRadius: 9
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(skill.name ?? "-")
                    .font(.body.bold())
                    .lineLimit(1)
                if let desc = skill.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if skill.disabled == true {
                StatusBadge(text: L10n.t("已禁用"), color: .secondary)
            }
            // 卸载（skills/uninstall，Hermes 抓包确认）：仅 uninstallable 的技能显示
            if isHermes && skill.uninstallable == true {
                Button {
                    pendingUninstall = skill
                } label: {
                    if uninstallingName == skill.name {
                        ProgressView()
                    } else {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(uninstallingName != nil)
                .accessibilityLabel(L10n.t("卸载"))
            }
            // 启用/禁用（skills/update，抓包确认；内置技能同样可禁用）。
            // Hermes 网页端无此开关（核对移除）。
            // 行级防抖：操作中的行禁用，防止并发 update + 交错 reload 导致开关回跳
            if !isHermes {
                Toggle("", isOn: Binding(
                    get: { skill.disabled != true },
                    set: { on in
                        Task { await setSkillEnabled(skill, enabled: on) }
                    }
                ))
                .labelsHidden()
                .disabled(!updatingSkillNames.isEmpty)
            }
        }
        .padding(.vertical, 3)
    }

    /// 启用/禁用技能
    private func setSkillEnabled(_ skill: AIAgentSkillInstalled, enabled: Bool) async {
        guard let name = skill.name, !name.isEmpty,
              !updatingSkillNames.contains(name) else { return }
        updatingSkillNames.insert(name)
        defer { updatingSkillNames.remove(name) }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentSkillUpdate.path,
                body: AIAgentSkillUpdateRequest(agentId: agentId, name: name, enabled: enabled),
                as: EmptyResponse.self)
            await loadInstalled()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            toastMessage = L10n.f("操作失败：%@", error.localizedDescription)
        }
    }

    /// 卸载技能（skills/uninstall，同步返回；成功后刷新已安装列表）
    private func uninstall(_ skill: AIAgentSkillInstalled) async {
        guard let name = skill.name, !name.isEmpty else { return }
        uninstallingName = name
        defer { uninstallingName = nil }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentSkillsUninstall.path,
                body: AIAgentSkillUninstallRequest(agentId: agentId, name: name),
                as: EmptyResponse.self)
            await loadInstalled()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            toastMessage = L10n.f("卸载失败：%@", error.localizedDescription)
        }
    }

    // MARK: - 数据

    private func search() async {
        isSearching = true
        hasSearched = true
        defer { isSearching = false }
        do {
            marketItems = try await client.send(
                path: APIEndpoint.aiAgentSkillsSearch.path,
                body: AIAgentSkillSearchRequest(agentId: agentId, source: source.rawValue, keyword: keyword),
                as: [AIAgentSkillItem].self)
            searchError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            marketItems = []
            searchError = error.localizedDescription
        }
    }

    private func loadInstalled() async {
        isLoadingInstalled = true
        defer { isLoadingInstalled = false }
        do {
            installed = try await client.send(
                path: APIEndpoint.aiAgentSkillsList.path,
                body: AIAgentModelRequest(agentId: agentId),
                as: [AIAgentSkillInstalled].self)
            installedLoadFailed = false
            installedLoadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            installed = []
            installedLoadFailed = true
            installedLoadError = error.localizedDescription
        }
    }

    private func install(_ item: AIAgentSkillItem) async {
        guard let slug = item.slug ?? item.identifier else { return }
        installingSlug = slug
        defer { installingSlug = nil }
        let taskID = UUID().uuidString
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentSkillsInstall.path,
                body: AIAgentSkillInstallRequest(agentId: agentId, source: source.rawValue, slug: slug, taskID: taskID),
                as: EmptyResponse.self)
            installingName = item.name ?? slug
            installTaskID = taskID
            showProgress = true
        } catch {
            guard !APIError.isCancellation(error) else { return }
            toastMessage = L10n.f("安装失败：%@", error.localizedDescription)
        }
    }
}
