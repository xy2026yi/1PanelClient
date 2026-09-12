//
//  AIVllmView.swift
//  1PanelClient
//
//  vLLM 推理实例（/api/v2/xpack/vllm）：实例列表（状态轮询）/
//  创建（AIVllmCreateView，进度走任务日志）/ 启停/重启/删除/
//  容器日志（复用 ComposeLogView）/ 编辑（create 表单复用）
//
//  operate/update/delete 请求未抓包，按命名规律推定，联调时集中修正
//

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class AIVllmViewModel: ObservableObject {
    @Published var instances: [VllmInstance] = []
    @Published private(set) var total = 0
    @Published private(set) var isLoading = true
    @Published var errorMessage: String?

    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var toastMessage: String?
    private var toastTask: Task<Void, Never>?

    /// 操作中的实例 ID（行内禁重复点击）
    @Published private(set) var operatingID: Int?

    private var page = 1
    private var loadGeneration = 0
    private static let pageSize = 20

    private(set) var client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient.shared(for: server)
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        await loadInstances()
    }

    func loadInstances() async {
        page = 1
        loadGeneration += 1
        do {
            let resp: PageResponse<VllmInstance> = try await client.send(
                path: APIEndpoint.vllmSearch.path,
                body: VllmSearchRequest(),
                as: PageResponse<VllmInstance>.self)
            instances = resp.items ?? []
            total = resp.total ?? 0
            errorMessage = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            if instances.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadMoreInstances() async {
        guard instances.count < total else { return }
        let next = page + 1
        let generation = loadGeneration
        do {
            let resp: PageResponse<VllmInstance> = try await client.send(
                path: APIEndpoint.vllmSearch.path,
                body: VllmSearchRequest(page: next, pageSize: Self.pageSize),
                as: PageResponse<VllmInstance>.self)
            guard generation == loadGeneration else { return }
            let existing = Set(instances.map(\.id))
            instances += (resp.items ?? []).filter { !existing.contains($0.id) }
            total = resp.total ?? total
            page = next
        } catch {
            // 追加失败静默
        }
    }

    var hasTransitioning: Bool {
        instances.contains { $0.isTransitioning }
    }

    // MARK: 实例操作

    /// 启动/停止/重启/删除（同一 operate 端点，delete 额外携带 forceDelete）
    func operate(_ instance: VllmInstance, operate: String, forceDelete: Bool = false) async {
        operatingID = instance.id
        defer { operatingID = nil }
        let isDelete = operate == "delete"
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.vllmOperate.path,
                body: VllmOperateRequest(
                    id: instance.id,
                    operate: operate,
                    taskID: UUID().uuidString,
                    forceDelete: isDelete ? forceDelete : nil),
                as: EmptyResponse.self)
            if isDelete {
                showToast(L10n.f("已删除「%@」", instance.displayName))
                // 后端删除是异步任务（请求带 taskID）：复查列表直到实例消失，
                // 最多约 8 秒；期间确认弹窗按钮保持进度态，列表行显示转圈
                for delayMs in [800, 1500, 2000, 2000, 2000] {
                    try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                    await loadInstances()
                    if !instances.contains(where: { $0.id == instance.id }) { break }
                }
            } else {
                try? await Task.sleep(nanoseconds: 800_000_000)
                await loadInstances()
            }
        } catch {
            guard !APIError.isCancellation(error) else { return }
            let detail = (error as? APIError)?.errorDescription ?? error.localizedDescription
            showAlert(message: isDelete
                ? L10n.f("删除失败：%@", detail)
                : L10n.f("操作失败：%@", detail))
        }
    }

    // MARK: 创建 / 编辑提交

    /// 创建成功返回 taskID（供进度页轮询），失败返回 nil
    func submitCreate(_ request: VllmCreateRequest) async -> String? {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.vllmCreate.path,
                body: request,
                as: EmptyResponse.self)
            return request.taskID
        } catch let err as APIError {
            showAlert(message: L10n.f("创建失败：%@", err.errorDescription ?? L10n.t("未知错误")))
        } catch {
            showAlert(message: L10n.f("创建失败：%@", error.localizedDescription))
        }
        return nil
    }

    /// 编辑提交（update 端点未抓包 [推测]，成功后刷新列表）
    func submitUpdate(_ request: VllmCreateRequest) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.vllmUpdate.path,
                body: request,
                as: EmptyResponse.self)
            showToast(L10n.t("已保存"))
            await loadInstances()
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("保存失败：%@", err.errorDescription ?? L10n.t("未知错误")))
        } catch {
            showAlert(message: L10n.f("保存失败：%@", error.localizedDescription))
        }
        return false
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

// MARK: - 实例列表页

struct AIVllmView: View {
    @StateObject private var vm: AIVllmViewModel
    private let server: ServerConfig

    @State private var showCreate = false
    @State private var editInstance: VllmInstance?
    @State private var actionInstance: VllmInstance?
    @State private var deleteInstance: VllmInstance?
    @State private var forceDeleteInstance = false
    @State private var pendingOperate: (instance: VllmInstance, operate: String)?
    @State private var logInstance: VllmInstance?
    @State private var showProgress = false
    @State private var activeTaskID = ""

    init(server: ServerConfig) {
        self.server = server
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(key: ManageItem.aiVllm.storeKey(server: server)) {
            AIVllmViewModel(server: server)
        })
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.instances.isEmpty {
                LoadingStateView()
            } else if let err = vm.errorMessage, vm.instances.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button(L10n.t("重试")) { Task { await vm.load() } }
                }
            } else {
                instanceList
            }
        }
        .navigationTitle("vLLM")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("创建实例"))
            }
        }
        .task { await PageVMStore.shared.autoRefresh(vm: vm) { await vm.load() } }
        // Installing/Rebuilding 等过渡态轮询，稳定后停
        .adaptivePolling(interval: 5, isActive: { vm.hasTransitioning }) {
            await vm.loadInstances()
        }
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .alert(
            pendingOperate.map { operateDisplayName($0.operate) } ?? "",
            isPresented: Binding(
                get: { pendingOperate != nil },
                set: { if !$0 { pendingOperate = nil } }
            )
        ) {
            Button(L10n.t("取消"), role: .cancel) { pendingOperate = nil }
            Button(L10n.t("确认"), role: .destructive) {
                Haptic.warning()
                if let pending = pendingOperate {
                    Task { await vm.operate(pending.instance, operate: pending.operate) }
                }
                pendingOperate = nil
            }
        } message: {
            if let pending = pendingOperate {
                Text(L10n.f("将对实例「%@」执行 %@ 操作，是否继续？",
                            pending.instance.displayName,
                            operateDisplayName(pending.operate)))
            }
        }
        .sheet(isPresented: $showCreate) {
            AIVllmCreateView(server: server, vm: vm) { taskID in
                activeTaskID = taskID
                showProgress = true
            }
        }
        .sheet(isPresented: Binding(
            get: { editInstance != nil },
            set: { if !$0 { editInstance = nil } }
        )) {
            if let instance = editInstance {
                AIVllmCreateView(server: server, vm: vm, instance: instance) { _ in }
            }
        }
        .sheet(isPresented: Binding(
            get: { deleteInstance != nil },
            set: { if !$0 { deleteInstance = nil } }
        )) {
            if let instance = deleteInstance {
                TextInputConfirmSheet(
                    title: L10n.t("删除实例"),
                    message: L10n.f("将删除 vLLM 实例「%@」及其容器与数据目录，不可恢复。请输入实例名称以确认删除。", instance.displayName),
                    expectedText: instance.displayName
                ) {
                    await vm.operate(instance, operate: "delete", forceDelete: forceDeleteInstance)
                } options: {
                    Section(L10n.t("选项")) {
                        Toggle(L10n.t("强制删除"), isOn: $forceDeleteInstance)
                    }
                }
            }
        }
        .sheet(item: $actionInstance) { instance in
            ActionBottomSheet(
                title: instance.displayName,
                items: actionItems(instance),
                onDismiss: { actionInstance = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: actionItems(instance).count))])
            .presentationDragIndicator(.visible)
        }
        .navigationDestination(isPresented: $showProgress) {
            TaskProgressView(taskID: activeTaskID, title: L10n.t("创建 vLLM 实例"), node: "local") { isDone in
                if isDone {
                    Task { await vm.loadInstances() }
                }
                return false
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { logInstance != nil },
            set: { if !$0 { logInstance = nil } }
        )) {
            if let instance = logInstance {
                ComposeLogView(
                    title: L10n.f("日志 · %@", instance.displayName),
                    composePath: Self.composePath(for: instance),
                    client: vm.client)
            }
        }
    }

    private var instanceList: some View {
        List {
            Section {
                if vm.instances.isEmpty {
                    ContentUnavailableView(
                        L10n.t("暂无实例"),
                        systemImage: "bolt.horizontal.circle",
                        description: Text(L10n.t("点击右上角 + 创建 vLLM 推理实例"))
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(vm.instances) { instance in
                        Button {
                            actionInstance = instance
                        } label: {
                            VllmInstanceRow(instance: instance, isOperating: vm.operatingID == instance.id)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if instance.id == vm.instances.last?.id {
                                Task { await vm.loadMoreInstances() }
                            }
                        }
                    }
                }
            } footer: {
                Text(L10n.t("点击实例查看操作，长命令启动参数以模板为准"))
            }
        }
        .listStyle(.insetGrouped)
        // 下拉刷新挂在 List 本体上（挂在祖先容器上不生效，与下载器页处理一致）
        .refreshable { await vm.loadInstances() }
    }

    private func actionItems(_ instance: VllmInstance) -> [ActionMenuItem] {
        var items: [ActionMenuItem] = []
        let op = instance.isRunning ? "stop" : "start"
        items.append(ActionMenuItem(
            title: instance.isRunning ? L10n.t("停止") : L10n.t("启动"),
            icon: instance.isRunning ? "stop.fill" : "play.fill",
            color: instance.isRunning ? .orange : .green
        ) {
            pendingOperate = (instance, op)
        })
        items.append(ActionMenuItem(
            title: L10n.t("重启"), icon: "arrow.triangle.2.circlepath", color: .blue
        ) {
            pendingOperate = (instance, "restart")
        })
        items.append(ActionMenuItem(
            title: L10n.t("日志"), icon: "doc.text", color: .indigo
        ) {
            logInstance = instance
        })
        items.append(ActionMenuItem(
            title: L10n.t("编辑"), icon: "pencil", color: .teal
        ) {
            editInstance = instance
        })
        items.append(ActionMenuItem(
            title: L10n.t("删除"), icon: "trash", color: .red, role: .destructive
        ) {
            forceDeleteInstance = false
            deleteInstance = instance
        })
        return items
    }

    /// compose 文件路径（容器日志用，与智能体/MCP 的日志路径约定一致）
    static func composePath(for instance: VllmInstance) -> String {
        var p = instance.path ?? ""
        if !p.isEmpty, !p.hasSuffix("/") { p += "/" }
        return p + "docker-compose.yml"
    }

    private func operateDisplayName(_ op: String) -> String {
        switch op {
        case "stop": return L10n.t("停止")
        case "start": return L10n.t("启动")
        case "restart": return L10n.t("重启")
        default: return op
        }
    }
}

// MARK: - 实例行

private struct VllmInstanceRow: View {
    let instance: VllmInstance
    let isOperating: Bool

    private var statusColor: Color {
        switch (instance.status ?? "").lowercased() {
        case "running": return .statusRunning
        case "stopped", "exited": return .secondary
        case "error", "failed", "unusual": return .statusError
        default: return instance.isTransitioning ? .blue : .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "bolt.horizontal.circle", color: .mint)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(instance.displayName)
                        .font(.body.bold())
                        .lineLimit(1)
                    if isOperating {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
                HStack(spacing: 6) {
                    StatusBadge(text: instance.typeDisplay, color: .indigo)
                    Text(instance.appVersion ?? "-")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let message = instance.message, !message.isEmpty {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(statusColor == .statusError ? .red : .secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if let status = instance.status, !status.isEmpty {
                    StatusBadge(text: status, color: statusColor)
                }
                if let port = instance.port {
                    Text(":\(port)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
