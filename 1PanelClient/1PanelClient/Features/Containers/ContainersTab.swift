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
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Docker 未安装或加载失败")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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

            // 端口映射
            if let ports = container.ports, !ports.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(ports, id: \.self) { p in
                        Text(p)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            // 状态 + CPU
            HStack(spacing: 6) {
                StatusBadge(
                    text: container.state.capitalized,
                    color: container.stateColor,
                    icon: "circle.fill"
                )
                Spacer()
                HStack(spacing: 2) {
                    Image(systemName: "cpu")
                        .font(.system(size: 9))
                    Text(container.cpuDisplay)
                        .font(.caption2.monospacedDigit())
                }
                .foregroundStyle(.secondary)
            }
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

    var body: some View {
        List {
            Section("基本信息") {
                LabeledRow("名称", value: container.displayName)
                if let img = container.imageName, !img.isEmpty {
                    LabeledRow("镜像", value: img)
                }
                LabeledRow("状态", value: container.state.capitalized)
                if let app = container.appName, !app.isEmpty {
                    LabeledRow("关联应用", value: app)
                } else {
                    LabeledRow("关联应用", value: "无")
                }
                if container.isFromApp == true, let app = container.appName, !app.isEmpty {
                    LabeledRow("关联网站", value: "由 \(app) 管理")
                } else {
                    LabeledRow("关联网站", value: "无")
                }
                LabeledRow("运行时长", value: container.runTime ?? "—")
                if let created = container.createTime, !created.isEmpty {
                    LabeledRow("创建时间", value: String(created.prefix(19)))
                }
            }

            Section {
                NavigationLink {
                    ContainerLogPlaceholderView(container: container)
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
                    Button { notify("停止容器") } label: { Label("停止", systemImage: "stop.fill") }
                    Button { notify("重启容器") } label: { Label("重启", systemImage: "arrow.triangle.2.circlepath") }
                    Button { notify("关闭容器") } label: { Label("关闭", systemImage: "xmark") }
                    Button { notify("升级容器") } label: { Label("升级", systemImage: "arrow.up.circle") }
                    Button { notify("编辑容器") } label: { Label("编辑", systemImage: "pencil") }
                    Button { notify("容器终端") } label: { Label("终端", systemImage: "terminal") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("提示", isPresented: $showMenuAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(menuAlertMessage)
        }
    }

    private func notify(_ feature: String) {
        menuAlertMessage = "\(feature)功能开发中，敬请期待。"
        showMenuAlert = true
    }
}

/// 容器日志占位页（接口未提供，待开发）
struct ContainerLogPlaceholderView: View {
    let container: Container

    var body: some View {
        ContentUnavailableView(
            "日志查看开发中",
            systemImage: "doc.text.magnifyingglass",
            description: Text("容器「\(container.displayName)」的日志接口待接入")
        )
        .navigationTitle("日志")
        .navigationBarTitleDisplayMode(.inline)
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
    @Published var imageOperating = false
    @Published var errorMessage: String?

    @Published var showAlert = false
    @Published var alertMessage = ""

    /// 标记 docker 状态是否已加载，避免 List 重绘反复请求
    private var dockerLoaded = false

    private var client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    func refresh() async {
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
            var items = resp.items ?? []
            // 合并运行时指标（CPU/内存）
            await mergeStats(into: &items)
            self.containers = items
        } catch let err as APIError {
            self.errorMessage = err.errorDescription
            self.containers = []
        } catch {
            self.errorMessage = error.localizedDescription
            self.containers = []
        }
    }

    private func mergeStats(into items: inout [Container]) async {
        guard let stats: [ContainerStats] = try? await client.send(
            path: APIEndpoint.containersListStats.path,
            method: "GET", as: [ContainerStats].self
        ) else { return }
        let pairs: [(String, ContainerStats)] = stats.compactMap {
            guard let id = $0.containerID else { return nil }
            return (id, $0)
        }
        let map = Dictionary(uniqueKeysWithValues: pairs)
        for i in items.indices {
            if let s = map[items[i].containerID] {
                items[i].cpuPercent = s.cpuPercent
                items[i].memoryUsage = s.memoryUsage
                items[i].memoryLimit = s.memoryLimit
                items[i].memoryPercent = s.memoryPercent
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
            self.dockerStatus = nil
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
