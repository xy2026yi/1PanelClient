//
//  AIAgentsView.swift
//  1PanelClient
//
//  AI 智能体列表（/api/v2/ai/agents）：分页 / 创建（应用安装）/ 启停重启 /
//  删除（先检查绑定资源）/ 详情配置入口；安装中状态自动轮询
//

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class AIAgentsViewModel: ObservableObject {
    @Published var agents: [AIAgent] = []
    @Published private(set) var total = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?

    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var toastMessage: String?
    private var toastTask: Task<Void, Never>?

    /// 安装/操作进行中（禁用提交）
    @Published var isSubmitting = false

    /// 删除检查出的绑定资源（非空时提示先解绑）
    @Published var boundResources: [AIAgentBoundResource]?

    private var page = 1
    private var loadGeneration = 0
    private static let pageSize = 20

    private(set) var client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient.shared(for: server)
    }

    // MARK: 列表

    func load() async {
        isLoading = true
        defer { isLoading = false }
        page = 1
        loadGeneration += 1
        let req = AISearchPageRequest(page: 1, pageSize: Self.pageSize)
        do {
            let resp: PageResponse<AIAgent> = try await client.send(
                path: APIEndpoint.aiAgentsSearch.path, body: req, as: PageResponse<AIAgent>.self)
            agents = resp.items ?? []
            total = resp.total ?? 0
            errorMessage = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            agents = []
            total = 0
            errorMessage = error.localizedDescription
        }
    }

    /// 静默刷新（安装中轮询 / 操作后刷新）
    func reloadSilently() async {
        let req = AISearchPageRequest(page: 1, pageSize: max(Self.pageSize, agents.count))
        do {
            let resp: PageResponse<AIAgent> = try await client.send(
                path: APIEndpoint.aiAgentsSearch.path, body: req, as: PageResponse<AIAgent>.self)
            agents = resp.items ?? []
            total = resp.total ?? 0
        } catch {
            // 静默刷新失败不打扰
        }
    }

    func loadMore() async {
        guard agents.count < total, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let next = page + 1
        let generation = loadGeneration
        let req = AISearchPageRequest(page: next, pageSize: Self.pageSize)
        do {
            let resp: PageResponse<AIAgent> = try await client.send(
                path: APIEndpoint.aiAgentsSearch.path, body: req, as: PageResponse<AIAgent>.self)
            guard generation == loadGeneration else { return }
            let existing = Set(agents.map(\.id))
            let newItems = (resp.items ?? []).filter { !existing.contains($0.id) }
            if newItems.isEmpty {
                total = agents.count
                return
            }
            agents += newItems
            total = resp.total ?? total
            page = next
        } catch {
            // 追加失败不打断列表
        }
    }

    // MARK: 创建辅助（拉模型账号与其模型池）

    func loadAccounts() async -> [AIAccount] {
        do {
            let resp: PageResponse<AIAccount> = try await client.send(
                path: APIEndpoint.aiAccountsSearch.path,
                body: AISearchPageRequest(page: 1, pageSize: 200),
                as: PageResponse<AIAccount>.self)
            return resp.items ?? []
        } catch {
            guard !APIError.isCancellation(error) else { return [] }
            return []
        }
    }

    /// GET /api/v2/apps/:key 拉应用详情（版本列表）
    func loadAppDetail(key: String) async -> AppStoreDetail? {
        let path = APIEndpoint.appsStoreDetail.path.replacingOccurrences(of: ":key", with: key)
        do {
            return try await client.send(path: path, method: "GET", as: AppStoreDetail.self)
        } catch {
            guard !APIError.isCancellation(error) else { return nil }
            return nil
        }
    }

    // MARK: 创建 / 启停 / 删除

    /// 创建成功返回 taskID（进度页用），失败返回 nil
    func create(req: AIAgentCreateRequest) async -> String? {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentsCreate.path, body: req, as: EmptyResponse.self)
            return req.taskID
        } catch let err as APIError {
            showAlert(message: L10n.f("创建失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return nil
        } catch {
            showAlert(message: L10n.f("创建失败：%@", error.localizedDescription))
            return nil
        }
    }

    /// 启动/停止/重启（复用已安装应用操作接口）
    func operate(agent: AIAgent, operate: String) async {
        guard let installId = agent.appInstallId else {
            showAlert(message: L10n.t("缺少应用安装信息，无法操作"))
            return
        }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledOperate.path,
                body: AppInstalledOperateRequest(installId: installId, operate: operate, taskID: UUID().uuidString),
                as: EmptyResponse.self)
            showToast(L10n.t("操作成功"))
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await reloadSilently()
        } catch let err as APIError {
            showAlert(message: L10n.f("操作失败：%@", err.errorDescription ?? L10n.t("未知错误")))
        } catch {
            showAlert(message: L10n.f("操作失败：%@", error.localizedDescription))
        }
    }

    /// 删除前检查：返回绑定资源列表（空 = 可删）
    func checkDelete(agentId: Int) async -> [AIAgentBoundResource] {
        do {
            return try await client.send(
                path: APIEndpoint.aiAgentsDeleteCheck.path,
                body: AIAgentDeleteCheckRequest(agentId: agentId),
                as: [AIAgentBoundResource].self)
        } catch {
            guard !APIError.isCancellation(error) else { return [] }
            // 检查失败不阻断删除（后端仍会校验）
            return []
        }
    }

    /// 删除成功返回 taskID，失败返回 nil
    func delete(agent: AIAgent, forceDelete: Bool) async -> String? {
        let taskID = UUID().uuidString
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentsDelete.path,
                body: AIAgentDeleteRequest(id: agent.id, taskID: taskID, forceDelete: forceDelete),
                as: EmptyResponse.self)
            return taskID
        } catch let err as APIError {
            showAlert(message: L10n.f("删除失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return nil
        } catch {
            showAlert(message: L10n.f("删除失败：%@", error.localizedDescription))
            return nil
        }
    }

    // MARK: 提示

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { self?.toastMessage = nil }
        }
    }
}

// MARK: - 智能体列表页

struct AIAgentsView: View {
    @StateObject private var vm: AIAgentsViewModel
    private let server: ServerConfig

    @State private var showCreate = false
    @State private var showProgress = false
    @State private var activeTaskID = ""
    @State private var progressTitle = ""
    @State private var detailAgent: AIAgent?

    init(server: ServerConfig) {
        self.server = server
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(key: ManageItem.aiAgents.storeKey(server: server)) {
            AIAgentsViewModel(server: server)
        })
    }

    /// 列表存在安装中条目时自动轮询
    private var hasInstalling: Bool {
        vm.agents.contains { $0.isInstalling }
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.agents.isEmpty {
                LoadingStateView()
            } else if let err = vm.errorMessage, vm.agents.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button(L10n.t("重试")) { Task { await vm.load() } }
                }
            } else if vm.agents.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("暂无智能体"), systemImage: "figure.run")
                } description: {
                    Text(L10n.t("点击右上角 + 创建智能体"))
                }
            } else {
                agentList
            }
        }
        .navigationTitle(L10n.t("智能体"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("创建智能体"))
            }
        }
        .refreshable { await vm.load() }
        .task { await PageVMStore.shared.autoRefresh(vm: vm) { await vm.load() } }
        .adaptivePolling(interval: 10, isActive: { hasInstalling }) {
            await vm.reloadSilently()
        }
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .navigationDestination(isPresented: $showCreate) {
            AIAgentCreateView(server: server, vm: vm)
        }
        .navigationDestination(isPresented: $showProgress) {
            TaskProgressView(taskID: activeTaskID, title: progressTitle) { isDone in
                if isDone {
                    Task { await vm.load() }
                }
                return false
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { detailAgent != nil },
            set: { if !$0 { detailAgent = nil } }
        )) {
            if let agent = detailAgent {
                AIAgentDetailView(server: server, agentId: agent.id, listVM: vm)
            }
        }
    }

    private var agentList: some View {
        List {
            Section {
                ForEach(vm.agents) { agent in
                    Button {
                        detailAgent = agent
                    } label: {
                        AIAgentRow(agent: agent)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if agent.id == vm.agents.last?.id {
                            Task { await vm.loadMore() }
                        }
                    }
                }

                if vm.agents.count < vm.total || vm.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .onAppear { Task { await vm.loadMore() } }
                }
            } header: {
                SectionLabel(
                    title: L10n.f("共 %@ 个", String(vm.total)),
                    systemImage: "figure.run"
                )
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - 智能体行

struct AIAgentRow: View {
    let agent: AIAgent

    private var statusColor: Color {
        switch (agent.status ?? "").lowercased() {
        case "running": return .statusRunning
        case "installing": return .blue
        case "stopped", "exited": return .statusStopped
        case "error", "failed": return .statusError
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "figure.run", color: .green)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.body.bold())
                        .lineLimit(1)
                    StatusBadge(text: agent.status ?? "-", color: statusColor)
                }
                HStack(spacing: 6) {
                    Text(agent.providerName ?? agent.provider ?? "-")
                    Text("·")
                    Text(agent.model ?? "-")
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if let port = agent.webUIPort, port > 0 {
                        Label(String(port), systemImage: "number")
                    }
                    Text(agent.displayCreatedAt)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
