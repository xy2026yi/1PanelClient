//
//  RuntimeDetailView.swift
//  1PanelClient
//
//  运行环境详情：可折叠状态面板（启停/重启，容器详情同构）、基础信息、
//  构建日志；⋯ 菜单承载 PHP 配置入口/删除，Node 模块管理。
//

import SwiftUI

struct RuntimeDetailView: View {
    /// 进入时的快照；展示时优先用 refreshable 拉取的最新对象
    let entry: RuntimeEntry
    let server: ServerConfig
    /// 复用列表 VM（删除流程/任务进度/操作）
    @ObservedObject var listVM: RuntimesViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var current: RuntimeEntry
    @State private var isStatusExpanded = false
    @State private var showTerminal = false
    /// ⋯ 菜单子页路由（PHP 各配置页）
    @State private var menuRoute: RuntimeMenuRoute?
    @State private var isLoadingDetail = false
    /// ⋯ 自绘菜单展开态（替代系统 Menu：弹层动画不进 UIKit 协调器）
    @State private var showMenu = false

    private let client: APIClient

    init(entry: RuntimeEntry, server: ServerConfig, listVM: RuntimesViewModel) {
        self.entry = entry
        self.server = server
        self.listVM = listVM
        self.client = APIClient.shared(for: server)
        _current = State(initialValue: entry)
    }

    private var type: RuntimeType? { current.runtimeType }

    private var statusText: String {
        RuntimeStatusBadge.text(for: current.status)
    }

    /// 行级操作进行中（启停/重启；含过渡态）
    private var isOperating: Bool {
        listVM.operatingIDs.contains(current.id) || current.isTransitional || isLoadingDetail
    }

    var body: some View {
        List {
            statusSection
            infoSection
            actionsSection
            if type == .node { nodeSection }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(current.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .toolbar {
            // ⋯ 菜单仅 PHP 需要（九项配置入口）；删除已移入状态面板操作行
            if type == .php {
                ToolbarItem(placement: .topBarTrailing) {
                    EllipsisMenuButton { showMenu = true }
                }
            }
        }
        // 自绘气泡菜单（EllipsisMenu 全站惯例）：系统 Menu 弹出层为 UIKit 承载，
        // iOS 26 上 position 动画与 SwiftUI 协调器复合触发警告
        .overlay {
            if showMenu {
                EllipsisMenuPopup(entries: menuEntries) { showMenu = false }
            }
        }
        // 终端对齐全站口径用 push（fullScreenCover 无返回按钮；DB/AI/终端模块同款）
        .navigationDestination(isPresented: $showTerminal) {
            TerminalScreen(
                server: server,
                target: .container(
                    containerID: current.containerName,
                    user: type?.terminalUser ?? "root",
                    command: "/bin/bash",
                    cols: 80, rows: 24
                ),
                title: current.displayName
            )
        }
        .toastOverlay(message: $listVM.toastMessage)
        .navigationDestination(item: $menuRoute) { route in
            route.view.navigationTitle(route.title)
        }
        .sheet(item: $listVM.deleteTarget) { target in
            detailDeleteSheet(target)
        }
        .task { await reload() }
    }

    // MARK: - 可折叠状态面板（容器详情同构）

    private var statusSection: some View {
        Section {
            headerRow
            if isStatusExpanded {
                operationsRow
                    .padding(.top, 4)
                    .padding(.bottom, 2)
            }
            if let msg = current.message, !msg.isEmpty {
                Text(msg)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(current.displayName)
                    .font(.body.bold())
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                StatusDot(color: RuntimeStatusBadge.color(for: current.status))
                Text(statusText)
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

    /// 生命周期操作（容器详情同构：CardActionButton 一行；其余操作在 ⋯ 菜单）
    private var operationsRow: some View {
        HStack(spacing: 8) {
            CardActionButton(
                title: current.isRunning ? L10n.t("停止") : L10n.t("启动"),
                icon: current.isRunning ? "stop.fill" : "play.fill",
                color: current.isRunning ? .orange : .green,
                busy: isOperating
            ) {
                Task {
                    await listVM.operate(current, operate: current.isRunning ? "down" : "up")
                    await reload()
                }
            }
            CardActionButton(
                title: L10n.t("重启"),
                icon: "arrow.triangle.2.circlepath",
                color: .blue,
                busy: isOperating
            ) {
                Task {
                    await listVM.operate(current, operate: "restart")
                    await reload()
                }
            }
            CardActionButton(
                title: L10n.t("终端"),
                icon: "terminal",
                color: .accentColor,
                busy: isOperating
            ) {
                showTerminal = true
            }
            CardActionButton(
                title: L10n.t("删除"),
                icon: "trash",
                color: .red,
                busy: isOperating
            ) {
                Task { await listVM.requestDelete(current) }
            }
        }
    }

    /// 下拉/进页刷新单实例（编辑保存、启停后状态随刷新变化）
    private func reload() async {
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        do {
            let path = APIEndpoint.runtimesGet.path
                .replacingOccurrences(of: ":id", with: String(current.id))
            let resp: RuntimeEntry = try await client.send(
                path: path, method: APIEndpoint.runtimesGet.method,
                as: RuntimeEntry.self
            )
            current = resp
        } catch {
            // 静默失败：保留快照，列表下拉可整体重试
        }
    }

    // MARK: - 基础信息

    private var infoSection: some View {
        Section(L10n.t("基础信息")) {
            LabeledContent(L10n.t("类型"), value: type?.displayName ?? (current.type ?? "—"))
            if let version = current.version, !version.isEmpty {
                LabeledContent(L10n.t("版本"), value: version)
            }
            if let port = current.port, !port.isEmpty {
                LabeledContent(L10n.t("端口"), value: port)
            }
            LabeledContent(L10n.t("容器"), value: current.containerName)
            if let image = current.image, !image.isEmpty {
                LabeledContent(L10n.t("镜像"), value: image)
            }
            if let dir = current.codeDir, !dir.isEmpty {
                LabeledContent(L10n.t("运行目录"), value: dir)
            }
            if let source = current.source, !source.isEmpty {
                LabeledContent(L10n.t("来源"), value: source)
            }
            if let path = current.path, !path.isEmpty {
                LabeledContent(L10n.t("路径"), value: path)
            }
            if let created = current.createdAt, !created.isEmpty {
                LabeledContent(L10n.t("创建时间"), value: created.prefix(19).description)
            }
            if let remark = current.remark, !remark.isEmpty {
                LabeledContent(L10n.t("备注"), value: remark)
            }
        }
    }

    // MARK: - 操作

    private var actionsSection: some View {
        Section(L10n.t("操作")) {
            NavigationLink {
                RuntimeRunLogView(entry: current, client: client)
            } label: {
                Label(L10n.t("运行日志"), systemImage: "doc.text.magnifyingglass")
            }
            // 构建日志仅 PHP：服务端对 node/python/go 返回"不支持当前类型"
            if type == .php {
                NavigationLink {
                    RuntimeBuildLogView(entry: current, client: client)
                } label: {
                    Label(L10n.t("构建日志"), systemImage: "doc.text")
                }
            }
        }
    }

    // MARK: - ⋯ 菜单条目（构建时捕获 current：onDismiss 后回读 @State 会取到 nil）

    private var menuEntries: [EllipsisMenuEntry] {
        var entries: [EllipsisMenuEntry] = []
        if type == .php {
            entries.append(contentsOf: [
                .action(title: L10n.t("配置修改"), icon: "slider.horizontal.3") {
                    menuRoute = RuntimeMenuRoute(title: L10n.t("配置修改"),
                        view: AnyView(RuntimePHPSettingsView(entry: current, client: client)))
                },
                .action(title: L10n.t("性能调整"), icon: "gauge") {
                    menuRoute = RuntimeMenuRoute(title: L10n.t("性能调整"),
                        view: AnyView(RuntimePHPFpmTuneView(entry: current, client: client)))
                },
                .action(title: L10n.t("负载状态"), icon: "chart.bar") {
                    menuRoute = RuntimeMenuRoute(title: L10n.t("负载状态"),
                        view: AnyView(RuntimeFPMStatusView(entry: current, client: client)))
                },
                .action(title: L10n.t("慢日志"), icon: "hourglass") {
                    menuRoute = RuntimeMenuRoute(title: L10n.t("慢日志"),
                        view: AnyView(RuntimeSlowLogView(entry: current, client: client)))
                },
                .action(title: "php.ini", icon: "doc.plaintext") {
                    menuRoute = RuntimeMenuRoute(title: "php.ini",
                        view: AnyView(RuntimePHPFileView(entry: current, client: client, fileType: "php")))
                },
                .action(title: "php-fpm.conf", icon: "doc.plaintext") {
                    menuRoute = RuntimeMenuRoute(title: "php-fpm.conf",
                        view: AnyView(RuntimePHPFileView(entry: current, client: client, fileType: "fpm")))
                },
                .action(title: L10n.t("容器配置"), icon: "shippingbox") {
                    menuRoute = RuntimeMenuRoute(title: L10n.t("容器配置"),
                        view: AnyView(RuntimePHPContainerView(entry: current, client: client)))
                },
                .action(title: L10n.t("扩展"), icon: "puzzlepiece") {
                    menuRoute = RuntimeMenuRoute(title: L10n.t("扩展"),
                        view: AnyView(RuntimePHPExtensionsView(entry: current, client: client)))
                },
                .action(title: L10n.t("进程守护"), icon: "gearshape.2") {
                    menuRoute = RuntimeMenuRoute(title: L10n.t("进程守护"),
                        view: AnyView(RuntimeSupervisorView(entry: current, client: client)))
                },
            ])
        }
        // 删除已移入状态面板操作行（⋯ 菜单仅承载 PHP 配置入口）
        return entries
    }

    // MARK: - Node 专属入口

    private var nodeSection: some View {
        Section("Node.js") {
            NavigationLink {
                RuntimeNodeModulesView(entry: current, client: client)
            } label: {
                Label(L10n.t("模块管理"), systemImage: "cube")
            }
            LabeledContent(L10n.t("包管理器"), value: current.packageManager)
        }
    }

    // MARK: - 删除（复用列表 VM 流程；关联资源非空时 requestDelete 直接提示解绑）

    private func detailDeleteSheet(_ target: RuntimeEntry) -> some View {
        TextInputConfirmSheet(
            title: L10n.t("删除运行环境"),
            message: L10n.f("将删除运行环境「%@」及其容器与配置，不可恢复。请输入名称以确认删除。",
                            target.displayName),
            expectedText: target.displayName
        ) {
            await listVM.confirmDelete(target, force: false, deleteImage: false)
            await MainActor.run { if listVM.deleteTarget == nil { dismiss() } }
        }
    }
}

// MARK: - 菜单子页路由

/// ⋯ 菜单 PHP 功能项的推入路由（标题 + 任意目标视图）
struct RuntimeMenuRoute: Identifiable, Hashable {
    let title: String
    let view: AnyView
    var id: String { title }

    static func == (lhs: RuntimeMenuRoute, rhs: RuntimeMenuRoute) -> Bool {
        lhs.title == rhs.title
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(title)
    }
}

// MARK: - 运行日志（容器日志 SSE，按 compose 文件过滤；PHP 为 supervisord 输出）

struct RuntimeRunLogView: View {
    let entry: RuntimeEntry
    let client: APIClient

    @State private var lines: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// 追底去抖任务：流式逐行 append 时合并滚动（容器日志页同款）
    @State private var followDebounce: Task<Void, Never>?

    /// compose 文件路径（运行目录 + docker-compose.yml；面板按此过滤容器日志）
    private var composePath: String? {
        guard let base = entry.path, !base.isEmpty else { return nil }
        return base + "/docker-compose.yml"
    }

    var body: some View {
        Group {
            if let composePath {
                logList(composePath)
            } else {
                ContentUnavailableView(
                    L10n.t("暂无日志"),
                    systemImage: "doc.text",
                    description: Text(L10n.t("无法获取运行目录，暂不能读取日志"))
                )
                .padding(.vertical, 30)
            }
        }
        .navigationTitle(L10n.t("运行日志"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func logList(_ composePath: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if isLoading && lines.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(L10n.t("加载日志…"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.dataMonospacedCaption)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(idx)
                    }
                    if let errorMessage, lines.isEmpty {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentWidthLimit(860)
            }
            .background(Color(.secondarySystemBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadLogs(composePath) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(L10n.t("刷新"))
                }
            }
            .onChange(of: lines.count) { _, count in
                // 追底走 onChange 显式滚动 + 250ms 去抖（容器日志页同款，
                // defaultScrollAnchor 与 LazyVStack 高度估算不合）
                guard count > 0 else { return }
                followDebounce?.cancel()
                followDebounce = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
        .task {
            await loadLogs(composePath)
        }
    }

    private func loadLogs(_ composePath: String) async {
        isLoading = true
        errorMessage = nil
        lines = []
        do {
            isLoading = false
            for try await line in client.streamSSELines(
                path: APIEndpoint.containersSearchLog.path,
                queryItems: [
                    URLQueryItem(name: "compose", value: composePath),
                    URLQueryItem(name: "since", value: "all"),
                    URLQueryItem(name: "tail", value: "100"),
                    URLQueryItem(name: "follow", value: "true"),
                    URLQueryItem(name: "operateNode", value: "local"),
                ]
            ) {
                lines.append(line)
                if lines.count > 2000 {
                    lines.removeFirst(lines.count - 2000)
                }
            }
        } catch {
            isLoading = false
            if lines.isEmpty {
                errorMessage = L10n.f("加载日志失败：%@", error.localizedDescription)
            }
        }
    }
}

// MARK: - 构建日志（/files/read/{type}，末尾追读）

struct RuntimeBuildLogView: View {
    let entry: RuntimeEntry
    let client: APIClient

    @State private var lines: [String] = []
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if isLoading && lines.isEmpty {
                    LoadingStateView(compact: true)
                        .padding(.vertical, 30)
                } else if let err = errorMessage, lines.isEmpty {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                } else if lines.isEmpty {
                    ContentUnavailableView(
                        L10n.t("暂无日志"),
                        systemImage: "doc.text",
                        description: Text(L10n.t("创建或编辑重建后产生构建日志"))
                    )
                    .padding(.vertical, 30)
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding()
        }
        .navigationTitle(L10n.t("构建日志"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    @State private var isLoading = false

    private func load() async {
        isLoading = lines.isEmpty
        errorMessage = nil
        defer { isLoading = false }
        do {
            let resp: RuntimeLogReadResponse = try await client.send(
                path: APIEndpoint.runtimesBuildLog.path
                    .replacingOccurrences(of: ":type", with: entry.type ?? "php"),
                body: RuntimeLogReadRequest(id: entry.id, type: entry.type ?? "php"),
                as: RuntimeLogReadResponse.self
            )
            lines = resp.lines ?? []
        } catch {
            if !APIError.isCancellation(error) {
                errorMessage = error.localizedDescription
            }
        }
    }
}
