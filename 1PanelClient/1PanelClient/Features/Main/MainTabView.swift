//
//  MainTabView.swift
//  1PanelClient
//

import SwiftUI

struct MainTabView: View {
    @StateObject private var manager = ServerManager.shared

    var body: some View {
        Group {
            if manager.current == nil {
                WelcomeView(manager: manager)
            } else {
                TabView {
                    OverviewTab(manager: manager)
                        .tabItem {
                            Label("概览", systemImage: "square.grid.2x2")
                        }

                    UnifiedAppsTab(manager: manager)
                        .tabItem {
                            Label("应用", systemImage: "app.badge")
                        }

                    ContainersTab(manager: manager)
                        .tabItem {
                            Label("容器", systemImage: "shippingbox")
                        }

                    ToolboxTab(manager: manager)
                        .tabItem {
                            Label("工具箱", systemImage: "wrench.adjustable")
                        }
                }
                .tint(.blue)
            }
        }
    }
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
