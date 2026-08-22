//
//  NodeManageView.swift
//  1PanelClient
//
//  多机管理：节点概览（状态/CPU/内存 + 应用/网站/数据库/计划任务数量）+ 切换 + 日志 + 添加节点
//  基于网页端抓包（logs/多机管理/多机管理-1.md）
//

import SwiftUI

// MARK: - 概览页

struct NodeManageView: View {
    @ObservedObject var manager: ServerManager
    let server: ServerConfig
    /// 共享 ManageTab 的导航栈路径：卡片用 Button 手动 push。
    /// 不用 NavigationLink(value:) —— List 内同行多链接在推送中重渲染时会被全部激活
    /// （点一个卡片把四个页面全叠进栈里），Button + 路径追加没有这个问题
    @Binding var navPath: NavigationPath

    /// 嵌套导航目标（挂在 ManageTab 的 NavigationStack 上，由本页 navigationDestination(for:) 注册）
    enum Dest: Hashable {
        case apps(String)
        case websites(String)
        case databases(String)
        case cronjobs(String)
        case log(String)
        case nodeDetail(Int)
        case upgradeLogs(Int)
        case taskProgress(taskID: String, title: String)
    }

    struct NodeCard: Identifiable {
        let item: NodeListItem
        var current: NodeCurrentItem?
        var counts: NodeCounts?
        var id: Int { item.id }
    }

    @State private var cards: [NodeCard] = []
    @State private var currentNode = "local"
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// 节点列表接口失败（社区版无多机能力）→ 回退为仅本机节点，计数/日志仍可用
    @State private var listFallback = false
    @State private var showAddSheet = false
    /// 加载代际：并发 load 时只让最后一次的结果生效（下拉刷新连点防旧数据覆盖）
    @State private var loadGeneration = 0

    private let client: APIClient

    init(manager: ServerManager, server: ServerConfig, navPath: Binding<NavigationPath>) {
        self.manager = manager
        self.server = server
        self._navPath = navPath
        self.client = APIClient(server: server)
    }

    var body: some View {
        List {
            if listFallback {
                Section {
                    Text(L10n.t("节点列表接口不可用（多机管理为专业版功能），已回退为本机节点。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if isLoading && cards.isEmpty {
                HStack {
                    Spacer()
                    ProgressView(L10n.t("加载中…"))
                    Spacer()
                }
                .frame(minHeight: 200)
                .listRowBackground(Color.clear)
            } else if let errorMessage, cards.isEmpty {
                VStack(spacing: 10) {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(L10n.t("重试")) { Task { await load() } }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
                .listRowBackground(Color.clear)
            } else if cards.isEmpty {
                Text(L10n.t("暂无节点"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(cards) { card in
                    nodeSection(card)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("多机管理"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .refreshable { await load() }
        .task {
            currentNode = NodeScope.current(for: server.id) ?? "local"
            await load()
        }
        .onAppear {
            currentNode = NodeScope.current(for: server.id) ?? "local"
        }
        // 切换节点后刷新「当前」标记
        .onReceive(NotificationCenter.default.publisher(for: NodeScope.changeNotification)) { _ in
            currentNode = NodeScope.current(for: server.id) ?? "local"
        }
        .navigationDestination(for: Dest.self) { dest in
            destination(for: dest)
        }
        .sheet(isPresented: $showAddSheet) {
            AddNodeView(server: server) { taskID in
                navPath.append(Dest.taskProgress(taskID: taskID, title: L10n.t("添加节点")))
            }
            .presentationDetents([.large])
        }
    }

    // MARK: 导航

    /// 卡片按钮已先切换节点再 push，这里只负责构建目标页
    @ViewBuilder
    private func destination(for dest: Dest) -> some View {
        switch dest {
        case .apps:
            AppsTab(manager: manager)
        case .websites:
            WebsitesTab(manager: manager)
        case .databases:
            DatabasesView(server: server)
        case .cronjobs:
            CronjobsTab(manager: manager)
        case .log(let node):
            SystemLogView(server: server, nodeName: node)
        case .nodeDetail(let nodeID):
            NodeDetailView(manager: manager, server: server, nodeID: nodeID, navPath: $navPath) {
                Task { await load() }
            }
        case .upgradeLogs(let nodeID):
            NodeUpgradeLogsView(server: server, nodeID: nodeID)
        case .taskProgress(let taskID, let title):
            // 节点管理任务（添加/编辑/同步）都在主控执行，固定读 local 节点日志
            TaskProgressView(taskID: taskID, title: title, node: "local") { _ in
                if !navPath.isEmpty { navPath.removeLast() }
                Task { await load() }
                return true
            }
        }
    }

    // MARK: 节点卡片

    private func nodeSection(_ card: NodeCard) -> some View {
        Section {
            headerRow(card)
            usageRow(card)
            countsGrid(card)
            actionsRow(card)
        }
    }

    /// 名称 / 地址 / 版本 / 分组 / 状态 / 当前标记（整行点击进入节点详情）
    private func headerRow(_ card: NodeCard) -> some View {
        Button {
            navPath.append(Dest.nodeDetail(card.item.id))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(card.item.displayName)
                        .font(.headline)
                    if card.item.name == currentNode {
                        StatusBadge(text: L10n.t("当前"), color: .blue)
                    }
                    Spacer()
                    StatusBadge(text: NodeUI.statusText(card.current?.status ?? card.item.status),
                                color: NodeUI.statusColor(card.current?.status ?? card.item.status))
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(subtitle(for: card))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func subtitle(for card: NodeCard) -> String {
        var parts = [card.item.name + "." + (card.item.addr ?? "")]
        if let version = card.item.version, !version.isEmpty {
            parts.append(version)
        }
        return parts.joined(separator: " · ")
    }

    /// CPU / 内存使用率（进度条）
    private func usageRow(_ card: NodeCard) -> some View {
        VStack(spacing: 8) {
            usageBar(
                label: L10n.t("CPU 使用率"),
                detail: card.current.map { L10n.f("%ld 核", $0.cpuTotal ?? 0) },
                percent: card.current?.cpuUsedPercent
            )
            usageBar(
                label: L10n.t("内存使用率"),
                detail: card.current.map {
                    ByteCountFormatter.string(fromByteCount: Int64($0.memoryTotal ?? 0), countStyle: .memory)
                },
                percent: card.current?.memoryUsedPercent
            )
        }
        .padding(.vertical, 2)
    }

    private func usageBar(label: String, detail: String?, percent: Double?) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            if let percent {
                ProgressView(value: min(max(percent, 0), 100) / 100)
                    .tint(percentColor(percent))
                Text(String(format: "%.1f%%", percent))
                    .font(.caption.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)
            } else {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func percentColor(_ p: Double) -> Color {
        if p >= 90 { return .red }
        if p >= 70 { return .orange }
        return .green
    }

    /// 应用 / 网站 / 数据库 / 计划任务 数量小卡片（点击进入对应页面，即切换到该节点）
    private func countsGrid(_ card: NodeCard) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                countLink(card, dest: .apps(card.item.name), icon: "app.badge", title: L10n.t("应用"), tint: .blue)
                countLink(card, dest: .websites(card.item.name), icon: "globe", title: L10n.t("网站"), tint: .green)
            }
            HStack(spacing: 8) {
                countLink(card, dest: .databases(card.item.name), icon: "cylinder", title: L10n.t("数据库"), tint: .purple)
                countLink(card, dest: .cronjobs(card.item.name), icon: "clock.badge.checkmark", title: L10n.t("计划任务"), tint: .teal)
            }
        }
        .padding(.vertical, 2)
    }

    private func countLink(_ card: NodeCard, dest: Dest, icon: String, title: String, tint: Color) -> some View {
        // 进入该节点的功能页 = 先切换到该节点（网页端同语义），再 push 对应页面
        Button {
            NodeScope.setCurrent(card.item.name, for: server.id)
            navPath.append(dest)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                Text(countText(card, dest))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func countText(_ card: NodeCard, _ dest: Dest) -> String {
        guard let counts = card.counts else { return "…" }
        switch dest {
        case .apps: return counts.apps.map(String.init) ?? "-"
        case .websites: return counts.websites.map(String.init) ?? "-"
        case .databases: return counts.databases.map(String.init) ?? "-"
        case .cronjobs: return counts.cronjobs.map(String.init) ?? "-"
        default: return "-"
        }
    }

    /// 切换 / 日志
    private func actionsRow(_ card: NodeCard) -> some View {
        HStack(spacing: 12) {
            if card.item.name == currentNode {
                Label(L10n.t("当前节点"), systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
            } else {
                Button {
                    NodeScope.setCurrent(card.item.name, for: server.id)
                } label: {
                    Text(L10n.t("切换"))
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            }

            Button {
                navPath.append(Dest.log(card.item.name))
            } label: {
                Text(L10n.t("日志"))
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
    }

    // MARK: 数据加载

    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        if cards.isEmpty { isLoading = true }
        do {
            let items: [NodeListItem] = try await client.send(
                path: APIEndpoint.nodesList.path,
                body: NodeListRequest(type: "all"),
                as: [NodeListItem].self
            )
            var newCards = items.map { NodeCard(item: $0) }
            // 实时状态（社区版无此接口，失败不阻塞概览）
            if let currents = try? await client.send(
                path: APIEndpoint.nodesCurrent.path,
                method: APIEndpoint.nodesCurrent.method,
                as: [NodeCurrentItem].self
            ) {
                for idx in newCards.indices {
                    newCards[idx].current = currents.first(where: { $0.nodeName == newCards[idx].item.name })
                }
            }
            guard generation == loadGeneration else { return }
            cards = newCards
            listFallback = false
            errorMessage = nil
        } catch APIError.httpError(let code, _) where code == 404 {
            // 社区版没有多机路由：回退为本机节点（计数/日志/按节点路由仍可用）
            guard generation == loadGeneration else { return }
            cards = [NodeCard(item: Self.fallbackLocalItem)]
            listFallback = true
            errorMessage = nil
        } catch {
            // 专业版的网络/认证等错误：无数据时显示重试；已有数据保留下拉前的旧值
            guard generation == loadGeneration else { return }
            if cards.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
        await loadCounts(generation: generation)
    }

    /// 社区版回退用的本机节点条目（地址取当前连接的 Host）
    private static var fallbackLocalItem: NodeListItem {
        let host = URL(string: ServerManager.shared.current?.normalizedBaseURL ?? "")?.host ?? "127.0.0.1"
        return NodeListItem(id: 0, groupID: nil, groupBelong: nil, name: "local", alias: nil,
                            addr: host, status: nil, isOffline: false, version: nil,
                            isXpack: nil, isBound: nil, isAutoUpgrade: nil, isFavorite: nil)
    }

    /// 按节点并行加载四类数量（显式 ?operateNode= 查询参数，不受当前切换影响）
    private func loadCounts(generation: Int) async {
        let nodeNames = cards.map(\.item.name)
        guard !nodeNames.isEmpty else { return }
        let client = self.client
        let results = await withTaskGroup(of: (String, NodeCounts).self) { group in
            for name in nodeNames {
                group.addTask {
                    let counts = await NodeCountsLoader.load(for: name, client: client)
                    return (name, counts)
                }
            }
            var collected: [(String, NodeCounts)] = []
            for await pair in group { collected.append(pair) }
            return collected
        }
        guard generation == loadGeneration else { return }
        for (name, counts) in results {
            if let idx = cards.firstIndex(where: { $0.item.name == name }) {
                cards[idx].counts = counts
            }
        }
    }
}

// MARK: - 数量统计

struct NodeCounts {
    var apps: Int?
    var websites: Int?
    var databases: Int?
    var cronjobs: Int?
}

/// 节点四类资源数量加载（概览页与详情页共用，复用调用方的 APIClient）
enum NodeCountsLoader {
    static func load(for node: String, client: APIClient) async -> NodeCounts {
        let query = [URLQueryItem(name: "operateNode", value: node)]
        var counts = NodeCounts()
        if let r: AppInstalledListResponse = try? await client.send(
            path: APIEndpoint.appsInstalledSearch.path,
            body: AppInstalledSearchRequest(page: 1, pageSize: 1, name: "", type: "", tags: [], update: false, all: false, unused: false, sync: false),
            queryItems: query,
            as: AppInstalledListResponse.self
        ) {
            counts.apps = r.total
        }
        if let r: WebsiteListResponse = try? await client.send(
            path: APIEndpoint.websitesSearch.path,
            body: WebsiteSearchRequest(name: "", page: 1, pageSize: 1, orderBy: "favorite", order: "descending", websiteGroupId: 0, type: ""),
            queryItems: query,
            as: WebsiteListResponse.self
        ) {
            counts.websites = r.total
        }
        if let r: PageResponse<DatabaseItem> = try? await client.send(
            path: APIEndpoint.databasesSearch.path,
            body: DBSearchRequest(page: 1, pageSize: 1, database: "mysql", orderBy: "createdAt", order: "null"),
            queryItems: query,
            as: PageResponse<DatabaseItem>.self
        ) {
            counts.databases = r.total
        }
        if let r: CronjobListResponse = try? await client.send(
            path: APIEndpoint.cronjobsSearch.path,
            body: CronjobSearchRequest(page: 1, pageSize: 1),
            queryItems: query,
            as: CronjobListResponse.self
        ) {
            counts.cronjobs = r.total
        }
        return counts
    }
}
