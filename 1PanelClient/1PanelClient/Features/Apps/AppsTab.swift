//
//  AppsTab.swift
//  1PanelClient
//

import SwiftUI
import Combine

struct AppsTab: View {
    @ObservedObject var manager: ServerManager
    @StateObject private var vm: AppsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var showStore = false
    @State private var showIgnored = false
    @State private var showSettings = false
    @State private var showMenu = false


    init(manager: ServerManager) {
        self.manager = manager
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: AppsViewModel(server: server))
    }

    var body: some View {
        rootContent
        .alert("提示", isPresented: $vm.showAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .onReceive(NotificationCenter.default.publisher(for: .installCompleted)) { _ in
            // 安装完成：关闭应用商店（连带所有子页面），刷新应用列表
            showStore = false
            Task { await vm.refresh() }
        }
        .task { await vm.refresh() }
    }

    /// 列表根内容（不含 NavigationStack），供 ManageTab 嵌入复用
    var rootContent: some View {
        Group {
            if vm.isLoading && vm.apps.isEmpty {
                ProgressView("加载中…")
            } else if vm.apps.isEmpty {
                ContentUnavailableView(
                    "暂无已安装应用",
                    systemImage: "shippingbox",
                    description: Text(vm.errorMessage ?? "这台服务器上没有已安装的应用")
                )
            } else {
                appList
            }
        }
        .searchIconMode(
            text: $searchText,
            isSearching: $isSearching,
            title: "应用",
            prompt: "搜索已安装应用"
        )
        .overlay(alignment: .bottomTrailing) {
            FloatingActionButton(action: {
                showStore = true
            })
            .accessibilityLabel("进入应用商店")
        }
        .toolbar {
            if !isSearching {
                ToolbarItem(placement: .topBarTrailing) {
                    EllipsisMenuButton {
                        withAnimation(.easeOut(duration: 0.18)) { showMenu.toggle() }
                    }
                    .accessibilityLabel("更多")
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if showMenu {
                EllipsisMenuPopup(entries: [
                    .action(title: "忽略应用") { showIgnored = true },
                    .action(title: "设置") { showSettings = true },
                ]) {
                    withAnimation(.easeIn(duration: 0.12)) { showMenu = false }
                }
            }
        }
        .onChange(of: searchText) { _, newValue in
            Task { await vm.search(query: newValue) }
        }
        .navigationDestination(for: AppInstall.self) { app in
            AppDetailView(app: app, vm: vm)
        }
        .navigationDestination(isPresented: $showIgnored) {
            IgnoredAppsView(vm: vm)
        }
        .navigationDestination(isPresented: $showSettings) {
            AppStoreSettingsView(vm: vm)
        }
        .navigationDestination(isPresented: $showStore) {
            AppStoreTab(manager: manager)
        }
    }

    private var appList: some View {
        List {
            Section {
                ForEach(vm.apps) { app in
                    NavigationLink(value: app) {
                        AppRow(
                            app: app,
                            isOperating: vm.operatingAppIds.contains(app.id)
                        )
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if app.isRunning {
                            Button {
                                Task { await vm.operate(app: app, op: .stop) }
                            } label: { Label("停止", systemImage: "stop.fill") }
                            .tint(.orange)
                        } else {
                            Button {
                                Task { await vm.operate(app: app, op: .start) }
                            } label: { Label("启动", systemImage: "play.fill") }
                            .tint(.green)
                        }
                        Button {
                            Task { await vm.operate(app: app, op: .restart) }
                        } label: { Label("重启", systemImage: "arrow.triangle.2.circlepath") }
                        .tint(.blue)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await vm.refresh()
        }
    }
}

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
                    title: "卸载 \(app.displayName)",
                    message: "此操作不可恢复。请输入应用名称「\(app.displayName)」以确认卸载。",
                    expectedText: app.displayName,
                    fieldLabel: "确认名称",
                    fieldPlaceholder: "应用名称",
                    confirmTitle: "卸载"
                ) {
                    Task { await performUninstall() }
                } options: {
                    Section("选项") {
                        if app.linkDB == true {
                            Toggle("同时删除数据库", isOn: $uninstallDeleteDB)
                        }
                        Toggle("删除备份", isOn: $uninstallDeleteBackup)
                        Toggle("删除镜像", isOn: $uninstallDeleteImage)
                        Toggle("强制删除", isOn: $uninstallForceDelete)
                    }
                }
            }
        .navigationDestination(isPresented: $showUninstallProgress) {
            TaskProgressView(
                taskID: uninstallTaskID,
                title: "卸载 \(app.displayName)",
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
        .alert("提示", isPresented: $vm.showAlert) {
            Button("好的", role: .cancel) {}
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
            Section("应用信息") {
                if let port = app.httpPort, port > 0 {
                    InfoRow("HTTP 端口", value: "\(port)")
                }
                if let ports = app.httpsPort, ports > 0 {
                    InfoRow("HTTPS 端口", value: "\(ports)")
                }
                if let path = app.path, !path.isEmpty {
                    NavigationLink {
                        FilesView(server: server, initialPath: path)
                    } label: {
                        InfoRow("目录", value: path)
                    }
                    .buttonStyle(.plain)
                }
                if let container = app.container, !container.isEmpty {
                    NavigationLink {
                        ContainerDetailFromAppView(app: app, server: server)
                    } label: {
                        InfoRow("容器名", value: container)
                    }
                    .buttonStyle(.plain)
                }
                if let sites = vm.linkedWebsites, !sites.isEmpty {
                    ForEach(sites) { site in
                        NavigationLink {
                            WebsiteDetailView(website: site, vm: websitesVM)
                        } label: {
                            InfoRow("网站", value: site.displayName)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let created = app.createdAt, !created.isEmpty {
                    InfoRow("安装时间", value: String(created.prefix(19)))
                }
            }

            // 日志
            Section {
                NavigationLink {
                    AppLogView(app: app, vm: vm)
                } label: {
                    Label("查看日志", systemImage: "doc.text.magnifyingglass")
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
            Button("取消", role: .cancel) {
                pendingAction = nil
            }
            Button("确认", role: .destructive) {
                executePendingAction()
            }
        } message: {
            if let action = pendingAction {
                Text("将对选中应用程序进行 \(actionDisplayName(action)) 操作，是否继续？")
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
                    Text((currentApp.status ?? "未知").capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
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
                    title: currentApp.isRunning ? "停止" : "启动",
                    icon: currentApp.isRunning ? "stop.fill" : "play.fill",
                    color: currentApp.isRunning ? .orange : .green
                ) {
                    pendingAction = currentApp.isRunning ? "stop" : "start"
                }
                actionButton(
                    title: "重启",
                    icon: "arrow.triangle.2.circlepath",
                    color: .blue
                ) {
                    pendingAction = "restart"
                }
                actionButton(
                    title: "重建",
                    icon: "hammer",
                    color: .indigo
                ) {
                    pendingAction = "rebuild"
                }
                actionButton(
                    title: "编辑",
                    icon: "slider.horizontal.3",
                    color: .teal
                ) {
                    showEdit = true
                }
            }
            HStack(spacing: 8) {
                actionButton(
                    title: "备份",
                    icon: "externaldrive.badge.timemachine",
                    color: .purple
                ) {
                    showBackup = true
                }
                if currentApp.canUpdate == true {
                    actionButton(
                        title: "升级",
                        icon: "arrow.up.circle",
                        color: .orange
                    ) {
                        Task { await vm.loadVersions(for: currentApp) }
                    }
                }
                actionButton(
                    title: "卸载",
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
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                    .frame(width: 22, height: 22)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
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
        case "stop":     return "停止"
        case "start":    return "启动"
        case "restart":  return "重启"
        case "rebuild":  return "重建"
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
                ProgressView("加载中…")
            } else if let container = vm.containers.first(where: { $0.name == app.container }) {
                ContainerDetailView(container: container, server: server, vm: vm)
            } else {
                ContentUnavailableView(
                    "未找到容器",
                    systemImage: "shippingbox",
                    description: Text(vm.errorMessage ?? "未找到名为「\(app.container ?? "—")」的容器，可能已被移除")
                )
            }
        }
        .navigationTitle("容器")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if vm.containers.isEmpty { await vm.refresh() }
        }
    }
}

// MARK: - 升级版本选择 Sheet

struct UpgradeSheetView: View {
    let app: AppInstall
    @ObservedObject var vm: AppsViewModel
    @State private var showComposeEditor = false
    @State private var deleteOldImage = false

    var body: some View {
        Group {
            if vm.isLoadingVersions {
                ProgressView("查询可用版本…")
            } else if vm.availableVersions.isEmpty {
                ContentUnavailableView(
                    "无可用版本",
                    systemImage: "arrow.up.circle.slash",
                    description: Text("该应用暂无更高版本可供升级")
                )
            } else {
                versionList
            }
        }
        .navigationTitle("升级 \(app.displayName)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 确保应用设置已加载，用于「升级后删除旧镜像」默认勾选
            if vm.appStoreConfig == nil {
                await vm.loadAppStoreConfig()
            }
            deleteOldImage = vm.appStoreConfig?.isUpgradeDeleteImage ?? false
        }
        .alert("提示", isPresented: $vm.showAlert) {
            Button("好的", role: .cancel) {
                if vm.pendingDismissUpgrade {
                    vm.pendingDismissUpgrade = false
                    vm.showUpgradeSheet = false
                }
            }
        } message: {
            Text(vm.alertMessage)
        }
        .navigationDestination(isPresented: $showComposeEditor) {
            if let version = vm.selectedVersion {
                ComposeEditorView(
                    app: app,
                    version: version,
                    vm: vm,
                    initialDeleteOldImage: deleteOldImage,
                    onBack: { showComposeEditor = false }
                )
            }
        }
        .navigationDestination(isPresented: $vm.showUpgradeProgress) {
            TaskProgressView(
                taskID: vm.upgradeTaskID,
                title: "升级 \(app.displayName)",
                onComplete: { isDone in
                    vm.needsRefresh = true
                    // 重置进度状态，避免重新进入时残留
                    vm.showUpgradeProgress = false
                    if isDone {
                        // 升级完成：通过通知 pop 回应用列表（ManageTab 嵌入模式下一次性 pop AppDetailView）
                        NotificationCenter.default.post(name: .popAppDetail, object: nil)
                        // 同时关闭升级页，兼容独立模式（popAppDetail 无效时由 showUpgradeSheet=false 收起）
                        vm.showUpgradeSheet = false
                        return true
                    }
                    return false
                }
            )
        }
    }

    private var versionList: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("升级将替换 docker-compose.yml，如有自定义修改请查看对比")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("提示")
            }

            Section {
                Toggle("升级后删除旧镜像", isOn: $deleteOldImage)
                    .tint(.orange)
            } header: {
                Text("升级选项")
            } footer: {
                Text("默认关闭。开启后升级请求会删除旧镜像以释放存储空间")
            }

            Section("可升级到") {
                ForEach(vm.availableVersions) { ver in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ver.version ?? "v\(ver.detailId)")
                                    .font(.body.bold())
                                Text("ID: \(ver.detailId)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if vm.upgradingVersionId == ver.detailId {
                                ProgressView()
                            }
                        }

                        HStack(spacing: 8) {
                            Button {
                                Task {
                                    let taskID = UUID().uuidString
                                    await vm.confirmUpgrade(
                                        app: app,
                                        to: ver,
                                        customCompose: nil,
                                        deleteOldImage: deleteOldImage,
                                        taskID: taskID
                                    )
                                }
                            } label: {
                                Label("直接升级", systemImage: "arrow.up.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .disabled(vm.upgradingVersionId != nil)

                            Button {
                                Task {
                                    if await vm.prepareComposeEditor(app: app, version: ver) {
                                        showComposeEditor = true
                                    }
                                }
                            } label: {
                                if vm.loadingComposeVersionId == ver.detailId {
                                    HStack {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                        Text("加载配置")
                                    }
                                    .frame(maxWidth: .infinity)
                                } else {
                                    Label("对比/编辑", systemImage: "doc.text.magnifyingglass")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(vm.upgradingVersionId != nil || vm.loadingComposeVersionId != nil)
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task { await vm.ignoreUpgrade(app: app, version: ver) }
                        } label: {
                            Label("忽略此版本", systemImage: "eye.slash")
                        }
                    }
                }
            }

            // 忽略所有升级
            Section {
                Button(role: .destructive) {
                    Task { await vm.ignoreUpgrade(app: app) }
                } label: {
                    Label("忽略所有升级", systemImage: "eye.slash")
                }

                if app.ignoredRecordID != nil {
                    Button {
                        Task { await vm.cancelIgnoreUpgrade(app: app) }
                    } label: {
                        Label("取消忽略升级", systemImage: "eye")
                    }
                }
            }
        }
    }
}

// MARK: - 忽略升级列表

struct IgnoredAppsView: View {
    @ObservedObject var vm: AppsViewModel

    @State private var ignored: [AppIgnoreUpgrade] = []
    @State private var isLoading = false

    var body: some View {
        Group {
            if isLoading && ignored.isEmpty {
                ProgressView("加载中…")
            } else if ignored.isEmpty {
                ContentUnavailableView(
                    "暂无忽略记录",
                    systemImage: "eye.slash",
                    description: Text("没有被忽略升级的应用")
                )
            } else {
                List {
                    Section {
                        ForEach(ignored) { item in
                            HStack {
                                Image(systemName: "shippingbox")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name ?? "未知应用")
                                        .font(.body.bold())
                                    if item.scope == "all" {
                                        Text("忽略所有版本")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else if let v = item.version, !v.isEmpty {
                                        Text("忽略版本 \(v)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Task { await cancelIgnore(recordId: item.id) }
                                } label: {
                                    Label("取消忽略", systemImage: "eye")
                                }
                            }
                        }
                    } header: {
                        Text("已忽略升级 (\(ignored.count))")
                    } footer: {
                        Text("左滑可取消忽略，恢复升级检查")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("忽略升级")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            ignored = try await vm.client.send(
                path: APIEndpoint.appsIgnoredList.path,
                method: APIEndpoint.appsIgnoredList.method,
                as: [AppIgnoreUpgrade].self
            )
        } catch let err as APIError {
            // 无忽略记录时服务端返回 data=null，APIClient 已回退为空数组
            vm.alertMessage = "加载失败：\(err.errorDescription ?? "未知错误")"
            vm.showAlert = true
        } catch {
            vm.alertMessage = "加载失败：\(error.localizedDescription)"
            vm.showAlert = true
        }
    }

    private func cancelIgnore(recordId: Int) async {
        struct Req: Encodable { let id: Int }
        do {
            let _: EmptyResponse = try await vm.client.send(
                path: APIEndpoint.appsIgnoredCancel.path,
                body: Req(id: recordId),
                as: EmptyResponse.self
            )
            ignored.removeAll { $0.id == recordId }
            vm.needsRefresh = true
        } catch {
            vm.alertMessage = "取消忽略失败：\(error.localizedDescription)"
            vm.showAlert = true
        }
    }
}

// MARK: - 更新参数（重建应用）push 导航

struct UpdateParamsView: View {
    let app: AppInstall
    @ObservedObject var vm: AppsViewModel

    @State private var paramsResp: InstalledParamsResponse?
    @State private var isLoading = true
    @State private var loadError: String?

    // 表单值
    @State private var paramValues: [String: String] = [:]
    @State private var containerName = ""
    @State private var allowPort = false
    @State private var restartPolicy = "always"
    @State private var cpuQuota = 0
    @State private var memoryLimit = 0
    @State private var memoryUnit = "MB"
    @State private var editCompose = false
    @State private var customCompose = ""

    private let restartPolicies = ["no", "always", "on-failure", "unless-stopped"]
    private let memoryUnits = ["MB", "GB"]

    private var hasLoaded: Bool { paramsResp != nil }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("加载参数…")
            } else if let resp = paramsResp {
                paramsForm(resp)
            } else {
                ContentUnavailableView {
                    Label("无法加载参数", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError ?? "请稍后重试")
                } actions: {
                    Button("重试") { Task { await load() } }
                }
            }
        }
        .navigationTitle("更新参数")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("更新") {
                    Task { await performUpdate() }
                }
                .disabled(!hasLoaded || vm.isUpdatingParams)
            }
        }
        .task { await load() }
        .alert("提示", isPresented: $vm.showAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
    }

    @ViewBuilder
    private func paramsForm(_ resp: InstalledParamsResponse) -> some View {
        Form {
            // 参数列表
            if let fields = resp.params, !fields.isEmpty {
                Section {
                    ForEach(fields) { field in
                        if field.edit == true {
                            InstalledParamEditRow(field: field, value: binding(for: field))
                        } else {
                            InstalledParamReadRow(field: field)
                        }
                    }
                } header: {
                    Text("参数")
                } footer: {
                    Text("修改后将重建容器使参数生效。")
                }
            }

            // 容器配置
            Section {
                HStack {
                    Text("容器名").foregroundStyle(.secondary)
                    Spacer()
                    TextField("", text: $containerName)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("端口外部访问", isOn: $allowPort)
                Picker("重启规则", selection: $restartPolicy) {
                    ForEach(restartPolicies, id: \.self) { Text($0).tag($0) }
                }
            } header: {
                Text("容器配置")
            }

            // 资源限制
            Section {
                HStack {
                    Text("CPU 核心").foregroundStyle(.secondary)
                    Spacer()
                    TextField("0", value: $cpuQuota, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    Text("核").foregroundStyle(.secondary).font(.caption)
                }
                HStack {
                    Text("内存限制").foregroundStyle(.secondary)
                    Spacer()
                    TextField("0", value: $memoryLimit, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    Picker("", selection: $memoryUnit) {
                        ForEach(memoryUnits, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 80)
                }
            } header: {
                Text("资源限制")
            } footer: {
                Text("填 0 表示不限制")
            }

            // docker-compose
            Section {
                Toggle("编辑 docker-compose.yml", isOn: $editCompose)
                    .onChange(of: editCompose) { _, isOn in
                        if isOn && customCompose.isEmpty {
                            customCompose = resp.dockerCompose ?? resp.rawCompose ?? ""
                        }
                    }
            } header: {
                Text("docker-compose")
            }

            if editCompose {
                Section {
                    TextEditor(text: $customCompose)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 200)
                } footer: {
                    Text("编辑后将使用自定义内容覆盖默认编排文件")
                }
            }

            // 当前 compose 预览（只读）
            if !editCompose, let raw = resp.rawCompose, !raw.isEmpty {
                Section {
                    CodePreview(text: raw, color: .secondary)
                        .frame(minHeight: 140)
                } header: {
                    Text("当前 docker-compose.yml")
                }
            }

            if vm.isUpdatingParams {
                Section {
                    HStack {
                        ProgressView()
                        Text("正在更新…")
                    }
                }
            }
        }
    }

    private func binding(for field: InstalledParamField) -> Binding<String> {
        let key = field.key ?? ""
        return Binding(
            get: { paramValues[key] ?? field.value?.stringValue ?? "" },
            set: { paramValues[key] = $0 }
        )
    }

    private func load() async {
        isLoading = true
        loadError = nil
        guard let resp = await vm.loadParams(for: app) else {
            loadError = vm.alertMessage
            isLoading = false
            return
        }
        self.paramsResp = resp
        // 用接口返回的当前值初始化
        if let fields = resp.params {
            for f in fields {
                if let k = f.key {
                    paramValues[k] = f.value?.stringValue ?? ""
                }
            }
        }
        containerName = resp.containerName ?? ""
        allowPort = resp.allowPort ?? false
        restartPolicy = resp.restartPolicy ?? "always"
        cpuQuota = resp.cpuQuota ?? 0
        memoryLimit = resp.memoryLimit ?? 0
        memoryUnit = resp.memoryUnit ?? "MB"
        customCompose = resp.dockerCompose ?? resp.rawCompose ?? ""
        isLoading = false
    }

    private func performUpdate() async {
        guard let resp = paramsResp else { return }
        var params: [String: AnyCodableValue] = [:]
        for (k, v) in paramValues {
            if let intVal = Int(v) {
                params[k] = .int(intVal)
            } else {
                params[k] = .string(v)
            }
        }
        let compose = editCompose ? customCompose : (resp.dockerCompose ?? resp.rawCompose ?? "")
        let req = AppParamsUpdateRequest(
            webUI: resp.webUI ?? "",
            installId: app.id,
            params: params,
            advanced: true,
            memoryLimit: memoryLimit,
            cpuQuota: cpuQuota,
            memoryUnit: memoryUnit,
            allowPort: allowPort,
            containerName: containerName,
            editCompose: editCompose,
            dockerCompose: compose,
            restartPolicy: restartPolicy
        )
        await vm.updateParams(app: app, req: req)
    }
}

/// 已安装参数 - 可编辑行
struct InstalledParamEditRow: View {
    let field: InstalledParamField
    @Binding var value: String

    var body: some View {
        switch field.type ?? "text" {
        case "number":
            HStack {
                Text(field.displayLabel).foregroundStyle(.secondary)
                Spacer()
                TextField("", text: $value)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
            }
        case "select":
            Picker(field.displayLabel, selection: $value) {
                ForEach(field.values ?? [], id: \.self) { v in
                    Text(v).tag(v)
                }
            }
        default:
            HStack {
                Text(field.displayLabel).foregroundStyle(.secondary)
                Spacer()
                TextField("", text: $value)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

/// 已安装参数 - 只读行（edit=false）
struct InstalledParamReadRow: View {
    let field: InstalledParamField

    var body: some View {
        HStack {
            Text(field.displayLabel).foregroundStyle(.secondary)
            Spacer()
            Text(field.value?.stringValue ?? "—")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Compose 文件对比/编辑页

struct ComposeEditorView: View {
    let app: AppInstall
    let version: AppVersion
    @ObservedObject var vm: AppsViewModel
    let onBack: () -> Void

    @State private var useCustom = false
    @State private var editedCompose = ""
    @State private var deleteOldImage: Bool

    init(
        app: AppInstall,
        version: AppVersion,
        vm: AppsViewModel,
        initialDeleteOldImage: Bool,
        onBack: @escaping () -> Void
    ) {
        self.app = app
        self.version = version
        self.vm = vm
        self.onBack = onBack
        _deleteOldImage = State(initialValue: initialDeleteOldImage)
    }

    private var newCompose: String {
        version.dockerCompose ?? ""
    }

    private var oldCompose: String {
        app.currentDockerCompose ?? app.dockerCompose ?? ""
    }

    var body: some View {
        List {
            // 模式切换
            Section {
                Toggle(isOn: $useCustom) {
                    Label(useCustom ? "使用自定义配置" : "使用默认配置",
                          systemImage: useCustom ? "wand.and.stars" : "doc")
                }
                .tint(.orange)

                if useCustom {
                    Text("已启用自定义 docker-compose.yml，请仔细检查内容")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("配置模式")
            }

            Section {
                Toggle("升级后删除旧镜像", isOn: $deleteOldImage)
                    .tint(.orange)
            } header: {
                Text("升级选项")
            } footer: {
                Text("默认关闭。开启后升级请求会删除旧镜像以释放存储空间")
            }

            // 操作按钮
            Section {
                Button {
                    Task {
                        let compose = useCustom ? editedCompose : nil
                        let taskID = UUID().uuidString
                        await vm.confirmUpgrade(
                            app: app,
                            to: version,
                            customCompose: compose,
                            deleteOldImage: deleteOldImage,
                            taskID: taskID
                        )
                        if vm.upgradeSuccess {
                            onBack()
                            // 编辑器返回后，UpgradeSheetView 的进度导航目标会接管，
                            // 显示升级任务进度（vm.showUpgradeProgress 已由 confirmUpgrade 置位）
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        Label(useCustom ? "使用自定义配置升级" : "使用默认配置升级",
                              systemImage: "arrow.up.circle.fill")
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(vm.upgradingVersionId != nil)

                if vm.upgradingVersionId != nil {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text("正在升级…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            // 当前版本（只读）
            Section {
                CodePreview(text: oldCompose, color: .secondary)
                    .frame(minHeight: 160)
            } header: {
                HStack {
                    Text("当前版本")
                    Spacer()
                    Text("v\(app.version ?? "?")")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            // 新版本（可编辑）
            Section {
                if useCustom {
                    TextEditor(text: $editedCompose)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 240)
                        .scrollContentBackground(.hidden)
                        .background(Color(.secondarySystemBackground))
                } else if newCompose.isEmpty {
                    ContentUnavailableView(
                        "未获取到新版本配置",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("请返回后重新打开升级对比，或检查版本接口是否返回 dockerCompose 字段")
                    )
                    .frame(minHeight: 160)
                } else {
                    CodePreview(text: newCompose, color: .primary)
                        .frame(minHeight: 200)
                }
            } header: {
                HStack {
                    Text(useCustom ? "自定义配置（可编辑）" : "新版本")
                    Spacer()
                    Text("v\(version.version ?? "?")")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            // 重置自定义编辑
            if useCustom {
                Section {
                    Button(role: .destructive) {
                        editedCompose = newCompose
                    } label: {
                        Label("重置为新版本默认值", systemImage: "arrow.counterclockwise")
                    }
                }
            }
        }
        .navigationTitle("docker-compose.yml")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if editedCompose.isEmpty {
                editedCompose = newCompose
            }
        }
    }
}

/// 只读代码预览
struct CodePreview: View {
    let text: String
    let color: Color

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "(空)" : text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

// MARK: - 应用行

struct AppRow: View {
    let app: AppInstall
    var isOperating: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                AppIconView(
                    appID: app.appID,
                    baseURL: ServerManager.shared.current?.baseURL ?? "",
                    appKey: app.appKey,
                    fallbackIcon: app.statusIcon,
                    fallbackColor: app.statusColor,
                    fallbackText: app.displayName
                )
                if isOperating {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.thinMaterial)
                        .frame(width: 44, height: 44)
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(app.displayName)
                    .font(.body.bold())
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let v = app.version, !v.isEmpty {
                        Text("v\(v)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if app.canUpdate == true {
                        StatusBadge(text: "有更新", color: .orange, icon: "arrow.up.circle.fill")
                    }
                }
            }

            Spacer()

            HStack(spacing: 4) {
                StatusDot(color: app.statusColor)
                Text(app.isRunning ? "已启动" : (app.status ?? "未知"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 应用日志查看（SSE 流式）

struct AppLogView: View {
    let app: AppInstall
    @ObservedObject var vm: AppsViewModel

    @State private var logLines: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isFollowing = true
    @State private var scrollToBottomTrigger = 0
    @State private var tail: Int = 200
    @State private var sinceMode = "all"
    @State private var streamTask: Task<Void, Never>?
    @State private var hasMoreAtTop = false

    /// 构造 compose 路径：path + /docker-compose.yml
    private var composePath: String {
        var p = app.path ?? ""
        if p.isEmpty {
            // 兜底：/opt/1panel/apps/<appKey>/<serviceName>/
            p = "/opt/1panel/apps/\(app.appKey ?? app.serviceName ?? "")/\(app.serviceName ?? "")"
        }
        if !p.hasSuffix("/") { p += "/" }
        return p + "docker-compose.yml"
    }

    private let sinceOptions: [(value: String, label: String)] = [
        ("all", "全部"),
        ("30m", "近30分钟"),
        ("2h", "近2小时"),
        ("24h", "近24小时"),
        ("7d", "近7天")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // 工具条
            controlBar
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))

            Divider()

            // 日志内容
            logContent

            Divider()

            // 跟随尾部开关
            followBar
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemBackground))
        }
        .navigationTitle("应用日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await startStreaming() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .task { await startStreaming() }
        .onDisappear { streamTask?.cancel() }
    }

    // 控制条
    private var controlBar: some View {
        HStack(spacing: 12) {
            // 时间范围
            Picker("", selection: $sinceMode) {
                ForEach(sinceOptions, id: \.value) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: sinceMode) { _, _ in
                Task { await startStreaming() }
            }

            Spacer()

            // 行数
            HStack(spacing: 4) {
                Text("行数")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $tail) {
                    Text("100").tag(100)
                    Text("200").tag(200)
                    Text("500").tag(500)
                    Text("1000").tag(1000)
                }
                .pickerStyle(.menu)
            }
        }
    }

    // 跟随开关条
    private var followBar: some View {
        HStack {
            if isLoading {
                ProgressView()
                    .scaleEffect(0.7)
                Text("流式接收中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text("已断开")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                isFollowing = true
                scrollToBottomTrigger += 1
            } label: {
                Label("跟随最新", systemImage: "arrow.down")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(isFollowing ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
                    .foregroundStyle(isFollowing ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // 日志内容主体
    @ViewBuilder
    private var logContent: some View {
        if logLines.isEmpty && isLoading {
            ProgressView("加载日志…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if logLines.isEmpty {
            ContentUnavailableView(
                "暂无日志",
                systemImage: "doc.text",
                description: Text(errorMessage ?? "该应用暂未产生日志")
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: logLines.count) { _, _ in
                    if isFollowing {
                        withAnimation {
                            proxy.scrollTo(logLines.count - 1, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: scrollToBottomTrigger) { _, _ in
                    if !logLines.isEmpty {
                        withAnimation {
                            proxy.scrollTo(logLines.count - 1, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: isFollowing) { _, following in
                    if following && !logLines.isEmpty {
                        withAnimation {
                            proxy.scrollTo(logLines.count - 1, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    if isFollowing && !logLines.isEmpty {
                        proxy.scrollTo(logLines.count - 1, anchor: .bottom)
                    }
                }
            }
        }
    }

    // 启动/重启流式拉取
    private func startStreaming() async {
        streamTask?.cancel()
        logLines.removeAll()
        errorMessage = nil
        isLoading = true

        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "compose", value: composePath),
            URLQueryItem(name: "since", value: sinceMode),
            URLQueryItem(name: "tail", value: String(tail)),
            URLQueryItem(name: "follow", value: "true"),
            URLQueryItem(name: "timestamp", value: "false"),
            URLQueryItem(name: "operateNode", value: "local")
        ]

        streamTask = Task {
            do {
                let stream = vm.client.streamSSELines(
                    path: "/api/v2/containers/search/log",
                    queryItems: queryItems
                )
                // 控制最大缓存行数，避免内存爆炸
                let maxLines = max(tail * 5, 1000)
                for try await line in stream {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        if logLines.count >= maxLines {
                            logLines.removeFirst(logLines.count - maxLines + 1)
                        }
                        logLines.append(line)
                    }
                }
                await MainActor.run { isLoading = false }
            } catch {
                await MainActor.run {
                    isLoading = false
                    if logLines.isEmpty {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }
}

// MARK: - ViewModel

@MainActor
final class AppsViewModel: ObservableObject {
    @Published var apps: [AppInstall] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var operatingAppIds: Set<Int> = []

    // 升级相关
    @Published var showUpgradeSheet = false
    @Published var availableVersions: [AppVersion] = []
    @Published var isLoadingVersions = false
    @Published var upgradingVersionId: Int?
    @Published var loadingComposeVersionId: Int?
    /// 当前选中的要升级到的版本（在 ComposeEditorView 里使用）
    @Published var selectedVersion: AppVersion?
    /// 标记升级是否成功完成（用于编辑器返回时的判断）
    @Published var upgradeSuccess = false
    /// 升级进度视图：提交升级成功后展示任务进度
    @Published var showUpgradeProgress = false
    @Published var upgradeTaskID = ""

    // 操作提示
    @Published var showAlert = false
    @Published var alertMessage = ""
    /// alert 确认后自动返回上一层（用于忽略升级成功后）
    @Published var pendingDismissUpgrade = false

    // 卸载相关
    @Published var isUninstalling = false
    @Published var uninstallDone = false

    // 更新参数相关
    @Published var isLoadingParams = false
    @Published var loadedParams: InstalledParamsResponse?
    @Published var isUpdatingParams = false
    @Published var paramsUpdated = false

    /// 标记列表需要刷新（在详情页操作后置 true，返回列表时触发刷新）
    @Published var needsRefresh = false

    /// 应用商店设置（卸载/升级/安装默认选项），供弹窗读取默认勾选
    @Published var appStoreConfig: AppStoreConfig?
    @Published var isLoadingAppStoreConfig = false

    private(set) var client: APIClient

    var updatableCount: Int {
        apps.filter { $0.canUpdate == true }.count
    }

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    func refresh() async {
        await load(query: "")
    }

    func search(query: String) async {
        await load(query: query)
    }

    // MARK: - 应用关联网站

    /// 当前打开应用详情的关联网站（nil=未加载，空=无关联）
    @Published var linkedWebsites: [Website]?

    /// 加载与指定应用关联的网站（website.appInstallId == app.id）；
    /// 加载期间置 nil 隐藏「网站」行，失败按无关联处理，不阻断详情页
    func loadLinkedWebsites(appID: Int) async {
        linkedWebsites = nil
        let req = WebsiteSearchRequest(
            name: "", page: 1, pageSize: 100,
            orderBy: "favorite", order: "descending",
            websiteGroupId: 0, type: ""
        )
        do {
            let resp: WebsiteListResponse = try await client.send(
                path: APIEndpoint.websitesSearch.path,
                body: req,
                as: WebsiteListResponse.self
            )
            linkedWebsites = (resp.items ?? []).filter { $0.appInstallId == appID }
        } catch {
            linkedWebsites = []
        }
    }

    private func load(query: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // update=false 返回全部应用但 canUpdate 始终 false（后端不计算）
        // update=true  只返回可更新的应用，但正确计算 canUpdate
        // 通过 logs/输出20.log 验证：两者 total 不同
        // 解决方案：先拿全部应用，再并发拿可更新列表，用后者标记前者的 canUpdate
        let allReq = AppInstalledSearchRequest(
            page: 1, pageSize: 100, name: query, type: "", tags: [],
            update: false, all: false, unused: false, sync: false
        )
        // 查询可更新列表时不用 name 过滤，因为可能被搜索词过滤掉
        let updatableReq = AppInstalledSearchRequest(
            page: 1, pageSize: 100, name: "", type: "", tags: [],
            update: true, all: false, unused: false, sync: false
        )

        do {
            async let allResp: AppInstalledListResponse = client.send(
                path: APIEndpoint.appsInstalledSearch.path,
                body: allReq,
                as: AppInstalledListResponse.self
            )
            async let updatableResp: AppInstalledListResponse = client.send(
                path: APIEndpoint.appsInstalledSearch.path,
                body: updatableReq,
                as: AppInstalledListResponse.self
            )
            // 并发拉取已忽略列表（GET 接口，失败不阻断主流程）
            async let ignoredResp: [AppIgnoreUpgrade] = client.send(
                path: APIEndpoint.appsIgnoredList.path,
                method: APIEndpoint.appsIgnoredList.method,
                as: [AppIgnoreUpgrade].self
            )

            let (all, updatable) = try await (allResp, updatableResp)
            // ignored 拉取失败则降级为空数组（不阻断应用列表展示）
            let ignored = (try? await ignoredResp) ?? []
            var apps = all.items ?? []
            let updatableMap = Dictionary((updatable.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // 构建 appID → ignoredRecordID 映射
            let ignoredMap = Dictionary(ignored.compactMap { item -> (Int, Int)? in
                guard let appID = item.appID else { return nil }
                return (appID, item.id)
            }, uniquingKeysWith: { a, _ in a })

            // 合并可更新状态、dockerCompose、忽略记录 ID
            for i in apps.indices {
                if let updatableApp = updatableMap[apps[i].id] {
                    apps[i].canUpdate = true
                    apps[i].currentDockerCompose = updatableApp.dockerCompose
                } else {
                    apps[i].canUpdate = false
                }
                if let appID = apps[i].appID {
                    apps[i].ignoredRecordID = ignoredMap[appID]
                }
            }
            self.apps = apps
        } catch let err as APIError {
            self.errorMessage = err.errorDescription
            self.apps = []
        } catch {
            self.errorMessage = error.localizedDescription
            self.apps = []
        }
    }

    // MARK: - 启动/停止/重启

    func operate(app: AppInstall, op: AppOperation) async {
        operatingAppIds.insert(app.id)
        defer { operatingAppIds.remove(app.id) }

        let req = AppInstalledOperateRequest(installId: app.id, operate: op.rawValue)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledOperate.path,
                body: req,
                as: EmptyResponse.self
            )
            // rebuild 是异步操作，状态不会立即变化，需要明确反馈
            if op == .rebuild {
                showAlert(message: "\(app.displayName) 重建请求已提交，容器正在后台重建…")
                needsRefresh = true
            }
            // 所有操作都刷新列表，让详情页 currentApp 能反映最新状态
            try? await Task.sleep(for: .seconds(1))
            await load(query: "")
        } catch let err as APIError {
            showAlert(message: "\(op.displayName)失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "\(op.displayName)失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 升级流程

    func loadVersions(for app: AppInstall) async {
        availableVersions = []
        selectedVersion = nil
        upgradeSuccess = false
        isLoadingVersions = true
        showUpgradeSheet = true

        do {
            let versions: [AppVersion] = try await client.send(
                path: APIEndpoint.appsUpdateVersions.path,
                body: AppUpdateVersionsRequest(appInstallId: app.id),
                queryItems: [URLQueryItem(name: "operateNode", value: "local")],
                as: [AppVersion].self
            )
            let currentDetailId = app.appDetailID ?? -1
            self.availableVersions = versions.filter { $0.detailId != currentDetailId }
        } catch let err as APIError {
            showAlert(message: "查询版本失败：\(err.errorDescription ?? "未知错误")")
            showUpgradeSheet = false
        } catch {
            showAlert(message: "查询版本失败：\(error.localizedDescription)")
            showUpgradeSheet = false
        }
        isLoadingVersions = false
    }

    func prepareComposeEditor(app: AppInstall, version: AppVersion) async -> Bool {
        if let dockerCompose = version.dockerCompose, !dockerCompose.isEmpty {
            selectedVersion = version
            return true
        }

        guard let updateVersion = version.version, !updateVersion.isEmpty else {
            selectedVersion = version
            return true
        }

        loadingComposeVersionId = version.detailId
        defer { loadingComposeVersionId = nil }

        do {
            let versions: [AppVersion] = try await client.send(
                path: APIEndpoint.appsUpdateVersions.path,
                body: AppUpdateVersionsRequest(appInstallId: app.id, updateVersion: updateVersion),
                queryItems: [URLQueryItem(name: "operateNode", value: "local")],
                as: [AppVersion].self
            )
            let preparedVersion = versions.first(where: { $0.detailId == version.detailId })
                ?? versions.first(where: { $0.version == updateVersion })
                ?? version
            selectedVersion = preparedVersion
            if let versionIndex = availableVersions.firstIndex(where: { $0.detailId == preparedVersion.detailId }) {
                availableVersions[versionIndex] = preparedVersion
            }
            return true
        } catch let err as APIError {
            showAlert(message: "加载新版本配置失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "加载新版本配置失败：\(error.localizedDescription)")
            return false
        }
    }

    func confirmUpgrade(
        app: AppInstall,
        to version: AppVersion,
        customCompose: String?,
        deleteOldImage: Bool,
        taskID: String
    ) async {
        upgradingVersionId = version.detailId
        upgradeSuccess = false
        defer { upgradingVersionId = nil }

        let req = AppInstalledOperateRequest(
            installId: app.id,
            operate: AppOperation.upgrade.rawValue,
            detailId: version.detailId,
            backup: appStoreConfig?.isUpgradeBackup ?? true,
            pullImage: true,
            dockerCompose: customCompose,
            deleteImage: deleteOldImage,
            taskID: taskID
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledOperate.path,
                body: req,
                as: EmptyResponse.self
            )
            upgradeSuccess = true
            // 先置位 taskID，再触发进度视图导航（progress 的 navigationDestination 挂在
            // UpgradeSheetView 上，因此不能关闭 UpgradeSheetView，否则会失去锚点导致白屏）。
            // 进度页完成时由 .popAppDetail 通知一次性 pop 回应用列表。
            upgradeTaskID = taskID
            showUpgradeProgress = true
        } catch let err as APIError {
            showAlert(message: "升级失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "升级失败：\(error.localizedDescription)")
        }
    }

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }

    // MARK: - 忽略升级

    /// 忽略指定版本的升级（在版本列表里左滑）
    func ignoreUpgrade(app: AppInstall, version: AppVersion) async {
        let req = AppIgnoreUpgradeRequest(
            appID: app.appID ?? 0,
            scope: "version",
            appDetailID: version.detailId
        )
        await performIgnore(req: req, app: app, successMsg: "已忽略 v\(version.version ?? "") 的升级提示")
    }

    /// 忽略所有版本的升级（在详情页）
    func ignoreUpgrade(app: AppInstall) async {
        let req = AppIgnoreUpgradeRequest(
            appID: app.appID ?? 0,
            scope: "all",
            appDetailID: nil
        )
        await performIgnore(req: req, app: app, successMsg: "已忽略该应用的所有升级提示")
    }

    private func performIgnore(req: AppIgnoreUpgradeRequest, app: AppInstall, successMsg: String) async {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledIgnore.path,
                body: req,
                as: EmptyResponse.self
            )
            // 先弹窗提示，确认后再返回上一层
            pendingDismissUpgrade = true
            showAlert(message: successMsg)
            // 不立即修改 apps 数组（会破坏 NavigationStack），标记返回列表时再刷新
            needsRefresh = true
        } catch let err as APIError {
            showAlert(message: "操作失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "操作失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 取消忽略升级

    /// 取消指定应用的忽略升级（直接用已加载的 ignoredRecordID）
    func cancelIgnoreUpgrade(app: AppInstall) async {
        guard let recordID = app.ignoredRecordID else {
            showAlert(message: "该应用当前未在忽略列表中")
            return
        }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsIgnoredCancel.path,
                body: ReqWithID(id: recordID),
                as: EmptyResponse.self
            )
            showAlert(message: "已取消忽略升级，后续将正常检查更新")
            needsRefresh = true
        } catch let err as APIError {
            showAlert(message: "取消忽略失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "取消忽略失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 更新参数（重建应用）

    /// 加载已安装应用的当前参数（用于「更新参数」表单）
    @MainActor
    func loadParams(for app: AppInstall) async -> InstalledParamsResponse? {
        isLoadingParams = true
        defer { isLoadingParams = false }
        let path = APIEndpoint.appsInstalledParams.path
            .replacingOccurrences(of: ":installId", with: String(app.id))
        do {
            let resp: InstalledParamsResponse = try await client.send(
                path: path,
                method: APIEndpoint.appsInstalledParams.method,
                as: InstalledParamsResponse.self
            )
            self.loadedParams = resp
            return resp
        } catch let err as APIError {
            showAlert(message: "加载参数失败：\(err.errorDescription ?? "未知错误")")
            return nil
        } catch {
            showAlert(message: "加载参数失败：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 应用商店设置（卸载/升级/安装默认选项）

    /// 加载应用商店设置（GET /api/v2/core/settings/apps/store/config）
    func loadAppStoreConfig() async {
        isLoadingAppStoreConfig = true
        defer { isLoadingAppStoreConfig = false }
        do {
            let resp: AppStoreConfig = try await client.send(
                path: APIEndpoint.appStoreSettingConfig.path,
                method: APIEndpoint.appStoreSettingConfig.method,
                as: AppStoreConfig.self
            )
            self.appStoreConfig = resp
        } catch let err as APIError {
            showAlert(message: "加载应用设置失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "加载应用设置失败：\(error.localizedDescription)")
        }
    }

    /// 更新单项应用商店设置（POST /api/v2/core/settings/apps/store/update）。
    /// 成功后同步本地 appStoreConfig 对应字段，避免重复请求。
    func updateAppStoreSetting(scope: AppStoreSettingScope, enabled: Bool) async {
        let status = enabled ? "Enable" : "Disable"
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appStoreSettingUpdate.path,
                body: AppStoreSettingUpdateRequest(scope: scope.rawValue, status: status),
                as: EmptyResponse.self
            )
            // 本地同步，避免重新拉取
            if appStoreConfig == nil { appStoreConfig = AppStoreConfig() }
            switch scope {
            case .uninstallDeleteBackup: appStoreConfig?.uninstallDeleteBackup = status
            case .uninstallDeleteImage:  appStoreConfig?.uninstallDeleteImage = status
            case .upgradeBackup:         appStoreConfig?.upgradeBackup = status
            case .upgradeDeleteImage:    appStoreConfig?.upgradeDeleteImage = status
            case .installAllowPort:      appStoreConfig?.installAllowPort = status
            }
        } catch let err as APIError {
            showAlert(message: "更新应用设置失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "更新应用设置失败：\(error.localizedDescription)")
        }
    }

    /// 提交参数更新（重建应用）
    func updateParams(app: AppInstall, req: AppParamsUpdateRequest) async {
        isUpdatingParams = true
        paramsUpdated = false
        defer { isUpdatingParams = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledParamsUpdate.path,
                body: req,
                as: EmptyResponse.self
            )
            paramsUpdated = true
            showAlert(message: "参数更新请求已提交，应用正在后台重建中…")
            needsRefresh = true
        } catch let err as APIError {
            showAlert(message: "更新失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "更新失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 卸载应用

    /// 卸载应用（先做删除前检查，再调用 delete 操作）
    /// options: deleteDB（删除数据库） / deleteImage（删除镜像） / deleteBackup（删除备份） / forceDelete（强制删除）
    func uninstall(app: AppInstall,
                   deleteDB: Bool,
                   deleteImage: Bool,
                   deleteBackup: Bool,
                   forceDelete: Bool,
                   taskID: String) async {
        isUninstalling = true
        uninstallDone = false
        defer { isUninstalling = false }

        // 0. 联动检查：查询是否存在一键部署类网站引用了该应用
        do {
            let searchReq = WebsiteSearchRequest(
                name: "", page: 1, pageSize: 200,
                orderBy: "created_at", order: "descending",
                websiteGroupId: 0, type: ""
            )
            let resp: WebsiteListResponse = try await client.send(
                path: APIEndpoint.websitesSearch.path,
                body: searchReq,
                as: WebsiteListResponse.self
            )
            let linked = (resp.items ?? []).filter {
                ($0.appType?.lowercased() == "installed" || ($0.type ?? "").lowercased() == "deployment")
                && ($0.appName ?? "").lowercased() == (app.appName ?? app.name ?? "").lowercased()
            }
            if !linked.isEmpty {
                let names = linked.map { $0.displayName }.joined(separator: "、")
                showAlert(message: "该应用被以下网站使用：\(names)。请先在「工具箱 → 网站」中删除对应网站（删除时可勾选删除关联应用），再卸载此应用。")
                return
            }
        } catch {
            // 网站查询失败时不阻塞卸载，继续走原有流程
        }

        // 1. 删除前检查（后端返回关联资源列表，非空则禁止删除）
        let checkPath = APIEndpoint.appsInstalledDeleteCheck.path
            .replacingOccurrences(of: ":installId", with: String(app.id))
        do {
            let linked: [AppDeleteCheckItem] = try await client.send(
                path: checkPath,
                method: "GET",
                as: [AppDeleteCheckItem].self
            )
            if !linked.isEmpty {
                let names = linked.map { "\($0.name ?? "未知")" }.joined(separator: "、")
                showAlert(message: "应用已经关联以下资源，请检查后重试！\n应用 \(names)")
                return
            }
        } catch {
            // data 为 null 或空数组时可能解码失败，继续执行删除
        }
        // 2. 执行删除
        let req = AppInstalledOperateRequest(
            installId: app.id,
            operate: "delete",
            deleteDB: deleteDB,
            deleteImage: deleteImage,
            forceDelete: forceDelete,
            deleteBackup: deleteBackup,
            taskID: taskID
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledOperate.path,
                body: req,
                as: EmptyResponse.self
            )
            uninstallDone = true
            needsRefresh = true
        } catch let err as APIError {
            showAlert(message: "卸载失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "卸载失败：\(error.localizedDescription)")
        }
    }
}

