//
//  ContainersTab.swift
//  1PanelClient
//

import SwiftUI
import Combine
import Charts

struct ContainersTab: View {
    @ObservedObject var manager: ServerManager
    @StateObject private var vm: ContainersViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var showImages = false
    @State private var showCreate = false

    /// 是否显示关闭按钮（fullScreen 模式用 true，作为分段/嵌入内容时用 false）
    var showCloseButton: Bool = true
    /// true=自带 NavigationStack（独立/fullScreen 用）；false=仅提供内容（嵌入外层栈）
    var standalone: Bool = true

    init(manager: ServerManager, showCloseButton: Bool = true, standalone: Bool = true) {
        self.manager = manager
        self.showCloseButton = showCloseButton
        self.standalone = standalone
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: ContainersViewModel(server: server))
    }

    var body: some View {
        Group {
            if standalone {
                NavigationStack {
                    rootContent
                }
            } else {
                rootContent
            }
        }
        .task { await vm.refresh() }
    }

    /// 列表根内容（不含 NavigationStack），供 ManageTab 嵌入复用
    var rootContent: some View {
        Group {
            if vm.isLoading && vm.containers.isEmpty {
                ProgressView("加载中…")
            } else if vm.containers.isEmpty && vm.dockerStatus == nil {
                ContentUnavailableView(
                    "暂无容器",
                    systemImage: "shippingbox",
                    description: Text(vm.errorMessage ?? "这台服务器上没有容器")
                )
            } else {
                containerList
            }
        }
        .searchIconMode(
            text: $searchText,
            isSearching: $isSearching,
            title: "容器",
            prompt: "搜索容器名",
            showCloseButton: showCloseButton,
            onClose: { dismiss() }
        )
        .alert("提示", isPresented: $vm.showAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .overlay(alignment: .bottomTrailing) {
            FloatingActionButton(action: {
                showCreate = true
            })
            .accessibilityLabel("创建容器")
        }
        .onChange(of: searchText) { _, newValue in
            Task { await vm.search(query: newValue) }
        }
        .navigationDestination(for: Container.self) { c in
            ContainerDetailView(container: c, server: manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""), vm: vm)
        }
        .navigationDestination(isPresented: $showCreate) {
            ContainerCreateView(vm: vm)
        }
        .navigationDestination(isPresented: $showImages) {
            ContainerImageView(vm: vm)
        }
    }

    private var containerList: some View {
        List {
            // 顶部 Docker 服务状态卡片
            DockerStatusCard(vm: vm) {
                showImages = true
            }

            if vm.containers.isEmpty {
                Section {
                    Text(vm.errorMessage ?? "这台服务器上没有容器")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(vm.containers) { c in
                        NavigationLink(value: c) {
                            ContainerRow(container: c)
                        }
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

// MARK: - Docker 服务状态卡片

struct DockerStatusCard: View {
    @ObservedObject var vm: ContainersViewModel
    var onShowImages: () -> Void = {}
    @State private var isExpanded = false
    @State private var pendingAction: String?

    var body: some View {
        Section {
            if vm.isLoadingDocker && vm.dockerStatus == nil {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("加载 Docker 状态…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if let status = vm.dockerStatus {
                headerRow(status)
                if isExpanded { actionsRow }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Docker 未安装或加载失败")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let msg = vm.dockerErrorMessage, !msg.isEmpty {
                        Text(msg)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(3)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .alert(
            pendingAction.map { actionDisplayName($0) } ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingAction = nil }
            Button("确认", role: .destructive) { executePendingAction() }
        } message: {
            if let action = pendingAction {
                Text("将对 Docker 进行 \(actionDisplayName(action)) 操作，是否继续？")
            }
        }
    }

    private func actionDisplayName(_ action: String) -> String {
        switch action {
        case "stop":   return "停止"
        case "start":  return "启动"
        case "restart":return "重启"
        case "prune":  return "清理容器"
        default:       return action
        }
    }

    private func executePendingAction() {
        let action = pendingAction
        pendingAction = nil
        guard let action else { return }
        Task {
            if action == "prune" {
                await vm.pruneContainers()
            } else {
                await vm.operateDocker(operation: action)
            }
        }
    }

    private var isRunning: Bool { vm.dockerStatus?.isActive == true }

    @ViewBuilder
    private func headerRow(_ status: DockerStatus) -> some View {
        HStack(spacing: 12) {
            // Docker 使用内置品牌图标
            BrandIcon(brand: .docker, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text("Docker")
                    .font(.body.bold())
                Text(status.isActive == true ? "运行中" : "已停止")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                StatusDot(color: isRunning ? .green : .gray)
                Text(status.isExist == false ? "未安装" : (isRunning ? "运行中" : "已停止"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(vm.dockerOperating)
        }
        .padding(.vertical, 2)
    }

    private var actionsRow: some View {
        HStack(spacing: 8) {
            actionButton(
                title: isRunning ? "停止" : "启动",
                icon: isRunning ? "stop.fill" : "play.fill",
                color: isRunning ? .orange : .green
            ) {
                pendingAction = isRunning ? "stop" : "start"
            }
            actionButton(
                title: "重启",
                icon: "arrow.triangle.2.circlepath",
                color: .blue
            ) {
                pendingAction = "restart"
            }
            actionButton(
                title: "清理容器",
                icon: "trash",
                color: .pink
            ) {
                pendingAction = "prune"
            }
            actionButton(
                title: "镜像",
                icon: "square.stack.3d.up",
                color: .teal
            ) {
                Task {
                    await vm.loadImages()
                    onShowImages()
                }
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func actionButton(
        title: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if vm.dockerOperating {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(color)
                        .frame(width: 22, height: 22)
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(vm.dockerOperating)
    }
}

// MARK: - 容器列表项（增强）

struct ContainerRow: View {
    let container: Container

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 名称 + 运行时长
            HStack(spacing: 8) {
                Text(container.displayName)
                    .font(.body.bold())
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let runTime = container.runTime, !runTime.isEmpty {
                    Text(runTime)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // 镜像名
            if let img = container.imageName, !img.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 10))
                    Text(img)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // 端口映射（单行，逗号分隔）
            if let ports = container.ports, !ports.isEmpty {
                Text(ports.joined(separator: ", "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // CPU 使用率（靠左，状态徽标已移除）
            HStack(spacing: 2) {
                Image(systemName: "cpu")
                    .font(.caption2)
                Text(container.cpuDisplay)
                    .font(.caption2.monospacedDigit())
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 容器详情页

struct ContainerDetailView: View {
    let container: Container
    let server: ServerConfig
    @ObservedObject var vm: ContainersViewModel
    @State private var showMenuAlert = false
    @State private var menuAlertMessage = ""
    @State private var showUpgrade = false
    @State private var showEdit = false
    @State private var showTerminal = false
    @State private var showTerminalCommandPicker = false
    @State private var terminalCommand = "/bin/sh"
    @State private var pendingDelete = false
    @State private var pendingAction: String?
    @State private var isStatusExpanded = false

    private var isRunning: Bool { container.state.lowercased() == "running" }

    var body: some View {
        List {
            statusSection

            Section("基本信息") {
                if let img = container.imageName, !img.isEmpty {
                    InfoRow("镜像", value: img)
                }
                if let app = container.appName, !app.isEmpty {
                    InfoRow("应用程序", value: app)
                }
                if let sites = container.websites, !sites.isEmpty {
                    InfoRow("网站", value: sites.joined(separator: "\n"))
                }
                if let ports = container.ports, !ports.isEmpty {
                    InfoRow("端口映射", value: ports.joined(separator: "\n"))
                }
                InfoRow("运行时长", value: container.runTime ?? "—")
                if let created = container.createTime, !created.isEmpty {
                    InfoRow("创建时间", value: String(created.prefix(19)))
                }
            }

            Section {
                NavigationLink {
                    ContainerLogView(container: container, vm: vm)
                } label: {
                    Label("日志", systemImage: "doc.text")
                }
                .buttonStyle(.plain)
                NavigationLink {
                    ContainerMonitorView(container: container)
                } label: {
                    Label("监控", systemImage: "chart.xyaxis.line")
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(container.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showUpgrade) {
            ContainerUpgradeView(container: container, vm: vm)
        }
        .navigationDestination(isPresented: $showEdit) {
            ContainerEditView(container: container, vm: vm)
        }
        .navigationDestination(isPresented: $showTerminal) {
            TerminalView(
                server: server,
                target: .container(
                    containerID: container.containerID,
                    user: "",
                    command: terminalCommand,
                    cols: 80,
                    rows: 24
                ),
                title: container.displayName
            )
        }
        .sheet(isPresented: $showTerminalCommandPicker) {
            TerminalCommandPicker(command: $terminalCommand) {
                showTerminalCommandPicker = false
                showTerminal = true
            }
        }
        .alert("提示", isPresented: $showMenuAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(menuAlertMessage)
        }
        .alert("删除容器", isPresented: $pendingDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task { await vm.operateContainer(name: container.name, operation: "remove") }
            }
        } message: {
            Text("确定删除容器「\(container.displayName)」吗？删除后不可恢复。")
        }
        .alert(
            pendingAction.map { containerActionDisplayName($0) } ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingAction = nil }
            Button("确认", role: .destructive) { executeContainerAction() }
        } message: {
            if let action = pendingAction {
                Text("将对容器进行 \(containerActionDisplayName(action)) 操作，是否继续？")
            }
        }
        .alert("提示", isPresented: $vm.showAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
    }

    // MARK: - 可折叠状态面板

    private var statusSection: some View {
        Section {
            headerRow

            if isStatusExpanded {
                operationsRow1
                    .padding(.top, 4)
                operationsRow2
                    .padding(.top, 4)
                    .padding(.bottom, 2)
            }
        }
    }

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "shippingbox.fill", color: .indigo)

            VStack(alignment: .leading, spacing: 3) {
                Text(container.displayName)
                    .font(.body.bold())
                    .lineLimit(1)
                Text(isRunning ? "运行中" : "已停止")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                StatusDot(color: isRunning ? .green : .gray)
                Text(isRunning ? "运行中" : "已停止")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isStatusExpanded.toggle()
                }
            } label: {
                Image(systemName: isStatusExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(vm.containerOperating)
        }
        .padding(.vertical, 2)
    }

    private var operationsRow1: some View {
        HStack(spacing: 8) {
            actionButton(
                title: isRunning ? "停止" : "启动",
                icon: isRunning ? "stop.fill" : "play.fill",
                color: isRunning ? .orange : .green
            ) {
                pendingAction = isRunning ? "stop" : "start"
            }
            actionButton(
                title: "重启",
                icon: "arrow.triangle.2.circlepath",
                color: .blue
            ) {
                pendingAction = "restart"
            }
            actionButton(
                title: "关闭",
                icon: "xmark",
                color: .red
            ) {
                pendingAction = "kill"
            }
            actionButton(
                title: "终端",
                icon: "terminal",
                color: .teal
            ) {
                showTerminalCommandPicker = true
            }
        }
    }

    private var operationsRow2: some View {
        HStack(spacing: 8) {
            actionButton(
                title: "升级",
                icon: "arrow.up.circle",
                color: .purple
            ) {
                showUpgrade = true
            }
            actionButton(
                title: "编辑",
                icon: "pencil",
                color: .cyan
            ) {
                showEdit = true
            }
            actionButton(
                title: "删除",
                icon: "trash",
                color: .pink
            ) {
                if container.isFromApp == true {
                    menuAlertMessage = "该容器由应用程序创建，无法直接删除。请进入「应用」删除对应应用，容器会随之移除。"
                    showMenuAlert = true
                } else {
                    pendingDelete = true
                }
            }
        }
    }

    @ViewBuilder
    private func actionButton(
        title: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if vm.containerOperating {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(color)
                        .frame(width: 22, height: 22)
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(vm.containerOperating)
    }

    private func containerActionDisplayName(_ action: String) -> String {
        switch action {
        case "stop":    return "停止"
        case "start":   return "启动"
        case "restart": return "重启"
        case "kill":    return "关闭"
        default:        return action
        }
    }

    private func executeContainerAction() {
        let action = pendingAction
        pendingAction = nil
        guard let action else { return }
        Task { await vm.operateContainer(name: container.name, operation: action) }
    }
}

/// 容器日志占位页（接口未提供，待开发）
struct ContainerLogView: View {
    let container: Container
    @ObservedObject var vm: ContainersViewModel
    @State private var lines: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if isLoading && lines.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("加载日志…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(idx)
                    }
                    if let errorMessage, lines.isEmpty {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Color(.secondarySystemBackground))
            // 进入页面即定位到底部（最新日志），内容增长时保持贴底
            .defaultScrollAnchor(.bottom)
            .navigationTitle("日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadLogs() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onChange(of: lines.count) { _, count in
                // 兜底追底；不用动画，日志突发时连续动画滚动会被合并打断
                guard count > 0 else { return }
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
        .task {
            await loadLogs()
        }
    }

    private func loadLogs() async {
        isLoading = true
        errorMessage = nil
        lines = []
        do {
            isLoading = false
            for try await line in vm.streamLogs(container: container.name) {
                lines.append(line)
                if lines.count > 2000 {
                    lines.removeFirst(lines.count - 2000)
                }
            }
        } catch {
            isLoading = false
            if lines.isEmpty {
                errorMessage = "加载日志失败：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: - 容器监控页

/// 单容器实时监控：按所选间隔轮询 /containers/stats/:id，
/// CPU / 内存(含缓存) / 磁盘I/O / 网络 四张曲线图（仅标题+图表）
@MainActor
final class ContainerMonitorViewModel: ObservableObject {
    @Published var cpuPoints: [MonitorPoint] = []      // CPU %
    @Published var memPoints: [MonitorPoint] = []      // 内存 MB
    @Published var cachePoints: [MonitorPoint] = []    // 缓存 MB
    @Published var ioReadPoints: [MonitorPoint] = []   // 读取 MB/s
    @Published var ioWritePoints: [MonitorPoint] = []  // 写入 MB/s
    @Published var netTXPoints: [MonitorPoint] = []    // 上行 KB/s
    @Published var netRXPoints: [MonitorPoint] = []    // 下行 KB/s
    @Published var errorMessage: String?

    /// 每系列最多保留采样点数（与网页端一致保留 20 个）
    private let maxPoints = 20
    private let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    /// 拉取一次快照并追加到各曲线
    func sample(containerID: String) async {
        let path = APIEndpoint.containersStats.path
            .replacingOccurrences(of: ":containerID", with: containerID)
        do {
            let stats: ContainerStatsSnapshot = try await client.send(
                path: path, method: APIEndpoint.containersStats.method, as: ContainerStatsSnapshot.self
            )
            errorMessage = nil
            guard let date = MonitorDate.parse(stats.shotTime ?? "") else { return }
            push(.init(date: date, value: stats.cpuPercent ?? 0), into: &cpuPoints)
            push(.init(date: date, value: stats.memory ?? 0), into: &memPoints)
            push(.init(date: date, value: stats.cache ?? 0), into: &cachePoints)
            push(.init(date: date, value: stats.ioRead ?? 0), into: &ioReadPoints)
            push(.init(date: date, value: stats.ioWrite ?? 0), into: &ioWritePoints)
            push(.init(date: date, value: stats.networkTX ?? 0), into: &netTXPoints)
            push(.init(date: date, value: stats.networkRX ?? 0), into: &netRXPoints)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func push(_ point: MonitorPoint, into points: inout [MonitorPoint]) {
        points.append(point)
        if points.count > maxPoints {
            points.removeFirst(points.count - maxPoints)
        }
    }
}

struct ContainerMonitorView: View {
    let container: Container
    @StateObject private var vm: ContainerMonitorViewModel
    /// 刷新间隔（秒），默认 5s
    @State private var interval = 5
    @Environment(\.scenePhase) private var scenePhase
    @State private var isSceneActive = true

    init(container: Container) {
        self.container = container
        _vm = StateObject(wrappedValue: ContainerMonitorViewModel(
            server: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        ))
    }

    var body: some View {
        List {
            Section {
                Picker("刷新间隔", selection: $interval) {
                    Text("3s").tag(3)
                    Text("5s").tag(5)
                    Text("10s").tag(10)
                    Text("30s").tag(30)
                    Text("60s").tag(60)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
            }

            if let err = vm.errorMessage, vm.cpuPoints.isEmpty {
                Section {
                    ContentUnavailableView(
                        "获取监控数据失败", systemImage: "exclamationmark.triangle", description: Text(err)
                    )
                }
            } else {
                monitorSection("CPU", single: vm.cpuPoints, color: .blue, unit: "%")
                monitorSection("内存", dual: memorySeries, unit: "MB")
                monitorSection("磁盘 I/O", dual: ioSeries, unit: "MB")
                monitorSection("网络", dual: networkSeries, unit: "KB")
            }
        }
        .environment(\.defaultMinListRowHeight, 32)
        .navigationTitle("监控")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, phase in
            isSceneActive = phase == .active
        }
        // 按所选间隔轮询（仅页面存活且 App 前台活跃时采样）
        .task {
            while !Task.isCancelled {
                if isSceneActive {
                    await vm.sample(containerID: container.containerID)
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    // MARK: 数据系列

    private var memorySeries: [LoadSeriesPoint] {
        vm.memPoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: "内存") }
            + vm.cachePoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: "缓存") }
    }

    private var ioSeries: [LoadSeriesPoint] {
        vm.ioReadPoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: "读取") }
            + vm.ioWritePoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: "写入") }
    }

    private var networkSeries: [LoadSeriesPoint] {
        vm.netTXPoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: "上行") }
            + vm.netRXPoints.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: "下行") }
    }

    // MARK: 图表区（标题 + 图表）

    @ViewBuilder
    private func monitorSection(
        _ title: String,
        single: [MonitorPoint] = [],
        color: Color = .blue,
        dual: [LoadSeriesPoint] = [],
        styles: KeyValuePairs<String, Color> = ["内存": .purple, "缓存": .orange,
                                                "读取": .blue, "写入": .orange,
                                                "上行": .green, "下行": .purple],
        unit: String
    ) -> some View {
        Section {
            HStack {
                Text(title).font(.headline)
                Spacer()
            }
            .padding(.top, 8)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

            Group {
                if !dual.isEmpty {
                    ContainerMonitorChart(points: dual, styles: styles, unit: unit)
                } else if !single.isEmpty {
                    // 单曲线（CPU）：系列名固定 "CPU"，图例隐藏
                    ContainerMonitorChart(
                        points: single.map { LoadSeriesPoint(date: $0.date, value: $0.value, kind: "CPU") },
                        styles: ["CPU": color],
                        unit: unit
                    )
                } else {
                    chartPlaceholder
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 8)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        }
    }

    private var chartPlaceholder: some View {
        Text("暂无数据")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 120)
    }
}

// MARK: - 可拖动查看数值的监控图表

/// 折线图 + 拖动浮层：按住图表横向滑动显示竖排数值（按值降序，颜色与曲线一致），
/// 交互与管理 - 监控的磁盘 I/O / 网络图表相同
struct ContainerMonitorChart: View {
    let points: [LoadSeriesPoint]
    let styles: KeyValuePairs<String, Color>
    let unit: String

    @State private var selectedDate: Date?

    var body: some View {
        let seriesCounts = Dictionary(grouping: points, by: \.kind).mapValues(\.count)
        return Chart(points) { p in
            LineMark(x: .value("时间", p.date), y: .value("值", p.value))
                .foregroundStyle(by: .value("类型", p.kind))
            // 数据点过少时折线画不出来，补圆点让单点也可见
            if (seriesCounts[p.kind] ?? 0) <= 2 {
                PointMark(x: .value("时间", p.date), y: .value("值", p.value))
                    .foregroundStyle(by: .value("类型", p.kind))
                    .symbolSize(30)
            }
            if let sel = selectedDate {
                RuleMark(x: .value("选中", sel))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartForegroundStyleScale(styles)
        .chartLegend(styles.count > 1 ? .visible : .hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Self.axisText(v, unit: unit))
                    }
                }
            }
        }
        .frame(height: 120)
        .chartOverlay { proxy in
            GeometryReader { geo in
                // 手势层：触摸 x → 日期
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                guard let plotAnchor = proxy.plotFrame else { return }
                                let plotFrame = geo[plotAnchor]
                                let x = gesture.location.x - plotFrame.minX
                                guard x >= 0, x <= plotFrame.width,
                                      let date: Date = proxy.value(atX: x) else { return }
                                selectedDate = clampDate(date)
                            }
                            .onEnded { _ in selectedDate = nil }
                    )

                // 选中浮层：竖排显示各系列数值（值大的在最上面），颜色与曲线一致
                if let sel = selectedDate {
                    let entries = sortedEntries(at: sel)
                    let x = proxy.position(forX: sel) ?? 0
                    // 靠右边缘时翻转到左侧
                    let flip = x + 128 > geo.size.width
                    tooltip(entries)
                        .offset(x: flip ? x - 128 : x + 12, y: 10)
                }
            }
        }
    }

    /// 选中时间的各系列数值（按值降序，返回已格式化文本）
    private func sortedEntries(at date: Date) -> [(title: String, text: String, color: Color)] {
        var raw: [(String, Double, Color)] = []
        for (kind, color) in styles {
            raw.append((kind, nearestValue(to: date, kind: kind) ?? 0, color))
        }
        return raw.sorted { $0.1 > $1.1 }
            .map { ($0.0, String(format: "%.2f%@", $0.1, unit), $0.2) }
    }

    /// 图内数值浮层（竖排，颜色与曲线一致）
    private func tooltip(_ entries: [(title: String, text: String, color: Color)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(entries, id: \.title) { entry in
                HStack(spacing: 5) {
                    StatusDot(color: entry.color)
                    Text(entry.title).foregroundStyle(entry.color)
                    Spacer(minLength: 4)
                    Text(entry.text).monospacedDigit().foregroundStyle(entry.color)
                }
            }
        }
        .font(.caption2)
        .frame(width: 112, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
    }

    /// 距目标时间最近的指定系列数值
    private func nearestValue(to date: Date, kind: String) -> Double? {
        points.filter { $0.kind == kind }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?
            .value
    }

    /// 把手势日期限制在数据时间范围内
    private func clampDate(_ date: Date) -> Date {
        guard let first = points.map(\.date).min(),
              let last = points.map(\.date).max() else { return date }
        return min(max(date, first), last)
    }

    /// Y 轴刻度文本：整数直接拼单位（30KB），小数保留一位（0.5KB）
    private static func axisText(_ value: Double, unit: String) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(value))\(unit)"
        }
        return String(format: "%.1f%@", value, unit)
    }
}

// MARK: - 容器升级页

struct ContainerUpgradeView: View {
    let container: Container
    @ObservedObject var vm: ContainersViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var image: String
    @State private var forcePull = false

    init(container: Container, vm: ContainersViewModel) {
        self.container = container
        self.vm = vm
        _image = State(initialValue: container.imageName ?? "")
    }

    var body: some View {
        Form {
            Section("目标镜像") {
                TextField("镜像名:标签", text: $image)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                if image.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("镜像不能为空")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Toggle("总是拉取镜像（force pull）", isOn: $forcePull)
            } footer: {
                Text("开启后将强制重新拉取镜像，忽略本地缓存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        if vm.containerOperating {
                            ProgressView()
                                .tint(.white)
                        }
                        Text("升级")
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(image.trimmingCharacters(in: .whitespaces).isEmpty || vm.containerOperating)
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle("升级 \(container.name)")
        .navigationBarTitleDisplayMode(.inline)
        .alert("提示", isPresented: $vm.showAlert) {
            Button("好的", role: .cancel) {
                if vm.alertMessage.contains("已提交") {
                    dismiss()
                }
            }
        } message: {
            Text(vm.alertMessage)
        }
    }

    private func submit() async {
        await vm.upgradeContainer(
            name: container.name,
            image: image.trimmingCharacters(in: .whitespaces),
            forcePull: forcePull
        )
    }
}

// MARK: - 容器编辑页

struct ContainerEditView: View {
    let container: Container
    @ObservedObject var vm: ContainersViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var info: ContainerInfo?
    @State private var image: String = ""
    @State private var forcePull = false
    @State private var publishAllPorts = false
    @State private var envs: [String] = []
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        Form {
            if isLoading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("加载容器配置…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
            } else if let loadError {
                Section {
                    Text(loadError)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            } else if let info {
                Section("基础") {
                    HStack {
                        Text("名称")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(info.name)
                            .font(.system(.body, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section {
                    TextField("镜像名:标签", text: $image, axis: .horizontal)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !vm.imageOptions.isEmpty {
                        Menu {
                            ForEach(vm.imageOptions, id: \.self) { opt in
                                Button(opt) { image = opt }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "square.stack.3d.up")
                                Text(image.isEmpty ? "选择镜像" : "选择镜像")
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("镜像")
                } footer: {
                    if image.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("镜像不能为空")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Toggle("强制拉取镜像", isOn: $forcePull)
                    Toggle("暴露所有端口", isOn: $publishAllPorts)
                }

                Section("环境变量") {
                    ForEach(envs.indices, id: \.self) { i in
                        TextField("KEY=VALUE", text: Binding(
                            get: { envs[i] },
                            set: { envs[i] = $0 }
                        ), axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...4)
                    }
                    .onDelete { envs.remove(atOffsets: $0) }

                    Button {
                        envs.append("")
                    } label: {
                        Label("添加环境变量", systemImage: "plus")
                    }
                }
            }
        }
        .navigationTitle("编辑容器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if let info { Task { await submit(info: info) } }
                } label: {
                    if vm.containerOperating {
                        ProgressView()
                    } else {
                        Text("保存").fontWeight(.medium)
                    }
                }
                .disabled(info == nil || image.trimmingCharacters(in: .whitespaces).isEmpty || vm.containerOperating)
            }
        }
        .alert("提示", isPresented: $vm.showAlert) {
            Button("好的", role: .cancel) {
                if vm.alertMessage.contains("已提交") {
                    dismiss()
                }
            }
        } message: {
            Text(vm.alertMessage)
        }
        .task {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        if vm.imageOptions.isEmpty { await vm.loadImageOptions() }
        guard let i = await vm.loadContainerInfo(name: container.name) else {
            loadError = vm.alertMessage.isEmpty ? "获取容器配置失败" : vm.alertMessage
            return
        }
        info = i
        image = i.image
        forcePull = i.forcePull ?? false
        publishAllPorts = i.publishAllPorts ?? false
        envs = i.env ?? []
    }

    private func submit(info: ContainerInfo) async {
        await vm.updateContainer(
            info: info,
            image: image.trimmingCharacters(in: .whitespaces),
            forcePull: forcePull,
            publishAllPorts: publishAllPorts,
            env: envs.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        )
    }
}

// MARK: - 镜像列表页

struct ContainerImageView: View {
    @ObservedObject var vm: ContainersViewModel
    @State private var showPull = false
    @State private var showRepos = false
    @State private var showPruneSelect = false
    @State private var pruneMode = false  // false=未使用, true=未标签

    var body: some View {
        Group {
            if vm.isLoadingImages && vm.images.isEmpty {
                ProgressView("加载镜像…")
            } else if vm.images.isEmpty {
                ContentUnavailableView(
                    "暂无镜像",
                    systemImage: "square.stack.3d.up",
                    description: Text(vm.errorMessage ?? "这台服务器上没有镜像")
                )
            } else {
                List {
                    ForEach(vm.images) { img in
                        ImageRow(image: img)
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await vm.loadImages() }
            }
        }
        .navigationTitle("镜像")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showPull = true } label: {
                        Label("拉取镜像", systemImage: "arrow.down.circle")
                    }
                    Button { showRepos = true } label: {
                        Label("仓库", systemImage: "shippingbox")
                    }
                    Divider()
                    Button {
                        pruneMode = false
                        showPruneSelect = true
                    } label: {
                        Label("清理未使用镜像", systemImage: "trash.slash")
                    }
                    Button {
                        pruneMode = true
                        showPruneSelect = true
                    } label: {
                        Label("清理未标签镜像", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(vm.imageOperating)
            }
        }
        .navigationDestination(isPresented: $showPull) {
            PullImageView(vm: vm)
        }
        .navigationDestination(isPresented: $showRepos) {
            RepoListView(vm: vm)
        }
        .navigationDestination(isPresented: $showPruneSelect) {
            ImagePruneSelectView(vm: vm, isUntaggedMode: pruneMode)
        }
        .alert("提示", isPresented: $vm.showAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .task {
            if vm.images.isEmpty { await vm.loadImages() }
        }
    }
}

struct ImageRow: View {
    let image: ContainerImage

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "square.stack.3d.up.fill", color: .teal, size: 34, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(image.displayName)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(image.sizeDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if image.isUsed == true {
                        StatusBadge(text: "使用中", color: .green)
                    } else {
                        StatusBadge(text: "未使用", color: .gray)
                    }
                    if image.isPinned == true {
                        StatusBadge(text: "已固定", color: .orange)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 拉取镜像

struct PullImageView: View {
    @ObservedObject var vm: ContainersViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var fromRepo = true
    @State private var repos: [ContainerRepo] = []
    @State private var selectedRepoID: Int = 0
    @State private var imageNameInput = ""
    @State private var imageNames: [String] = []
    @State private var isPulling = false
    @State private var pullTaskID: String?
    @State private var showTaskProgress = false

    private var canPull: Bool {
        !imageNames.isEmpty && (!fromRepo || selectedRepoID > 0)
    }

    var body: some View {
        Form {
            Section {
                Toggle("镜像仓库", isOn: $fromRepo)

                if fromRepo {
                    if repos.isEmpty {
                        Text("暂无已配置的仓库")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("仓库名", selection: $selectedRepoID) {
                            ForEach(repos) { repo in
                                Text(repo.name ?? "未知").tag(repo.id)
                            }
                        }
                    }
                }
            }

            Section {
                ForEach(imageNames.indices, id: \.self) { idx in
                    HStack {
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(.teal)
                        Text(imageNames[idx])
                            .font(.system(.subheadline, design: .monospaced))
                        Spacer()
                        Button {
                            imageNames.remove(at: idx)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red.opacity(0.7))
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                    TextField("镜像名（回车添加）", text: $imageNameInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit {
                            addImage()
                        }
                    if !imageNameInput.isEmpty {
                        Button("添加") {
                            addImage()
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("镜像名")
            } footer: {
                Text("输入镜像名后回车继续添加，支持同时拉取多个镜像。")
            }

            Section {
                Button {
                    Task { await startPull() }
                } label: {
                    HStack {
                        if isPulling { ProgressView().scaleEffect(0.8) }
                        Text(isPulling ? "拉取中…" : "确认拉取")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(!canPull || isPulling)
            }
        }
        .navigationTitle("拉取镜像")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            repos = await vm.loadRepos()
            if let first = repos.first { selectedRepoID = first.id }
        }
        .navigationDestination(isPresented: $showTaskProgress) {
            if let taskID = pullTaskID {
                TaskProgressView(taskID: taskID, title: "拉取镜像") { _ in
                    Task { await vm.loadImages() }
                    return false
                }
            }
        }
    }

    private func addImage() {
        let trimmed = imageNameInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        imageNames.append(trimmed)
        imageNameInput = ""
    }

    private func startPull() async {
        isPulling = true
        let taskID = await vm.pullImage(
            fromRepo: fromRepo,
            repoID: fromRepo ? selectedRepoID : 0,
            imageNames: imageNames
        )
        isPulling = false
        if let taskID {
            pullTaskID = taskID
            showTaskProgress = true
        }
    }
}

// MARK: - 仓库列表

struct RepoListView: View {
    @ObservedObject var vm: ContainersViewModel
    @State private var repos: [ContainerRepo] = []
    @State private var isLoading = false
    @State private var showCreate = false
    /// 当前编辑的仓库（sheet(item:)）
    @State private var editingRepo: ContainerRepo?
    @State private var pendingDelete: ContainerRepo?

    var body: some View {
        Group {
            if isLoading && repos.isEmpty {
                ProgressView("加载仓库…")
            } else if repos.isEmpty {
                ContentUnavailableView(
                    "暂无仓库",
                    systemImage: "shippingbox",
                    description: Text("这台服务器上没有配置镜像仓库")
                )
            } else {
                List {
                    ForEach(repos) { repo in
                        Button {
                            editingRepo = repo
                        } label: {
                            RepoRow(repo: repo)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = repo
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                Task { await sync(repo) }
                            } label: {
                                Label("同步", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .tint(.blue)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await loadRepos() }
            }
        }
        .navigationTitle("仓库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCreate = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            RepoFormView(editing: nil, vm: vm) { await loadRepos() }
        }
        .sheet(item: $editingRepo) { repo in
            RepoFormView(editing: repo, vm: vm) { await loadRepos() }
        }
        .alert(
            "删除仓库",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                let repo = pendingDelete
                pendingDelete = nil
                if let repo {
                    Task {
                        if await vm.deleteRepo(id: repo.id) {
                            await loadRepos()
                        }
                    }
                }
            }
        } message: {
            if let repo = pendingDelete {
                Text("确定删除仓库「\(repo.name ?? "")」吗？")
            }
        }
        .alert("提示", isPresented: $vm.showAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .task { await loadRepos() }
    }

    private func loadRepos() async {
        isLoading = true
        repos = await vm.loadRepos()
        isLoading = false
    }

    /// 同步仓库状态：提交后稍等再刷新列表，让状态有机会更新
    private func sync(_ repo: ContainerRepo) async {
        if await vm.syncRepo(id: repo.id) {
            try? await Task.sleep(for: .seconds(1))
            await loadRepos()
        }
    }
}

// MARK: - 仓库表单（添加/编辑）

struct RepoFormView: View {
    /// nil = 添加；非 nil = 编辑（信息预填）
    let editing: ContainerRepo?
    @ObservedObject var vm: ContainersViewModel
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var downloadUrl = ""
    @State private var useAuth = false
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    /// true = https
    @State private var useHTTPS = true
    /// http 协议二次确认步骤（需输入「立即重启」）
    @State private var confirmStep = false
    @State private var restartConfirm = ""
    @State private var isSaving = false

    init(editing: ContainerRepo?, vm: ContainersViewModel, onSaved: @escaping () async -> Void) {
        self.editing = editing
        self.vm = vm
        self.onSaved = onSaved
        // 编辑：原有信息预填
        _name = State(initialValue: editing?.name ?? "")
        _downloadUrl = State(initialValue: editing?.downloadUrl ?? "")
        _useAuth = State(initialValue: editing?.auth ?? false)
        _username = State(initialValue: editing?.username ?? "")
        _useHTTPS = State(initialValue: (editing?.protocolField ?? "https").lowercased() != "http")
    }

    private var isEditing: Bool { editing != nil }

    private var canSubmit: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
              !downloadUrl.trimmingCharacters(in: .whitespaces).isEmpty
        else { return false }
        if useAuth {
            guard !username.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            // 添加时密码必填；编辑不提交密码（保留原密码）
            if !isEditing && password.isEmpty { return false }
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                if confirmStep {
                    Section {
                        Label("操作 http 类型仓库需要重启 Docker 服务。\n如果确认操作，请手动输入 '立即重启'", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.subheadline)
                    }
                    Section("确认") {
                        TextField("立即重启", text: $restartConfirm)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } else {
                    formSection
                }
            }
            .navigationTitle(isEditing ? "编辑仓库" : "添加仓库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if confirmStep {
                            confirmStep = false
                            restartConfirm = ""
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "提交中…" : (confirmStep ? "确认" : "确认")) {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit || isSaving || (confirmStep && restartConfirm != "立即重启"))
                }
            }
        }
    }

    private var formSection: some View {
        Section {
            TextField("名称", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Toggle("认证", isOn: $useAuth)
            if useAuth {
                TextField("用户名", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !isEditing {
                    HStack {
                        Group {
                            if showPassword {
                                TextField("密码", text: $password)
                            } else {
                                SecureField("密码", text: $password)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        Button { showPassword.toggle() } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            TextField("下载地址", text: $downloadUrl)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Picker("协议", selection: $useHTTPS) {
                Text("https").tag(true)
                Text("http").tag(false)
            }
            .pickerStyle(.segmented)
            Text("http 仓库添加授信需要重启 Docker 服务")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func submit() async {
        // http 协议：先进入二次确认步骤
        if !useHTTPS && !confirmStep {
            confirmStep = true
            return
        }
        isSaving = true
        defer { isSaving = false }

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = downloadUrl.trimmingCharacters(in: .whitespaces)
        let protocolStr = useHTTPS ? "https" : "http"

        let ok: Bool
        if let repo = editing {
            let req = RepoUpdateRequest(
                id: repo.id,
                createdAt: repo.createdAt ?? "",
                name: trimmedName,
                downloadUrl: trimmedURL,
                protocolField: protocolStr,
                username: useAuth ? username.trimmingCharacters(in: .whitespaces) : "",
                auth: useAuth,
                status: repo.status ?? "",
                message: repo.message ?? ""
            )
            ok = await vm.updateRepo(req)
        } else {
            let req = RepoCreateRequest(
                auth: useAuth,
                protocolField: protocolStr,
                name: trimmedName,
                downloadUrl: trimmedURL,
                username: useAuth ? username.trimmingCharacters(in: .whitespaces) : "",
                password: useAuth ? password : ""
            )
            ok = await vm.createRepo(req)
        }
        if ok {
            await onSaved()
            dismiss()
        }
    }
}

struct RepoRow: View {
    let repo: ContainerRepo

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "shippingbox.fill", color: .indigo, size: 34, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(repo.name ?? "未知")
                    .font(.subheadline.bold())
                if let url = repo.downloadUrl, !url.isEmpty {
                    Text(url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if repo.auth == true {
                        StatusBadge(text: "已认证", color: .green)
                    } else {
                        StatusBadge(text: "公开", color: .gray)
                    }
                    if let status = repo.status, !status.isEmpty {
                        let isSuccess = status.lowercased() == "success"
                        StatusBadge(
                            text: isSuccess ? "正常" : status,
                            color: isSuccess ? .green : .orange                        )
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 镜像清理选择

struct ImagePruneSelectView: View {
    @ObservedObject var vm: ContainersViewModel
    let isUntaggedMode: Bool

    @State private var selectedIDs: Set<String> = []
    @State private var isDeleting = false

    private var filteredImages: [ContainerImage] {
        if isUntaggedMode {
            return vm.images.filter { ($0.tags ?? []).isEmpty }
        } else {
            return vm.images.filter { $0.isUsed != true }
        }
    }

    private var selectedImageNames: [String] {
        filteredImages
            .filter { selectedIDs.contains($0.id) }
            .compactMap { img -> String? in
                if let tag = img.tags?.first, !tag.isEmpty { return tag }
                return nil
            }
    }

    private var allSelected: Bool {
        !filteredImages.isEmpty && filteredImages.allSatisfy { selectedIDs.contains($0.id) }
    }

    var body: some View {
        Group {
            if filteredImages.isEmpty {
                ContentUnavailableView(
                    isUntaggedMode ? "暂无未标签镜像" : "暂无未使用镜像",
                    systemImage: "checkmark.seal",
                    description: Text("没有可清理的镜像")
                )
            } else {
                List(selection: $selectedIDs) {
                    Section {
                        ForEach(filteredImages) { img in
                            HStack {
                                if let tag = img.tags?.first, !tag.isEmpty {
                                    Text(tag)
                                        .font(.system(.subheadline, design: .monospaced))
                                } else {
                                    Text("<none>")
                                        .font(.system(.subheadline, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(img.sizeDisplay)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(img.id)
                        }
                    } header: {
                        HStack {
                            Text(isUntaggedMode ? "未标签镜像（\(filteredImages.count)）" : "未使用镜像（\(filteredImages.count)）")
                            Spacer()
                            Button {
                                if allSelected {
                                    selectedIDs.removeAll()
                                } else {
                                    selectedIDs = Set(filteredImages.map(\.id))
                                }
                            } label: {
                                Text(allSelected ? "取消全选" : "全选")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .environment(\.editMode, .constant(.active))
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(isUntaggedMode ? "清理未标签镜像" : "清理未使用镜像")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await deleteSelected() }
                } label: {
                    if isDeleting {
                        ProgressView()
                    } else {
                        Text("删除（\(selectedIDs.count)）")
                            .fontWeight(.medium)
                    }
                }
                .disabled(selectedIDs.isEmpty || isDeleting)
            }
        }
        .task {
            if vm.images.isEmpty { await vm.loadImages() }
        }
    }

    private func deleteSelected() async {
        let names = selectedImageNames
        guard !names.isEmpty else { return }
        isDeleting = true
        let ok = await vm.deleteImages(names: names)
        isDeleting = false
        if ok {
            selectedIDs.removeAll()
        }
    }
}

// MARK: - ViewModel

@MainActor
final class ContainersViewModel: ObservableObject {
    @Published var containers: [Container] = []
    @Published var dockerStatus: DockerStatus?
    @Published var images: [ContainerImage] = []
    @Published var imageOptions: [String] = []

    /// 创建容器选项
    @Published var networkOptions: [String] = []
    @Published var volumeOptions: [String] = []
    @Published var containerLimit: ContainerLimit?

    @Published var isLoading = false
    @Published var isLoadingDocker = false
    @Published var isLoadingImages = false
    @Published var dockerOperating = false
    @Published var containerOperating = false
    @Published var imageOperating = false
    @Published var errorMessage: String?
    @Published var dockerErrorMessage: String?

    @Published var showAlert = false
    @Published var alertMessage = ""

    /// 标记 docker 状态是否已加载，避免 List 重绘反复请求
    private var dockerLoaded = false

    private var client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    func refresh() async {
        if dockerStatus == nil { isLoadingDocker = true }
        // 并行加载容器列表和 Docker 状态，避免串行等待
        async let listTask = load(query: "")
        async let dockerTask = loadDockerStatus(force: false)
        _ = await (listTask, dockerTask)
    }

    func search(query: String) async {
        await load(query: query)
    }

    // MARK: - 容器列表 + 运行时指标

    private func load(query: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let req = ContainerSearchRequest(
            page: 1, pageSize: 100, name: query, state: "all",
            orderBy: "createdAt", order: "null"
        )
        do {
            let resp: ContainerListResponse = try await client.send(
                path: APIEndpoint.containersSearch.path,
                body: req, as: ContainerListResponse.self
            )
            // 先显示列表，避免等待 stats 接口导致长时间 loading
            self.containers = resp.items ?? []
            // 后台合并运行时指标（CPU/内存），完成后刷新界面
            await mergeStats()
        } catch let err as APIError {
            self.errorMessage = err.errorDescription
            self.containers = []
        } catch {
            self.errorMessage = error.localizedDescription
            self.containers = []
        }
    }

    private func mergeStats() async {
        guard let stats: [ContainerStats] = try? await client.send(
            path: APIEndpoint.containersListStats.path,
            method: "GET", as: [ContainerStats].self
        ) else { return }
        let pairs: [(String, ContainerStats)] = stats.compactMap {
            guard let id = $0.containerID else { return nil }
            return (id, $0)
        }
        let map = Dictionary(uniqueKeysWithValues: pairs)
        for i in containers.indices {
            if let s = map[containers[i].containerID] {
                containers[i].cpuPercent = s.cpuPercent
                containers[i].memoryUsage = s.memoryUsage
                containers[i].memoryLimit = s.memoryLimit
                containers[i].memoryPercent = s.memoryPercent
            }
        }
    }

    // MARK: - Docker 服务状态

    func loadDockerStatus(force: Bool) async {
        if !force && dockerLoaded { return }
        dockerLoaded = true
        isLoadingDocker = true
        defer { isLoadingDocker = false }
        do {
            self.dockerStatus = try await client.send(
                path: APIEndpoint.containersDockerStatus.path,
                method: "GET", as: DockerStatus.self
            )
        } catch {
            // 解码/网络失败时记录原因，便于排查；不阻断容器列表展示
            self.dockerStatus = nil
            self.dockerErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Docker 操作（start/stop/restart）

    func operateDocker(operation: String) async {
        dockerOperating = true
        defer { dockerOperating = false }
        let opName = operation == "start" ? "启动" : (operation == "stop" ? "停止" : "重启")
        let req = DockerOperateRequest(operation: operation)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersDockerOperate.path,
                body: req, as: EmptyResponse.self
            )
            try? await Task.sleep(for: .seconds(1))
            await loadDockerStatus(force: true)
            await load(query: "")
        } catch {
            showAlert(message: "\(opName) Docker 失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 清理容器

    func pruneContainers() async {
        dockerOperating = true
        defer { dockerOperating = false }
        let req = ContainerPruneRequest(
            taskID: UUID().uuidString, pruneType: "container", withTagAll: false
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersPrune.path,
                body: req, as: EmptyResponse.self
            )
            try? await Task.sleep(for: .seconds(1))
            await load(query: "")
            showAlert(message: "清理容器任务已提交")
        } catch {
            showAlert(message: "清理容器失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 单个容器操作（stop/start/restart/kill）

    func operateContainer(name: String, operation: String) async {
        containerOperating = true
        defer { containerOperating = false }
        let opName: String
        switch operation {
        case "stop": opName = "停止"
        case "start": opName = "启动"
        case "restart": opName = "重启"
        case "kill": opName = "关闭"
        case "remove": opName = "删除"
        default: opName = operation
        }
        let req = ContainerOperateRequest(names: [name], operation: operation, taskID: UUID().uuidString)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersOperate.path,
                body: req, as: EmptyResponse.self
            )
            try? await Task.sleep(for: .seconds(1))
            await load(query: "")
            showAlert(message: "\(opName)容器「\(name)」任务已提交")
        } catch {
            showAlert(message: "\(opName)容器失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 容器升级

    func upgradeContainer(name: String, image: String, forcePull: Bool) async {
        containerOperating = true
        defer { containerOperating = false }
        let req = ContainerUpgradeRequest(
            taskID: UUID().uuidString, names: [name], image: image, forcePull: forcePull
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersUpgrade.path,
                body: req, as: EmptyResponse.self
            )
            try? await Task.sleep(for: .seconds(1))
            await load(query: "")
            showAlert(message: "升级容器「\(name)」任务已提交")
        } catch {
            showAlert(message: "升级容器失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 容器日志（SSE 流式）

    /// 返回容器日志的 SSE 流（已剥离 `data: ` 前缀）
    func streamLogs(container name: String) -> AsyncThrowingStream<String, Error> {
        client.streamSSELines(
            path: APIEndpoint.containersSearchLog.path,
            queryItems: [
                URLQueryItem(name: "container", value: name),
                URLQueryItem(name: "since", value: "all"),
                URLQueryItem(name: "tail", value: "100"),
                URLQueryItem(name: "follow", value: "true"),
                URLQueryItem(name: "operateNode", value: "local")
            ]
        )
    }

    // MARK: - 容器编辑（info / image 选项 / update）

    private struct ContainerInfoRequest: Encodable { let name: String }

    /// 获取容器详情配置（POST /containers/info）
    /// 失败时弹出 alert，返回 nil
    func loadContainerInfo(name: String) async -> ContainerInfo? {
        do {
            return try await client.send(
                path: APIEndpoint.containersInfo.path,
                body: ContainerInfoRequest(name: name),
                as: ContainerInfo.self
            )
        } catch {
            showAlert(message: "获取容器配置失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 加载镜像选项（GET /containers/image），用于编辑/升级时下拉选择
    func loadImageOptions() async {
        do {
            let opts = try await client.send(
                path: APIEndpoint.containersImageOptions.path,
                method: "GET", as: [ContainerOption].self
            )
            self.imageOptions = opts.map { $0.option }
        } catch {
            self.imageOptions = []
        }
    }

    // MARK: - 创建容器

    /// 加载创建容器所需选项：网络 / 存储卷 / 镜像 / CPU·内存上限
    func loadCreateOptions() async {
        async let nets: [ContainerOption]? = try? await client.send(
            path: APIEndpoint.containersNetwork.path, method: "GET", as: [ContainerOption].self
        )
        async let vols: [ContainerOption]? = try? await client.send(
            path: APIEndpoint.containersVolume.path, method: "GET", as: [ContainerOption].self
        )
        async let imgs: [ContainerOption]? = try? await client.send(
            path: APIEndpoint.containersImageOptions.path, method: "GET", as: [ContainerOption].self
        )
        async let lim: ContainerLimit? = try? await client.send(
            path: APIEndpoint.containersLimit.path, method: "GET", as: ContainerLimit.self
        )
        let (n, v, i, l) = await (nets, vols, imgs, lim)
        self.networkOptions = (n ?? []).map { $0.option }
        self.volumeOptions = (v ?? []).map { $0.option }
        self.imageOptions = (i ?? []).map { $0.option }
        self.containerLimit = l
    }

    /// 创建容器（POST /containers），字段对齐 doc/手动创建容器.log
    func createContainer(draft: ContainerCreateDraft) async {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty,
              !draft.image.trimmingCharacters(in: .whitespaces).isEmpty else {
            showAlert(message: "容器名称和镜像不能为空")
            return
        }
        containerOperating = true
        defer { containerOperating = false }

        let ports = draft.ports.map {
            ContainerUpdatePort(
                hostIP: "", hostPort: $0.host,
                containerPort: $0.containerPort, protocolField: $0.protocolField,
                host: $0.host
            )
        }
        let volumes = draft.volumes.map {
            ContainerVolumeInfo(
                type: $0.type, sourceDir: $0.sourceDir, containerDir: $0.containerDir,
                mode: $0.mode, shared: $0.shared
            )
        }
        let networks = [ContainerNetworkInfo(
            network: draft.network, ipv4: "", ipv6: "", macAddr: ""
        )]
        let req = ContainerUpdateRequest(
            taskID: UUID().uuidString,
            name: draft.name.trimmingCharacters(in: .whitespaces),
            image: draft.image.trimmingCharacters(in: .whitespaces),
            imageInput: true,
            forcePull: draft.forcePull,
            networks: networks,
            hostname: draft.hostname,
            domainName: "",
            dns: [],
            cmdStr: "",
            entrypointStr: "",
            memoryItem: 0,
            cmd: [],
            workingDir: "",
            user: "",
            openStdin: draft.openStdin,
            tty: draft.tty,
            entrypoint: [],
            publishAllPorts: draft.publishAllPorts,
            exposedPorts: ports,
            nanoCPUs: 0,
            cpuShares: draft.cpuShares,
            memory: Int64(draft.memoryMB) * 1024 * 1024,
            volumes: volumes,
            privileged: draft.privileged,
            autoRemove: draft.autoRemove,
            labels: [],
            env: draft.env,
            restartPolicy: draft.restartPolicy
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersCreate.path, body: req, as: EmptyResponse.self
            )
            try? await Task.sleep(for: .seconds(1))
            await load(query: "")
            showAlert(message: "创建容器「\(draft.name)」任务已提交")
        } catch {
            showAlert(message: "创建容器失败：\(error.localizedDescription)")
        }
    }

    /// 更新容器配置（POST /containers/update）
    /// info 来自 /containers/info；image / forcePull / publishAllPorts / env 为用户编辑后的值
    func updateContainer(
        info: ContainerInfo,
        image: String,
        forcePull: Bool,
        publishAllPorts: Bool,
        env: [String]
    ) async {
        containerOperating = true
        defer { containerOperating = false }

        let ports = (info.exposedPorts ?? []).map { p in
            ContainerUpdatePort(
                hostIP: p.hostIP,
                hostPort: p.hostPort,
                containerPort: p.containerPort,
                protocolField: p.protocolField,
                host: "\(p.hostIP):\(p.hostPort)"
            )
        }
        let req = ContainerUpdateRequest(
            taskID: UUID().uuidString,
            name: info.name,
            image: image,
            imageInput: false,
            forcePull: forcePull,
            networks: info.networks ?? [],
            hostname: info.hostname ?? "",
            domainName: info.domainName ?? "",
            dns: info.dns ?? [],
            cmdStr: "",
            entrypointStr: (info.entrypoint ?? []).joined(separator: " "),
            memoryItem: 0,
            cmd: info.cmd ?? [],
            workingDir: info.workingDir ?? "",
            user: info.user ?? "",
            openStdin: info.openStdin ?? false,
            tty: info.tty ?? false,
            entrypoint: info.entrypoint ?? [],
            publishAllPorts: publishAllPorts,
            exposedPorts: ports,
            nanoCPUs: info.nanoCPUs ?? 0,
            cpuShares: info.cpuShares ?? 0,
            memory: info.memory ?? 0,
            volumes: info.volumes ?? [],
            privileged: info.privileged ?? false,
            autoRemove: info.autoRemove ?? false,
            labels: info.labels ?? [],
            env: env,
            restartPolicy: info.restartPolicy ?? "always"
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersUpdate.path,
                body: req, as: EmptyResponse.self
            )
            try? await Task.sleep(for: .seconds(1))
            await load(query: "")
            showAlert(message: "更新容器「\(info.name)」任务已提交")
        } catch {
            showAlert(message: "更新容器失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 镜像列表

    func loadImages() async {
        isLoadingImages = true
        defer { isLoadingImages = false }
        do {
            self.images = try await client.send(
                path: APIEndpoint.containersImageAll.path,
                method: "GET", as: [ContainerImage].self
            )
        } catch {
            self.images = []
        }
    }

    // MARK: - 清理镜像（withTagAll: false=未标签, true=未使用）

    func pruneImages(withTagAll: Bool) async {
        imageOperating = true
        defer { imageOperating = false }
        let type = withTagAll ? "未使用" : "未标签"
        let req = ContainerPruneRequest(
            taskID: UUID().uuidString, pruneType: "image", withTagAll: withTagAll
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersPrune.path,
                body: req, as: EmptyResponse.self
            )
            try? await Task.sleep(for: .seconds(1))
            await loadImages()
            showAlert(message: "清理\(type)镜像任务已提交")
        } catch {
            showAlert(message: "清理\(type)镜像失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 拉取镜像

    func pullImage(fromRepo: Bool, repoID: Int, imageNames: [String]) async -> String? {
        imageOperating = true
        defer { imageOperating = false }
        let req = ImagePullRequest(
            taskID: UUID().uuidString,
            fromRepo: fromRepo,
            repoID: repoID,
            imageName: imageNames
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersImagePull.path,
                body: req, as: EmptyResponse.self
            )
            return req.taskID
        } catch {
            showAlert(message: "拉取镜像失败：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 查询仓库

    private struct RepoSearchRequest: Encodable {
        let page: Int
        let pageSize: Int
    }

    func loadRepos() async -> [ContainerRepo] {
        let req = RepoSearchRequest(page: 1, pageSize: 100)
        do {
            let resp: PageResponse<ContainerRepo> = try await client.send(
                path: APIEndpoint.containersRepoSearch.path,
                body: req, as: PageResponse<ContainerRepo>.self
            )
            return resp.items ?? []
        } catch {
            return []
        }
    }

    // MARK: - 仓库管理（添加/编辑/删除/同步）

    func createRepo(_ req: RepoCreateRequest) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersRepoCreate.path, body: req, as: EmptyResponse.self
            )
            return true
        } catch {
            showAlert(message: "添加仓库失败：\(error.localizedDescription)")
            return false
        }
    }

    func updateRepo(_ req: RepoUpdateRequest) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersRepoUpdate.path, body: req, as: EmptyResponse.self
            )
            return true
        } catch {
            showAlert(message: "更新仓库失败：\(error.localizedDescription)")
            return false
        }
    }

    func deleteRepo(id: Int) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersRepoDelete.path,
                body: RepoIDRequest(id: id), as: EmptyResponse.self
            )
            return true
        } catch {
            showAlert(message: "删除仓库失败：\(error.localizedDescription)")
            return false
        }
    }

    func syncRepo(id: Int) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersRepoSync.path,
                body: RepoIDRequest(id: id), as: EmptyResponse.self
            )
            showAlert(message: "仓库同步任务已提交")
            return true
        } catch {
            showAlert(message: "同步仓库失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 删除镜像

    func deleteImages(names: [String]) async -> Bool {
        imageOperating = true
        defer { imageOperating = false }
        let req = ImageDeleteRequest(names: names)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersImageDelete.path,
                body: req, as: EmptyResponse.self
            )
            await loadImages()
            return true
        } catch {
            showAlert(message: "删除镜像失败：\(error.localizedDescription)")
            return false
        }
    }

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }
}

// MARK: - 创建容器

struct ContainerCreateView: View {
    @ObservedObject var vm: ContainersViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ContainerCreateDraft()
    @State private var newEnvText = ""

    private let restartPolicies = ["no", "always", "unless-stopped", "on-failure"]
    private let protocols = ["tcp", "udp"]
    private let volumeTypes = ["bind", "volume"]
    private let volumeModes = ["rw", "ro"]
    private let shareModes = ["private", "shared"]

    var body: some View {
        Form {
            basicsSection
            networkSection
            portsSection
            volumesSection
            envSection
            restartSection
            resourceSection
            advancedSection
        }
        .navigationTitle("创建容器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await vm.createContainer(draft: draft) }
                } label: {
                    if vm.containerOperating {
                        ProgressView()
                    } else {
                        Text("创建").bold()
                    }
                }
                .disabled(vm.containerOperating || draft.name.isEmpty || draft.image.isEmpty)
            }
        }
        .task { await vm.loadCreateOptions() }
        .alert("提示", isPresented: $vm.showAlert) {
            Button("好的", role: .cancel) {
                if vm.alertMessage.contains("任务已提交") { dismiss() }
            }
        } message: { Text(vm.alertMessage) }
    }

    // MARK: 基础

    private var basicsSection: some View {
        Section("基础信息") {
            HStack {
                Text("名称").foregroundStyle(.secondary)
                TextField("如 nginx-test", text: $draft.name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("镜像").foregroundStyle(.secondary)
                    TextField("如 nginx:latest", text: $draft.image)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                }
                if !vm.imageOptions.isEmpty {
                    Menu {
                        ForEach(vm.imageOptions, id: \.self) { (opt: String) in
                            Button(opt) { draft.image = opt }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "square.stack.3d.up")
                            Text(draft.image.isEmpty ? "选择已有镜像" : draft.image)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.caption)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            Toggle("总是拉取最新镜像", isOn: $draft.forcePull)
        }
    }

    // MARK: 网络

    private var networkSection: some View {
        Section("网络") {
            Picker("网络", selection: $draft.network) {
                ForEach(vm.networkOptions.isEmpty ? ["bridge"] : vm.networkOptions, id: \.self) { (n: String) in
                    Text(n).tag(n)
                }
            }
            HStack {
                Text("主机名").foregroundStyle(.secondary)
                TextField("hostname", text: $draft.hostname)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .onAppear {
            if !vm.networkOptions.isEmpty && !vm.networkOptions.contains(draft.network) {
                draft.network = vm.networkOptions.first ?? "bridge"
            }
        }
    }

    // MARK: 端口

    private var portsSection: some View {
        Section {
            Toggle("暴露所有端口", isOn: $draft.publishAllPorts)
            ForEach($draft.ports) { $port in
                portRow($port)
            }
            .onDelete { draft.ports.remove(atOffsets: $0) }
            addRowButton("添加端口映射") { draft.ports.append(CreatePortRow()) }
        } header: {
            Text("端口映射")
        } footer: {
            Text("容器端口 → 主机端口，如 80 → 8080")
        }
    }

    private func portRow(_ port: Binding<CreatePortRow>) -> some View {
        VStack(spacing: 6) {
            HStack {
                TextField("容器端口", text: port.containerPort)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("主机端口", text: port.host)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
            }
            Picker("协议", selection: port.protocolField) {
                ForEach(protocols, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: 挂载卷

    private var volumesSection: some View {
        Section {
            ForEach($draft.volumes) { $vol in
                volumeRow($vol)
            }
            .onDelete { draft.volumes.remove(atOffsets: $0) }
            addRowButton("添加挂载卷") { draft.volumes.append(CreateVolumeRow()) }
        } header: {
            Text("挂载卷")
        } footer: {
            Text("主机目录 → 容器目录")
        }
    }

    private func volumeRow(_ vol: Binding<CreateVolumeRow>) -> some View {
        VStack(spacing: 6) {
            HStack {
                TextField("主机目录", text: vol.sourceDir)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.caption, design: .monospaced))
                Image(systemName: "arrow.left").font(.caption).foregroundStyle(.secondary)
                TextField("容器目录", text: vol.containerDir)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.caption, design: .monospaced))
            }
            HStack {
                Picker("模式", selection: vol.mode) {
                    ForEach(volumeModes, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("共享", selection: vol.shared) {
                    ForEach(shareModes, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    // MARK: 环境变量

    private var envSection: some View {
        Section("环境变量") {
            ForEach(draft.env.indices, id: \.self) { idx in
                HStack {
                    Text(draft.env[idx])
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                }
            }
            .onDelete { draft.env.remove(atOffsets: $0) }
            HStack {
                TextField("KEY=VALUE", text: $newEnvText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.caption, design: .monospaced))
                Button {
                    let t = newEnvText.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    draft.env.append(t)
                    newEnvText = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
        }
    }

    // MARK: 重启策略

    private var restartSection: some View {
        Section("重启策略") {
            Picker("策略", selection: $draft.restartPolicy) {
                ForEach(restartPolicies, id: \.self) { Text($0).tag($0) }
            }
        }
    }

    // MARK: 资源限制

    private var resourceSection: some View {
        Section {
            HStack {
                Text("CPU 权重")
                Spacer()
                Stepper("\(draft.cpuShares)", value: $draft.cpuShares, in: 2...262144, step: 64)
                    .monospacedDigit()
            }
            HStack {
                Text("内存上限")
                Spacer()
                TextField("0", value: $draft.memoryMB, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text("MB").foregroundStyle(.secondary)
            }
        } header: {
            Text("资源限制")
        } footer: {
            if let lim = vm.containerLimit {
                Text("宿主机可用：CPU \(lim.cpu ?? 0) 核" + (lim.memory.map { "，内存 \(formatBytes($0))" } ?? ""))
            }
        }
    }

    // MARK: 高级

    private var advancedSection: some View {
        Section("高级") {
            Toggle("特权模式", isOn: $draft.privileged)
            Toggle("自动删除", isOn: $draft.autoRemove)
            Toggle("TTY", isOn: $draft.tty)
            Toggle("标准输入", isOn: $draft.openStdin)
        }
    }

    // MARK: 辅助

    private func addRowButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus.circle")
                .foregroundStyle(Color.accentColor)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let f = Double(bytes)
        if f > 1_073_741_824 { return String(format: "%.1f GB", f / 1_073_741_824) }
        if f > 1_048_576 { return String(format: "%.0f MB", f / 1_048_576) }
        return "\(bytes) B"
    }
}
