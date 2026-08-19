//
//  ContainerDetailView.swift
//  1PanelClient
//

import SwiftUI

// MARK: - 容器详情页

struct ContainerDetailView: View {
    let server: ServerConfig
    @ObservedObject var vm: ContainersViewModel
    @Environment(\.dismiss) private var dismiss
    /// 最新容器状态（下拉刷新 / 暂停等任务完成后更新），初始为进入时的快照
    @State private var current: Container

    init(container: Container, server: ServerConfig, vm: ContainersViewModel) {
        self.server = server
        self.vm = vm
        _current = State(initialValue: container)
    }

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
    /// 暂停/恢复任务进度（非空时 push TaskProgressView）
    @State private var progressTaskID: String?
    @State private var progressTitle = ""

    private var isRunning: Bool { current.state.lowercased() == "running" }
    private var isPaused: Bool { current.state.lowercased() == "paused" }
    private var statusText: String {
        if isRunning { return "运行中" }
        if isPaused { return "已暂停" }
        return "已停止"
    }
    private var statusColor: Color {
        if isRunning { return .green }
        if isPaused { return .orange }
        return .gray
    }

    var body: some View {
        List {
            statusSection

            Section("基本信息") {
                if let img = current.imageName, !img.isEmpty {
                    InfoRow("镜像", value: img)
                }
                if let app = current.appName, !app.isEmpty {
                    NavigationLink {
                        AppDetailFromContainerView(container: current, server: server)
                    } label: {
                        InfoRow("应用程序", value: app)
                    }
                    .buttonStyle(.plain)
                }
                if let sites = current.websites, !sites.isEmpty {
                    ForEach(sites, id: \.self) { site in
                        NavigationLink {
                            WebsiteDetailFromContainerView(domain: site, server: server)
                        } label: {
                            InfoRow("网站", value: site)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let ports = current.ports, !ports.isEmpty {
                    PortsInfoRow(ports: ports)
                }
                InfoRow("运行时长", value: current.runTime ?? "—")
                if let created = current.createTime, !created.isEmpty {
                    InfoRow("创建时间", value: String(created.prefix(19)))
                }
            }

            Section {
                NavigationLink {
                    ContainerLogView(container: current, vm: vm)
                } label: {
                    Label("日志", systemImage: "doc.text")
                }
                .buttonStyle(.plain)
                NavigationLink {
                    ContainerMonitorView(container: current)
                } label: {
                    Label("监控", systemImage: "chart.xyaxis.line")
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(current.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await refreshContainer()
        }
        .navigationDestination(isPresented: $showUpgrade) {
            ContainerUpgradeView(container: current, vm: vm)
        }
        .navigationDestination(isPresented: $showEdit) {
            ContainerEditView(container: current, vm: vm)
        }
        .navigationDestination(isPresented: $showTerminal) {
            TerminalScreen(
                server: server,
                target: .container(
                    containerID: current.containerID,
                    user: "",
                    command: terminalCommand,
                    cols: 80,
                    rows: 24
                ),
                title: current.displayName
            )
        }
        // 暂停/恢复任务进度页；完成或转后台后刷新列表并返回
        .navigationDestination(isPresented: Binding(
            get: { progressTaskID != nil },
            set: { if !$0 { progressTaskID = nil } }
        )) {
            if let taskID = progressTaskID {
                TaskProgressView(taskID: taskID, title: progressTitle) { _ in
                    Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        await refreshContainer()
                    }
                    progressTaskID = nil
                    return true
                }
            }
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
                Task {
                    if await vm.operateContainer(name: current.name, operation: "remove") {
                        // 删除成功后刷新，容器已不存在时 refreshContainer 会退出本页
                        await refreshContainer()
                    }
                }
            }
        } message: {
            Text("确定删除容器「\(current.displayName)」吗？删除后不可恢复。")
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
            VStack(alignment: .leading, spacing: 3) {
                Text(current.displayName)
                    .font(.body.bold())
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                StatusDot(color: statusColor)
                Text(statusText)
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
            // 运行中可暂停，已暂停可恢复，其余状态不显示
            if isRunning || isPaused {
                actionButton(
                    title: isPaused ? "恢复" : "暂停",
                    icon: isPaused ? "play.circle" : "pause.fill",
                    color: .mint
                ) {
                    pendingAction = isPaused ? "unpause" : "pause"
                }
            }
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
                color: .red
            ) {
                if current.isFromApp == true {
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
        case "pause":   return "暂停"
        case "unpause": return "恢复"
        default:        return action
        }
    }

    private func executeContainerAction() {
        let action = pendingAction
        pendingAction = nil
        guard let action else { return }
        Task {
            // 暂停/恢复为异步任务，提交后进入任务进度页轮询日志
            if action == "pause" || action == "unpause" {
                progressTitle = action == "pause" ? "暂停容器" : "恢复容器"
                if let taskID = await vm.operateContainerTask(name: current.name, operation: action) {
                    progressTaskID = taskID
                }
            } else {
                await vm.operateContainer(name: current.name, operation: action)
            }
        }
    }

    /// 下拉刷新 / 任务完成后刷新：重拉容器列表并按 containerID 更新本页快照；
    /// 列表中已不存在（如已删除）时退出详情页
    private func refreshContainer() async {
        await vm.refresh()
        if let updated = vm.containers.first(where: { $0.containerID == current.containerID }) {
            current = updated
        } else {
            dismiss()
        }
    }
}

/// 容器详情 → 关联应用详情：
/// 拉取已安装应用列表后按 容器名/安装名 匹配，直接展示应用详情页（返回即回容器详情）
struct AppDetailFromContainerView: View {
    let container: Container
    let server: ServerConfig
    @StateObject private var vm: AppsViewModel

    init(container: Container, server: ServerConfig) {
        self.container = container
        self.server = server
        _vm = StateObject(wrappedValue: AppsViewModel(server: server))
    }

    private var matchedApp: AppInstall? {
        vm.apps.first { $0.container == container.name }
            ?? vm.apps.first { $0.name == container.appInstallName }
            ?? vm.apps.first { $0.displayName == container.appName }
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.apps.isEmpty {
                ProgressView("加载中…")
            } else if let app = matchedApp {
                AppDetailView(app: app, vm: vm)
            } else {
                ContentUnavailableView(
                    "未找到关联应用",
                    systemImage: "app.badge",
                    description: Text(vm.errorMessage ?? "该容器关联的应用不存在或已被卸载")
                )
            }
        }
        .navigationTitle("应用程序")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if vm.apps.isEmpty { await vm.refresh() }
        }
    }
}

/// 容器详情 → 关联网站详情：
/// 容器接口的 websites 为「主域名:端口」形式，搜索网站列表后按 primaryDomain /
/// 去端口的域名（alias）匹配，直接展示网站详情页（返回即回容器详情）
struct WebsiteDetailFromContainerView: View {
    let domain: String
    let server: ServerConfig
    @StateObject private var vm: WebsitesViewModel

    init(domain: String, server: ServerConfig) {
        self.domain = domain
        self.server = server
        _vm = StateObject(wrappedValue: WebsitesViewModel(server: server))
    }

    /// 去掉端口后的域名（adg.domain.xyz:443 → adg.domain.xyz）
    private var host: String {
        domain.split(separator: ":", maxSplits: 1).first.map(String.init) ?? domain
    }

    private var matchedWebsite: Website? {
        vm.websites.first { $0.primaryDomain == domain }
            ?? vm.websites.first { $0.primaryDomain == host || $0.alias == host }
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.websites.isEmpty {
                ProgressView("加载中…")
            } else if let website = matchedWebsite {
                WebsiteDetailView(website: website, vm: vm)
            } else {
                ContentUnavailableView(
                    "未找到网站",
                    systemImage: "globe",
                    description: Text("未找到域名「\(host)」对应的网站，可能已被删除")
                )
            }
        }
        .navigationTitle("网站")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if vm.websites.isEmpty { await vm.search(query: "") }
        }
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

