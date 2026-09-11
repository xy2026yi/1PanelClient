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

    /// 市场来源
    enum SkillSource: String, CaseIterable, Identifiable {
        case official = "official"
        case skillsSh = "skills-sh"

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .official: return L10n.t("官方")
            case .skillsSh: return "skills.sh"
            }
        }
    }

    @State private var mode = 0 // 0 市场 / 1 已安装

    // 市场
    @State private var source: SkillSource = .official
    @State private var keyword = ""
    @State private var marketItems: [AIAgentSkillItem] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var searchError: String?
    @State private var installingSlug: String?

    // 已安装
    @State private var installed: [AIAgentSkillInstalled] = []
    @State private var isLoadingInstalled = true

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
            TaskProgressView(taskID: installTaskID, title: L10n.f("安装技能 %@", installingName)) { isDone in
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

    /// uninstallable=true 为用户安装，false 为内置
    private var installedSkills: [AIAgentSkillInstalled] {
        installed.filter { $0.uninstallable == true }
    }

    private var builtinSkills: [AIAgentSkillInstalled] {
        installed.filter { $0.uninstallable != true }
    }

    @ViewBuilder
    private var installedSection: some View {
        if isLoadingInstalled && installed.isEmpty {
            Section {
                HStack { Spacer(); ProgressView(); Spacer() }
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
            if !installedSkills.isEmpty {
                Section {
                    ForEach(installedSkills) { skill in
                        installedRow(skill, builtin: false)
                    }
                } header: {
                    SectionLabel(
                        title: L10n.f("已安装 · 共 %d 个", installedSkills.count),
                        systemImage: "checkmark.seal"
                    )
                }
            }
            if !builtinSkills.isEmpty {
                Section {
                    ForEach(builtinSkills) { skill in
                        installedRow(skill, builtin: true)
                    }
                } header: {
                    SectionLabel(
                        title: L10n.f("内置 · 共 %d 个", builtinSkills.count),
                        systemImage: "seal"
                    )
                }
            }
        }
    }

    private func installedRow(_ skill: AIAgentSkillInstalled, builtin: Bool) -> some View {
        HStack(spacing: 12) {
            IconBadge(
                systemName: builtin ? "seal.fill" : "checkmark.seal.fill",
                color: builtin ? .secondary : .statusRunning,
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
            if let src = skill.source, !src.isEmpty {
                StatusBadge(text: src, color: .secondary)
            }
        }
        .padding(.vertical, 3)
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
        } catch {
            guard !APIError.isCancellation(error) else { return }
            installed = []
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
