//
//  AIMcpView.swift
//  1PanelClient
//
//  MCP Server 列表（/api/v2/ai/mcp）：分页搜索 / 创建 / 编辑 /
//  启停重启 / 测试连接 / 配置 JSON 复制 / 日志 / 删除 / 域名绑定；
//  进入与操作后批量同步状态（status/sync）
//

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class AIMcpViewModel: ObservableObject {
    @Published var servers: [McpServer] = []
    @Published private(set) var total = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?

    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var toastMessage: String?
    private var toastTask: Task<Void, Never>?

    @Published var isOperating = false
    @Published var pendingDelete: McpServer?

    private var page = 1
    private var loadGeneration = 0
    private static let pageSize = 20

    private(set) var client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient.shared(for: server)
    }

    // MARK: 列表

    func load(name: String = "") async {
        isLoading = true
        defer { isLoading = false }
        page = 1
        loadGeneration += 1
        let req = AISearchPageRequest(page: 1, pageSize: Self.pageSize, name: name)
        do {
            let resp: PageResponse<McpServer> = try await client.send(
                path: APIEndpoint.aiMcpSearch.path, body: req, as: PageResponse<McpServer>.self)
            servers = resp.items ?? []
            total = resp.total ?? 0
            errorMessage = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            servers = []
            total = 0
            errorMessage = error.localizedDescription
        }
        await syncStatus()
    }

    func loadMore(name: String = "") async {
        guard servers.count < total, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let next = page + 1
        let generation = loadGeneration
        let req = AISearchPageRequest(page: next, pageSize: Self.pageSize, name: name)
        do {
            let resp: PageResponse<McpServer> = try await client.send(
                path: APIEndpoint.aiMcpSearch.path, body: req, as: PageResponse<McpServer>.self)
            guard generation == loadGeneration else { return }
            let existing = Set(servers.map(\.id))
            let newItems = (resp.items ?? []).filter { !existing.contains($0.id) }
            if newItems.isEmpty {
                total = servers.count
                return
            }
            servers += newItems
            total = resp.total ?? total
            page = next
        } catch {
            // 追加失败不打断列表
        }
    }

    /// 批量同步容器状态（列表进入 / 操作后刷新）
    func syncStatus() async {
        let ids = servers.map(\.id)
        guard !ids.isEmpty else { return }
        do {
            let items: [McpStatusItem] = try await client.send(
                path: APIEndpoint.aiMcpStatusSync.path,
                body: McpStatusSyncRequest(ids: ids),
                as: [McpStatusItem].self)
            var byID: [Int: McpStatusItem] = [:]
            for item in items { byID[item.id] = item }
            servers = servers.map { server in
                guard let item = byID[server.id] else { return server }
                var copy = server
                if let status = item.status { copy.status = status }
                if let message = item.message { copy.message = message }
                return copy
            }
        } catch {
            // 状态同步失败静默（列表仍展示上次状态）
        }
    }

    // MARK: 操作

    func operate(server: McpServer, operate: String) async {
        isOperating = true
        defer { isOperating = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiMcpServerOperate.path,
                body: McpServerOperateRequest(id: server.id, operate: operate),
                as: EmptyResponse.self)
            showToast(L10n.t("操作成功"))
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await load()
        } catch let err as APIError {
            showAlert(message: L10n.f("操作失败：%@", err.errorDescription ?? L10n.t("未知错误")))
        } catch {
            showAlert(message: L10n.f("操作失败：%@", error.localizedDescription))
        }
    }

    /// 测试连接，成功返回结果描述
    func testConnection(server: McpServer) async -> String? {
        do {
            let result: McpConnectionTestResult = try await client.send(
                path: APIEndpoint.aiMcpConnectionTest.path,
                body: McpConnectionTestRequest(id: server.id),
                as: McpConnectionTestResult.self)
            let status = (result.success == true) ? L10n.t("连接成功") : L10n.t("连接失败")
            var parts = [status]
            if let endpoint = result.endpoint, !endpoint.isEmpty {
                parts.append(endpoint)
            }
            if let message = result.message, !message.isEmpty {
                parts.append(message)
            }
            return parts.joined(separator: "\n")
        } catch {
            guard !APIError.isCancellation(error) else { return nil }
            return L10n.f("测试失败：%@", error.localizedDescription)
        }
    }

    func delete(server: McpServer) async {
        pendingDelete = nil
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiMcpServerDelete.path,
                body: McpServerDeleteRequest(id: server.id),
                as: EmptyResponse.self)
            showToast(L10n.f("MCP「%@」已删除", server.name))
            await load()
        } catch let err as APIError {
            showAlert(message: L10n.f("删除失败：%@", err.errorDescription ?? L10n.t("未知错误")))
        } catch {
            showAlert(message: L10n.f("删除失败：%@", error.localizedDescription))
        }
    }

    // MARK: 提示

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { self?.toastMessage = nil }
        }
    }
}

// MARK: - MCP 列表页

struct AIMcpView: View {
    @StateObject private var vm: AIMcpViewModel
    private let server: ServerConfig

    @State private var searchText = ""
    @State private var isSearching = false
    @State private var showCreate = false
    @State private var editingServer: McpServer?
    @State private var actionServer: McpServer?
    @State private var logServer: McpServer?
    @State private var configServer: McpServer?
    @State private var showDomain = false
    @State private var testingServer: McpServer?
    @State private var testResult: String?
    @State private var showTestResult = false
    @State private var searchTask: Task<Void, Never>?

    init(server: ServerConfig) {
        self.server = server
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(key: ManageItem.aiMcp.storeKey(server: server)) {
            AIMcpViewModel(server: server)
        })
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.servers.isEmpty {
                LoadingStateView()
            } else if let err = vm.errorMessage, vm.servers.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button(L10n.t("重试")) { Task { await vm.load(name: searchText) } }
                }
            } else if vm.servers.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("暂无 MCP Server"), systemImage: "puzzlepiece")
                } description: {
                    Text(L10n.t("点击右上角 + 创建 MCP Server"))
                }
            } else {
                serverList
            }
        }
        .searchIconMode(
            text: $searchText,
            isSearching: $isSearching,
            title: "MCP",
            prompt: L10n.t("搜索名称")
        )
        .toolbar {
            // 搜索按钮由 searchIconMode 提供；此处合并为单一菜单，避免右上角按钮过多
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showCreate = true
                    } label: {
                        Label(L10n.t("创建 MCP"), systemImage: "plus")
                    }
                    Button {
                        showDomain = true
                    } label: {
                        Label(L10n.t("域名绑定"), systemImage: "globe")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel(L10n.t("更多操作"))
            }
        }
        .refreshable { await vm.load(name: searchText) }
        .task { await PageVMStore.shared.autoRefresh(vm: vm) { await vm.load(name: searchText) } }
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .alert(L10n.t("删除 MCP"), isPresented: Binding(
            get: { vm.pendingDelete != nil },
            set: { if !$0 { vm.pendingDelete = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { vm.pendingDelete = nil }
            Button(L10n.t("删除"), role: .destructive) {
                Haptic.warning()
                if let s = vm.pendingDelete {
                    Task { await vm.delete(server: s) }
                }
            }
        } message: {
            Text(L10n.f("确定删除 MCP「%@」吗？", vm.pendingDelete?.name ?? ""))
        }
        .alert(L10n.t("测试连接"), isPresented: $showTestResult) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(testResult ?? "")
        }
        .navigationDestination(isPresented: $showCreate) {
            AIMcpFormView(server: server, editing: nil, vm: vm)
        }
        .navigationDestination(isPresented: Binding(
            get: { editingServer != nil },
            set: { if !$0 { editingServer = nil } }
        )) {
            if let s = editingServer {
                AIMcpFormView(server: server, editing: s, vm: vm)
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { logServer != nil },
            set: { if !$0 { logServer = nil } }
        )) {
            if let s = logServer {
                ComposeLogView(
                    title: L10n.t("日志"),
                    composePath: Self.composePath(for: s),
                    client: vm.client
                )
            }
        }
        .navigationDestination(isPresented: $showDomain) {
            AIMcpDomainView(server: server)
        }
        .sheet(item: $configServer) { s in
            AIMcpConfigSheet(server: s)
                .presentationDragIndicator(.visible)
                .bottomSheetDetents([.medium])
        }
        .sheet(item: $actionServer) { s in
            ActionBottomSheet(
                title: s.name,
                items: actionItems(s),
                onDismiss: { actionServer = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: actionItems(s).count))])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: searchText) { _, newValue in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                await vm.load(name: newValue)
            }
        }
    }

    private var serverList: some View {
        List {
            Section {
                ForEach(vm.servers) { s in
                    Button {
                        editingServer = s
                    } label: {
                        McpServerRow(server: s)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                            Haptic.selection()
                            actionServer = s
                        }
                    )
                    .onAppear {
                        if s.id == vm.servers.last?.id {
                            Task { await vm.loadMore(name: searchText) }
                        }
                    }
                }

                if vm.servers.count < vm.total || vm.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .onAppear { Task { await vm.loadMore(name: searchText) } }
                }
            } header: {
                SectionLabel(
                    title: L10n.f("共 %@ 个", String(vm.total)),
                    systemImage: "puzzlepiece"
                )
            }
        }
        .listStyle(.insetGrouped)
    }

    private func actionItems(_ s: McpServer) -> [ActionMenuItem] {
        [
            ActionMenuItem(
                title: s.isRunning ? L10n.t("停止") : L10n.t("启动"),
                icon: s.isRunning ? "stop.fill" : "play.fill",
                color: s.isRunning ? .orange : .green
            ) {
                Task { await vm.operate(server: s, operate: s.isRunning ? "stop" : "start") }
            },
            ActionMenuItem(title: L10n.t("重启"), icon: "arrow.triangle.2.circlepath", color: .blue) {
                Task { await vm.operate(server: s, operate: "restart") }
            },
            ActionMenuItem(title: L10n.t("测试连接"), icon: "bolt.horizontal.circle", color: .cyan) {
                Task {
                    if let result = await vm.testConnection(server: s) {
                        testResult = result
                        showTestResult = true
                    }
                }
            },
            ActionMenuItem(title: L10n.t("配置"), icon: "curlybraces.square", color: .purple) {
                configServer = s
            },
            ActionMenuItem(title: L10n.t("日志"), icon: "doc.text.magnifyingglass") {
                logServer = s
            },
            ActionMenuItem(title: L10n.t("编辑"), icon: "pencil") {
                editingServer = s
            },
            ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red, role: .destructive) {
                vm.pendingDelete = s
            },
        ]
    }

    /// compose 路径（容器日志用）
    static func composePath(for server: McpServer) -> String {
        var p = server.dir ?? ""
        if !p.hasSuffix("/") { p += "/" }
        return p + "docker-compose.yml"
    }
}

// MARK: - 行

struct McpServerRow: View {
    let server: McpServer

    private var statusColor: Color {
        switch (server.status ?? "").lowercased() {
        case "running": return .statusRunning
        case "stopped", "exited": return .statusStopped
        case "error", "failed": return .statusError
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "puzzlepiece.fill", color: .orange)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(server.name)
                        .font(.body.bold())
                        .lineLimit(1)
                    StatusBadge(text: server.status ?? "-", color: statusColor)
                }
                HStack(spacing: 6) {
                    Text(server.type ?? "-")
                    Text("·")
                    Text(server.outputTransport ?? "-")
                    Text("·")
                    Text(String(server.port ?? 0))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let message = server.message, !message.isEmpty {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - 配置 JSON Sheet（本地拼装 + 复制，无网络请求）

struct AIMcpConfigSheet: View {
    let server: McpServer
    @Environment(\.dismiss) private var dismiss

    /// {"mcpServers":{"<name>":{"url":"<baseUrl>"}}}（不带 \/ 转义）
    private var configJSON: String {
        let url = server.baseUrl ?? ""
        let object: [String: [String: [String: String]]] = [
            "mcpServers": [
                server.name: ["url": url]
            ]
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(object) {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return ""
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(configJSON)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .textSelection(.enabled)
            }
            .navigationTitle(L10n.t("配置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = configJSON
                        dismiss()
                    } label: {
                        Label(L10n.t("复制"), systemImage: "doc.on.doc")
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("关闭")) { dismiss() }
                }
            }
        }
    }
}
