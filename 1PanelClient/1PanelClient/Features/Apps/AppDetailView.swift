//
//  AppDetailView.swift
//  1PanelClient
//

import SwiftUI

// MARK: - 应用详情页

struct AppDetailView: View {
    let app: AppInstall
    @ObservedObject var vm: AppsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showUninstall = false
    @State private var showEdit = false
    @State private var showBackup = false
    @State private var isExpanded = false
    @State private var pendingAction: String?

    // 卸载进度
    @State private var showUninstallProgress = false
    @State private var uninstallTaskID = ""

    // 卸载弹窗状态
    @State private var uninstallDeleteDB = false
    @State private var uninstallDeleteImage = false
    @State private var uninstallDeleteBackup = false
    @State private var uninstallForceDelete = false

    /// 详情内嵌跳转网站详情所需的 VM（独立于网站列表页实例）
    @StateObject private var websitesVM: WebsitesViewModel

    init(app: AppInstall, vm: AppsViewModel) {
        self.app = app
        self.vm = vm
        let server = ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _websitesVM = StateObject(wrappedValue: WebsitesViewModel(server: server))
    }

    private var server: ServerConfig { serverConfig }

    /// 当前服务器配置（详情页内跳转 文件/容器/网站 共用）
    private var serverConfig: ServerConfig {
        ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
    }

    /// 从 VM 实时查找最新应用数据（操作后状态自动刷新）
    private var currentApp: AppInstall {
        vm.apps.first(where: { $0.id == app.id }) ?? app
    }

    var body: some View {
        listContent
            .sheet(isPresented: $showUninstall) {
                TextInputConfirmSheet(
                    title: L10n.f("卸载 %@", app.displayName),
                    message: L10n.f("此操作不可恢复。请输入应用名称「%@」以确认卸载。", app.displayName),
                    expectedText: app.displayName,
                    fieldLabel: L10n.t("确认名称"),
                    fieldPlaceholder: L10n.t("应用名称"),
                    confirmTitle: L10n.t("卸载")
                ) {
                    Task { await performUninstall() }
                } options: {
                    Section(L10n.t("选项")) {
                        if app.linkDB == true {
                            Toggle(L10n.t("同时删除数据库"), isOn: $uninstallDeleteDB)
                        }
                        Toggle(L10n.t("删除备份"), isOn: $uninstallDeleteBackup)
                        Toggle(L10n.t("删除镜像"), isOn: $uninstallDeleteImage)
                        Toggle(L10n.t("强制删除"), isOn: $uninstallForceDelete)
                    }
                }
            }
        .navigationDestination(isPresented: $showUninstallProgress) {
            TaskProgressView(
                taskID: uninstallTaskID,
                title: L10n.f("卸载 %@", app.displayName),
                onComplete: { isDone in
                    vm.needsRefresh = true
                    if isDone {
                        // 通过通知操作 ManageTab 的 NavigationPath，
                        // 由接收方显式 pop 回应用列表（详情页 + 进度页全部移除）
                        NotificationCenter.default.post(name: .popAppDetail, object: nil)
                        return true
                    }
                    return false
                }
            )
        }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .task {
            // 预加载应用设置，卸载弹窗的「删除备份 / 删除镜像」默认勾选取自这里
            if vm.appStoreConfig == nil {
                await vm.loadAppStoreConfig()
            }
        }
        .task {
            // 加载应用关联的网站（appInstallId 匹配），有关联才显示「网站」行
            await vm.loadLinkedWebsites(appID: app.id)
        }
    }

    private var listContent: some View {
        List {
            // 可展开状态区
            Section {
                statusHeaderRow
                if isExpanded { actionButtonsRow }
            }

            // 应用信息（精简）
            Section(L10n.t("应用信息")) {
                if let port = app.httpPort, port > 0 {
                    InfoRow(L10n.t("HTTP 端口"), value: "\(port)", monospaced: true)
                }
                if let ports = app.httpsPort, ports > 0 {
                    InfoRow(L10n.t("HTTPS 端口"), value: "\(ports)", monospaced: true)
                }
                if let path = app.path, !path.isEmpty {
                    NavigationLink {
                        FilesView(server: server, initialPath: path)
                    } label: {
                        InfoRow(L10n.t("目录"), value: path)
                    }
                    .buttonStyle(.plain)
                }
                if let container = app.container, !container.isEmpty {
                    NavigationLink {
                        ContainerDetailFromAppView(app: app, server: server)
                    } label: {
                        InfoRow(L10n.t("容器名"), value: container)
                    }
                    .buttonStyle(.plain)
                }
                if let sites = vm.linkedWebsites, !sites.isEmpty {
                    ForEach(sites) { site in
                        NavigationLink {
                            WebsiteDetailView(website: site, vm: websitesVM)
                        } label: {
                            InfoRow(L10n.t("网站"), value: site.displayName)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let created = app.createdAt, !created.isEmpty {
                    InfoRow(L10n.t("安装时间"), value: String(created.prefix(19)))
                }
            }

            // 日志
            Section {
                NavigationLink {
                    AppLogView(app: app, vm: vm)
                } label: {
                    Label(L10n.t("查看日志"), systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.plain)
            }
        }
        .refreshable {
            await vm.refresh()
        }
        .navigationTitle(app.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $vm.showUpgradeSheet) {
            UpgradeSheetView(app: app, vm: vm)
        }
        .navigationDestination(isPresented: $showEdit) {
            UpdateParamsView(app: app, vm: vm)
        }
        .navigationDestination(isPresented: $showBackup) {
            // 应用备份：type=app，name/detailName 均为安装名
            BackupListView(target: BackupTarget(
                type: "app",
                name: app.name ?? "",
                detailName: app.name ?? ""
            ))
        }
        .alert(
            pendingAction.map { actionDisplayName($0) } ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            )
        ) {
            Button(L10n.t("取消"), role: .cancel) {
                pendingAction = nil
            }
            Button(L10n.t("确认"), role: .destructive) {
                executePendingAction()
            }
        } message: {
            if let action = pendingAction {
                Text(L10n.f("将对选中应用程序进行 %@ 操作，是否继续？", actionDisplayName(action)))
            }
        }
        .onDisappear {
            if vm.needsRefresh {
                vm.needsRefresh = false
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    await vm.refresh()
                }
            }
        }
    }

    // MARK: - 状态头行

    private var statusHeaderRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(currentApp.displayName)
                        .font(.system(.headline, design: .default))
                    if let v = currentApp.version, !v.isEmpty {
                        Text("v\(v)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 4) {
                    StatusDot(color: currentApp.statusColor)
                    Text((currentApp.status ?? L10n.t("未知")).capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 展开操作按钮

    /// 第一行：停止/启动、重启、重建、编辑；第二行：备份（+ 可更新时的升级）、卸载
    private var actionButtonsRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                actionButton(
                    title: currentApp.isRunning ? L10n.t("停止") : L10n.t("启动"),
                    icon: currentApp.isRunning ? "stop.fill" : "play.fill",
                    color: currentApp.isRunning ? .orange : .green
                ) {
                    pendingAction = currentApp.isRunning ? "stop" : "start"
                }
                actionButton(
                    title: L10n.t("重启"),
                    icon: "arrow.triangle.2.circlepath",
                    color: .blue
                ) {
                    pendingAction = "restart"
                }
                actionButton(
                    title: L10n.t("重建"),
                    icon: "hammer",
                    color: .indigo
                ) {
                    pendingAction = "rebuild"
                }
                actionButton(
                    title: L10n.t("编辑"),
                    icon: "slider.horizontal.3",
                    color: .teal
                ) {
                    showEdit = true
                }
            }
            HStack(spacing: 8) {
                actionButton(
                    title: L10n.t("备份"),
                    icon: "externaldrive.badge.timemachine",
                    color: .purple
                ) {
                    showBackup = true
                }
                if currentApp.canUpdate == true {
                    actionButton(
                        title: L10n.t("升级"),
                        icon: "arrow.up.circle",
                        color: .orange
                    ) {
                        Task { await vm.loadVersions(for: currentApp) }
                    }
                }
                actionButton(
                    title: L10n.t("卸载"),
                    icon: "trash",
                    color: .red
                ) {
                    Task { await prepareUninstall() }
                }
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 2)
    }

    /// 打开卸载弹窗前确保应用设置已加载，
    /// 「删除备份 / 删除镜像」默认勾选与设置页保持一致
    private func prepareUninstall() async {
        if vm.appStoreConfig == nil {
            await vm.loadAppStoreConfig()
        }
        uninstallDeleteBackup = vm.appStoreConfig?.isUninstallDeleteBackup ?? false
        uninstallDeleteImage = vm.appStoreConfig?.isUninstallDeleteImage ?? false
        showUninstall = true
    }

    @ViewBuilder
    private func actionButton(
        title: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        CardActionButton(title: title, icon: icon, color: color, action: action)
    }

    private func executePendingAction() {
        let action = pendingAction
        pendingAction = nil
        switch action {
        case "stop":
            Task { await vm.operate(app: app, op: .stop) }
        case "start":
            Task { await vm.operate(app: app, op: .start) }
        case "restart":
            Task { await vm.operate(app: app, op: .restart) }
        case "rebuild":
            Task { await vm.operate(app: app, op: .rebuild) }
        default:
            break
        }
    }

    private func actionDisplayName(_ action: String) -> String {
        switch action {
        case "stop":     return L10n.t("停止")
        case "start":    return L10n.t("启动")
        case "restart":  return L10n.t("重启")
        case "rebuild":  return L10n.t("重建")
        default:         return action
        }
    }

    // MARK: - 卸载执行（确认弹窗由共享 TextInputConfirmSheet 提供）

    private func performUninstall() async {
        let taskID = UUID().uuidString
        await vm.uninstall(
            app: app,
            deleteDB: uninstallDeleteDB,
            deleteImage: uninstallDeleteImage,
            deleteBackup: uninstallDeleteBackup,
            forceDelete: uninstallForceDelete,
            taskID: taskID
        )
        if vm.uninstallDone {
            showUninstall = false
            uninstallTaskID = taskID
            showUninstallProgress = true
        }
    }
}

// MARK: - 应用详情 → 关联容器详情

/// 拉取容器列表后按容器名匹配，直接展示容器详情页（返回即回应用详情）
struct ContainerDetailFromAppView: View {
    let app: AppInstall
    let server: ServerConfig
    @StateObject private var vm: ContainersViewModel

    init(app: AppInstall, server: ServerConfig) {
        self.app = app
        self.server = server
        _vm = StateObject(wrappedValue: ContainersViewModel(server: server))
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.containers.isEmpty {
                LoadingStateView()
            } else if let container = vm.containers.first(where: { $0.name == app.container }) {
                ContainerDetailView(container: container, server: server, vm: vm)
            } else {
                ContentUnavailableView(
                    L10n.t("未找到容器"),
                    systemImage: "shippingbox",
                    description: Text(vm.errorMessage ?? L10n.f("未找到名为「%@」的容器，可能已被移除", app.container ?? "—"))
                )
            }
        }
        .navigationTitle(L10n.t("容器"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if vm.containers.isEmpty { await vm.refresh() }
        }
    }
}

