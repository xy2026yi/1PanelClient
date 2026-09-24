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
    @State private var showNetworks = false
    @State private var showVolumes = false
    @State private var showComposes = false
    @State private var showDaemonSettings = false
    /// 状态筛选（all/running/paused/exited，本地过滤）
    @State private var stateFilter = "all"


    init(manager: ServerManager) {
        self.manager = manager
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        let vm = PageVMStore.shared.vm(key: ManageItem.containers.storeKey(server: server)) {
            ContainersViewModel(server: server)
        }
        _vm = StateObject(wrappedValue: vm)
        // VM 经 PageVMStore 常驻（lastState 保留），而 @State 随页面重建重置：
        // 不回填则 chips 高亮「全部」但列表仍按旧状态过滤，且选中项被
        // ChipsFilterBar 的 guard 吞掉，用户卡在错误筛选里切不回去
        _stateFilter = State(initialValue: vm.lastState)
    }

    var body: some View {
        rootContent
        .task { await PageVMStore.shared.autoRefresh(vm: vm) { await vm.refresh() } }
    }

    /// 列表根内容（不含 NavigationStack），供 ManageTab 嵌入复用
    var rootContent: some View {
        Group {
            if vm.isLoading && vm.containers.isEmpty {
                LoadingStateView()
            } else if let err = vm.errorMessage, !err.isEmpty, vm.containers.isEmpty {
                LoadErrorStateView(message: err) {
                    Task { await vm.refresh() }
                }
            } else if vm.containers.isEmpty && vm.dockerStatus == nil {
                ContentUnavailableView(
                    L10n.t("暂无容器"),
                    systemImage: "shippingbox",
                    description: Text(L10n.t("这台服务器上没有容器"))
                )
            } else {
                // 状态筛选 chips 钉在列表外常驻（与网站/计划任务页同款）：
                // 滚动不消失、筛空后仍可切回「全部」；选中即触发服务端过滤
                VStack(spacing: 0) {
                    ChipsFilterBar(
                        items: [
                            .init(id: "running", title: L10n.t("运行中")),
                            .init(id: "paused", title: L10n.t("已暂停")),
                            .init(id: "exited", title: L10n.t("已停止")),
                        ],
                        allID: "all",
                        selectedID: $stateFilter
                    )
                    containerList
                }
            }
        }
        .searchIconMode(
            text: $searchText,
            isSearching: $isSearching,
            title: L10n.t("容器"),
            prompt: L10n.t("搜索容器名")
        )
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .toastOverlay(message: $vm.toastMessage)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // 右上角两按钮：搜索（searchIconMode 提供）+ 创建；
                // 状态筛选已下放为列表上方 chips
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("创建容器"))
            }
        }
        .onChange(of: searchText) { _, newValue in
            Task { await vm.search(query: newValue) }
        }
        .onChange(of: stateFilter) { _, newValue in
            Task { await vm.applyStateFilter(newValue) }
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
        .navigationDestination(isPresented: $showNetworks) {
            ContainerNetworksView(server: manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
        }
        .navigationDestination(isPresented: $showVolumes) {
            ContainerVolumesView(server: manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
        }
        .navigationDestination(isPresented: $showComposes) {
            ContainerComposesView(server: manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
        }
        .navigationDestination(isPresented: $showDaemonSettings) {
            ContainerDaemonSettingsView(server: manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
        }
    }

    private var containerList: some View {
        List {
            // 顶部 Docker 服务状态卡片
            DockerStatusCard(vm: vm, onShowImages: {
                showImages = true
            }, onShowNetworks: {
                showNetworks = true
            }, onShowVolumes: {
                showVolumes = true
            }, onShowComposes: {
                showComposes = true
            }, onShowSettings: {
                showDaemonSettings = true
            })

            if vm.containers.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label(vm.errorMessage ?? L10n.t("这台服务器上没有容器"), systemImage: "shippingbox")
                    }
                }
            } else {
                Section {
                    ForEach(vm.containers) { c in
                        NavigationLink(value: c) {
                            ContainerRow(container: c)
                        }
                        .onAppear {
                            if c.containerID == vm.containers.last?.containerID {
                                Task { await vm.loadMoreContainers() }
                            }
                        }
                    }
                    if vm.containers.count < vm.total || vm.isLoadingMore {
                        LoadingStateView(compact: true)
                        .onAppear { Task { await vm.loadMoreContainers() } }
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
    var onShowNetworks: () -> Void = {}
    var onShowVolumes: () -> Void = {}
    var onShowComposes: () -> Void = {}
    var onShowSettings: () -> Void = {}
    @State private var isExpanded = false
    @State private var pendingAction: String?

    var body: some View {
        Group {
            if vm.isLoadingDocker && vm.dockerStatus == nil {
                Section {
                    ServiceStatusLoadingRow(text: L10n.t("加载 Docker 状态…"))
                }
            } else if vm.dockerStatus != nil {
                ServiceStatusCard(
                    title: "Docker",
                    subtitle: vm.daemonVersion.flatMap {
                        $0.isEmpty || $0 == "-" ? nil : "v\($0)"
                    },
                    statusText: statusText,
                    statusColor: isRunning ? .green : .gray,
                    isOperating: vm.dockerOperating,
                    isExpanded: $isExpanded,
                    actions: [
                        ServiceAction(
                            title: isRunning ? L10n.t("停止") : L10n.t("启动"),
                            icon: isRunning ? "stop.fill" : "play.fill",
                            color: isRunning ? .orange : .green
                        ) { pendingAction = isRunning ? "stop" : "start" },
                        ServiceAction(title: L10n.t("重启"), icon: "arrow.triangle.2.circlepath", color: .blue) {
                            pendingAction = "restart"
                        },
                        ServiceAction(title: L10n.t("清理容器"), icon: "trash", color: .pink) {
                            pendingAction = "prune"
                        },
                        ServiceAction(title: L10n.t("镜像"), icon: "square.stack.3d.up", color: .teal) {
                            Task {
                                await vm.loadImages()
                                onShowImages()
                            }
                        },
                        ServiceAction(title: L10n.t("网络"), icon: "network", color: .cyan) {
                            onShowNetworks()
                        },
                        ServiceAction(title: L10n.t("存储卷"), icon: "externaldrive.fill.badge.timemachine", color: .indigo) {
                            onShowVolumes()
                        },
                        ServiceAction(title: L10n.t("编排"), icon: "square.stack.3d.up.fill", color: .brown) {
                            onShowComposes()
                        },
                        ServiceAction(title: L10n.t("设置"), icon: "gearshape", color: .gray) {
                            onShowSettings()
                        }
                    ]
                ) {
                    // Docker 使用内置品牌图标
                    BrandIcon(brand: .docker, size: 44)
                }
            } else {
                Section {
                    ServiceStatusFailedRow(text: L10n.t("Docker 未安装或加载失败"), detail: vm.dockerErrorMessage)
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
            Button(L10n.t("取消"), role: .cancel) { pendingAction = nil }
            Button(L10n.t("确认"), role: .destructive) { Haptic.warning(); executePendingAction() }
        } message: {
            if let action = pendingAction {
                Text(L10n.f("将对 Docker 进行 %@ 操作，是否继续？", actionDisplayName(action)))
            }
        }
    }

    private var statusText: String {
        guard let status = vm.dockerStatus else { return L10n.t("未知") }
        return status.isExist == false ? L10n.t("未安装") : (isRunning ? L10n.t("运行中") : L10n.t("已停止"))
    }

    private func actionDisplayName(_ action: String) -> String {
        switch action {
        case "stop":   return L10n.t("停止")
        case "start":  return L10n.t("启动")
        case "restart":return L10n.t("重启")
        case "prune":  return L10n.t("清理容器")
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
                        .font(.panelScaled(10))
                    Text(img)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // 端口映射（单行，逗号分隔）
            if let ports = container.ports, !ports.isEmpty {
                Text(ports.joined(separator: ", "))
                    .font(.panelScaled(10, design: .monospaced))
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
                Text(L10n.t("端口映射"))
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
                    withAnimation(Motion.standard) { isExpanded.toggle() }
                } label: {
                    Label(
                        isExpanded ? L10n.t("收起") : L10n.f("展开全部 %ld 条", ports.count),
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

