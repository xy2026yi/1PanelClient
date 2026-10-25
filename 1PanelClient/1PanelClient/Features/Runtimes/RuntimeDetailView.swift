//
//  RuntimeDetailView.swift
//  1PanelClient
//
//  运行环境详情：基础信息、启停/编辑/删除、构建日志、容器终端，
//  及类型专属入口（PHP 配置/扩展/进程守护，Node 模块管理）。
//

import SwiftUI

struct RuntimeDetailView: View {
    /// 列表传入的条目（列表数据刷新时父视图重建本页）
    let entry: RuntimeEntry
    let server: ServerConfig
    /// 复用列表 VM（删除流程/任务进度/刷新）
    @ObservedObject var listVM: RuntimesViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var showTerminal = false
    @State private var showStatusDrawer = false
    /// ⋯ 菜单子页路由（PHP 各配置页）
    @State private var menuRoute: RuntimeMenuRoute?

    private let client: APIClient

    init(entry: RuntimeEntry, server: ServerConfig, listVM: RuntimesViewModel) {
        self.entry = entry
        self.server = server
        self.listVM = listVM
        self.client = APIClient.shared(for: server)
    }

    private var type: RuntimeType? { entry.runtimeType }

    var body: some View {
        List {
            statusSection
            infoSection
            actionsSection
            if type == .node { nodeSection }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(entry.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if type == .php { phpMenuItems }
                    Button(role: .destructive) {
                        Task { await listVM.requestDelete(entry) }
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
                        containerID: entry.containerName,
                        user: type?.terminalUser ?? "root",
                        command: "/bin/bash",
                        cols: 80, rows: 24
                    ),
                    title: entry.displayName
                )
            }
        }
        // 状态抽屉（启停/重启/终端；操作 toast 经列表 VM）
        .sheet(isPresented: $showStatusDrawer) { statusDrawerSheet }
        .toastOverlay(message: $listVM.toastMessage)
        .navigationDestination(item: $menuRoute) { route in
            route.view.navigationTitle(route.title)
        }
        .sheet(item: $listVM.deleteTarget) { target in
            detailDeleteSheet(target)
        }
    }

    // MARK: - 状态抽屉（状态行点击展开：启停/重启/终端）

    private var statusSection: some View {
        Section {
            Button {
                showStatusDrawer = true
            } label: {
                HStack(spacing: 12) {
                    RuntimeStatusBadge(status: entry.status)
                    if listVM.operatingIDs.contains(entry.id) || entry.isTransitional {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let msg = entry.message, !msg.isEmpty {
                Text(msg)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    /// 状态抽屉：状态标题 + 启停/重启/终端（操作反馈经列表 VM toast）
    private var statusDrawerSheet: some View {
        ActionBottomSheet(
            title: L10n.f("状态：%@",
                          RuntimeStatusBadge.text(for: entry.status)),
            items: drawerItems,
            onDismiss: { showStatusDrawer = false }
        )
        .presentationDetents([.medium])
    }

    private var drawerItems: [ActionMenuItem] {
        var items: [ActionMenuItem] = []
        if entry.isRunning {
            items.append(ActionMenuItem(title: L10n.t("停止"), icon: "stop") {
                Task { await listVM.operate(entry, operate: "down") }
            })
            items.append(ActionMenuItem(title: L10n.t("重启"),
                                        icon: "arrow.triangle.2.circlepath") {
                Task { await listVM.operate(entry, operate: "restart") }
            })
        } else {
            items.append(ActionMenuItem(title: L10n.t("启动"), icon: "play") {
                Task { await listVM.operate(entry, operate: "up") }
            })
        }
        items.append(ActionMenuItem(title: L10n.t("终端"), icon: "terminal") {
            showTerminal = true
        })
        return items
    }

    // MARK: - 基础信息

    private var infoSection: some View {
        Section(L10n.t("基础信息")) {
            LabeledContent(L10n.t("类型"), value: type?.displayName ?? (entry.type ?? "—"))
            if let version = entry.version, !version.isEmpty {
                LabeledContent(L10n.t("版本"), value: version)
            }
            if let port = entry.port, !port.isEmpty {
                LabeledContent(L10n.t("端口"), value: port)
            }
            LabeledContent(L10n.t("容器"), value: entry.containerName)
            if let image = entry.image, !image.isEmpty {
                LabeledContent(L10n.t("镜像"), value: image)
            }
            if let dir = entry.codeDir, !dir.isEmpty {
                LabeledContent(L10n.t("运行目录"), value: dir)
            }
            if let source = entry.source, !source.isEmpty {
                LabeledContent(L10n.t("来源"), value: source)
            }
            if let path = entry.path, !path.isEmpty {
                LabeledContent(L10n.t("路径"), value: path)
            }
            if let created = entry.createdAt, !created.isEmpty {
                LabeledContent(L10n.t("创建时间"), value: created.prefix(19).description)
            }
            if let remark = entry.remark, !remark.isEmpty {
                LabeledContent(L10n.t("备注"), value: remark)
            }
        }
    }

    // MARK: - 操作

    private var actionsSection: some View {
        Section(L10n.t("操作")) {
            NavigationLink {
                RuntimeBuildLogView(entry: entry, client: client)
            } label: {
                Label(L10n.t("构建日志"), systemImage: "doc.text")
            }
        }
    }

    // MARK: - PHP 专属入口（⋯ 菜单）

    @ViewBuilder private var phpMenuItems: some View {
        menuLink(L10n.t("配置修改"), "slider.horizontal.3") {
            RuntimePHPSettingsView(entry: entry, client: client)
        }
        menuLink(L10n.t("性能调整"), "gauge") {
            RuntimePHPFpmTuneView(entry: entry, client: client)
        }
        menuLink(L10n.t("负载状态"), "chart.bar") {
            RuntimeFPMStatusView(entry: entry, client: client)
        }
        menuLink(L10n.t("慢日志"), "hourglass") {
            RuntimeSlowLogView(entry: entry, client: client)
        }
        menuLink("php.ini", "doc.plaintext") {
            RuntimePHPFileView(entry: entry, client: client, fileType: "php")
        }
        menuLink("php-fpm.conf", "doc.plaintext") {
            RuntimePHPFileView(entry: entry, client: client, fileType: "fpm")
        }
        menuLink(L10n.t("容器配置"), "shippingbox") {
            RuntimePHPContainerView(entry: entry, client: client)
        }
        menuLink(L10n.t("扩展"), "puzzlepiece") {
            RuntimePHPExtensionsView(entry: entry, client: client)
        }
        menuLink(L10n.t("进程守护"), "gearshape.2") {
            RuntimeSupervisorView(entry: entry, client: client)
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
                RuntimeNodeModulesView(entry: entry, client: client)
            } label: {
                Label(L10n.t("模块管理"), systemImage: "cube")
            }
            LabeledContent(L10n.t("包管理器"), value: entry.packageManager)
        }
    }


    // MARK: - 详情页删除（复用列表 VM 流程）

    private func detailDeleteSheet(_ target: RuntimeEntry) -> some View {
        TextInputConfirmSheet(
            title: L10n.f("删除运行环境 %@", target.displayName),
            message: deleteMessage(target),
            expectedText: target.displayName,
            confirmTitle: L10n.t("确认删除")
        ) {
            await listVM.confirmDelete(target, force: false, deleteImage: false)
            await MainActor.run { if listVM.deleteTarget == nil { dismiss() } }
        }
        .presentationDetents([.medium])
    }

    private func deleteMessage(_ target: RuntimeEntry) -> String {
        if listVM.deleteBlockers.isEmpty {
            return L10n.t("删除后容器与配置将被移除，该操作无法回滚。输入名称确认删除。")
        }
        let names = listVM.deleteBlockers
            .map { "\($0.type ?? ""): \($0.name ?? "")" }
            .joined(separator: "、")
        return L10n.f("以下资源仍在使用该运行环境：%@。删除后相关网站将不可用。输入名称确认删除。", names)
    }
}

// MARK: - 构建日志（/files/read/{type}，末尾追读）

struct RuntimeBuildLogView: View {
    let entry: RuntimeEntry
    let client: APIClient

    @State private var lines: [String] = []
    @State private var logPath = ""
    @State private var isLoading = false
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
                    Text(L10n.t("暂无日志"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 30)
                        .frame(maxWidth: .infinity)
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 11, design: .monospaced))
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
            logPath = resp.path ?? ""
        } catch {
            if !APIError.isCancellation(error) {
                errorMessage = error.localizedDescription
            }
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
