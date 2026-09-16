//
//  AIAgentPluginsView.swift
//  1PanelClient
//
//  OpenClaw 智能体插件（/api/v2/ai/agents/plugins/*，与频道插件是两套端点）：
//  已安装（启停带任务进度）+ 插件市场（搜索 / 安装带进度）
//

import SwiftUI

struct AIAgentPluginsView: View {
    let server: ServerConfig
    let agentId: Int

    private enum Segment: String, CaseIterable, Identifiable {
        case installed
        case market
        var id: String { rawValue }
    }

    @State private var segment: Segment = .installed
    @State private var installed: [AIAgentPluginInfo] = []
    @State private var isLoadingInstalled = true
    @State private var installedError: String?

    // 市场
    @State private var keyword = ""
    @State private var results: [AIAgentMarketPlugin] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var searchError: String?

    // 进度（启停 / 安装共用）
    @State private var progressTaskID = ""
    @State private var progressTitle = ""
    @State private var showProgress = false
    /// 操作中的插件 id（行级 spinner，其余行仅禁用）
    @State private var operatingPluginID: String?
    /// 卸载确认弹窗挂起的插件
    @State private var pendingUninstall: AIAgentPluginInfo?

    @State private var toastMessage: String?
    @State private var errorMessage: String?
    @State private var showError = false

    private let client: APIClient

    init(server: ServerConfig, agentId: Int) {
        self.server = server
        self.agentId = agentId
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $segment) {
                Text(L10n.t("已安装")).tag(Segment.installed)
                Text(L10n.t("插件市场")).tag(Segment.market)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            List {
                switch segment {
                case .installed: installedSection
                case .market: marketSection
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle(L10n.t("插件"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadInstalled() }
        .refreshable { await loadInstalled() }
        .toastOverlay(message: $toastMessage)
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(
            L10n.t("卸载插件"),
            isPresented: Binding(
                get: { pendingUninstall != nil },
                set: { if !$0 { pendingUninstall = nil } }
            )
        ) {
            Button(L10n.t("取消"), role: .cancel) { pendingUninstall = nil }
            Button(L10n.t("卸载"), role: .destructive) {
                guard let plugin = pendingUninstall else { return }
                pendingUninstall = nil
                Task { await operatePlugin(plugin, operate: "uninstall") }
            }
        } message: {
            Text(L10n.f("确定卸载插件「%@」？", pendingUninstall?.name ?? pendingUninstall?.id ?? ""))
        }
        .navigationDestination(isPresented: $showProgress) {
            TaskProgressView(taskID: progressTaskID, title: progressTitle, latest: false, node: "local") { _ in
                // 完成 or 用户选后台运行：都刷新（后台运行后版本/启停状态仍会变化）
                Task { await loadInstalled() }
                return false
            }
        }
    }

    // MARK: 已安装

    @ViewBuilder
    private var installedSection: some View {
        Section {
            if isLoadingInstalled {
                HStack { Spacer(); LoadingStateView(); Spacer() }
                    .listRowBackground(Color.clear)
            } else if let err = installedError {
                LoadErrorStateView(message: err) {
                    Task { await loadInstalled() }
                }
                .listRowBackground(Color.clear)
            } else if installed.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无插件"),
                    systemImage: "puzzlepiece",
                    description: Text(L10n.t("切换到「插件市场」搜索并安装"))
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(installed) { plugin in
                    HStack(spacing: 12) {
                        IconBadge(
                            systemName: plugin.enabled == true ? "puzzlepiece.extension.fill" : "puzzlepiece.extension",
                            color: plugin.enabled == true ? .green : .secondary
                        )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(plugin.name ?? plugin.id)
                                .font(.body.bold())
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                if let version = plugin.version, !version.isEmpty {
                                    Text("v\(version)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let origin = plugin.origin, !origin.isEmpty {
                                    StatusBadge(text: originDisplay(origin), color: .secondary)
                                }
                            }
                        }
                        Spacer()
                        if operatingPluginID == plugin.id {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Toggle("", isOn: Binding(
                                get: { plugin.enabled ?? false },
                                set: { on in
                                    Task { await operate(plugin, enabled: on) }
                                }
                            ))
                            .labelsHidden()
                            .disabled(operatingPluginID != nil)
                        }
                    }
                    .padding(.vertical, 3)
                    // 升级/卸载（plugins/operate，抓包确认）：仅 origin=global 的插件可操作，
                    // bundled 内置不可卸载/升级
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if plugin.origin == "global" {
                            Button(role: .destructive) {
                                pendingUninstall = plugin
                            } label: {
                                Label(L10n.t("卸载"), systemImage: "trash")
                            }
                            Button {
                                Task { await operatePlugin(plugin, operate: "update") }
                            } label: {
                                Label(L10n.t("升级"), systemImage: "arrow.up.circle")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
        } header: {
            SectionLabel(title: L10n.f("已安装 · 共 %d 个", installed.count), systemImage: "checkmark.seal")
        } footer: {
            Text(L10n.t("启停将重启智能体，进度见任务页"))
        }
    }

    private func originDisplay(_ origin: String) -> String {
        switch origin {
        case "bundled": return L10n.t("内置")
        case "global": return L10n.t("全局")
        default: return origin
        }
    }

    // MARK: 插件市场

    @ViewBuilder
    private var marketSection: some View {
        Section {
            HStack(spacing: 10) {
                TextField(L10n.t("搜索插件，如 mem"), text: $keyword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await search() } }
                Button {
                    Task { await search() }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .disabled(isSearching)
            }

            if isSearching && results.isEmpty {
                HStack { Spacer(); LoadingStateView(); Spacer() }
                    .listRowBackground(Color.clear)
            } else if let err = searchError, results.isEmpty {
                LoadErrorStateView(message: err) {
                    Task { await search() }
                }
                .listRowBackground(Color.clear)
            } else if hasSearched, results.isEmpty {
                ContentUnavailableView(
                    L10n.t("无搜索结果"),
                    systemImage: "magnifyingglass",
                    description: Text(L10n.t("换个关键词试试"))
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(results) { plugin in
                    marketRow(plugin)
                }
            }
        } footer: {
            if !results.isEmpty {
                Text(L10n.f("共 %d 个结果", results.count))
            }
        }
    }

    private func marketRow(_ plugin: AIAgentMarketPlugin) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "shippingbox", color: .indigo)
            VStack(alignment: .leading, spacing: 3) {
                Text(plugin.name ?? plugin.package)
                    .font(.body.bold())
                    .lineLimit(1)
                if let desc = plugin.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    if let version = plugin.version, !version.isEmpty {
                        Text("v\(version)")
                    }
                    if plugin.official == true {
                        StatusBadge(text: L10n.t("官方"), color: .blue)
                    }
                    if let downloads = plugin.downloads, downloads > 0 {
                        Label(downloads.formatted(.number.notation(.compactName).locale(L10n.locale)), systemImage: "arrow.down.circle")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer()

            Button {
                Task { await install(plugin) }
            } label: {
                if operatingPluginID == plugin.id {
                    ProgressView()
                } else {
                    Text(L10n.t("安装"))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(operatingPluginID != nil)
        }
        .padding(.vertical, 3)
    }

    // MARK: 数据与操作

    private func loadInstalled() async {
        isLoadingInstalled = true
        defer { isLoadingInstalled = false }
        do {
            installed = try await client.send(
                path: APIEndpoint.aiAgentPluginsList.path,
                body: AIAgentModelRequest(agentId: agentId),
                as: [AIAgentPluginInfo].self)
            installedError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            installedError = error.localizedDescription
        }
    }

    private func search() async {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        isSearching = true
        hasSearched = true
        defer { isSearching = false }
        do {
            results = try await client.send(
                path: APIEndpoint.aiAgentPluginsSearch.path,
                body: AIAgentPluginsSearchRequest(agentId: agentId, keyword: kw, limit: 20),
                as: [AIAgentMarketPlugin].self)
            searchError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            results = []
            searchError = error.localizedDescription
        }
    }

    /// 启停插件（operate enable/disable，任务进度）
    private func operate(_ plugin: AIAgentPluginInfo, enabled: Bool) async {
        await operatePlugin(plugin, operate: enabled ? "enable" : "disable",
                            titleVerb: enabled ? L10n.t("启用") : L10n.t("禁用"))
    }

    /// 插件操作（plugins/operate：enable/disable/update/uninstall，任务进度）
    private func operatePlugin(_ plugin: AIAgentPluginInfo, operate: String,
                               titleVerb: String? = nil) async {
        // 进度页在栈期间不再受理新操作（推送字段会被覆盖、旧进度页轮询错位）
        guard !showProgress, operatingPluginID == nil else { return }
        operatingPluginID = plugin.id
        defer { operatingPluginID = nil }
        let taskID = UUID().uuidString
        // 标题：启停沿用「启用/禁用插件 x」；升级/卸载用任务日志同款动词
        let title: String
        if let titleVerb {
            title = L10n.f("%@插件 %@", titleVerb, plugin.name ?? plugin.id)
        } else {
            title = L10n.f(operate == "update" ? "更新插件 %@" : "卸载插件 %@",
                           plugin.name ?? plugin.id)
        }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentPluginsOperate.path,
                body: AIAgentPluginsOperateRequest(
                    agentId: agentId, pluginId: plugin.id,
                    operate: operate, taskID: taskID),
                as: EmptyResponse.self)
            progressTaskID = taskID
            progressTitle = title
            showProgress = true
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// 市场插件安装（带版本）
    private func install(_ plugin: AIAgentMarketPlugin) async {
        guard !showProgress, operatingPluginID == nil else { return }
        operatingPluginID = plugin.id
        defer { operatingPluginID = nil }
        let taskID = UUID().uuidString
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentPluginsInstall.path,
                body: AIAgentPluginsInstallRequest(
                    agentId: agentId, package: plugin.package,
                    version: plugin.version ?? "", taskID: taskID),
                as: EmptyResponse.self)
            progressTaskID = taskID
            progressTitle = L10n.f("安装插件 %@", plugin.name ?? plugin.package)
            showProgress = true
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
