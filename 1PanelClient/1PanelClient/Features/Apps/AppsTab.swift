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
    @State private var showIgnored = false
    @State private var showSettings = false
    @State private var showMenu = false


    init(manager: ServerManager) {
        self.manager = manager
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: AppsViewModel(server: server))
    }

    var body: some View {
        rootContent
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .onReceive(NotificationCenter.default.publisher(for: .installCompleted)) { _ in
            // 安装完成：关闭应用商店（连带所有子页面），刷新应用列表
            showStore = false
            Task { await vm.refresh() }
        }
        .task { await vm.refresh() }
    }

    /// 列表根内容（不含 NavigationStack），供 ManageTab 嵌入复用
    var rootContent: some View {
        Group {
            if vm.isLoading && vm.apps.isEmpty {
                ProgressView(L10n.t("加载中…"))
            } else if vm.apps.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无已安装应用"),
                    systemImage: "shippingbox",
                    description: Text(vm.errorMessage ?? L10n.t("这台服务器上没有已安装的应用"))
                )
            } else {
                appList
            }
        }
        .searchIconMode(
            text: $searchText,
            isSearching: $isSearching,
            title: L10n.t("应用"),
            prompt: L10n.t("搜索已安装应用")
        )
        .overlay(alignment: .bottomTrailing) {
            FloatingActionButton(action: {
                showStore = true
            })
            .accessibilityLabel(L10n.t("进入应用商店"))
        }
        .toolbar {
            if !isSearching {
                ToolbarItem(placement: .topBarTrailing) {
                    EllipsisMenuButton {
                        withAnimation(.easeOut(duration: 0.18)) { showMenu.toggle() }
                    }
                    .accessibilityLabel(L10n.t("更多"))
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if showMenu {
                EllipsisMenuPopup(entries: [
                    .action(title: L10n.t("忽略应用")) { showIgnored = true },
                    .action(title: L10n.t("设置")) { showSettings = true },
                ]) {
                    withAnimation(.easeIn(duration: 0.12)) { showMenu = false }
                }
            }
        }
        .onChange(of: searchText) { _, newValue in
            Task { await vm.search(query: newValue) }
        }
        .navigationDestination(for: AppInstall.self) { app in
            AppDetailView(app: app, vm: vm)
        }
        .navigationDestination(isPresented: $showIgnored) {
            IgnoredAppsView(vm: vm)
        }
        .navigationDestination(isPresented: $showSettings) {
            AppStoreSettingsView(vm: vm)
        }
        .navigationDestination(isPresented: $showStore) {
            AppStoreTab(manager: manager)
        }
    }

    private var appList: some View {
        List {
            Section {
                ForEach(vm.apps) { app in
                    NavigationLink(value: app) {
                        AppRow(
                            app: app,
                            isOperating: vm.operatingAppIds.contains(app.id)
                        )
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if app.isRunning {
                            Button {
                                Task { await vm.operate(app: app, op: .stop) }
                            } label: { Label(L10n.t("停止"), systemImage: "stop.fill") }
                            .tint(.orange)
                        } else {
                            Button {
                                Task { await vm.operate(app: app, op: .start) }
                            } label: { Label(L10n.t("启动"), systemImage: "play.fill") }
                            .tint(.green)
                        }
                        Button {
                            Task { await vm.operate(app: app, op: .restart) }
                        } label: { Label(L10n.t("重启"), systemImage: "arrow.triangle.2.circlepath") }
                        .tint(.blue)
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
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.thinMaterial)
                        .frame(width: 44, height: 44)
                    ProgressView()
                        .scaleEffect(0.6)
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

