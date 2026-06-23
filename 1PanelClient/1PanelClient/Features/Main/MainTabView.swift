//
//  MainTabView.swift
//  1PanelClient
//
//  底部三段式结构（对齐 1Panel 官方 App）：
//    1. 首页   - OverviewTab（资源卡片 + 实时监控 + 系统信息）
//    2. 管理   - ManageTab（应用/网站/容器/计划任务等列表式入口）
//    3. 设置   - SettingsTab（独立 Tab，含服务器与偏好设置）
//

import SwiftUI

struct MainTabView: View {
    @StateObject private var manager = ServerManager.shared
    @State private var selectedTab: AppTab = .overview

    var body: some View {
        Group {
            if manager.current == nil {
                WelcomeView(manager: manager)
            } else {
                TabView(selection: $selectedTab) {
                    OverviewTab(manager: manager, selectedTab: $selectedTab)
                        .tag(AppTab.overview)
                        .tabItem { Label("首页", systemImage: "house") }

                    ManageTab(manager: manager)
                        .tag(AppTab.manage)
                        .tabItem { Label("管理", systemImage: "list.bullet.rectangle.portrait") }

                    SettingsTab(manager: manager)
                        .tag(AppTab.settings)
                        .tabItem { Label("设置", systemImage: "gearshape") }
                }
                // AccentColor 资产自动作为默认 tint，无需显式指定
            }
        }
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
