//
//  AIAgentSkillsView.swift
//  1PanelClient
//
//  智能体 · 技能（/api/v2/ai/agents/skills）：
//  技能市场（官方 / skills.sh 来源 + 关键词搜索 + 安装进度）/ 已安装列表
//

import SwiftUI

struct AIAgentSkillsView: View {
    let server: ServerConfig
    let agentId: Int
    let agentName: String

    /// 市场来源（OpenClaw 抓包确认：clawhub 中国/全球 + SkillHub 腾讯）
    enum SkillSource: String, CaseIterable, Identifiable {
        case clawhubCN = "clawhub-cn"
        case clawhubGlobal = "clawhub-global"
        case skillhub = "skillhub"

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .clawhubCN: return "Clawhub（" + L10n.t("中国") + "）"
            case .clawhubGlobal: return "Clawhub（" + L10n.t("全球") + "）"
            case .skillhub: return "SkillHub（" + L10n.t("腾讯") + "）"
            }
        }
    }

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

    // 安装进度
    @State private var showProgress = false
    @State private var installTaskID = ""
    @State private var installingName = ""

    @State private var toastMessage: String?

    private let client: APIClient

    init(server: ServerConfig, agentId: Int, agentName: String) {
        self.server = server
        self.agentId = agentId
        self.agentName = agentName
        self.client = APIClient.shared(for: server)
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
                ForEach(SkillSource.allCases) { s in
                    Text(s.displayName).tag(s)
                }
            }
            .onChange(of: source) { _, _ in
                if hasSearched {
                    Task { await search() }
                }
            }

            TextField(L10n.t("输入关键词搜索"), text: $keyword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
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

    /// 按 source 前缀分组（抓包确认）：openclaw-bundled 内置 /
    /// openclaw-extra 扩展 / openclaw-managed 外部；旧值/未知归其他
    private var groupedInstalled: [(title: String, icon: String, items: [AIAgentSkillInstalled])] {
        let groups: [(prefix: String, title: String, icon: String)] = [
            ("openclaw-bundled", L10n.t("内置技能"), "seal.fill"),
            ("openclaw-extra", L10n.t("扩展技能"), "arrow.down.circle.fill"),
            ("openclaw-managed", L10n.t("外部技能"), "shippingbox.fill"),
        ]
        var result: [(String, String, [AIAgentSkillInstalled])] = []
        for group in groups {
            let items = installed.filter { ($0.source ?? "").hasPrefix(group.prefix) }
            if !items.isEmpty {
                result.append((group.title, group.icon, items))
            }
        }
        let known = Set(groups.map(\.prefix))
        let others = installed.filter { item in
            guard let s = item.source, !s.isEmpty else { return true }
            return !known.contains(where: { s.hasPrefix($0) })
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
            // 启用/禁用（skills/update，抓包确认；内置技能同样可禁用）
            Toggle("", isOn: Binding(
                get: { skill.disabled != true },
                set: { on in
                    Task { await setSkillEnabled(skill, enabled: on) }
                }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 3)
    }

    /// 启用/禁用技能
    private func setSkillEnabled(_ skill: AIAgentSkillInstalled, enabled: Bool) async {
        guard let name = skill.name, !name.isEmpty else { return }
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
