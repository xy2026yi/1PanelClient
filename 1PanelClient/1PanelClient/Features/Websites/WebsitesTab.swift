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
    /// OpenResty 未安装时的应用商店 VM（列表安装按钮直达应用详情，安装流程复用应用商店页面）
    @StateObject private var openRestyInstallVM: AppStoreViewModel


    init(manager: ServerManager) {
        self.manager = manager
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
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
        Group {
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
        // 右上角两键：放大镜（搜索）+ 创建；证书入口已上移至 管理-网站 Hub 页
        .searchIconMode(
            text: $searchText,
            isSearching: $isSearching,
            title: L10n.t("网站"),
            prompt: L10n.t("搜索域名")
        )
        .toolbar {
            if !isSearching {
                ToolbarItem(placement: .topBarTrailing) {
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
        .onChange(of: searchText) { _, newValue in
            Task { await vm.search(query: newValue) }
        }
        .navigationDestination(for: Website.self) { website in
            WebsiteDetailView(website: website, vm: vm)
        }
        .navigationDestination(isPresented: $showCreate) {
            CreateWebsiteView(vm: vm)
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
                        NavigationLink(value: w) {
                            WebsiteRow(website: w)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await vm.refresh(force: true)
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

// MARK: - 网站详情页图标（logs/HTTPS.svg 样式）

/// HTTPS 入口行首图标（HTTPS.svg 样式的盾牌，template 渲染随明暗主题自适应）
struct HTTPSLinkIcon: View {
    var size: CGFloat = 20

    var body: some View {
        Image("icon-https")
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(.blue)
    }
}

