//
//  MainTabView.swift
//  1PanelClient
//
//  底部三段式结构（对齐 1Panel 官方 App）：
//    1. 首页   - OverviewTab（资源卡片 + 实时监控 + 系统信息，顶栏进入服务器管理）
//    2. 管理   - ManageTab（应用/网站/容器/计划任务等列表式入口）
//    3. 设置   - SettingsTab（外观与关于APP）
//
//  双形态导航（iPad 适配）：
//    - compact（iPhone / iPad 分屏半屏）：自定义底部 Tab 栏，进入子页面时自动隐藏
//    - regular（iPad 全屏 / Stage Manager）：NavigationSplitView 侧栏常驻，无需隐藏
//      三个 Tab 仍走 ZStack 保活切换，状态机与 compact 完全共享
//

import SwiftUI

/// 键盘快捷键（Cmd+1/2/3）请求切换 Tab；由 _PanelClientApp 的 .commands 发出
extension Notification.Name {
    static let selectAppTab = Notification.Name("selectAppTab")
}

struct MainTabView: View {
    @StateObject private var manager = ServerManager.shared
    @State private var selectedTab: AppTab = .overview
    /// OverviewTab 卡片点击待跳转的 ManageItem；ManageTab 监听此值并自动 push
    @State private var pendingManageItem: ManageItem?
    /// 三个 Tab 各自的导航深度（根页面 = true 时显示底部 Tab 栏；仅 compact 分支使用）
    @State private var manageAtRoot = true
    @State private var overviewAtRoot = true
    @State private var settingsAtRoot = true

    @Environment(\.horizontalSizeClass) private var hSize

    private var showTabBar: Bool {
        switch selectedTab {
        case .overview: return overviewAtRoot
        case .manage:   return manageAtRoot
        case .settings: return settingsAtRoot
        }
    }

    var body: some View {
        if manager.current == nil {
            WelcomeView(manager: manager)
        } else if hSize == .regular {
            NavigationSplitView {
                sidebar
            } detail: {
                tabContent
            }
        } else {
            tabContent
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if showTabBar {
                        BottomTabBar(selectedTab: $selectedTab)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: showTabBar)
        }
    }

    /// 三个 Tab 的保活容器（双形态共用）：ZStack + opacity 切换，切回时状态不丢
    private var tabContent: some View {
        ZStack {
            OverviewTab(
                manager: manager,
                selectedTab: $selectedTab,
                atRoot: $overviewAtRoot,
                onSelectManageItem: { item in
                    pendingManageItem = item
                    selectedTab = .manage
                }
            )
            .opacity(selectedTab == .overview ? 1 : 0)
            .allowsHitTesting(selectedTab == .overview)

            ManageTab(
                manager: manager,
                initialItem: $pendingManageItem,
                atRoot: $manageAtRoot
            )
            .opacity(selectedTab == .manage ? 1 : 0)
            .allowsHitTesting(selectedTab == .manage)

            SettingsTab(atRoot: $settingsAtRoot)
                .opacity(selectedTab == .settings ? 1 : 0)
                .allowsHitTesting(selectedTab == .settings)
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectAppTab)) { note in
            if let tab = note.object as? AppTab {
                withAnimation(.easeInOut(duration: 0.15)) {
                    selectedTab = tab
                }
            }
        }
    }

    /// regular 侧栏：与底部 Tab 栏同一组文案/图标，selection 复用 selectedTab
    private var sidebar: some View {
        List(selection: Binding(
            get: { Optional(selectedTab) },
            set: { if let tab = $0 { selectedTab = tab } }
        )) {
            Label(L10n.t("首页"), systemImage: "house")
                .tag(AppTab.overview)
            Label(L10n.t("管理"), systemImage: "list.bullet.rectangle.portrait")
                .tag(AppTab.manage)
            Label(L10n.t("设置"), systemImage: "gearshape")
                .tag(AppTab.settings)
        }
        .navigationTitle("1Panel")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 自定义底部 Tab 栏

private struct BottomTabBar: View {
    @Binding var selectedTab: AppTab

    var body: some View {
        HStack(spacing: 0) {
            tabItem(.overview, title: L10n.t("首页"), icon: "house")
            tabItem(.manage, title: L10n.t("管理"), icon: "list.bullet.rectangle.portrait")
            tabItem(.settings, title: L10n.t("设置"), icon: "gearshape")
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func tabItem(_ tab: AppTab, title: String, icon: String) -> some View {
        let isSelected = selectedTab == tab
        Button {
            Haptic.selection()
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 21))
                    .symbolRenderingMode(.hierarchical)
                Text(title)
                    .font(.system(size: 10))
            }
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

enum AppTab: Hashable {
    case overview
    case manage
    case settings
}

/// 首次启动欢迎页（无服务器时显示）
struct WelcomeView: View {
    @ObservedObject var manager: ServerManager
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                Image(systemName: "server.rack")
                    .font(.system(size: 80))
                    .foregroundStyle(.tint)

                VStack(spacing: 8) {
                    Text("1Panel Client")
                        .font(.largeTitle.bold())
                    Text(L10n.t("管理你的 1Panel 服务器"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    showAdd = true
                } label: {
                    Label(L10n.t("添加服务器"), systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
            }
            .contentWidthLimit(420)
            .navigationTitle("")
            .sheet(isPresented: $showAdd) {
                ServerEditView(manager: manager)
            }
        }
    }
}
