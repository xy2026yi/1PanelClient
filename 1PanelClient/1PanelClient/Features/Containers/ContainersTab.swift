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


    init(manager: ServerManager) {
        self.manager = manager
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: ContainersViewModel(server: server))
    }

    var body: some View {
        rootContent
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
            prompt: "搜索容器名"
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
        Group {
            if vm.isLoadingDocker && vm.dockerStatus == nil {
                Section {
                    ServiceStatusLoadingRow(text: "加载 Docker 状态…")
                }
            } else if vm.dockerStatus != nil {
                ServiceStatusCard(
                    title: "Docker",
                    statusText: statusText,
                    statusColor: isRunning ? .green : .gray,
                    isOperating: vm.dockerOperating,
                    isExpanded: $isExpanded,
                    actions: [
                        ServiceAction(
                            title: isRunning ? "停止" : "启动",
                            icon: isRunning ? "stop.fill" : "play.fill",
                            color: isRunning ? .orange : .green
                        ) { pendingAction = isRunning ? "stop" : "start" },
                        ServiceAction(title: "重启", icon: "arrow.triangle.2.circlepath", color: .blue) {
                            pendingAction = "restart"
                        },
                        ServiceAction(title: "清理容器", icon: "trash", color: .pink) {
                            pendingAction = "prune"
                        },
                        ServiceAction(title: "镜像", icon: "square.stack.3d.up", color: .teal) {
                            Task {
                                await vm.loadImages()
                                onShowImages()
                            }
                        }
                    ]
                ) {
                    // Docker 使用内置品牌图标
                    BrandIcon(brand: .docker, size: 44)
                }
            } else {
                Section {
                    ServiceStatusFailedRow(text: "Docker 未安装或加载失败", detail: vm.dockerErrorMessage)
                }
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

    private var statusText: String {
        guard let status = vm.dockerStatus else { return "未知" }
        return status.isExist == false ? "未安装" : (isRunning ? "运行中" : "已停止")
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

// MARK: - 端口映射行（超长折叠）

/// 端口映射信息行：超过 5 行默认折叠，按钮就地展开/收起
///（部分应用端口映射达数十行，全部展开会把详情页撑得过长）
struct PortsInfoRow: View {
    let ports: [String]
    @State private var isExpanded = false

    private static let previewLimit = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("端口映射")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Spacer(minLength: 12)
                Text(visiblePorts.joined(separator: "\n"))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.subheadline)

            if needsFold {
                Button {
                    withAnimation { isExpanded.toggle() }
                } label: {
                    Label(
                        isExpanded ? "收起" : "展开全部 \(ports.count) 条",
                        systemImage: isExpanded ? "chevron.up" : "chevron.down"
                    )
                    .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var needsFold: Bool { ports.count > Self.previewLimit }

    private var visiblePorts: [String] {
        isExpanded || !needsFold ? ports : Array(ports.prefix(Self.previewLimit))
    }
}

