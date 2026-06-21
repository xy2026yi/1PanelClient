//
//  AppsTab.swift
//  1PanelClient
//

import SwiftUI
import Combine

struct AppsTab: View {
    @ObservedObject var manager: ServerManager
    @StateObject private var vm: AppsViewModel
    @State private var searchText = ""

    init(manager: ServerManager) {
        self.manager = manager
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: AppsViewModel(server: server))
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.apps.isEmpty {
                    ProgressView("加载中…")
                } else if vm.apps.isEmpty {
                    ContentUnavailableView(
                        "暂无已安装应用",
                        systemImage: "shippingbox",
                        description: Text(vm.errorMessage ?? "这台服务器上没有已安装的应用")
                    )
                } else {
                    appList
                }
            }
            .navigationTitle("应用")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "搜索应用名")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await vm.refresh() }
                    } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .onChange(of: searchText) { _, newValue in
                Task { await vm.search(query: newValue) }
            }
        }
        .task { await vm.refresh() }
    }

    private var appList: some View {
        List {
            // 可更新统计栏（当有可更新应用时显示）
            if vm.updatableCount > 0 {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(vm.updatableCount) 个应用可更新")
                                .font(.subheadline.bold())
                            Text("左滑应用行，点击「升级」查看可用版本")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                ForEach(vm.apps) { app in
                    AppRow(
                        app: app,
                        isOperating: vm.operatingAppIds.contains(app.id)
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        // 升级按钮（仅有可更新版本时显示）
                        if app.canUpdate == true {
                            Button {
                                Task { await vm.loadVersions(for: app) }
                            } label: {
                                Label("升级", systemImage: "arrow.up.circle")
                            }
                            .tint(.orange)
                        }

                        // 启动/停止
                        if app.isRunning {
                            Button {
                                Task { await vm.operate(app: app, op: .stop) }
                            } label: {
                                Label("停止", systemImage: "stop.fill")
                            }
                            .tint(.orange)
                        } else {
                            Button {
                                Task { await vm.operate(app: app, op: .start) }
                            } label: {
                                Label("启动", systemImage: "play.fill")
                            }
                            .tint(.green)
                        }

                        // 重启
                        Button {
                            Task { await vm.operate(app: app, op: .restart) }
                        } label: {
                            Label("重启", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .tint(.blue)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        // 升级版本选择 Sheet
        .sheet(isPresented: $vm.showUpgradeSheet) {
            if let app = vm.upgradingApp {
                UpgradeSheetView(app: app, vm: vm)
            }
        }
        // 操作结果提示
        .alert("提示", isPresented: $vm.showAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
    }
}

// MARK: - 升级版本选择 Sheet

struct UpgradeSheetView: View {
    let app: AppInstall
    @ObservedObject var vm: AppsViewModel

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoadingVersions {
                    ProgressView("查询可用版本…")
                } else if vm.availableVersions.isEmpty {
                    ContentUnavailableView(
                        "无可用版本",
                        systemImage: "arrow.up.circle.slash",
                        description: Text("该应用暂无更高版本可供升级")
                    )
                } else {
                    List {
                        // 当前版本
                        Section("当前版本") {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading) {
                                    Text(app.version ?? "未知")
                                        .font(.body.bold())
                                    Text("已安装")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        // 可选版本
                        Section("可升级到") {
                            ForEach(vm.availableVersions) { ver in
                                Button {
                                    Task { await vm.confirmUpgrade(app: app, to: ver) }
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(ver.version ?? "v\(ver.detailId)")
                                                .font(.body.bold())
                                                .foregroundStyle(.primary)
                                            Text("ID: \(ver.detailId)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if vm.upgradingVersionId == ver.detailId {
                                            ProgressView()
                                        } else {
                                            Image(systemName: "arrow.up.circle.fill")
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(vm.upgradingVersionId != nil)
                            }
                        }
                    }
                }
            }
            .navigationTitle("升级 \(app.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { vm.showUpgradeSheet = false }
                }
            }
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
                RoundedRectangle(cornerRadius: 10)
                    .fill(app.statusColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                if isOperating {
                    ProgressView()
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: app.statusIcon)
                        .font(.title3)
                        .foregroundStyle(app.statusColor)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(app.displayName)
                        .font(.body.bold())
                        .lineLimit(1)

                    if let v = app.version, !v.isEmpty {
                        Text("v\(v)")
                            .font(.caption2.monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                            .foregroundStyle(.secondary)
                    }

                    if app.canUpdate == true {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.up.circle.fill")
                            Text("可更新")
                        }
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .clipShape(Capsule())
                        .foregroundStyle(.orange)
                    }
                }

                if let container = app.container, !container.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "cylinder")
                            .font(.caption2)
                        Text(container)
                            .lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text((app.status ?? "未知").capitalized)
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(app.statusColor.opacity(0.15))
                        .foregroundStyle(app.statusColor)
                        .clipShape(Capsule())

                    if let port = app.httpPort, port > 0 {
                        Label("\(port)", systemImage: "network")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let fav = app.favorite, fav {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - ViewModel

@MainActor
final class AppsViewModel: ObservableObject {
    @Published var apps: [AppInstall] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var operatingAppIds: Set<Int> = []

    // 升级相关
    @Published var showUpgradeSheet = false
    @Published var upgradingApp: AppInstall?
    @Published var availableVersions: [AppVersion] = []
    @Published var isLoadingVersions = false
    @Published var upgradingVersionId: Int?

    // 操作提示
    @Published var showAlert = false
    @Published var alertMessage = ""

    private var client: APIClient

    /// 可更新应用数量
    var updatableCount: Int {
        apps.filter { $0.canUpdate == true }.count
    }

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    func refresh() async {
        await load(query: "")
    }

    func search(query: String) async {
        await load(query: query)
    }

    private func load(query: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let req = AppInstalledSearchRequest(
            page: 1, pageSize: 100, name: query, type: "", tags: [],
            update: false, all: false, unused: false, sync: false
        )
        do {
            let resp: AppInstalledListResponse = try await client.send(
                path: APIEndpoint.appsInstalledSearch.path,
                body: req,
                as: AppInstalledListResponse.self
            )
            self.apps = resp.items ?? []
        } catch let err as APIError {
            self.errorMessage = err.errorDescription
            self.apps = []
        } catch {
            self.errorMessage = error.localizedDescription
            self.apps = []
        }
    }

    // MARK: - 启动/停止/重启

    func operate(app: AppInstall, op: AppOperation) async {
        operatingAppIds.insert(app.id)
        defer { operatingAppIds.remove(app.id) }

        let req = AppInstalledOperateRequest(installId: app.id, operate: op.rawValue)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledOperate.path,
                body: req,
                as: EmptyResponse.self
            )
            try? await Task.sleep(for: .seconds(1))
            await load(query: "")
        } catch let err as APIError {
            showAlert(message: "\(op.displayName)失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "\(op.displayName)失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 升级流程

    /// 加载某个应用的可用更新版本
    func loadVersions(for app: AppInstall) async {
        upgradingApp = app
        availableVersions = []
        isLoadingVersions = true
        showUpgradeSheet = true

        do {
            let versions: [AppVersion] = try await client.send(
                path: APIEndpoint.appsUpdateVersions.path,
                queryItems: [URLQueryItem(name: "appInstallId", value: String(app.id))],
                as: [AppVersion].self
            )
            // 过滤掉当前版本，只显示更新的
            let currentDetailId = app.appDetailID ?? -1
            self.availableVersions = versions.filter { $0.detailId != currentDetailId }
        } catch let err as APIError {
            showAlert(message: "查询版本失败：\(err.errorDescription ?? "未知错误")")
            showUpgradeSheet = false
        } catch {
            showAlert(message: "查询版本失败：\(error.localizedDescription)")
            showUpgradeSheet = false
        }
        isLoadingVersions = false
    }

    /// 确认升级到指定版本
    func confirmUpgrade(app: AppInstall, to version: AppVersion) async {
        upgradingVersionId = version.detailId
        defer { upgradingVersionId = nil }

        let req = AppInstallRequest(
            appDetailId: version.detailId,
            params: [:],
            name: app.name ?? app.displayName,
            advanced: false,
            pullImage: true
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstall.path,
                body: req,
                as: EmptyResponse.self
            )
            showUpgradeSheet = false
            showAlert(message: "升级请求已提交，应用正在后台更新中…")
            // 等待 3 秒后刷新列表
            try? await Task.sleep(for: .seconds(3))
            await load(query: "")
        } catch let err as APIError {
            showAlert(message: "升级失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "升级失败：\(error.localizedDescription)")
        }
    }

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }
}

extension AppOperation {
    var displayName: String {
        switch self {
        case .start: return "启动"
        case .stop: return "停止"
        case .restart: return "重启"
        }
    }
}
