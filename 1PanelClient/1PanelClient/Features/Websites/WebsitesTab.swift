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
        _vm = StateObject(wrappedValue: WebsitesViewModel(server: server))
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
        .task { await vm.refresh() }
        // 安装完成（含从本页未安装入口发起的安装）后重查安装状态并刷新列表
        .onReceive(NotificationCenter.default.publisher(for: .installCompleted)) { _ in
            Task { await vm.refresh(force: true) }
        }
    }

    /// 列表根内容（不含 NavigationStack）
    var rootContent: some View {
        Group {
            if vm.isLoading && vm.websites.isEmpty {
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
            if vm.openRestyNotInstalled {
                // OpenResty 未安装：网站功能依赖它，整页只保留安装入口
                // （安装按钮直达应用商店详情页，安装完成后本页收到通知自动刷新）
                Section("OpenResty") {
                    NotInstalledOpenRestyRow()
                    NavigationLink {
                        AppStoreDetailView(appKey: "openresty", vm: openRestyInstallVM)
                    } label: {
                        Label(L10n.t("安装 OpenResty"), systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
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

// MARK: - OpenResty 未安装占位

/// 未安装占位行：淡化品牌图标 + 名称 + 未安装标签（安装按钮在同一 Section 直达应用商店）
struct NotInstalledOpenRestyRow: View {
    var body: some View {
        HStack(spacing: 14) {
            BrandIcon(brand: .openresty, size: 44)
                .opacity(0.4)
            VStack(alignment: .leading, spacing: 3) {
                Text("OpenResty").font(.headline).foregroundStyle(.secondary)
                Text(L10n.t("未安装"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
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

