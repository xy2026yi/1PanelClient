//
//  MainTabView.swift
//  1PanelClient
//
//  底部三段式结构（对齐 1Panel 官方 App）：
//    1. 首页   - OverviewTab（资源卡片 + 实时监控 + 系统信息）
//    2. 管理   - ManageTab（应用/网站/容器/计划任务等列表式入口）
//    3. 设置   - SettingsTab（独立 Tab，含服务器与偏好设置）
//
//  自定义底部 Tab 栏：进入管理子页面时自动隐藏，返回根页面时恢复
//

import SwiftUI

struct MainTabView: View {
    @StateObject private var manager = ServerManager.shared
    @State private var selectedTab: AppTab = .overview
    /// OverviewTab 卡片点击待跳转的 ManageItem；ManageTab 监听此值并自动打开 fullScreen
    @State private var pendingManageItem: ManageItem?
    /// 管理 Tab 导航深度 > 0 时隐藏底部 Tab 栏
    @State private var manageAtRoot = true

    private var showTabBar: Bool {
        selectedTab != .manage || manageAtRoot
    }

    var body: some View {
        if manager.current == nil {
            WelcomeView(manager: manager)
        } else {
            ZStack {
                OverviewTab(
                    manager: manager,
                    selectedTab: $selectedTab,
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

                SettingsTab(manager: manager)
                    .opacity(selectedTab == .settings ? 1 : 0)
                    .allowsHitTesting(selectedTab == .settings)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showTabBar {
                    BottomTabBar(selectedTab: $selectedTab)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: showTabBar)
        }
    }
}

// MARK: - 自定义底部 Tab 栏

private struct BottomTabBar: View {
    @Binding var selectedTab: AppTab

    var body: some View {
        HStack(spacing: 0) {
            tabItem(.overview, title: "首页", icon: "house")
            tabItem(.manage, title: "管理", icon: "list.bullet.rectangle.portrait")
            tabItem(.settings, title: "设置", icon: "gearshape")
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
                    Text("管理你的 1Panel 服务器")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    showAdd = true
                } label: {
                    Label("添加服务器", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
            }
            .navigationTitle("")
            .sheet(isPresented: $showAdd) {
                ServerEditView(manager: manager)
            }
        }
    }
}
