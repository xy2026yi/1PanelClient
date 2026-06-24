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
        .overlay(alignment: .bottomTrailing) {
            Button {
                showCreate = true
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
            ContainerDetailView(container: c, server: manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""), vm: vm)
        }
        .navigationDestination(isPresented: $showCreate) {
            ContainerCreateView(vm: vm)
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
    let server: ServerConfig
    @ObservedObject var vm: ContainersViewModel
    @State private var showMenuAlert = false
    @State private var menuAlertMessage = ""
    @State private var showUpgrade = false
    @State private var showEdit = false
    @State private var showTerminal = false
    @State private var showTerminalCommandPicker = false
    @State private var terminalCommand = "/bin/sh"

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
                    Button { showEdit = true } label: { Label("编辑", systemImage: "pencil") }
                    Button { showTerminalCommandPicker = true } label: { Label("终端", systemImage: "terminal") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(vm.containerOperating)
            }
        }
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
                    .onMove { envs.move(fromOffsets: $0, toOffset: $1) }

                    Button {
                        envs.append("")
                    } label: {
                        Label("添加环境变量", systemImage: "plus")
                    }
                }

                Section {
                    Button {
                        Task { await submit(info: info) }
                    } label: {
                        HStack {
                            if vm.containerOperating {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text("保存")
                                .frame(maxWidth: .infinity)
                                .font(.headline)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(image.trimmingCharacters(in: .whitespaces).isEmpty || vm.containerOperating)
                }
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("编辑容器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
                    .disabled(info == nil)
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
            createActionSection
        }
        .navigationTitle("创建容器")
        .navigationBarTitleDisplayMode(.inline)
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

    // MARK: 创建按钮

    private var createActionSection: some View {
        Section {
            Button {
                Task { await vm.createContainer(draft: draft) }
            } label: {
                HStack {
                    Spacer()
                    if vm.containerOperating {
                        ProgressView().tint(.white)
                    } else {
                        Text("创建容器")
                            .font(.headline)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.containerOperating || draft.name.isEmpty || draft.image.isEmpty)
        }
        .listRowBackground(Color.clear)
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
