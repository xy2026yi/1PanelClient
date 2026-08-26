//
//  MainTabView.swift
//  1PanelClient
//
//  底部三段式结构（对齐 1Panel 官方 App）：
//    1. 首页   - OverviewTab（资源卡片 + 实时监控 + 系统信息，顶栏进入服务器管理）
//    2. 管理   - ManageTab（应用/网站/容器/计划任务等列表式入口）
//    3. 设置   - SettingsTab（外观与关于APP）
//
//  双形态导航（iPad 适配，自绘侧栏方案）：
//    - tabContent 恒为 ZStack 首子视图（三 Tab 保活切换），regular 时侧栏以兄弟
//      图层叠加、内容 leading padding 收窄；尺寸类翻转不换分支、不重建导航树
//    - 窗口三段式：≥800 完整侧栏 / 600-800 图标栏 / <600 底部 Tab 栏
//      （iPhone Max 横屏 regular 同样走侧栏，内容收窄逻辑与 iPad 一致）
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
    /// 管理 Tab 的导航路径由这里持有：iPad 窗口缩放跨尺寸类时双形态分支互换会
    /// 重建整棵导航树，路径留在子视图 @State 里会丢栈跳回管理根页
    @State private var manageNavPath = NavigationPath()
    /// regular 侧栏折叠开关（收起为图标栏），跨启动持久化；compact 下无侧栏不生效
    @AppStorage("main.sidebarCollapsed") private var sidebarCollapsed = false
    /// 窗口宽度（Stage Manager 缩放实时更新）：三段式形态——
    /// ≥800 完整侧栏 / 600-800 自动收为图标栏 / <600 无侧栏走底部 Tab 栏。
    /// 侧栏固定宽度是系统惯例（内容区吸收缩放），加图标栏中间档让缩放有过渡
    @State private var windowWidth: CGFloat = 1024
    /// 窄窗口下用户在图标栏显式点「展开」：临时覆盖自动收起，回到宽窗口即清除
    @State private var narrowExpandRequested = false
    /// 三个 Tab 各自的导航深度（根页面 = true 时显示底部 Tab 栏；仅 compact 分支使用）
    @State private var manageAtRoot = true
    @State private var overviewAtRoot = true
    @State private var settingsAtRoot = true

    @Environment(\.horizontalSizeClass) private var hSize
    /// 「减弱动态效果」：Tab 栏滑入/侧栏收展动画退化为淡入淡出或直接布局
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showTabBar: Bool {
        switch selectedTab {
        case .overview: return overviewAtRoot
        case .manage:   return manageAtRoot
        case .settings: return settingsAtRoot
        }
    }

    var body: some View {
        rootContent
            // 切换/移除当前服务器时清空管理导航栈：栈内页面的 VM 与 path 里存的值
            // （网站等模型，ID 按服务器自增）都绑旧服务器，带着新 VM 操作旧 id
            // 会误伤新服务器上的数据；回根后重新 push 自然用新服务器构建
            .onChange(of: manager.currentServerID) { _, _ in
                manageNavPath = NavigationPath()
            }
    }

    /// 双形态统一结构：tabContent 是 ZStack 的恒定首子视图，尺寸类翻转时不换分支、
    /// 不重建导航树——isPresented 推入、表单草稿、滚动位置全部保留，规避
    /// NavigationSplitView 分支互换的一整类重建 bug。
    /// regular 时侧栏以 ZStack 兄弟图层叠加，内容用 leading padding 真实收窄
    /// （不能用 safeAreaInset(edge: .leading)：UIKit 只传播纵向安全区，
    /// NavigationStack 里的 List/Form 会无视横向内缩、被侧栏盖住）
    @ViewBuilder
    private var rootContent: some View {
        if manager.current == nil {
            WelcomeView(manager: manager)
        } else {
            ZStack(alignment: .leading) {
                tabContent
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if !sidebarVisible && showTabBar {
                            BottomTabBar(selectedTab: $selectedTab)
                                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(Motion.standard, value: showTabBar)
                    .padding(.leading, sidebarVisible ? currentSidebarWidth : 0)

                if sidebarVisible {
                    if useRail {
                        sidebarRail
                            .transition(.opacity)
                    } else {
                        sidebar
                            .transition(.opacity)
                    }
                }
            }
            // 「减弱动态效果」开启时侧栏收展/Tab 栏滑入退化为纯布局变化，不动画
            .animation(reduceMotion ? nil : Motion.standard, value: hSize)
            .animation(reduceMotion ? nil : Motion.standard, value: sidebarVisible)
            .animation(reduceMotion ? nil : Motion.standard, value: useRail)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                windowWidth = width
                if width >= 800 {
                    narrowExpandRequested = false
                }
            }
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
                navPath: $manageNavPath,
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
                withAnimation(Motion.fast) {
                    selectedTab = tab
                }
            }
        }
    }

    /// regular 下侧栏当前是否显示（尺寸类为 regular 且窗口宽度放得下）
    private var sidebarVisible: Bool {
        hSize == .regular && windowWidth >= 600
    }

    /// 窗口偏窄时自动收为图标栏（用户显式展开可临时覆盖）
    private var autoRail: Bool { windowWidth < 800 }

    private var useRail: Bool {
        if sidebarCollapsed { return true }
        return autoRail && !narrowExpandRequested
    }

    /// regular 侧栏：手绘平铺行（不用系统 List——iOS 26 sidebar 样式会带
    /// 分组容器包裹感与行间分隔线，旧 NavigationSplitView 侧栏没有这些）。
    /// 顶部 44pt 标题栏与 Stage Manager 窗口控制胶囊同行（胶囊覆盖左端空白），
    /// 「1Panel」居中，选中行仅轻着色，底部带折叠开关，收起后切换为
    /// sidebarRail 图标栏，背景上下出血铺满全高
    private var sidebar: some View {
        VStack(spacing: 0) {
            Text("1Panel")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 44)

            sidebarRow(.overview, title: L10n.t("首页"), icon: "house")
            sidebarRow(.manage, title: L10n.t("管理"), icon: "list.bullet.rectangle.portrait")
            sidebarRow(.settings, title: L10n.t("设置"), icon: "gearshape")

            Spacer()

            Divider()
            Button {
                Haptic.selection()
                sidebarCollapsed = true
                narrowExpandRequested = false
            } label: {
                Label(L10n.t("收起侧栏"), systemImage: "sidebar.leading")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
        }
        .frame(width: Self.sidebarWidth)
        .background {
            Rectangle()
                .fill(.bar)
                // leading 一并出血：iPhone Max 横屏 regular 下刘海侧有 ~62pt 安全区，
                // 只纵向出血会在侧栏左缘露出一条窗口底色竖带
                .ignoresSafeArea(.container, edges: [.top, .bottom, .leading])
        }
    }

    /// 侧栏平铺行：图标 + 标题，选中态整行轻着色（无容器包裹、无分隔线）
    private func sidebarRow(_ tab: AppTab, title: String, icon: String) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            Haptic.selection()
            selectedTab = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(.callout))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 24)
                Text(title)
                    .font(.body)
                Spacer()
            }
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.12))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .padding(.horizontal, 8)
    }

    /// 收起态的图标栏：仅保留三个 Tab 图标（可切换）+ 底部展开开关
    private var sidebarRail: some View {
        VStack(spacing: 4) {
            railButton(.overview, title: L10n.t("首页"), icon: "house")
            railButton(.manage, title: L10n.t("管理"), icon: "list.bullet.rectangle.portrait")
            railButton(.settings, title: L10n.t("设置"), icon: "gearshape")

            Spacer()

            Button {
                Haptic.selection()
                sidebarCollapsed = false
                // 窗口还窄时显式展开属于临时覆盖，回到宽窗口自动恢复正常逻辑
                if autoRail { narrowExpandRequested = true }
            } label: {
                Image(systemName: "sidebar.trailing")
                    .font(.system(.callout).weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("展开侧栏"))
            .padding(.bottom, 8)
        }
        // 顶部让出与侧栏标题栏等高的区域（Stage Manager 胶囊同行区）
        .padding(.top, 44)
        .frame(width: Self.railWidth)
        .background {
            Rectangle()
                .fill(.bar)
                // leading 一并出血：iPhone Max 横屏 regular 下刘海侧有 ~62pt 安全区，
                // 只纵向出血会在侧栏左缘露出一条窗口底色竖带
                .ignoresSafeArea(.container, edges: [.top, .bottom, .leading])
        }
    }

    private func railButton(_ tab: AppTab, title: String, icon: String) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            Haptic.selection()
            selectedTab = tab
        } label: {
            Image(systemName: icon)
                .font(.system(.body))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 40, height: 40)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.opacity(0.12))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(title)
        .padding(.vertical, 2)
    }

    /// regular 下侧栏当前占用的宽度（展开 320 / 图标栏 64）；compact 无侧栏
    private var currentSidebarWidth: CGFloat {
        useRail ? Self.railWidth : Self.sidebarWidth
    }

    private static let sidebarWidth: CGFloat = 320
    private static let railWidth: CGFloat = 64
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
            withAnimation(Motion.fast) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(.title3))
                    .symbolRenderingMode(.hierarchical)
                Text(title)
                    .font(.system(.caption2))
            }
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
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
