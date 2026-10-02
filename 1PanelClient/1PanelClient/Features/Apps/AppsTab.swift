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
    @State private var showUpgradable = false
    @State private var showSettings = false
    @State private var showMenu = false

    // 列表行动作（动作统一：左划 → 长按半屏菜单，与网站列表同构）
    /// 单击推入详情的目标（tap 手势 + 编程式推入，避免 NavigationLink
    /// 内置点击与长按手势在整行 contentShape 上竞争）
    @State private var pushedApp: AppInstall?
    /// 长按弹操作菜单的目标
    @State private var actionApp: AppInstall?
    /// 菜单动作延迟到 sheet 收起后执行（时序说明见 WebsitesTab 同名实现）
    @State private var pendingMenuAction: (() -> Void)?
    /// 启停/重启/重建的确认弹窗目标
    @State private var pendingRowOperate: (app: AppInstall, op: AppOperation)?
    /// 编辑（更新参数）推入目标
    @State private var editTarget: AppInstall?
    /// 备份列表推入目标
    @State private var backupTarget: AppInstall?

    // 卸载（长按菜单「卸载」）：确认 sheet + 选项 + 进度
    @State private var uninstallTarget: AppInstall?
    @State private var showUninstallProgress = false
    @State private var uninstallTaskID = ""
    @State private var uninstallDeleteDB = false
    @State private var uninstallDeleteImage = false
    @State private var uninstallDeleteBackup = false
    @State private var uninstallForceDelete = false


    init(manager: ServerManager) {
        self.manager = manager
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(key: ManageItem.apps.storeKey(server: server)) {
            AppsViewModel(server: server)
        })
    }

    var body: some View {
        rootContent
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .toastOverlay(message: $vm.toastMessage)
        .onReceive(NotificationCenter.default.publisher(for: .installCompleted)) { _ in
            // 安装完成，分步收栈的最后一步：等进度页、安装表单依次退场（各 0.35s）
            // 再关商店并刷新列表——同帧整链拆除会触发
            // NavigationRequestObserver「每帧多次更新」警告
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.7))
                showStore = false
                await vm.refresh()
            }
        }
        .task { await PageVMStore.shared.autoRefresh(vm: vm) { await vm.refresh() } }
    }

    /// 列表根内容（不含 NavigationStack），供 ManageTab 嵌入复用
    var rootContent: some View {
        VStack(spacing: 0) {
            // 类别筛选条放在分支外常驻：选中类别无应用时仍能切回「全部」（空 key 无法筛选，剔除）
            if !vm.tags.isEmpty {
                ChipsFilterBar(
                    items: vm.tags
                        .filter { !($0.key ?? "").isEmpty }
                        .map { .init(id: $0.key ?? "", title: $0.displayName) },
                    allID: "",
                    selectedID: $vm.selectedTagKey
                )
            }

            if vm.isLoading && vm.apps.isEmpty {
                LoadingStateView()
            } else if let err = vm.errorMessage, !err.isEmpty, vm.apps.isEmpty {
                LoadErrorStateView(message: err) {
                    Task { await vm.refresh() }
                }
            } else if vm.apps.isEmpty {
                if vm.selectedTagKey.isEmpty {
                    ContentUnavailableView(
                        L10n.t("暂无已安装应用"),
                        systemImage: "shippingbox",
                        description: Text(L10n.t("这台服务器上没有已安装的应用"))
                    )
                } else {
                    ContentUnavailableView(
                        L10n.t("该类别暂无已安装应用"),
                        systemImage: "shippingbox"
                    )
                }
            } else {
                appList
            }
        }
        // 右上角收敛为两键：放大镜（搜索）+ 省略号（商店/可升级/设置）
        .searchIconMode(
            text: $searchText,
            isSearching: $isSearching,
            title: L10n.t("应用"),
            prompt: L10n.t("搜索已安装应用")
        )
        .toolbar {
            if !isSearching {
                ToolbarItem(placement: .topBarTrailing) {
                    EllipsisMenuButton {
                        withAnimation(Motion.fast) { showMenu.toggle() }
                    }
                    .accessibilityLabel(L10n.t("更多"))
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if showMenu {
                EllipsisMenuPopup(entries: [
                    .action(title: L10n.t("商店"), icon: "storefront") { showStore = true },
                    .action(title: L10n.t("可升级"), icon: "arrow.trianglehead.2.clockwise.rotate.90") { showUpgradable = true },
                    .action(title: L10n.t("设置"), icon: "gear") { showSettings = true },
                ]) {
                    withAnimation(Motion.fast) { showMenu = false }
                }
            }
        }
        .onChange(of: searchText) { _, newValue in
            Task { await vm.search(query: newValue) }
        }
        .onChange(of: vm.selectedTagKey) { _, _ in
            // 切换类别：沿用当前搜索词重查第一页
            Task { await vm.search(query: searchText) }
        }
        // 单击行进入详情（pushedApp 由行 tap 手势驱动；pop 时自动置 nil）
        .navigationDestination(item: $pushedApp) { app in
            AppDetailView(app: app, vm: vm)
        }
        // 长按菜单「编辑」→ 更新参数（与详情页同一页面）
        .navigationDestination(item: $editTarget) { app in
            UpdateParamsView(app: app, vm: vm)
        }
        // 长按菜单「备份」→ 应用备份列表（type=app，name/detailName 均为安装名）
        .navigationDestination(item: $backupTarget) { app in
            BackupListView(target: BackupTarget(
                type: "app",
                name: app.name ?? "",
                detailName: app.name ?? ""
            ))
        }
        .navigationDestination(isPresented: $showUpgradable) {
            UpgradableAppsView(vm: vm)
        }
        .navigationDestination(isPresented: $showSettings) {
            AppStoreSettingsView(vm: vm)
        }
        .navigationDestination(isPresented: $showStore) {
            AppStoreTab(manager: manager)
        }
        // 长按行的半屏操作菜单（启停/重启/重建/编辑/备份/卸载）。
        // pendingMenuAction 模式时序前提：ActionBottomSheet 在 Task 下一 MainActor
        // 周期执行菜单闭包（写入 pendingMenuAction），必然早于 sheet 收起动画完成
        // 后才回调的 onDismiss——runPendingMenuAction 取到动作后再弹确认层
        .sheet(item: $actionApp, onDismiss: {
            runPendingMenuAction()
        }) { app in
            ActionBottomSheet(
                title: app.displayName,
                items: appActions(app),
                onDismiss: { actionApp = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: appActions(app).count))])
            .presentationDragIndicator(.visible)
        }
        // 长按菜单：启停/重启/重建确认（口径同详情页操作区）
        .alert(
            pendingRowOperate?.op.displayName ?? "",
            isPresented: Binding(
                get: { pendingRowOperate != nil },
                set: { if !$0 { pendingRowOperate = nil } }
            )
        ) {
            Button(L10n.t("取消"), role: .cancel) { pendingRowOperate = nil }
            Button(L10n.t("确认")) {
                guard let target = pendingRowOperate else { return }
                pendingRowOperate = nil
                Task { await vm.operate(app: target.app, op: target.op) }
            }
        } message: {
            if let target = pendingRowOperate {
                Text(L10n.f("将对应用「%@」进行 %@ 操作，是否继续？", target.app.displayName, target.op.displayName))
            }
        }
        // 长按菜单：卸载确认（输入应用名 + 连带删除选项，与详情页同款组件）
        .sheet(item: $uninstallTarget) { app in
            TextInputConfirmSheet(
                title: L10n.f("卸载 %@", app.displayName),
                message: L10n.f("此操作不可恢复。请输入应用名称「%@」以确认卸载。", app.displayName),
                expectedText: app.displayName,
                fieldLabel: L10n.t("确认名称"),
                fieldPlaceholder: L10n.t("应用名称"),
                confirmTitle: L10n.t("卸载")
            ) {
                Task { await performUninstall(app) }
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
        // 卸载进度（确认提交成功后推入；完成/后台运行均返回列表）
        .navigationDestination(isPresented: $showUninstallProgress) {
            TaskProgressView(
                taskID: uninstallTaskID,
                title: L10n.t("卸载应用"),
                onComplete: { isDone in
                    vm.needsRefresh = true
                    if isDone { Task { await vm.refresh() } }
                    return false
                }
            )
        }
    }

    private var appList: some View {
        List {
            Section {
                ForEach(vm.apps) { app in
                    // 单击进详情 / 长按弹操作菜单（启停/重启/重建/编辑/备份/卸载）：
                    // 行手势全站统一口径，原左划启停/重启已并入长按菜单
                    AppRow(
                        app: app,
                        isOperating: vm.operatingAppIds.contains(app.id)
                    )
                    .rowTapAndLongPress(
                        onTap: { pushedApp = app },
                        onLongPress: { actionApp = app }
                    )
                    // VoiceOver 无长按手势：以自定义操作暴露同一菜单
                    .accessibilityAction(named: L10n.t("更多操作")) { actionApp = app }
                    .onAppear {
                        if app.id == vm.apps.last?.id {
                            Task { await vm.loadMoreApps() }
                        }
                    }
                }
                if vm.apps.count < vm.total || vm.isLoadingMore {
                    LoadingStateView(compact: true)
                    .onAppear { Task { await vm.loadMoreApps() } }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await vm.refresh()
        }
    }

    // MARK: - 长按操作菜单

    /// 菜单条目与详情页操作区同集：启停/重启/重建/编辑/备份/卸载
    private func appActions(_ app: AppInstall) -> [ActionMenuItem] {
        [
            ActionMenuItem(
                title: app.isRunning ? L10n.t("停止") : L10n.t("启动"),
                icon: app.isRunning ? "stop.fill" : "play.fill",
                color: app.isRunning ? .orange : .green
            ) {
                pendingMenuAction = {
                    pendingRowOperate = (app, app.isRunning ? .stop : .start)
                }
            },
            ActionMenuItem(title: L10n.t("重启"), icon: "arrow.triangle.2.circlepath", color: .blue) {
                pendingMenuAction = { pendingRowOperate = (app, .restart) }
            },
            ActionMenuItem(title: L10n.t("重建"), icon: "hammer", color: .indigo) {
                pendingMenuAction = { pendingRowOperate = (app, .rebuild) }
            },
            ActionMenuItem(title: L10n.t("编辑"), icon: "slider.horizontal.3", color: .teal) {
                pendingMenuAction = { editTarget = app }
            },
            ActionMenuItem(title: L10n.t("备份"), icon: "externaldrive.badge.timemachine", color: .purple) {
                pendingMenuAction = { backupTarget = app }
            },
            ActionMenuItem(title: L10n.t("卸载"), icon: "trash", color: .red, role: .destructive) {
                pendingMenuAction = { Task { await prepareUninstall(app) } }
            },
        ]
    }

    private func runPendingMenuAction() {
        guard let action = pendingMenuAction else { return }
        pendingMenuAction = nil
        action()
    }

    /// 打开卸载确认前确保应用设置已加载，「删除备份 / 删除镜像」默认勾选
    /// 与设置页保持一致（同详情页 prepareUninstall）
    private func prepareUninstall(_ app: AppInstall) async {
        if vm.appStoreConfig == nil {
            await vm.loadAppStoreConfig()
        }
        uninstallDeleteBackup = vm.appStoreConfig?.isUninstallDeleteBackup ?? false
        uninstallDeleteImage = vm.appStoreConfig?.isUninstallDeleteImage ?? false
        uninstallTarget = app
    }

    /// 执行卸载：成功后收确认 sheet 并推入任务进度页
    private func performUninstall(_ app: AppInstall) async {
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
            uninstallTarget = nil
            uninstallTaskID = taskID
            showUninstallProgress = true
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
                    RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                        .fill(.thinMaterial)
                        .frame(width: 44, height: 44)
                    ProgressView()
                        .scaleEffect(0.7)
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
                        StatusBadge(text: L10n.t("有更新"), color: .orange, icon: "arrow.up.circle.fill")
                    }
                }
            }

            Spacer()

            HStack(spacing: 4) {
                StatusDot(color: app.statusColor)
                Text(app.isRunning ? L10n.t("已启动") : (app.status ?? L10n.t("未知")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

