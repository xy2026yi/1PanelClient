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
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if type == .php { phpMenuItems }
                    Button(role: .destructive) {
                        Task { await listVM.requestDelete(current) }
                    } label: {
                        Label(L10n.t("删除"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .fullScreenCover(isPresented: $showTerminal) {
            NavigationStack {
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
                RuntimeBuildLogView(entry: current, client: client)
            } label: {
                Label(L10n.t("构建日志"), systemImage: "doc.text")
            }
        }
    }

    // MARK: - PHP 专属入口（⋯ 菜单）

    @ViewBuilder private var phpMenuItems: some View {
        menuLink(L10n.t("配置修改"), "slider.horizontal.3") {
            RuntimePHPSettingsView(entry: current, client: client)
        }
        menuLink(L10n.t("性能调整"), "gauge") {
            RuntimePHPFpmTuneView(entry: current, client: client)
        }
        menuLink(L10n.t("负载状态"), "chart.bar") {
            RuntimeFPMStatusView(entry: current, client: client)
        }
        menuLink(L10n.t("慢日志"), "hourglass") {
            RuntimeSlowLogView(entry: current, client: client)
        }
        menuLink("php.ini", "doc.plaintext") {
            RuntimePHPFileView(entry: current, client: client, fileType: "php")
        }
        menuLink("php-fpm.conf", "doc.plaintext") {
            RuntimePHPFileView(entry: current, client: client, fileType: "fpm")
        }
        menuLink(L10n.t("容器配置"), "shippingbox") {
            RuntimePHPContainerView(entry: current, client: client)
        }
        menuLink(L10n.t("扩展"), "puzzlepiece") {
            RuntimePHPExtensionsView(entry: current, client: client)
        }
        menuLink(L10n.t("进程守护"), "gearshape.2") {
            RuntimeSupervisorView(entry: current, client: client)
        }
    }

    /// 菜单项 → 点按经菜单路由状态推入子页
    private func menuLink<Destination: View>(_ title: String, _ icon: String,
                                             @ViewBuilder destination: @escaping () -> Destination) -> some View {
        Button {
            menuRoute = RuntimeMenuRoute(title: title, view: AnyView(destination()))
        } label: {
            Label(title, systemImage: icon)
        }
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

    // MARK: - 删除（复用列表 VM 流程）

    private func detailDeleteSheet(_ target: RuntimeEntry) -> some View {
        TextInputConfirmSheet(
            title: L10n.t("删除运行环境"),
            message: deleteMessage(target),
            expectedText: target.displayName
        ) {
            await listVM.confirmDelete(target, force: false, deleteImage: false)
            await MainActor.run { if listVM.deleteTarget == nil { dismiss() } }
        }
    }

    private func deleteMessage(_ target: RuntimeEntry) -> String {
        if listVM.deleteBlockers.isEmpty {
            return L10n.f("将删除运行环境「%@」及其容器与配置，不可恢复。请输入名称以确认删除。",
                          target.displayName)
        }
        let names = listVM.deleteBlockers
            .map { "\($0.type ?? ""): \($0.name ?? "")" }
            .joined(separator: "、")
        return L10n.f("以下资源仍在使用该运行环境：%@，删除后相关网站将不可用。请输入名称以确认删除。", names)
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
                } else if let err = errorMessage {
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
