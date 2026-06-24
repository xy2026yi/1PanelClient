//
//  ContainersTab.swift
//  1PanelClient
//

import SwiftUI
import Combine

struct ContainersTab: View {
    @ObservedObject var manager: ServerManager
    @StateObject private var vm: ContainersViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var showImages = false
    @State private var showCreateAlert = false

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
        if standalone {
            NavigationStack {
                rootContent
            }
            .fullScreenCover(isPresented: $showImages) {
                ContainerImageView(vm: vm, showCloseButton: true)
            }
            .task { await vm.refresh() }
        } else {
            rootContent
                .task { await vm.refresh() }
        }
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
        .alert("创建容器", isPresented: $showCreateAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("创建容器功能开发中，敬请期待。")
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                showCreateAlert = true
            } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor, in: Circle())
                    .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 4)
            }
            .padding(.trailing, 20)
            .padding(.bottom, 20)
            .accessibilityLabel("创建容器")
        }
        .onChange(of: searchText) { _, newValue in
            Task { await vm.search(query: newValue) }
        }
        .navigationDestination(for: Container.self) { c in
            ContainerDetailView(container: c, vm: vm)
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
    }

    private var isRunning: Bool { vm.dockerStatus?.isActive == true }

    @ViewBuilder
    private func headerRow(_ status: DockerStatus) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "shippingbox.fill", color: .indigo, size: 40, cornerRadius: 10)

            VStack(alignment: .leading, spacing: 3) {
                Text("Docker")
                    .font(.body.bold())
                Text(status.isActive == true ? "Running" : "Stopped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Circle()
                    .fill(isRunning ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)
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
                Task { await vm.operateDocker(operation: isRunning ? "stop" : "start") }
            }
            actionButton(
                title: "重启",
                icon: "arrow.triangle.2.circlepath",
                color: .blue
            ) {
                Task { await vm.operateDocker(operation: "restart") }
            }
            actionButton(
                title: "清理容器",
                icon: "trash",
                color: .pink
            ) {
                Task { await vm.pruneContainers() }
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
                    .font(.system(size: 9))
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
    @ObservedObject var vm: ContainersViewModel
    @State private var showMenuAlert = false
    @State private var menuAlertMessage = ""
    @State private var showUpgrade = false

    var body: some View {
        List {
            Section("基本信息") {
                LabeledRow("名称", value: container.displayName)
                if let img = container.imageName, !img.isEmpty {
                    LabeledRow("镜像", value: img)
                }
                LabeledRow("状态", value: container.state.capitalized)
                if let app = container.appName, !app.isEmpty {
                    LabeledRow("应用程序", value: app)
                }
                if let sites = container.websites, !sites.isEmpty {
                    LabeledRow("网站", value: sites.joined(separator: "\n"))
                }
                if let ports = container.ports, !ports.isEmpty {
                    LabeledRow("端口映射", value: ports.joined(separator: "\n"))
                }
                LabeledRow("运行时长", value: container.runTime ?? "—")
                if let created = container.createTime, !created.isEmpty {
                    LabeledRow("创建时间", value: String(created.prefix(19)))
                }
            }

            Section {
                NavigationLink {
                    ContainerLogView(container: container, vm: vm)
                } label: {
                    Label("日志", systemImage: "doc.text")
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(container.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // 根据状态显示 启动/停止
                    if container.state.lowercased() == "running" {
                        Button(role: .destructive) {
                            Task { await vm.operateContainer(name: container.name, operation: "stop") }
                        } label: { Label("停止", systemImage: "stop.fill") }
                    } else {
                        Button {
                            Task { await vm.operateContainer(name: container.name, operation: "start") }
                        } label: { Label("启动", systemImage: "play.fill") }
                    }
                    Button {
                        Task { await vm.operateContainer(name: container.name, operation: "restart") }
                    } label: { Label("重启", systemImage: "arrow.triangle.2.circlepath") }
                    Button(role: .destructive) {
                        Task { await vm.operateContainer(name: container.name, operation: "kill") }
                    } label: { Label("关闭", systemImage: "xmark") }
                    Divider()
                    Button {
                        showUpgrade = true
                    } label: { Label("升级", systemImage: "arrow.up.circle") }
                    Button { notify("编辑", message: "编辑容器功能开发中") } label: { Label("编辑", systemImage: "pencil") }
                    Button { notify("终端", message: "容器终端功能开发中") } label: { Label("终端", systemImage: "terminal") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(vm.containerOperating)
            }
        }
        .navigationDestination(isPresented: $showUpgrade) {
            ContainerUpgradeView(container: container, vm: vm)
        }
        .alert("提示", isPresented: $showMenuAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(menuAlertMessage)
        }
        // 容器操作（停止/启动/重启/关闭/升级）结果走 VM 的 alert，
        // 详情页也要绑定，否则操作后弹窗只在列表页显示
        .alert("提示", isPresented: $vm.showAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
    }

    private func notify(_ feature: String, message: String? = nil) {
        menuAlertMessage = message ?? "\(feature)功能开发中，敬请期待。"
        showMenuAlert = true
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
                            .font(.system(size: 11, design: .monospaced))
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
                guard count > 0 else { return }
                withAnimation {
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
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

// MARK: - 镜像列表页

struct ContainerImageView: View {
    @ObservedObject var vm: ContainersViewModel
    @Environment(\.dismiss) private var dismiss
    var showCloseButton: Bool = true

    var body: some View {
        NavigationStack {
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
                if showCloseButton {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await vm.pruneImages(withTagAll: false) }
                        } label: { Label("清理未标签镜像", systemImage: "trash") }
                        Button {
                            Task { await vm.pruneImages(withTagAll: true) }
                        } label: { Label("清理未使用镜像", systemImage: "trash.slash") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(vm.imageOperating)
                }
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
}

struct ImageRow: View {
    let image: ContainerImage

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "square.stack.3d.up.fill", color: .teal, size: 38, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(image.displayName)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(image.sizeDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if image.isUsed == true {
                        StatusBadge(text: "使用中", color: .green, backgroundOpacity: 0.12)
                    } else {
                        StatusBadge(text: "未使用", color: .gray, backgroundOpacity: 0.1)
                    }
                    if image.isPinned == true {
                        StatusBadge(text: "已固定", color: .orange, backgroundOpacity: 0.12)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - ViewModel

@MainActor
final class ContainersViewModel: ObservableObject {
    @Published var containers: [Container] = []
    @Published var dockerStatus: DockerStatus?
    @Published var images: [ContainerImage] = []

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
        // 预先标记 Docker 状态加载中，避免容器列表加载期间
        // （dockerStatus==nil 且未开始加载）误显示"未安装或加载失败"
        if dockerStatus == nil { isLoadingDocker = true }
        await load(query: "")
        await loadDockerStatus(force: false)
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

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }
}
