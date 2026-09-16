//
//  WebsitesTab.swift
//  1PanelClient
//

import SwiftUI
import Combine

struct WebsitesTab: View {
    @ObservedObject var manager: ServerManager
    @StateObject private var vm: WebsitesViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var showCreate = false
    @State private var showOpenRestyConfig = false
    // OpenResty 管理增强页入口
    @State private var showOpenRestyStatus = false
    @State private var showOpenRestyPerformance = false
    @State private var showOpenRestyModules = false
    @State private var showOpenRestyOther = false
    // 分组管理推页入口（筛选条末尾「管理」chip）
    @State private var showGroupManage = false
    // 批量操作（多选模式，logs/网站批量抓包 2026-09-14）
    @State private var isSelecting = false
    @State private var selectedIDs: Set<Int> = []
    @State private var showBatchGroup = false
    @State private var showBatchSSL = false
    @State private var pendingBatchDelete = false
    @State private var isBatchOperating = false
    @State private var batchTask: WebsiteBatchTask?
    // 长按行菜单：单站启停 / 删除确认
    @State private var pendingRowOperate: (website: Website, operate: String)?
    @State private var pendingRowDelete: Website?
    /// 长按行的半屏操作菜单目标
    @State private var actionWebsite: Website?
    /// 单击行推入的网站详情（tap 手势 + item destination 编程式导航）
    @State private var pushedWebsite: Website?
    /// 挂起的菜单动作：菜单完全收起（sheet onDismiss）后再执行，
    /// 避免与下一级 alert/多选切换的呈现竞争
    @State private var pendingMenuAction: (() -> Void)?
    /// OpenResty 未安装时的应用商店 VM（列表安装按钮直达应用详情，安装流程复用应用商店页面）
    @StateObject private var openRestyInstallVM: AppStoreViewModel
    /// 分组管理页所需服务器配置（init 时固定，避免 manager.current 中途切换）
    private let server: ServerConfig


    init(manager: ServerManager) {
        self.manager = manager
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        self.server = server
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(key: ManageItem.websiteList.storeKey(server: server)) {
            WebsitesViewModel(server: server)
        })
        _openRestyInstallVM = StateObject(wrappedValue: AppStoreViewModel(server: server))
    }

    var body: some View {
        rootContent
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
        Text(vm.alertMessage)
        }
        .toastOverlay(message: $vm.toastMessage)
        .task { await PageVMStore.shared.autoRefresh(vm: vm) { await vm.refresh() } }
        // 安装完成（含从本页未安装入口发起的安装）后重查安装状态并刷新列表
        .onReceive(NotificationCenter.default.publisher(for: .installCompleted)) { _ in
            Task { await vm.refresh(force: true) }
        }
    }

    /// 列表根内容（不含 NavigationStack）
    var rootContent: some View {
        VStack(spacing: 0) {
            // 分组筛选条放在分支外常驻（末尾「管理」入口推入分组管理页）：
            // 选中分组无网站时仍能切回「全部」；OpenResty 未安装整页引导时不展示
            if !vm.openRestyNotInstalled && !vm.groups.isEmpty {
                GroupFilterBar(groups: vm.groups, selectedID: $vm.selectedGroupID) {
                    showGroupManage = true
                }
            }

            // 未装判断放在加载态之前（与 WAF 页一致）：安装完成点「完成」后本页立刻
            // 强制刷新，旧检查结果（未装）让引导分支存活到收栈完成；若加载态优先，
            // 分支切换会把引导组件连同其导航注册一起拔掉，进度页的「完成」收不回导航
            if vm.openRestyNotInstalled {
                // OpenResty 未安装：整页安装引导（同 WAF 页），安装完成后收到通知自动刷新
                OpenRestyInstallPrompt(
                    storeVM: openRestyInstallVM,
                    message: L10n.t("网站功能依赖 OpenResty，请先安装后再使用")
                )
            } else if vm.isLoading && vm.websites.isEmpty {
                LoadingStateView()
            } else {
                websiteList
            }
        }
        // 右上角两键：放大镜（搜索）+ 创建；多选时为退出按钮（与文件页一致）；
        // 分组管理入口在筛选条末尾（推页呈现）；多选入口在行长按菜单
        .searchIconMode(
            text: $searchText,
            isSearching: $isSearching,
            title: L10n.t("网站"),
            prompt: L10n.t("搜索域名")
        )
        .toolbar {
            if !isSearching {
                ToolbarItem(placement: .topBarTrailing) {
                    if isSelecting {
                        // 退出多选（批量操作栏不再放退出按钮，与文件页一致）
                        Button {
                            exitSelecting()
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .accessibilityLabel(L10n.t("退出多选"))
                    } else {
                        Button {
                            showCreate = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        // OpenResty 未安装时无法创建网站（环境检查必然失败）
                        .disabled(vm.openRestyNotInstalled)
                        .accessibilityLabel(L10n.t("创建网站"))
                    }
                }
            }
        }
        .onChange(of: searchText) { _, newValue in
            Task { await vm.search(query: newValue) }
        }
        .onChange(of: vm.selectedGroupID) { _, _ in
            // 切换分组：沿用当前搜索词重查第一页
            Task { await vm.search(query: searchText) }
        }
        .navigationDestination(isPresented: $showCreate) {
            CreateWebsiteView(vm: vm)
        }
        // 单击行进入详情（pushedWebsite 由行 tap 手势驱动；pop 时自动置 nil）
        .navigationDestination(item: $pushedWebsite) { w in
            WebsiteDetailView(website: w, vm: vm)
        }
        .navigationDestination(isPresented: $showGroupManage) {
            GroupManageView(server: server, scope: .website) {
                Task { await vm.refresh(force: true) }
            }
        }
        .navigationDestination(isPresented: $showOpenRestyConfig) {
            OpenRestyConfigView(vm: vm)
        }
        .navigationDestination(isPresented: $showOpenRestyStatus) {
            OpenRestyStatusView(vm: vm)
        }
        .navigationDestination(isPresented: $showOpenRestyPerformance) {
            OpenRestyPerformanceView(vm: vm)
        }
        .navigationDestination(isPresented: $showOpenRestyModules) {
            OpenRestyModulesView(vm: vm)
        }
        .navigationDestination(isPresented: $showOpenRestyOther) {
            OpenRestyOtherView(vm: vm)
        }
        // 批量操作：删除确认 + 分组/证书 Sheet + 任务进度
        .alert(L10n.t("批量删除网站"), isPresented: $pendingBatchDelete) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("删除"), role: .destructive) {
                Haptic.warning()
                Task { await batchOperate("delete") }
            }
        } message: {
            Text(L10n.f("将删除选中的 %ld 个网站及其配置，该操作无法回滚，是否继续？", selectedIDs.count))
        }
        // 长按行的半屏操作菜单（多选/启停/删除）
        .sheet(item: $actionWebsite, onDismiss: {
            runPendingMenuAction()
        }) { w in
            ActionBottomSheet(
                title: w.displayName,
                items: websiteActions(w),
                onDismiss: { actionWebsite = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: websiteActions(w).count))])
            .presentationDragIndicator(.visible)
        }
        // 长按菜单：单站启停确认
        .alert(
            pendingRowOperate.map { $0.operate == "stop" ? L10n.t("停止") : L10n.t("启用") } ?? "",
            isPresented: Binding(
                get: { pendingRowOperate != nil },
                set: { if !$0 { pendingRowOperate = nil } }
            )
        ) {
            Button(L10n.t("取消"), role: .cancel) { pendingRowOperate = nil }
            Button(L10n.t("确认")) {
                guard let target = pendingRowOperate else { return }
                pendingRowOperate = nil
                Task {
                    if await vm.operateWebsite(id: target.website.id, operate: target.operate) {
                        await vm.refresh(force: true)
                    }
                }
            }
        } message: {
            if let target = pendingRowOperate {
                Text(L10n.f(
                    "将对网站「%@」进行 %@ 操作，是否继续？",
                    target.website.displayName,
                    target.operate == "stop" ? L10n.t("停止") : L10n.t("启用")))
            }
        }
        // 长按菜单：单站删除确认（R1 输入域名 + 连带删除选项，与详情页同款组件；
        // 此前为一键 alert，生产站点可被误删，确认强度与详情页相差一个量级）
        .sheet(item: $pendingRowDelete) { w in
            WebsiteDeleteConfirmSheet(website: w, vm: vm)
        }
        .sheet(isPresented: $showBatchGroup) {
            WebsiteBatchGroupSheet(server: server, ids: Array(selectedIDs), groups: vm.groups) {
                exitSelecting()
                vm.toastMessage = L10n.t("分组已更新")
                await vm.refresh(force: true)
            }
        }
        .sheet(isPresented: $showBatchSSL) {
            WebsiteBatchSSLSheet(server: server, ids: Array(selectedIDs)) { taskID in
                exitSelecting()
                batchTask = WebsiteBatchTask(taskID: taskID, title: L10n.t("批量设置证书"))
            }
        }
        .navigationDestination(item: $batchTask) { task in
            TaskProgressView(taskID: task.taskID, title: task.title) { isDone in
                if isDone {
                    Task { await vm.refresh(force: true) }
                }
                return false
            }
        }
    }

    // MARK: - 批量操作（多选）

    /// 多选行：勾选圈 + 原行内容
    private func selectingRow(_ w: Website) -> some View {
        Button {
            if selectedIDs.contains(w.id) {
                selectedIDs.remove(w.id)
            } else {
                selectedIDs.insert(w.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedIDs.contains(w.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedIDs.contains(w.id) ? Color.accentColor : Color.secondary)
                WebsiteRow(website: w)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func exitSelecting() {
        withAnimation(Motion.standard) {
            isSelecting = false
            selectedIDs.removeAll()
        }
    }

    /// 与 Website.statusColor 同口径：running / normal 视为运行中
    private func isRunning(_ w: Website) -> Bool {
        ["running", "normal"].contains((w.status ?? "").lowercased())
    }

    /// 长按行的半屏菜单项：多选 / 停止·启用 / 删除
    /// （动作经 pendingMenuAction 挂起，菜单收起后再触发）
    private func websiteActions(_ w: Website) -> [ActionMenuItem] {
        [
            ActionMenuItem(title: L10n.t("多选"), icon: "checkmark.circle", color: .blue) {
                pendingMenuAction = {
                    withAnimation(Motion.standard) {
                        isSelecting = true
                        selectedIDs.insert(w.id)
                    }
                }
            },
            ActionMenuItem(
                title: isRunning(w) ? L10n.t("停止") : L10n.t("启用"),
                icon: isRunning(w) ? "stop.fill" : "play.fill",
                color: isRunning(w) ? .orange : .green
            ) {
                pendingMenuAction = {
                    pendingRowOperate = (w, isRunning(w) ? "stop" : "start")
                }
            },
            ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red, role: .destructive) {
                pendingMenuAction = { pendingRowDelete = w }
            },
        ]
    }

    private func runPendingMenuAction() {
        guard let action = pendingMenuAction else { return }
        pendingMenuAction = nil
        action()
    }

    /// 批量启停/删除：POST batch/operate（delete 与启停共用端点，抓包确认）
    private func batchOperate(_ operate: String) async {
        let ids = Array(selectedIDs)
        guard !ids.isEmpty else { return }
        isBatchOperating = true
        defer { isBatchOperating = false }
        let taskID = UUID().uuidString
        do {
            let _: EmptyResponse = try await vm.client.send(
                path: APIEndpoint.websitesBatchOperate.path,
                body: WebsiteBatchOperateRequest(operate: operate, ids: ids, taskID: taskID),
                as: EmptyResponse.self)
            exitSelecting()
            let title: String
            switch operate {
            case "start": title = L10n.t("批量开启网站")
            case "stop": title = L10n.t("批量关闭网站")
            default: title = L10n.t("批量删除网站")
            }
            batchTask = WebsiteBatchTask(taskID: taskID, title: title)
        } catch {
            guard !APIError.isCancellation(error) else { return }
            vm.showAlert = true
            vm.alertMessage = error.localizedDescription
        }
    }

    private var websiteList: some View {
        List {
            // 顶部 OpenResty 信息与管理卡片
            OpenRestyCard(
                vm: vm,
                showConfig: $showOpenRestyConfig,
                showStatus: $showOpenRestyStatus,
                showPerformance: $showOpenRestyPerformance,
                showModules: $showOpenRestyModules,
                showOther: $showOpenRestyOther
            )

            if vm.websites.isEmpty {
                Section {
                    if let err = vm.errorMessage, !err.isEmpty, !vm.isLoadingOpenResty {
                        ContentUnavailableView {
                            Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(err)
                        } actions: {
                            Button(L10n.t("重试")) {
                                Task { await vm.refresh(force: true) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else if vm.isLoadingOpenResty {
                        // 安装状态判定中：等结论出来再展示空态/错误，
                        // 避免未安装场景先闪现「加载失败/创建网站」误导文案
                        EmptyView()
                    } else {
                        ContentUnavailableView(
                            L10n.t("暂无网站"),
                            systemImage: "globe",
                            description: Text(L10n.t("点击右上角 + 创建第一个网站"))
                        )
                    }
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(vm.websites) { w in
                        if isSelecting {
                            selectingRow(w)
                        } else {
                            // 单击/长按自处理（与文件页同构）：NavigationLink 的内置点击
                            // 会与外挂长按手势在整行 contentShape 上竞争（单击失灵），
                            // 改为 tap 手势 + navigationDestination(item:) 编程式推入
                            WebsiteRow(website: w)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    pushedWebsite = w
                                }
                                // 长按弹半屏操作菜单（多选/启停/删除）
                                .onLongPressGesture(minimumDuration: 0.5) {
                                    Haptic.selection()
                                    actionWebsite = w
                                }
                                .onAppear {
                                    if w.id == vm.websites.last?.id {
                                        Task { await vm.loadMoreWebsites() }
                                    }
                                }
                        }
                    }
                    if !isSelecting && (vm.websites.count < vm.total || vm.isLoadingMore) {
                        LoadingStateView(compact: true)
                        .onAppear { Task { await vm.loadMoreWebsites() } }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await vm.refresh(force: true)
        }
        // 多选模式底部批量操作栏（退出在右上角工具栏）
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                WebsiteBatchBar(
                    selectedCount: selectedIDs.count,
                    totalCount: vm.websites.count,
                    isOperating: isBatchOperating,
                    onSelectAll: {
                        if selectedIDs.count >= vm.websites.count {
                            selectedIDs.removeAll()
                        } else {
                            selectedIDs = Set(vm.websites.map(\.id))
                        }
                    },
                    onOperate: { operate in
                        if operate == "delete" {
                            pendingBatchDelete = true
                        } else {
                            Task { await batchOperate(operate) }
                        }
                    },
                    onGroup: { showBatchGroup = true },
                    onSSL: { showBatchSSL = true }
                )
            }
        }
    }
}

// MARK: - OpenResty 信息与管理卡片

struct OpenRestyCard: View {
    @ObservedObject var vm: WebsitesViewModel
    @State private var isExpanded = false
    @Binding var showConfig: Bool
    // 管理增强页入口（destination 由 WebsitesTab 挂在根内容上：
    // 挂在 List 内的 Section 上时导航注册不可靠）
    @Binding var showStatus: Bool
    @Binding var showPerformance: Bool
    @Binding var showModules: Bool
    @Binding var showOther: Bool
    @State private var pendingAction: String?

    init(vm: WebsitesViewModel,
         showConfig: Binding<Bool>,
         showStatus: Binding<Bool>,
         showPerformance: Binding<Bool>,
         showModules: Binding<Bool>,
         showOther: Binding<Bool>) {
        self.vm = vm
        self._showConfig = showConfig
        self._showStatus = showStatus
        self._showPerformance = showPerformance
        self._showModules = showModules
        self._showOther = showOther
    }

    var body: some View {
        Group {
            if vm.isLoadingOpenResty && vm.openresty == nil {
                Section {
                    ServiceStatusLoadingRow(text: L10n.t("加载 OpenResty 状态…"))
                }
            } else if let app = vm.openresty {
                ServiceStatusCard(
                    title: "OpenResty",
                    subtitle: app.version.flatMap { $0.isEmpty ? nil : "v\($0)" },
                    statusText: app.status ?? L10n.t("未知"),
                    statusColor: app.statusColor,
                    isOperating: vm.openRestyOperating,
                    isExpanded: $isExpanded,
                    actions: [
                        ServiceAction(
                            title: app.isRunning ? L10n.t("停止") : L10n.t("启动"),
                            icon: app.isRunning ? "stop.fill" : "play.fill",
                            color: app.isRunning ? .orange : .green
                        ) { pendingAction = app.isRunning ? "stop" : "start" },
                        ServiceAction(title: L10n.t("重启"), icon: "arrow.triangle.2.circlepath", color: .blue) {
                            pendingAction = "restart"
                        },
                        ServiceAction(title: L10n.t("重载"), icon: "arrow.clockwise", color: .teal) {
                            pendingAction = "reload"
                        },
                        ServiceAction(title: L10n.t("配置"), icon: "slider.horizontal.3", color: .purple) {
                            showConfig = true
                        },
                        ServiceAction(title: L10n.t("状态"), icon: "gauge", color: .mint) {
                            showStatus = true
                        },
                        ServiceAction(title: L10n.t("性能调整"), icon: "speedometer", color: .indigo) {
                            showPerformance = true
                        },
                        ServiceAction(title: L10n.t("模块"), icon: "puzzlepiece", color: .cyan) {
                            showModules = true
                        },
                        ServiceAction(title: L10n.t("其他"), icon: "ellipsis", color: .brown) {
                            showOther = true
                        },
                    ]
                ) {
                    // OpenResty 使用内置品牌图标，避免依赖服务器应用图标接口
                    BrandIcon(brand: .openresty, size: 44)
                }
            } else {
                Section {
                    ServiceStatusFailedRow(text: L10n.t("OpenResty 未安装或加载失败"))
                }
            }
        }
        .alert(
            pendingAction.map { openRestyActionDisplayName($0) } ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            )
        ) {
            Button(L10n.t("取消"), role: .cancel) { pendingAction = nil }
            // 启动/停止/重启/重载均为可逆服务操作，不用红色破坏性样式
            Button(L10n.t("确认")) { executeOpenRestyAction() }
        } message: {
            if let action = pendingAction {
                Text(L10n.f("将对 OpenResty 进行 %@ 操作，是否继续？", openRestyActionDisplayName(action)))
            }
        }
    }

    private func openRestyActionDisplayName(_ action: String) -> String {
        switch action {
        case "stop":    return L10n.t("停止")
        case "start":   return L10n.t("启动")
        case "restart": return L10n.t("重启")
        case "reload":  return L10n.t("重载")
        default:        return action
        }
    }

    private func executeOpenRestyAction() {
        let action = pendingAction
        pendingAction = nil
        guard let action else { return }
        let op: AppOperation
        switch action {
        case "stop":    op = .stop
        case "start":   op = .start
        case "restart": op = .restart
        case "reload":  op = .reload
        default:        return
        }
        Task { await vm.operateOpenResty(op: op) }
    }
}

// MARK: - OpenResty 未安装整页引导（网站 / WAF 页共用）

/// OpenResty 未安装：淡化品牌图标 + 说明 + 直达应用商店的安装按钮
/// （安装流程复用应用商店页面，列表页收到 installCompleted 通知后自行刷新）
struct OpenRestyInstallPrompt: View {
    /// 应用商店 ViewModel（详情页 + 安装表单共用）
    @ObservedObject var storeVM: AppStoreViewModel
    /// 依赖说明文案（网站/WAF 各自传入）
    let message: String

    /// 详情页推入开关：用 isPresented 而非 NavigationLink，安装完成后才能程序化
    /// 收回整条导航链（进度页「完成」声明由调用方处理导航，见 AppInstallView onComplete）
    @State private var showDetail = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            BrandIcon(brand: .openresty, size: 72)
                .opacity(0.5)

            VStack(spacing: 8) {
                Text(L10n.t("OpenResty 未安装"))
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                showDetail = true
            } label: {
                Label(L10n.t("安装 OpenResty"), systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)

            Spacer()
        }
        .padding()
        // 安装完成后的导航回收在被 push 的 OpenRestyInstallFlowDetailView 里处理：
        // 宿主页（网站/WAF）收到同一通知会强制刷新，可能把本引导分支换掉，
        // 回收逻辑若挂在这里会随 @State 一起被销毁，导致「完成」收不回导航
        .navigationDestination(isPresented: $showDetail) {
            OpenRestyInstallFlowDetailView(storeVM: storeVM)
        }
    }
}

/// 应用详情页包装：进度页「完成」把导航交还发起方处理（onComplete 返回 true 不自行
/// dismiss），由本视图在收到 installCompleted 后收回整条链——挂在被 push 的视图上，
/// 不随宿主页刷新换分支而销毁，dismiss 始终有效（同数据库页安装流程模式）
private struct OpenRestyInstallFlowDetailView: View {
    @ObservedObject var storeVM: AppStoreViewModel

    /// 是否已进入安装表单（用于区分「自己的安装完成」与无关的全局 installCompleted 通知）
    @State private var didEnterInstall = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AppStoreDetailView(appKey: "openresty", vm: storeVM)
            // 跟踪是否进入过安装表单（showInstall true→false 表示用户开始了安装流程）
            .onChange(of: storeVM.showInstall) { _, isShown in
                if isShown { didEnterInstall = true }
            }
            // 安装完成：两步收回导航链（先弹安装表单+进度页，再弹详情页），
            // 仅当确实进入了本流程发起的安装时才回收，
            // 避免无关的全局 installCompleted 通知误触发（表现为点击安装变返回）
            .onReceive(NotificationCenter.default.publisher(for: .installCompleted)) { _ in
                guard didEnterInstall else { return }
                storeVM.showInstall = false
                // 等导航栈稳定后再 dismiss，避免动画冲突
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    dismiss()
                }
            }
    }
}

// MARK: - 网站列表行

struct WebsiteRow: View {
    let website: Website

    /// 上：主域名:端口；下：类型 [appName]；右：状态
    /// （浏览器打开链接入口在网站详情页右上角 toolbar）
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(domainLine)
                    .font(.body.bold())
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(website.typeDisplayName)
                    if let app = website.appName, !app.isEmpty {
                        Text("[\(app)]")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 4) {
                StatusDot(color: website.statusColor)
                Text(website.status ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        // 整行可命中长按手势（Spacer 区域默认不响应 hit-test）
        .contentShape(Rectangle())
    }

    /// 域名:端口 组合显示
    private var domainLine: String {
        var line = website.displayName
        if let port = website.port, port > 0 {
            line += ":\(port)"
        }
        return line
    }
}

// MARK: - 网站详情页图标

/// HTTPS 入口行首图标（key.shield，蓝色随明暗主题自适应）
struct HTTPSLinkIcon: View {
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: "key.shield")
            .font(.panelScaled(size * 0.85, weight: .medium))
            .foregroundStyle(.blue)
            .frame(width: size, height: size)
    }
}

