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
            ForEach(vm.apps) { app in
                AppRow(app: app, isOperating: vm.operatingAppIds.contains(app.id))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
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
                        Button {
                            Task { await vm.operate(app: app, op: .restart) }
                        } label: {
                            Label("重启", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .tint(.blue)
                    }
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct AppRow: View {
    let app: AppInstall
    var isOperating: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            // 应用图标
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(app.statusColor).opacity(0.15))
                    .frame(width: 44, height: 44)
                if isOperating {
                    ProgressView()
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: app.statusIcon)
                        .font(.title3)
                        .foregroundStyle(Color(app.statusColor))
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

                    if let canUpdate = app.canUpdate, canUpdate {
                        Text("可更新")
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
                    // 状态标签
                    Text((app.status ?? "未知").capitalized)
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color(app.statusColor).opacity(0.15))
                        .foregroundStyle(Color(app.statusColor))
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

    private var client: APIClient

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
            page: 1,
            pageSize: 100,
            name: query,
            type: "",
            tags: [],
            update: false,
            all: false,
            unused: false,
            sync: false
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

    func operate(app: AppInstall, op: AppOperation) async {
        operatingAppIds.insert(app.id)
        defer { operatingAppIds.remove(app.id) }

        let req = AppInstalledOperateRequest(
            installId: app.id,
            operate: op.rawValue
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledOperate.path,
                body: req,
                as: EmptyResponse.self
            )
            // 等待 1 秒让服务端更新状态
            try? await Task.sleep(for: .seconds(1))
            await load(query: "")
        } catch let err as APIError {
            self.errorMessage = err.errorDescription
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
}
