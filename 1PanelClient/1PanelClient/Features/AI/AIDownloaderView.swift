//
//  AIDownloaderView.swift
//  1PanelClient
//
//  模型下载器（/api/v2/xpack/model/downloader）：已下载模型（删除）/
//  下载队列（进度轮询 / 取消 / 重试 / 移除记录）/ 仓库搜索（HuggingFace /
//  ModelScope，见 AIDownloaderSearchView）/ 下载设置（模型目录与端点令牌）
//

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class AIDownloaderViewModel: ObservableObject {
    @Published var settings: ModelDownloaderSettings?
    @Published var localModels: [ModelLocalItem] = []
    @Published private(set) var localTotal = 0
    @Published private(set) var isLoadingMoreLocal = false
    /// 列表为空且加载失败时的错误（有内容时保留旧列表不显示错误）
    @Published private(set) var localError: String?
    @Published var tasks: [ModelDownloadTask] = []
    @Published private(set) var tasksTotal = 0
    @Published private(set) var isLoadingMoreTasks = false
    @Published private(set) var tasksError: String?

    private var localPage = 1
    private var tasksPage = 1
    private static let pageSize = 20
    @Published private(set) var isLoading = true
    @Published private(set) var isLoadingTasks = false
    @Published var errorMessage: String?

    @Published var showAlert = false
    @Published var alertMessage = ""
    /// 清理由 toastOverlay 组件内建完成（2 秒自动消失），VM 只负责赋值
    @Published var toastMessage: String?

    private(set) var client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient.shared(for: server)
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        await loadSettings()
        await loadLocal()
        await loadTasks()
    }

    func loadSettings() async {
        do {
            // 设置读取是 GET（send 的 method 默认 POST，必须显式传，
            // 误发 POST 会命中保存校验：ModelDir required）
            settings = try await client.send(
                path: APIEndpoint.modelDownloaderSettings.path,
                method: "GET",
                body: nil,
                as: ModelDownloaderSettings.self)
            errorMessage = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func saveSettings(_ s: ModelDownloaderSettings) async -> String? {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.modelDownloaderSettings.path,
                method: "POST",
                body: s,
                as: EmptyResponse.self)
            await loadSettings()
            return nil
        } catch {
            guard !APIError.isCancellation(error) else { return nil }
            return error.localizedDescription
        }
    }

    // MARK: 已下载模型

    func loadLocal() async {
        localPage = 1
        do {
            let resp: PageResponse<ModelLocalItem> = try await client.send(
                path: APIEndpoint.modelDownloaderLocalSearch.path,
                body: ModelDownloaderPageRequest(),
                as: PageResponse<ModelLocalItem>.self)
            localModels = resp.items ?? []
            localTotal = resp.total ?? 0
            localError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            // 失败不再静默成「暂无数据」：空列表时展示错误，便于区分真空与加载失败
            if localModels.isEmpty {
                localError = error.localizedDescription
            }
        }
    }

    func loadMoreLocal() async {
        guard localModels.count < localTotal, !isLoadingMoreLocal else { return }
        isLoadingMoreLocal = true
        defer { isLoadingMoreLocal = false }
        let next = localPage + 1
        do {
            let resp: PageResponse<ModelLocalItem> = try await client.send(
                path: APIEndpoint.modelDownloaderLocalSearch.path,
                body: ModelDownloaderPageRequest(page: next, pageSize: Self.pageSize),
                as: PageResponse<ModelLocalItem>.self)
            let existing = Set(localModels.map(\.id))
            localModels += (resp.items ?? []).filter { !existing.contains($0.id) }
            localTotal = resp.total ?? localTotal
            localPage = next
        } catch {
            guard !APIError.isCancellation(error) else { return }
            // 追加失败：收敛 total 到已加载数，底部进度行不再常驻（切回分段/下拉重置）
            localTotal = localModels.count
        }
    }

    func deleteLocal(_ item: ModelLocalItem) async {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.modelDownloaderLocalDelete.path,
                body: ModelLocalDeleteRequest(name: item.name),
                as: EmptyResponse.self)
            showToast(L10n.f("已删除「%@」", item.name))
            await loadLocal()
        } catch let err as APIError {
            showAlert(message: L10n.f("删除失败：%@", err.errorDescription ?? L10n.t("未知错误")))
        } catch {
            showAlert(message: L10n.f("删除失败：%@", error.localizedDescription))
        }
    }

    // MARK: 下载队列

    func loadTasks() async {
        isLoadingTasks = true
        defer { isLoadingTasks = false }
        tasksPage = 1
        let previousActiveIDs = Set(tasks.filter { $0.isActive }.map(\.id))
        do {
            let resp: PageResponse<ModelDownloadTask> = try await client.send(
                path: APIEndpoint.modelDownloaderTasksSearch.path,
                body: ModelDownloaderTasksRequest(),
                as: PageResponse<ModelDownloadTask>.self)
            tasks = resp.items ?? []
            tasksTotal = resp.total ?? 0
            tasksError = nil
            // 有任务在本次刷新中从进行中转为成功：顺带刷新已下载列表，
            // 用户在队列页等到完成后切到「已下载」即可见最新数据
            let justSucceeded = tasks.contains {
                previousActiveIDs.contains($0.id)
                    && ($0.status ?? "").lowercased() == "success"
            }
            if justSucceeded {
                await loadLocal()
            }
        } catch {
            guard !APIError.isCancellation(error) else { return }
            // 轮询瞬时失败保留旧进度；仅空列表时展示错误
            if tasks.isEmpty {
                tasksError = error.localizedDescription
            }
        }
    }

    func loadMoreTasks() async {
        guard tasks.count < tasksTotal, !isLoadingMoreTasks, !isLoadingTasks else { return }
        isLoadingMoreTasks = true
        defer { isLoadingMoreTasks = false }
        let next = tasksPage + 1
        do {
            let resp: PageResponse<ModelDownloadTask> = try await client.send(
                path: APIEndpoint.modelDownloaderTasksSearch.path,
                body: ModelDownloaderTasksRequest(page: next, pageSize: Self.pageSize),
                as: PageResponse<ModelDownloadTask>.self)
            let existing = Set(tasks.map(\.id))
            tasks += (resp.items ?? []).filter { !existing.contains($0.id) }
            tasksTotal = resp.total ?? tasksTotal
            tasksPage = next
        } catch {
            guard !APIError.isCancellation(error) else { return }
            tasksTotal = tasks.count
        }
    }

    var hasActiveTask: Bool {
        tasks.contains { $0.isActive }
    }

    // MARK: 任务操作（端点未抓包，按命名规律推定，联调时修正）

    func cancelTask(_ task: ModelDownloadTask) async {
        await operate(task, path: APIEndpoint.modelDownloaderTaskCancel.path,
                      success: L10n.f("已取消「%@」", task.displayName))
    }

    func retryTask(_ task: ModelDownloadTask) async {
        await operate(task, path: APIEndpoint.modelDownloaderTaskRetry.path,
                      success: L10n.f("已重新排队「%@」", task.displayName))
    }

    func removeTaskRecord(_ task: ModelDownloadTask) async {
        await operate(task, path: APIEndpoint.modelDownloaderTaskRemove.path,
                      success: L10n.t("已移除记录"))
    }

    private func operate(_ task: ModelDownloadTask, path: String, success: String) async {
        do {
            let _: EmptyResponse = try await client.send(
                path: path,
                body: ModelTaskIDRequest(id: task.id),
                as: EmptyResponse.self)
            showToast(success)
            await loadTasks()
        } catch let err as APIError {
            showAlert(message: L10n.f("操作失败：%@", err.errorDescription ?? L10n.t("未知错误")))
        } catch {
            showAlert(message: L10n.f("操作失败：%@", error.localizedDescription))
        }
    }

    // MARK: 下载

    /// 从 HuggingFace / ModelScope 下载仓库，成功后返回 true（供调用方提示/切页）
    @discardableResult
    func download(source: ModelRepoSource, repoID: String) async -> Bool {
        let endpoint: APIEndpoint
        switch source {
        case .huggingface: endpoint = .modelDownloaderHFDownload
        case .modelscope: endpoint = .modelDownloaderMSDownload
        }
        do {
            let _: ModelDownloadTask = try await client.send(
                path: endpoint.path,
                body: ModelRepoRequest(repoID: repoID),
                as: ModelDownloadTask.self)
            showToast(L10n.f("「%@」已加入下载队列", repoID))
            await loadTasks()
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("下载失败：%@", err.errorDescription ?? L10n.t("未知错误")))
        } catch {
            showAlert(message: L10n.f("下载失败：%@", error.localizedDescription))
        }
        return false
    }

    // MARK: 提示

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }

    private func showToast(_ message: String) {
        toastMessage = message
    }
}

// MARK: - 主页

struct AIDownloaderView: View {
    @StateObject private var vm: AIDownloaderViewModel

    private enum Segment: String, CaseIterable, Identifiable {
        case local
        case tasks
        case search
        var id: String { rawValue }
    }

    @State private var segment: Segment = .local
    @State private var showSettings = false
    @State private var deleteLocalItem: ModelLocalItem?

    init(server: ServerConfig) {
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(key: ManageItem.aiDownloader.storeKey(server: server)) {
            AIDownloaderViewModel(server: server)
        })
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.settings == nil {
                LoadingStateView()
            } else if let err = vm.errorMessage, vm.settings == nil {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button(L10n.t("重试")) { Task { await vm.load() } }
                }
            } else {
                content
            }
        }
        .navigationTitle(L10n.t("模型下载"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(L10n.t("下载设置"))
            }
        }
        .task { await PageVMStore.shared.autoRefresh(vm: vm) { await vm.load() } }
        // 切换分段时后台刷新目标分段：队列下载完成后切到「已下载」能立即看到新模型
        .onChange(of: segment) { _, newSegment in
            switch newSegment {
            case .local:
                Task { await vm.loadLocal() }
            case .tasks:
                Task { await vm.loadTasks() }
            case .search:
                break
            }
        }
        // 队列有 Waiting/Downloading 任务时轮询进度，全部完成后停
        .adaptivePolling(interval: 5, isActive: { vm.hasActiveTask }) {
            await vm.loadTasks()
        }
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .sheet(isPresented: $showSettings) {
            AIDownloaderSettingsSheet(vm: vm)
        }
        .sheet(isPresented: Binding(
            get: { deleteLocalItem != nil },
            set: { if !$0 { deleteLocalItem = nil } }
        )) {
            if let item = deleteLocalItem {
                TextInputConfirmSheet(
                    title: L10n.t("删除模型"),
                    message: L10n.f("将删除服务器上的模型目录「%@」及其文件，不可恢复。请输入模型名称以确认删除。", item.name),
                    expectedText: item.name
                ) {
                    await vm.deleteLocal(item)
                }
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Picker("", selection: $segment) {
                Text(L10n.t("已下载")).tag(Segment.local)
                Text(L10n.t("下载队列")).tag(Segment.tasks)
                Text(L10n.t("搜索")).tag(Segment.search)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // 三分段叠放 + 透明度切换：切换不销毁视图，搜索结果/滚动位置保留
            // （allowsHitTesting 挡住隐藏分层的触摸）
            ZStack {
                localList
                    .opacity(segment == .local ? 1 : 0)
                    .allowsHitTesting(segment == .local)
                tasksList
                    .opacity(segment == .tasks ? 1 : 0)
                    .allowsHitTesting(segment == .tasks)
                AIDownloaderSearchView(vm: vm)
                    .opacity(segment == .search ? 1 : 0)
                    .allowsHitTesting(segment == .search)
            }
        }
    }

    // MARK: 已下载

    private var localList: some View {
        List {
            Section {
                if let err = vm.localError, vm.localModels.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(err)
                    } actions: {
                        Button(L10n.t("重试")) { Task { await vm.loadLocal() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                } else if vm.localModels.isEmpty {
                    ContentUnavailableView(
                        L10n.t("暂无已下载模型"),
                        systemImage: "arrow.down.circle",
                        description: Text(L10n.t("切换到「搜索」从 HuggingFace / ModelScope 下载模型"))
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(vm.localModels) { item in
                        ModelLocalRow(item: item)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Haptic.warning()
                                    deleteLocalItem = item
                                } label: {
                                    Label(L10n.t("删除"), systemImage: "trash")
                                }
                            }
                            .onAppear {
                                if item.id == vm.localModels.last?.id {
                                    Task { await vm.loadMoreLocal() }
                                }
                            }
                    }

                    if vm.localModels.count < vm.localTotal || vm.isLoadingMoreLocal {
                        LoadingStateView(compact: true)
                        .onAppear { Task { await vm.loadMoreLocal() } }
                    }
                }
            } header: {
                SectionLabel(
                    title: L10n.f("本地模型 · 共 %d 个", vm.localTotal),
                    systemImage: "internaldrive"
                )
            } footer: {
                if let dir = vm.settings?.modelDir, !dir.isEmpty {
                    Text(L10n.f("模型目录：%@", dir))
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await vm.loadLocal() }
    }

    // MARK: 下载队列

    private var tasksList: some View {
        List {
            Section {
                if let err = vm.tasksError, vm.tasks.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(err)
                    } actions: {
                        Button(L10n.t("重试")) { Task { await vm.loadTasks() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                } else if vm.tasks.isEmpty {
                    ContentUnavailableView(
                        L10n.t("队列为空"),
                        systemImage: "tray",
                        description: Text(L10n.t("下载任务将在此显示进度"))
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(vm.tasks) { task in
                        ModelTaskRow(
                            task: task,
                            onCancel: task.canCancel == true
                                ? { Task<Void, Never> { await vm.cancelTask(task) } } : nil,
                            onRetry: task.canRetry == true
                                ? { Task<Void, Never> { await vm.retryTask(task) } } : nil,
                            onRemoveRecord: task.canRemoveRecord == true
                                ? { Task<Void, Never> { await vm.removeTaskRecord(task) } } : nil
                        )
                        .onAppear {
                            if task.id == vm.tasks.last?.id {
                                Task { await vm.loadMoreTasks() }
                            }
                        }
                    }

                    if vm.tasks.count < vm.tasksTotal || vm.isLoadingMoreTasks {
                        LoadingStateView(compact: true)
                        .onAppear { Task { await vm.loadMoreTasks() } }
                    }
                }
            } header: {
                SectionLabel(
                    title: L10n.f("下载队列 · 共 %d 条", vm.tasksTotal),
                    systemImage: "arrow.down.circle.dotted"
                )
            } footer: {
                if vm.hasActiveTask {
                    Text(L10n.t("有任务进行中，每 5 秒自动刷新进度"))
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await vm.loadTasks() }
    }
}

// MARK: - 已下载模型行

private struct ModelLocalRow: View {
    let item: ModelLocalItem

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "shippingbox.fill", color: .cyan)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.body.bold())
                    .lineLimit(1)
                Text(item.path ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(item.displaySize)
                    if let created = item.createdAt, !created.isEmpty {
                        Text(created)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 下载任务行

private struct ModelTaskRow: View {
    let task: ModelDownloadTask
    var onCancel: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    var onRemoveRecord: (() -> Void)? = nil

    private var statusColor: Color {
        switch (task.status ?? "").lowercased() {
        case "downloading": return .blue
        case "waiting", "pending": return .secondary
        case "success": return .statusRunning
        default: return task.isFailed ? .statusError : .secondary
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconBadge(
                systemName: task.status?.lowercased() == "success" ? "checkmark.circle.fill" : "arrow.down.circle.fill",
                color: task.isActive ? .blue : statusColor == .statusError ? .red : .cyan
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(task.displayName)
                        .font(.body.bold())
                        .lineLimit(1)
                    StatusBadge(text: task.sourceDisplay, color: .secondary)
                }
                if let repo = task.repoID, repo != task.displayName {
                    Text(repo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if task.isActive {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(min(max(task.progress ?? 0, 0), 100)), total: 100)
                            .tint(.blue)
                        Text("\(min(max(task.progress ?? 0, 0), 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(task.progressDetail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let msg = task.errorMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if onCancel != nil || onRetry != nil || onRemoveRecord != nil {
                    Menu {
                        if let onCancel {
                            Button {
                                onCancel()
                            } label: {
                                Label(L10n.t("取消下载"), systemImage: "stop.circle")
                            }
                        }
                        if let onRetry {
                            Button {
                                onRetry()
                            } label: {
                                Label(L10n.t("重试"), systemImage: "arrow.clockwise")
                            }
                        }
                        if let onRemoveRecord {
                            Button(role: .destructive) {
                                onRemoveRecord()
                            } label: {
                                Label(L10n.t("移除记录"), systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                if let status = task.status, !status.isEmpty {
                    StatusBadge(text: status, color: statusColor)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 下载设置 Sheet

struct AIDownloaderSettingsSheet: View {
    @ObservedObject var vm: AIDownloaderViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var modelDir = ""
    @State private var hfEndpoint = ""
    @State private var hfToken = ""
    @State private var modelScopeEndpoint = ""
    @State private var modelScopeToken = ""
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    OutlinedTextField(label: "/opt/1panel/ai/models", text: $modelDir)
                        .font(.dataMonospacedBody)
                } header: {
                    SectionLabel(title: L10n.t("模型目录"), systemImage: "internaldrive")
                } footer: {
                    Text(L10n.t("下载的模型将保存到该目录，vLLM 与 Ollama 可直接挂载使用"))
                }

                Section {
                    OutlinedTextField(label: "https://hf-mirror.com", text: $hfEndpoint, keyboardType: .URL)
                        .font(.dataMonospacedBody)
                    OutlinedTextField(label: L10n.t("令牌（可选）"), text: $hfToken, isSecure: true)
                } header: {
                    SectionLabel(title: "HuggingFace", systemImage: "hare")
                } footer: {
                    Text(L10n.t("加速地址用于国内网络直连，如 https://hf-mirror.com；留空使用官方地址"))
                }

                Section {
                    OutlinedTextField(label: "https://www.modelscope.cn", text: $modelScopeEndpoint, keyboardType: .URL)
                        .font(.dataMonospacedBody)
                    OutlinedTextField(label: L10n.t("令牌（可选）"), text: $modelScopeToken, isSecure: true)
                } header: {
                    SectionLabel(title: "ModelScope", systemImage: "sparkles.rectangle.stack")
                }

                if let err = saveError {
                    Section {
                        Text(err)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(L10n.t("下载设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("保存")) {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                }
            }
        }
        .onAppear(perform: fill)
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.large])
    }

    private func fill() {
        guard modelDir.isEmpty, let s = vm.settings else { return }
        modelDir = s.modelDir ?? ""
        hfEndpoint = s.hfEndpoint ?? ""
        hfToken = s.hfToken ?? ""
        modelScopeEndpoint = s.modelScopeEndpoint ?? ""
        modelScopeToken = s.modelScopeToken ?? ""
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let settings = ModelDownloaderSettings(
            modelDir: modelDir,
            hfEndpoint: hfEndpoint,
            hfToken: hfToken,
            modelScopeEndpoint: modelScopeEndpoint,
            modelScopeToken: modelScopeToken)
        if let err = await vm.saveSettings(settings) {
            saveError = err
        } else {
            vm.toastMessage = L10n.t("已保存")
            dismiss()
        }
    }
}
