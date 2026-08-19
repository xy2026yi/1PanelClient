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
    @State private var showCreateSheet = false
    @State private var showCerts = false
    @State private var showOpenRestyConfig = false
    @State private var showMenu = false


    init(manager: ServerManager) {
        self.manager = manager
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: WebsitesViewModel(server: server))
    }

    var body: some View {
        rootContent
        .alert(vm.alertMessage, isPresented: $vm.showAlert) {
            Button("好", role: .cancel) {}
        }
        .task { await vm.refresh() }
    }

    /// 列表根内容（不含 NavigationStack）
    var rootContent: some View {
        Group {
            if vm.isLoading && vm.websites.isEmpty {
                ProgressView("加载中…")
            } else {
                websiteList
            }
        }
        .searchIconMode(
            text: $searchText,
            isSearching: $isSearching,
            title: "网站",
            prompt: "搜索域名"
        )
        .toolbar {
            // SSL 证书入口：仅非搜索态显示
            if !isSearching {
                ToolbarItem(placement: .topBarTrailing) {
                    EllipsisMenuButton {
                        withAnimation(.easeOut(duration: 0.18)) { showMenu.toggle() }
                    }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if showMenu {
                EllipsisMenuPopup(entries: [
                    .action(title: "SSL证书") { showCerts = true },
                ]) {
                    withAnimation(.easeIn(duration: 0.12)) { showMenu = false }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            FloatingActionButton(action: {
                showCreateSheet = true
            })
            .accessibilityLabel("创建网站")
        }
        .onChange(of: searchText) { _, newValue in
            Task { await vm.search(query: newValue) }
        }
        .navigationDestination(for: Website.self) { website in
            WebsiteDetailView(website: website, vm: vm)
        }
        .navigationDestination(isPresented: $showCerts) {
            CertificatesTab(manager: manager)
        }
        .navigationDestination(isPresented: $showCreateSheet) {
            CreateWebsiteView(vm: vm)
        }
        .navigationDestination(isPresented: $showOpenRestyConfig) {
            OpenRestyConfigView(vm: vm)
        }
    }

    private var websiteList: some View {
        List {
            // 顶部 OpenResty 信息与管理卡片
            OpenRestyCard(vm: vm, manager: manager, showConfig: $showOpenRestyConfig)

            if vm.websites.isEmpty {
                Section {
                    if let err = vm.errorMessage, !err.isEmpty {
                        ContentUnavailableView {
                            Label("加载失败", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(err)
                        } actions: {
                            Button("重试") {
                                Task { await vm.refresh() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else {
                        ContentUnavailableView(
                            "暂无网站",
                            systemImage: "globe",
                            description: Text("点击右下角 + 创建第一个网站")
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
            await vm.refresh()
        }
    }
}

// MARK: - OpenResty 信息与管理卡片

struct OpenRestyCard: View {
    @ObservedObject var vm: WebsitesViewModel
    @ObservedObject var manager: ServerManager
    @State private var isExpanded = false
    @Binding var showConfig: Bool
    @State private var pendingAction: String?

    init(vm: WebsitesViewModel, manager: ServerManager, showConfig: Binding<Bool>) {
        self.vm = vm
        self.manager = manager
        self._showConfig = showConfig
    }

    var body: some View {
        Group {
            if vm.isLoadingOpenResty && vm.openresty == nil {
                Section {
                    ServiceStatusLoadingRow(text: "加载 OpenResty 状态…")
                }
            } else if let app = vm.openresty {
                ServiceStatusCard(
                    title: "OpenResty",
                    subtitle: app.version.flatMap { $0.isEmpty ? nil : "v\($0)" },
                    statusText: app.status ?? "未知",
                    statusColor: app.statusColor,
                    isOperating: vm.openRestyOperating,
                    isExpanded: $isExpanded,
                    actions: [
                        ServiceAction(
                            title: app.isRunning ? "停止" : "启动",
                            icon: app.isRunning ? "stop.fill" : "play.fill",
                            color: app.isRunning ? .orange : .green
                        ) { pendingAction = app.isRunning ? "stop" : "start" },
                        ServiceAction(title: "重启", icon: "arrow.triangle.2.circlepath", color: .blue) {
                            pendingAction = "restart"
                        },
                        ServiceAction(title: "重载", icon: "arrow.clockwise", color: .teal) {
                            pendingAction = "reload"
                        },
                        ServiceAction(title: "配置", icon: "slider.horizontal.3", color: .purple) {
                            showConfig = true
                        }
                    ]
                ) {
                    // OpenResty 使用内置品牌图标，避免依赖服务器应用图标接口
                    BrandIcon(brand: .openresty, size: 44)
                }
            } else {
                Section {
                    ServiceStatusFailedRow(text: "OpenResty 未安装或加载失败")
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
            Button("取消", role: .cancel) { pendingAction = nil }
            Button("确认", role: .destructive) { executeOpenRestyAction() }
        } message: {
            if let action = pendingAction {
                Text("将对 OpenResty 进行 \(openRestyActionDisplayName(action)) 操作，是否继续？")
            }
        }
    }

    private func openRestyActionDisplayName(_ action: String) -> String {
        switch action {
        case "stop":    return "停止"
        case "start":   return "启动"
        case "restart": return "重启"
        case "reload":  return "重载"
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

// MARK: - 网站列表行

struct WebsiteRow: View {
    let website: Website

    /// 上：主域名:端口；下：类型 [appName]；右：状态
    /// （浏览器打开链接入口已移至网站详情页右下角悬浮按钮）
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

// MARK: - 网站详情页图标（logs/链接.svg、logs/HTTPS.svg 样式）

/// 网站详情页右下角悬浮「打开链接」按钮：链接.svg 样式的蓝色链式图标
struct WebsiteLinkFab: View {
    let url: URL
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(url)
        } label: {
            Image("icon-link")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 30, height: 30)
                .frame(width: 56, height: 56)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 4)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 20)
        .accessibilityLabel("在浏览器打开网站")
    }
}

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

