//
//  AIOllamaView.swift
//  1PanelClient
//
//  本地模型 Ollama（/api/v2/ai/ollama）：未安装引导（跳应用商店）/
//  服务卡抽屉（启停/重启/连接信息/网关增强）/ 模型列表
//  （拉取进度 / 失败重试 / 模型拉取日志 / 运行终端 / 断开 / 删除）
//

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class AIOllamaViewModel: ObservableObject {
    @Published var check: AppInstallCheck?
    @Published var models: [AIOllamaModel] = []
    @Published private(set) var total = 0
    @Published private(set) var isLoading = true
    @Published private(set) var isLoadingModels = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?

    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var toastMessage: String?
    private var toastTask: Task<Void, Never>?

    @Published var isOperating = false
    @Published var pendingDeleteModels: [AIOllamaModel]?

    private var page = 1
    private var loadGeneration = 0
    private static let pageSize = 20

    private(set) var client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient.shared(for: server)
    }

    var isInstalled: Bool { check?.isExist ?? false }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        await loadCheck()
        if isInstalled {
            await loadModels()
        }
    }

    func loadCheck() async {
        do {
            check = try await client.send(
                path: APIEndpoint.appsInstalledCheck.path,
                body: AppCheckRequest(key: "ollama", name: ""),
                as: AppInstallCheck.self)
            errorMessage = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        page = 1
        loadGeneration += 1
        let req = AISearchPageRequest(page: 1, pageSize: Self.pageSize)
        do {
            let resp: PageResponse<AIOllamaModel> = try await client.send(
                path: APIEndpoint.aiOllamaModelSearch.path, body: req, as: PageResponse<AIOllamaModel>.self)
            models = resp.items ?? []
            total = resp.total ?? 0
        } catch {
            guard !APIError.isCancellation(error) else { return }
            // 拉取列表失败不整页报错（服务卡仍可展示）
            models = []
            total = 0
        }
    }

    func loadMoreModels() async {
        guard models.count < total, !isLoadingMore, !isLoadingModels else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let next = page + 1
        let generation = loadGeneration
        let req = AISearchPageRequest(page: next, pageSize: Self.pageSize)
        do {
            let resp: PageResponse<AIOllamaModel> = try await client.send(
                path: APIEndpoint.aiOllamaModelSearch.path, body: req, as: PageResponse<AIOllamaModel>.self)
            guard generation == loadGeneration else { return }
            let existing = Set(models.map(\.id))
            let newItems = (resp.items ?? []).filter { !existing.contains($0.id) }
            models += newItems
            total = resp.total ?? total
            page = next
        } catch {
            // 追加失败静默
        }
    }

    // MARK: 服务操作（已安装应用）

    func operate(_ op: String) async {
        guard let installId = check?.appInstallId, installId > 0 else { return }
        isOperating = true
        defer { isOperating = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledOperate.path,
                body: AppInstalledOperateRequest(installId: installId, operate: op),
                as: EmptyResponse.self)
            showToast(L10n.t("操作成功"))
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await loadCheck()
        } catch let err as APIError {
            showAlert(message: L10n.f("操作失败：%@", err.errorDescription ?? L10n.t("未知错误")))
        } catch {
            showAlert(message: L10n.f("操作失败：%@", error.localizedDescription))
        }
    }

    // MARK: 模型操作

    /// 拉取模型，成功返回 taskID
    func pullModel(name: String, recreate: Bool = false) async -> String? {
        let taskID = UUID().uuidString
        do {
            let _: EmptyResponse = try await client.send(
                path: recreate ? APIEndpoint.aiOllamaModelRecreate.path : APIEndpoint.aiOllamaModelCreate.path,
                body: recreate
                    ? AIOllamaModelRecreateRequest(name: name, taskID: taskID)
                    : AIOllamaModelCreateRequest(name: name, taskID: taskID),
                as: EmptyResponse.self)
            return taskID
        } catch let err as APIError {
            showAlert(message: L10n.f("拉取失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return nil
        } catch {
            showAlert(message: L10n.f("拉取失败：%@", error.localizedDescription))
            return nil
        }
    }

    func deleteModels(_ targets: [AIOllamaModel], forceDelete: Bool) async {
        pendingDeleteModels = nil
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiOllamaModelDelete.path,
                body: AIOllamaModelDeleteRequest(ids: targets.map(\.id), forceDelete: forceDelete),
                as: EmptyResponse.self)
            showToast(L10n.t("删除成功"))
            await loadModels()
        } catch let err as APIError {
            showAlert(message: L10n.f("删除失败：%@", err.errorDescription ?? L10n.t("未知错误")))
        } catch {
            showAlert(message: L10n.f("删除失败：%@", error.localizedDescription))
        }
    }

    /// 断开运行中的模型会话
    func closeModel(_ model: AIOllamaModel) async {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiOllamaClose.path,
                body: AIOllamaCloseRequest(name: model.displayName),
                as: EmptyResponse.self)
            showToast(L10n.f("已断开「%@」", model.displayName))
            await loadModels()
        } catch let err as APIError {
            showAlert(message: L10n.f("操作失败：%@", err.errorDescription ?? L10n.t("未知错误")))
        } catch {
            showAlert(message: L10n.f("操作失败：%@", error.localizedDescription))
        }
    }

    /// 读取模型拉取日志（AI/TaskPull + 模型 ID 作为 resourceID）
    func loadPullLog(model: AIOllamaModel) async -> [String] {
        do {
            let resp: TaskLogResponse = try await client.send(
                path: APIEndpoint.logsTaskRead.path,
                body: TaskLogReadRequest(
                    id: 0, type: "task", name: "",
                    page: 1, pageSize: 500, latest: true,
                    taskID: "", taskType: "AI", taskOperate: "TaskPull",
                    resourceID: model.id),
                queryItems: [URLQueryItem(name: "operateNode", value: "local")],
                as: TaskLogResponse.self)
            return resp.lines ?? []
        } catch {
            return []
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

// MARK: - 本地模型主页

struct AIOllamaView: View {
    @StateObject private var vm: AIOllamaViewModel
    private let server: ServerConfig

    @State private var isServiceExpanded = false
    @State private var pendingOperate: String?
    @State private var showAdd = false
    @State private var showProgress = false
    @State private var activeTaskID = ""
    @State private var progressTitle = ""
    @State private var showGateway = false
    @State private var showConnection = false
    @State private var showPullLog = false
    @State private var pullLogModelName = ""
    @State private var pullLogLines: [String] = []
    @State private var isLoadingPullLog = false
    @State private var runModel: AIOllamaModel?
    @State private var actionModel: AIOllamaModel?
    @State private var deleteModel: AIOllamaModel?
    @State private var forceDelete = false

    init(server: ServerConfig) {
        self.server = server
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(key: ManageItem.aiOllama.storeKey(server: server)) {
            AIOllamaViewModel(server: server)
        })
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.check == nil {
                LoadingStateView()
            } else if let check = vm.check {
                if check.isExist == true {
                    content(check: check)
                } else {
                    notInstalledView
                }
            } else if let err = vm.errorMessage {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button(L10n.t("重试")) { Task { await vm.load() } }
                }
            }
        }
        .navigationTitle(L10n.t("本地模型"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if vm.isInstalled {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L10n.t("添加模型"))
                }
            }
        }
        .refreshable { await vm.load() }
        .task { await PageVMStore.shared.autoRefresh(vm: vm) { await vm.load() } }
        .adaptivePolling(interval: 10, isActive: { hasRunning }) {
            await vm.loadModels()
        }
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .alert(
            pendingOperate.map { operateDisplayName($0) } ?? "",
            isPresented: Binding(
                get: { pendingOperate != nil },
                set: { if !$0 { pendingOperate = nil } }
            )
        ) {
            Button(L10n.t("取消"), role: .cancel) { pendingOperate = nil }
            Button(L10n.t("确认"), role: .destructive) {
                Haptic.warning()
                let op = pendingOperate
                pendingOperate = nil
                if let op { Task { await vm.operate(op) } }
            }
        } message: {
            Text(L10n.f("将对 Ollama 进行 %@ 操作，是否继续？", pendingOperate.map { operateDisplayName($0) } ?? ""))
        }
        .sheet(isPresented: Binding(
            get: { deleteModel != nil },
            set: { if !$0 { deleteModel = nil } }
        )) {
            TextInputConfirmSheet(
                title: L10n.t("删除模型"),
                message: L10n.f("删除后本地模型文件将被清理，不可恢复。请输入模型名称「%@」以确认删除。", deleteModel?.displayName ?? ""),
                expectedText: deleteModel?.displayName ?? "",
                onConfirm: {
                    if let m = deleteModel {
                        await vm.deleteModels([m], forceDelete: forceDelete)
                    }
                },
                options: {
                    Section(L10n.t("选项")) {
                        Toggle(L10n.t("强制删除"), isOn: $forceDelete)
                    }
                }
            )
        }
        .sheet(isPresented: $showAdd) {
            AIOllamaAddModelSheet(server: server) { name in
                Task { await pull(name: name) }
            }
            .presentationDragIndicator(.visible)
            .bottomSheetDetents([.medium])
        }
        .sheet(isPresented: $showPullLog) {
            NavigationStack {
                Group {
                    if isLoadingPullLog {
                        LoadingStateView()
                    } else if pullLogLines.isEmpty {
                        ContentUnavailableView(
                            L10n.t("暂无日志"),
                            systemImage: "doc.text",
                            description: Text(L10n.t("该模型尚未执行过拉取任务"))
                        )
                    } else {
                        LogLinesView(lines: pullLogLines)
                    }
                }
                .navigationTitle(L10n.f("日志 · %@", pullLogModelName))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.t("关闭")) { showPullLog = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showConnection) {
            NavigationStack {
                Form {
                    if let check = vm.check {
                        connectionSection(check: check)
                    }
                }
                .navigationTitle(L10n.t("连接信息"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.t("关闭")) { showConnection = false }
                    }
                }
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $actionModel) { model in
            ActionBottomSheet(
                title: model.displayName,
                items: modelMenuItems(model),
                onDismiss: { actionModel = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: modelMenuItems(model).count))])
            .presentationDragIndicator(.visible)
        }
        .navigationDestination(isPresented: $showProgress) {
            TaskProgressView(taskID: activeTaskID, title: progressTitle) { isDone in
                if isDone {
                    Task { await vm.loadModels() }
                }
                return false
            }
        }
        .navigationDestination(isPresented: $showGateway) {
            AIOllamaGatewayView(server: server, appInstallID: vm.check?.appInstallId ?? 0)
        }
        .navigationDestination(isPresented: Binding(
            get: { runModel != nil },
            set: { if !$0 { runModel = nil } }
        )) {
            if let m = runModel {
                TerminalScreen(
                    server: server,
                    target: .ollamaModel(name: m.displayName, cols: 80, rows: 24),
                    title: m.displayName
                )
            }
        }
    }

    private var hasRunning: Bool {
        vm.models.contains { $0.isRunning }
    }

    private func operateDisplayName(_ op: String) -> String {
        switch op {
        case "stop": return L10n.t("停止")
        case "start": return L10n.t("启动")
        case "restart": return L10n.t("重启")
        default: return op
        }
    }

    // MARK: - 未安装引导

    private var notInstalledView: some View {
        VStack(spacing: 20) {
            Spacer()

            IconBadge(systemName: "cpu", color: .purple, size: 72, cornerRadius: 16)
                .opacity(0.5)

            VStack(spacing: 8) {
                Text(L10n.f("%@未安装", "Ollama"))
                    .font(.headline)
                Text(L10n.f("请先安装 %@ 后再使用此功能", "Ollama"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            NavigationLink {
                AppStoreDetailView(appKey: "ollama", vm: installStoreVM)
            } label: {
                Label(L10n.f("安装 %@", "Ollama"), systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)

            Spacer()
        }
        .padding()
        .navigationDestination(isPresented: $installStoreVM.showInstall) {
            if let installDetail = installStoreVM.installDetail {
                AppInstallView(detail: installDetail, vm: installStoreVM)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .installCompleted)) { _ in
            // 安装完成后回到本页并重新检查（Ollama 页为安装流程发起方）
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await vm.loadCheck()
            }
        }
    }

    /// 应用商店 VM（未安装引导安装用）
    @StateObject private var installStoreVM: AppStoreViewModel = {
        let server = ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        return AppStoreViewModel(server: server)
    }()

    // MARK: - 已安装内容

    private func content(check: AppInstallCheck) -> some View {
        List {
            ServiceStatusCard(
                title: "Ollama",
                subtitle: check.version,
                statusText: check.status ?? "-",
                statusColor: (check.status ?? "").lowercased() == "running" ? .statusRunning : .statusStopped,
                isOperating: vm.isOperating,
                isExpanded: $isServiceExpanded,
                actions: [
                    ServiceAction(
                        title: (check.status ?? "").lowercased() == "running" ? L10n.t("停止") : L10n.t("启动"),
                        icon: (check.status ?? "").lowercased() == "running" ? "stop.fill" : "play.fill",
                        color: (check.status ?? "").lowercased() == "running" ? .orange : .green
                    ) {
                        pendingOperate = (check.status ?? "").lowercased() == "running" ? "stop" : "start"
                    },
                    ServiceAction(title: L10n.t("重启"), icon: "arrow.triangle.2.circlepath", color: .blue) {
                        pendingOperate = "restart"
                    },
                    ServiceAction(title: L10n.t("连接信息"), icon: "point.3.connected.trianglepath.dotted", color: .teal) {
                        showConnection = true
                    },
                    ServiceAction(title: L10n.t("网关增强"), icon: "globe", color: .purple) {
                        showGateway = true
                    },
                ]
            ) {
                IconBadge(systemName: "cpu", color: .purple, size: 44)
            }

            modelSection
        }
        .listStyle(.insetGrouped)
    }

    /// 连接信息：容器连接（容器名/端口）与外部连接（面板地址/端口）
    private func connectionSection(check: AppInstallCheck) -> some View {
        Section {
            CopyableInfoRow(L10n.t("容器地址"), value: check.containerName ?? "-", monospaced: true)
            CopyableInfoRow(L10n.t("容器端口"), value: String(check.httpPort ?? 0), monospaced: true)
            CopyableInfoRow(L10n.t("外部地址"), value: panelHost, monospaced: true)
            CopyableInfoRow(L10n.t("外部端口"), value: String(check.httpPort ?? 0), monospaced: true)
        } header: {
            SectionLabel(title: L10n.t("连接信息"), systemImage: "point.3.connected.trianglepath.dotted")
        } footer: {
            Text(L10n.t("外部连接需在防火墙放行对应端口"))
        }
    }

    /// 面板主机地址（外部连接展示用）
    private var panelHost: String {
        URLComponents(string: server.normalizedBaseURL)?.host ?? server.baseURL
    }

    @ViewBuilder
    private var modelSection: some View {
        Section {
            if vm.isLoadingModels && vm.models.isEmpty {
                HStack {
                    Spacer()
                    LoadingStateView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if vm.models.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无模型"),
                    systemImage: "cpu",
                    description: Text(L10n.t("点击右上角 + 拉取模型"))
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(vm.models) { model in
                    Button {
                        runModel = model
                    } label: {
                        AIOllamaModelRow(model: model)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                            Haptic.selection()
                            actionModel = model
                        }
                    )
                    .onAppear {
                        if model.id == vm.models.last?.id {
                            Task { await vm.loadMoreModels() }
                        }
                    }
                }

                if vm.models.count < vm.total || vm.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .onAppear { Task { await vm.loadMoreModels() } }
                }
            }
        } header: {
            SectionLabel(
                title: L10n.f("模型 · 共 %d 个", vm.models.count),
                systemImage: "shippingbox"
            )
        } footer: {
            Text(L10n.t("点击模型进入运行终端，长按查看更多操作"))
        }
    }

    private func modelMenuItems(_ model: AIOllamaModel) -> [ActionMenuItem] {
        var items: [ActionMenuItem] = []
        if model.isRunning {
            items.append(ActionMenuItem(title: L10n.t("断开"), icon: "minus.circle", color: .orange, role: .destructive) {
                Task { await vm.closeModel(model) }
            })
        }
        items.append(ActionMenuItem(title: L10n.t("运行"), icon: "play.fill", color: .green) {
            runModel = model
        })
        // 仅拉取失败的模型提供重试
        if isPullFailed(model) {
            items.append(ActionMenuItem(title: L10n.t("重试"), icon: "arrow.clockwise.circle", color: .blue) {
                Task { await pull(name: model.displayName, recreate: true) }
            })
        }
        items.append(ActionMenuItem(title: L10n.t("日志"), icon: "doc.text", color: .indigo) {
            Task { await openPullLog(model: model) }
        })
        items.append(ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red, role: .destructive) {
            forceDelete = false
            deleteModel = model
        })
        return items
    }

    // MARK: - 拉取

    private func pull(name: String, recreate: Bool = false) async {
        if let taskID = await vm.pullModel(name: name, recreate: recreate) {
            activeTaskID = taskID
            progressTitle = L10n.f("拉取 %@", name)
            showProgress = true
        }
    }

    /// 拉取失败判定（Success/Running/Pulling 等状态不提供重试）
    private func isPullFailed(_ model: AIOllamaModel) -> Bool {
        ["failed", "error", "err"].contains((model.status ?? "").lowercased())
    }

    private func openPullLog(model: AIOllamaModel) async {
        pullLogModelName = model.displayName
        showPullLog = true
        isLoadingPullLog = true
        pullLogLines = await vm.loadPullLog(model: model)
        isLoadingPullLog = false
    }
}

// MARK: - 模型行

struct AIOllamaModelRow: View {
    let model: AIOllamaModel

    private var statusColor: Color {
        switch (model.status ?? "").lowercased() {
        case "running": return .statusRunning
        case "success": return .statusRunning
        case "pulling": return .blue
        case "error", "failed": return .statusError
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "cpu.fill", color: .purple)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.body.bold())
                        .lineLimit(1)
                    if let status = model.status, !status.isEmpty {
                        StatusBadge(text: status, color: statusColor)
                    }
                }
                Text(model.displaySize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

// MARK: - 添加模型 Sheet

struct AIOllamaAddModelSheet: View {
    let server: ServerConfig
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.t("模型名称"), text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } header: {
                    SectionLabel(title: L10n.t("拉取模型"), systemImage: "arrow.down.circle")
                } footer: {
                    Text(L10n.t("输入 Ollama 模型名称（如 llama3.2、deepseek-v4-flash），拉取进度将在任务中展示"))
                }
            }
            .navigationTitle(L10n.t("添加模型"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("拉取")) {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        dismiss()
                        onSubmit(trimmed)
                    }
                    .disabled(!canSubmit)
                }
            }
        }
    }
}

// MARK: - AI 网关域名（/ai/domain）

struct AIOllamaGatewayView: View {
    let server: ServerConfig
    let appInstallID: Int

    @State private var info: AIDomainInfo?
    @State private var isLoading = true

    private let client: APIClient

    init(server: ServerConfig, appInstallID: Int) {
        self.server = server
        self.appInstallID = appInstallID
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else {
                DomainBindFormView(
                    server: server,
                    title: L10n.t("网关增强"),
                    footerHint: L10n.t("绑定域名后可通过该地址访问 Ollama OpenAI 兼容接口"),
                    info: info,
                    onSave: { req in
                        await save(req)
                    }
                )
            }
        }
        .navigationTitle(L10n.t("网关增强"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            info = try await client.send(
                path: APIEndpoint.aiDomainGet.path,
                body: AIDomainGetRequest(appInstallID: appInstallID),
                as: AIDomainInfo.self)
        } catch {
            guard !APIError.isCancellation(error) else { return }
            info = nil
        }
        isLoading = false
    }

    private func save(_ req: AIDomainBindRequest) async -> String? {
        var request = req
        request.appInstallID = appInstallID
        do {
            let _: EmptyResponse = try await client.send(
                path: (info?.websiteID ?? 0) > 0 ? APIEndpoint.aiDomainUpdate.path : APIEndpoint.aiDomainBind.path,
                body: request,
                as: EmptyResponse.self)
            await load()
            return nil
        } catch {
            guard !APIError.isCancellation(error) else { return nil }
            return error.localizedDescription
        }
    }
}
