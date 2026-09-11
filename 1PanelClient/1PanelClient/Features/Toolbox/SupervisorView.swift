//
//  SupervisorView.swift
//  1PanelClient
//
//  进程守护 Supervisor：三态（未安装 → 脚本库；未初始化 → 初始化表单；正常 → 服务卡+进程列表）/
//  进程长按菜单（重启/日志/源文/编辑/删除）；设置入口（配置修改/服务日志/初始化）
//  接口见 logs/进程守护.md 抓包（/api/v2/hosts/tool/*）
//

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class SupervisorViewModel: ObservableObject {
    @Published var status: SupervisorStatus?
    @Published var isLoading = true
    @Published var isOperating = false
    @Published var errorMessage: String?

    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var toastMessage: String?
    private var toastTask: Task<Void, Never>?

    // 进程列表
    @Published var processes: [SupervisorProcessItem] = []
    @Published private(set) var isLoadingProcesses = false

    /// 删除确认
    @Published var pendingDeleteProcess: SupervisorProcessItem?

    private(set) var client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient.shared(for: server)
    }

    var config: SupervisorConfig? { status?.config }
    var isInstalled: Bool { config?.isExist ?? false }
    /// true = 已安装但未初始化
    var needsInit: Bool { isInstalled && (config?.needsInitialization ?? false) }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        await loadStatus()
        await loadProcesses()
    }

    func loadStatus() async {
        do {
            status = try await client.send(
                path: APIEndpoint.supervisorStatus.path,
                body: SupervisorToolRequest(type: "supervisord"),
                as: SupervisorStatus.self)
            errorMessage = nil
        } catch {
            // 页面退出取消不是失败：保留原状态
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// 已初始化后才拉取进程列表
    func loadProcesses() async {
        guard !needsInit else {
            processes = []
            return
        }
        isLoadingProcesses = true
        defer { isLoadingProcesses = false }
        do {
            processes = try await client.send(
                path: APIEndpoint.supervisorProcessList.path,
                method: "GET",
                as: [SupervisorProcessItem].self)
        } catch {
            guard !APIError.isCancellation(error) else { return }
            // 基础状态已可展示：列表失败降级为空列表 + 提示
            processes = []
            errorMessage = error.localizedDescription
        }
    }

    /// Supervisor 服务启停（stop/start/restart）
    func operateService(_ operation: String) async {
        isOperating = true
        errorMessage = nil
        defer { isOperating = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.supervisorServiceOperate.path,
                body: SupervisorServiceOperateRequest(type: "supervisord", operate: operation),
                as: EmptyResponse.self)
            showToast(L10n.t("操作成功"))
            await loadStatus()
        } catch {
            showAlert(message: L10n.f("操作失败：%@", error.localizedDescription))
        }
    }

    /// 初始化（修改 [include] 并重启服务）
    @discardableResult
    func initialize(configPath: String, serviceName: String) async -> Bool {
        isOperating = true
        defer { isOperating = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.supervisorInit.path,
                body: SupervisorInitRequest(type: "supervisord", configPath: configPath, serviceName: serviceName),
                as: EmptyResponse.self)
            showToast(L10n.t("初始化完成"))
            await load()
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("初始化失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("初始化失败：%@", error.localizedDescription))
            return false
        }
    }

    @discardableResult
    func createProcess(req: SupervisorProcessRequest) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.supervisorProcess.path, body: req, as: EmptyResponse.self)
            showToast(L10n.f("进程「%@」已创建", req.name))
            await loadProcesses()
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("创建失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("创建失败：%@", error.localizedDescription))
            return false
        }
    }

    @discardableResult
    func updateProcess(req: SupervisorProcessRequest) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.supervisorProcess.path, body: req, as: EmptyResponse.self)
            showToast(L10n.f("进程「%@」已更新", req.name))
            await loadProcesses()
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("更新失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("更新失败：%@", error.localizedDescription))
            return false
        }
    }

    func restartProcess(_ process: SupervisorProcessItem) async {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.supervisorProcess.path,
                body: SupervisorProcessRequest(operate: "restart", name: process.name),
                as: EmptyResponse.self)
            showToast(L10n.f("进程「%@」已重启", process.name))
            await loadProcesses()
        } catch let err as APIError {
            showAlert(message: L10n.f("重启失败：%@", err.errorDescription ?? L10n.t("未知错误")))
        } catch {
            showAlert(message: L10n.f("重启失败：%@", error.localizedDescription))
        }
    }

    func deleteProcess(_ process: SupervisorProcessItem) async {
        pendingDeleteProcess = nil
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.supervisorProcess.path,
                body: SupervisorProcessRequest(operate: "delete", name: process.name),
                as: EmptyResponse.self)
            showToast(L10n.f("进程「%@」已删除", process.name))
            await loadProcesses()
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

// MARK: - 主视图

struct SupervisorView: View {
    @StateObject private var vm: SupervisorViewModel

    private let server: ServerConfig

    @State private var isServiceExpanded = false
    @State private var pendingAction: String?
    @State private var showCreate = false
    @State private var showMenu = false
    @State private var showSettings = false
    /// 长按弹出的操作菜单目标（重启 / 日志 / 源文 / 编辑 / 删除）
    @State private var actionProcess: SupervisorProcessItem?
    /// 行「编辑」推入的表单目标
    @State private var editingProcess: SupervisorProcessItem?
    /// 行「日志」推入的日志页目标
    @State private var logProcess: SupervisorProcessItem?
    /// 行「源文」推入的源文编辑页目标
    @State private var fileProcess: SupervisorProcessItem?

    init(server: ServerConfig) {
        self.server = server
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(key: ManageItem.supervisor.storeKey(server: server)) {
            SupervisorViewModel(server: server)
        })
    }

    var body: some View {
        alertAndDestinations
    }

    /// 状态四分支（加载 / 未安装 / 未初始化 / 正常）
    @ViewBuilder
    private var rootContent: some View {
        if vm.isLoading && vm.status == nil {
            LoadingStateView()
        } else if let config = vm.config {
            if !(config.isExist ?? false) {
                notInstalledView
            } else if vm.needsInit {
                // 已安装未初始化：整页初始化表单
                SupervisorInitForm(vm: vm)
            } else {
                content(config: config)
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

    /// 基础修饰（标题 / 工具栏 / 刷新 / 轻提示）
    private var baseModifiers: some View {
        rootContent
            .navigationTitle(L10n.t("进程守护"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 未安装/未初始化时不显示设置与添加入口
                if vm.isInstalled && !vm.needsInit {
                    ToolbarItem(placement: .topBarTrailing) {
                        EllipsisMenuButton {
                            withAnimation(Motion.fast) { showMenu.toggle() }
                        }
                        .accessibilityLabel(L10n.t("更多操作"))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showCreate = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(L10n.t("添加进程"))
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if showMenu {
                    EllipsisMenuPopup(entries: [
                        .action(title: L10n.t("配置修改"), icon: "slider.horizontal.3") {
                            showSettings = true
                        },
                    ]) {
                        withAnimation(Motion.fast) { showMenu = false }
                    }
                }
            }
            .refreshable { await vm.load() }
            .task { await PageVMStore.shared.autoRefresh(vm: vm) { await vm.load() } }
            .toastOverlay(message: $vm.toastMessage)
    }

    /// 确认弹窗与推页目标
    private var alertAndDestinations: some View {
        baseModifiers
            .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
                Button(L10n.t("好的"), role: .cancel) {}
            } message: {
                Text(vm.alertMessage)
            }
        .alert(
            pendingAction.map { supervisorActionDisplayName($0) } ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            )
        ) {
            Button(L10n.t("取消"), role: .cancel) { pendingAction = nil }
            Button(L10n.t("确认"), role: .destructive) {
                Haptic.warning()
                let op = pendingAction
                pendingAction = nil
                if let op { Task { await vm.operateService(op) } }
            }
        } message: {
            if let action = pendingAction {
                Text(L10n.f("将对 Supervisor 进行 %@ 操作，是否继续？", supervisorActionDisplayName(action)))
            }
        }
        .alert(L10n.t("删除进程"), isPresented: Binding(
            get: { vm.pendingDeleteProcess != nil },
            set: { if !$0 { vm.pendingDeleteProcess = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { vm.pendingDeleteProcess = nil }
            Button(L10n.t("删除"), role: .destructive) {
                Haptic.warning()
                if let process = vm.pendingDeleteProcess {
                    Task { await vm.deleteProcess(process) }
                }
            }
        } message: {
            Text(L10n.f("确定删除进程「%@」吗？删除后其配置文件将被移除，此操作不可恢复。", vm.pendingDeleteProcess?.name ?? ""))
        }
        .navigationDestination(isPresented: $showCreate) {
            SupervisorProcessFormView(server: server, editing: nil, vm: vm)
        }
        .navigationDestination(isPresented: $showSettings) {
            SupervisorSettingsView(server: server, vm: vm)
        }
        .navigationDestination(isPresented: Binding(
            get: { editingProcess != nil },
            set: { if !$0 { editingProcess = nil } }
        )) {
            if let process = editingProcess {
                SupervisorProcessFormView(server: server, editing: process, vm: vm)
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { logProcess != nil },
            set: { if !$0 { logProcess = nil } }
        )) {
            if let process = logProcess {
                SupervisorProcessLogView(server: server, processName: process.name)
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { fileProcess != nil },
            set: { if !$0 { fileProcess = nil } }
        )) {
            if let process = fileProcess {
                SupervisorProcessFileView(server: server, processName: process.name)
            }
        }
    }

    private func supervisorActionDisplayName(_ action: String) -> String {
        switch action {
        case "stop":    return L10n.t("停止")
        case "start":   return L10n.t("启动")
        case "restart": return L10n.t("重启")
        default:        return action
        }
    }

    // MARK: - 未安装

    /// 未安装：与 FTP 未安装页同款样式，安装入口跳脚本库
    private var notInstalledView: some View {
        VStack(spacing: 20) {
            Spacer()

            IconBadge(systemName: "gearshape.2.fill", color: .blue, size: 72, cornerRadius: 16)
                .opacity(0.5)

            VStack(spacing: 8) {
                Text(L10n.f("%@未安装", "Supervisor"))
                    .font(.headline)
                Text(L10n.f("请先安装 %@ 后再使用此功能", "Supervisor"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            NavigationLink {
                ScriptLibraryView(server: server)
            } label: {
                Label(L10n.f("安装 %@", "Supervisor"), systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)

            Spacer()
        }
        .padding()
    }

    // MARK: - 已初始化

    @ViewBuilder
    private func content(config: SupervisorConfig) -> some View {
        List {
            ServiceStatusCard(
                title: "Supervisor",
                subtitle: config.version.flatMap { $0.isEmpty ? nil : "v\($0)" },
                statusText: (config.status == "running") ? L10n.t("运行中") : L10n.t("已停止"),
                statusColor: (config.status == "running") ? .statusRunning : .statusStopped,
                isOperating: vm.isOperating,
                isExpanded: $isServiceExpanded,
                actions: [
                    ServiceAction(
                        title: (config.status == "running") ? L10n.t("停止") : L10n.t("启动"),
                        icon: (config.status == "running") ? "stop.fill" : "play.fill",
                        color: (config.status == "running") ? .orange : .green
                    ) { pendingAction = (config.status == "running") ? "stop" : "start" },
                    ServiceAction(title: L10n.t("重启"), icon: "arrow.triangle.2.circlepath", color: .blue) {
                        pendingAction = "restart"
                    },
                ]
            ) {
                IconBadge(systemName: "gearshape.2.fill", color: .blue, size: 44)
            }

            processSection
        }
        .listStyle(.insetGrouped)
        .sheet(item: $actionProcess) { process in
            ActionBottomSheet(
                title: process.name,
                items: [
                    ActionMenuItem(title: L10n.t("重启"), icon: "arrow.triangle.2.circlepath", color: .blue) {
                        Task { await vm.restartProcess(process) }
                    },
                    ActionMenuItem(title: L10n.t("日志"), icon: "doc.text.magnifyingglass") {
                        logProcess = process
                    },
                    ActionMenuItem(title: L10n.t("源文件"), icon: "doc.text") {
                        fileProcess = process
                    },
                    ActionMenuItem(title: L10n.t("编辑"), icon: "pencil") {
                        editingProcess = process
                    },
                    ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red, role: .destructive) {
                        vm.pendingDeleteProcess = process
                    },
                ],
                onDismiss: { actionProcess = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: 5))])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var processSection: some View {
        Section {
            if vm.processes.isEmpty {
                if vm.isLoadingProcesses || vm.isLoading {
                    HStack {
                        Spacer()
                        LoadingStateView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ContentUnavailableView(
                        L10n.t("暂无进程"),
                        systemImage: "gearshape.2",
                        description: Text(L10n.t("点击右上角 + 添加进程"))
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(vm.processes) { process in
                    Button {
                        editingProcess = process
                    } label: {
                        SupervisorProcessRow(process: process)
                    }
                    .buttonStyle(.plain)
                    // 行级操作收进长按菜单；simultaneousGesture 与点击进入共存
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                            Haptic.selection()
                            actionProcess = process
                        }
                    )
                }
            }
        } header: {
            SectionLabel(title: L10n.t("守护进程"), systemImage: "square.stack.3d.up")
        }
    }
}

// MARK: - 进程行

struct SupervisorProcessRow: View {
    let process: SupervisorProcessItem

    private var stateColor: Color {
        switch process.primaryState?.status {
        case "RUNNING": return .statusRunning
        case "BACKOFF", "STARTING": return .semanticWarning
        case "FATAL", "EXITED": return .statusError
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "gearshape.fill", color: .blue)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(process.name)
                        .font(.body.bold())
                        .lineLimit(1)
                    if let state = process.primaryState?.status, !state.isEmpty {
                        StatusBadge(text: state, color: stateColor, monospaced: true)
                    }
                }
                Text(process.command ?? "—")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let user = process.user, !user.isEmpty {
                        Text(user)
                    }
                    if let dir = process.dir, !dir.isEmpty {
                        Text(dir)
                            .lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if let pid = process.primaryState?.pid, !pid.isEmpty {
                    StatusBadge(text: "PID \(pid)", color: .secondary, monospaced: true)
                }
                if let uptime = process.primaryState?.uptime, !uptime.isEmpty {
                    Text(uptime)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - 初始化表单（未初始化整页 / 设置页复用）

/// 初始化：修改主配置 [include] 由面板接管进程配置目录，提交前需输入「立即重启」确认
struct SupervisorInitForm: View {
    @ObservedObject var vm: SupervisorViewModel

    @State private var configPath = ""
    @State private var serviceName = ""
    @State private var showConfirm = false
    @State private var isSubmitting = false
    @State private var didFill = false

    private var canSubmit: Bool {
        !configPath.isEmpty && configPath.hasPrefix("/") && !serviceName.isEmpty && !isSubmitting
    }

    var body: some View {
        Form {
            Section {
                TextField(L10n.t("主配置文件位置"), text: $configPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(L10n.t("服务名称"), text: $serviceName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                SectionLabel(title: L10n.t("初始化"), systemImage: "wand.and.stars")
            } footer: {
                Text(L10n.t("初始化操作需要修改配置文件的 [include] files 参数，修改后的服务配置文件所在目录为 1Panel 安装目录下 1panel/tools/supervisord/supervisor.d/"))
            }

            Section {
                Label(L10n.t("初始化会重启服务，导致原有的守护进程全部关闭"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
        }
        .navigationTitle(L10n.t("初始化"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showConfirm = true
                } label: {
                    if isSubmitting { ProgressView() } else { Text(L10n.t("初始化")).bold() }
                }
                .disabled(!canSubmit)
            }
        }
        .onAppear {
            guard !didFill else { return }
            didFill = true
            configPath = vm.config?.configPath ?? "/etc/supervisor/supervisord.conf"
            serviceName = vm.config?.serviceName ?? "supervisor"
        }
        .sheet(isPresented: $showConfirm) {
            TextInputConfirmSheet(
                title: L10n.t("初始化"),
                message: L10n.t("初始化会重启服务，导致原有的守护进程全部关闭。如果确认操作，请手动输入「立即重启」。"),
                expectedText: L10n.t("立即重启"),
                fieldLabel: L10n.t("确认名称"),
                fieldPlaceholder: L10n.t("立即重启")
            ) {
                Task { await submit() }
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        if await vm.initialize(configPath: configPath, serviceName: serviceName) {
            // 初始化成功后主页切到正常态，无需留在本页
        }
    }
}
