//
//  NodeDetailView.swift
//  1PanelClient
//
//  节点详情：头部（状态/当前/专业版 + 操作菜单）、运行状态、资源概览、节点日志、节点信息
//  操作：编辑（完整表单）/ 同步（任务进度）/ 更新记录 / 重启面板 / 重启服务器
//  基于网页端抓包（logs/多机管理/多机管理-2.md）
//

import SwiftUI

struct NodeDetailView: View {
    @ObservedObject var manager: ServerManager
    let server: ServerConfig
    let nodeID: Int
    @Binding var navPath: NavigationPath
    /// 详情数据变更后（编辑/同步完成等）通知概览页刷新
    var onReload: () -> Void

    enum RestartTarget: String, Identifiable {
        case panel = "1panel"
        case system = "system"

        var id: String { rawValue }

        var title: String {
            self == .panel ? L10n.t("重启面板") : L10n.t("重启服务器")
        }

        var successToast: String {
            self == .panel
                ? L10n.t("重启指令已发送，面板服务正在重启，几秒后恢复")
                : L10n.t("重启指令已发送，服务器将失联 1-2 分钟")
        }
    }

    /// 数据态与加载逻辑在 NodeDetailViewModel（本文件下方）；
    /// 以下只留交互/呈现态
    @StateObject private var vm: NodeDetailViewModel
    @State private var showEditSheet = false
    @State private var showRenameSheet = false
    @State private var restartTarget: RestartTarget?
    @State private var showDeleteSheet = false
    @State private var deleteForce = false
    @State private var deleteWithData = false
    @State private var toastMessage: String?
    @State private var alertMessage: String?
    @State private var showRestartAlert = false

    init(manager: ServerManager, server: ServerConfig, nodeID: Int,
         navPath: Binding<NavigationPath>, onReload: @escaping () -> Void = {}) {
        self.manager = manager
        self.server = server
        self.nodeID = nodeID
        self._navPath = navPath
        self.onReload = onReload
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(
            key: PageVMStore.pageKey("nodeDetail|\(nodeID)", server: server)) {
            NodeDetailViewModel(nodeID: nodeID, server: server)
        })
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.item == nil {
                LoadingStateView()
            } else if let errorMessage = vm.errorMessage, vm.item == nil {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button(L10n.t("重试")) { Task { await vm.load() } }
                        .buttonStyle(.borderedProminent)
                }
            } else if let item = vm.item {
                List {
                    headerSection(item)
                    statusSection
                    resourceSection
                    logSection
                    infoSection(item)
                }
            }
        }
        .navigationTitle(vm.item?.displayName ?? L10n.t("节点详情"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showRenameSheet = true
                    } label: {
                        Label(L10n.t("改名称"), systemImage: "pencil")
                    }
                    Button {
                        showEditSheet = true
                    } label: {
                        Label(L10n.t("编辑"), systemImage: "pencil")
                    }
                    Button {
                        Task { await syncNode() }
                    } label: {
                        Label(L10n.t("同步"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(vm.isSyncing)
                    Button {
                        navPath.append(NodeManageView.Dest.upgradeLogs(nodeID))
                    } label: {
                        Label(L10n.t("更新记录"), systemImage: "clock.arrow.circlepath")
                    }
                    Divider()
                    Button(role: .destructive) {
                        restartTarget = .panel
                    } label: {
                        Label(RestartTarget.panel.title, systemImage: "power")
                    }
                    Button(role: .destructive) {
                        restartTarget = .system
                    } label: {
                        Label(RestartTarget.system.title, systemImage: "power.dotted")
                    }
                    // local 为主控节点，删除后当前面板连接即失效，不提供删除入口
                    if !vm.isLocalNode {
                        Divider()
                        Button(role: .destructive) {
                            deleteForce = false
                            deleteWithData = false
                            showDeleteSheet = true
                        } label: {
                            Label(L10n.t("删除"), systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .refreshable { await vm.load() }
        .task {
            vm.syncCurrentNode()
            await PageVMStore.shared.autoRefresh(vm: vm) { await vm.load() }
        }
        // 从日志/进度/资源页返回时静默刷新（编辑、同步完成后数据变化可见）。
        // hasLoaded 门控防与 .task 双首发；5s 节流由 autoRefresh 承担
        .onAppear {
            vm.syncCurrentNode()
            if vm.hasLoaded {
                Task { await PageVMStore.shared.autoRefresh(vm: vm) { await vm.load() } }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NodeScope.changeNotification)) { _ in
            vm.syncCurrentNode()
        }
        // 编辑节点 push 进入（与安装应用一致）；提交成功后分步收栈再进任务进度
        .navigationDestination(isPresented: $showEditSheet) {
            AddNodeView(server: server, editing: vm.item, currentNode: vm.current) { taskID in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    navPath.append(NodeManageView.Dest.taskProgress(taskID: taskID, title: L10n.t("编辑节点")))
                }
            }
        }
        .sheet(isPresented: $showRenameSheet) {
            if let item = vm.item {
                NodeRenameSheet(server: server, item: item) {
                    Task { await vm.load() }
                    onReload()
                }
            }
        }
        .sheet(item: $restartTarget) { target in
            TextInputConfirmSheet(
                title: target.title,
                message: L10n.t("此操作不可恢复。如果确认操作，请手动输入「立即重启」。"),
                expectedText: L10n.t("立即重启"),
                fieldLabel: L10n.t("确认输入"),
                fieldPlaceholder: L10n.t("请输入 立即重启"),
                confirmTitle: L10n.t("确认重启")
            ) {
                Task { await restart(target) }
            }
        }
        .sheet(isPresented: $showDeleteSheet) {
            TextInputConfirmSheet(
                title: L10n.t("删除节点"),
                message: L10n.f("删除后将从多机管理中移除该节点，此操作不可恢复。请输入节点名称「%@」以确认删除。", vm.item?.displayName ?? server.name),
                expectedText: vm.item?.displayName ?? server.name,
                fieldLabel: L10n.t("确认名称"),
                fieldPlaceholder: L10n.t("节点名称")
            ) {
                Task { await deleteNode() }
            } options: {
                Section {
                    Toggle(L10n.t("强制删除"), isOn: $deleteForce)
                    Toggle(L10n.t("删除节点数据"), isOn: $deleteWithData)
                } footer: {
                    Text(L10n.t("强制删除：节点异常或离线时仍强制移除。删除节点数据：同时卸载该节点上安装的 1Panel 服务。"))
                }
            }
        }
        .toastOverlay(message: $toastMessage)
        .alert(L10n.t("提示"), isPresented: $showRestartAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - 卡片

    /// 卡片1：名称 / 地址 / 健康 / 当前节点 / 专业版标记
    private func headerSection(_ item: NodeDetailItem) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(item.displayName)
                        .font(.headline)
                    if vm.isCurrentNode {
                        StatusBadge(text: L10n.t("当前节点"), color: .blue)
                    }
                    Spacer()
                    StatusBadge(text: NodeUI.statusText(vm.current?.status ?? item.status),
                                color: NodeUI.statusColor(vm.current?.status ?? item.status))
                }
                HStack(spacing: 8) {
                    Text("\(item.name).\(item.addr ?? "")")
                    if item.isXpack == true {
                        StatusBadge(text: L10n.t("专业版已启用"), color: .purple)
                    } else {
                        StatusBadge(text: L10n.t("专业版未启用"), color: .secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    /// 卡片2：运行状态（CPU / 内存，与概览一致）
    private var statusSection: some View {
        Section(L10n.t("运行状态")) {
            usageBar(
                label: L10n.t("CPU 使用率"),
                detail: vm.current.map { L10n.f("%ld 核", $0.cpuTotal ?? 0) },
                percent: vm.current?.cpuUsedPercent
            )
            usageBar(
                label: L10n.t("内存使用率"),
                detail: vm.current.map {
                    ByteCountFormatter.string(fromByteCount: Int64($0.memoryTotal ?? 0), countStyle: .memory)
                },
                percent: vm.current?.memoryUsedPercent
            )
        }
    }

    private func usageBar(label: String, detail: String?, percent: Double?) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            if let percent {
                ProgressView(value: min(max(percent, 0), 100) / 100)
                    .tint(percentColor(percent))
                Text(String(format: "%.1f%%", percent))
                    .font(.caption.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)
            } else {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func percentColor(_ p: Double) -> Color {
        if p >= 90 { return .red }
        if p >= 70 { return .orange }
        return .green
    }

    /// 卡片3：资源概览（点击进入对应页面 = 切换到该节点）
    private var resourceSection: some View {
        Section(L10n.t("资源概览")) {
            HStack(spacing: 8) {
                countLink(dest: .apps(vm.nodeName), icon: "app.badge", title: L10n.t("应用"), tint: .blue, value: vm.counts?.apps)
                countLink(dest: .websites(vm.nodeName), icon: "globe", title: L10n.t("网站"), tint: .green, value: vm.counts?.websites)
            }
            HStack(spacing: 8) {
                countLink(dest: .databases(vm.nodeName), icon: "cylinder", title: L10n.t("数据库"), tint: .purple, value: vm.counts?.databases)
                countLink(dest: .cronjobs(vm.nodeName), icon: "clock.badge.checkmark", title: L10n.t("计划任务"), tint: .teal, value: vm.counts?.cronjobs)
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    private func countLink(dest: NodeManageView.Dest, icon: String, title: String, tint: Color, value: Int?) -> some View {
        Button {
            NodeScope.setCurrent(vm.nodeName, for: server.id)
            navPath.append(dest)
        } label: {
            // plain 样式命中区只有文字部分，补全行矩形命中
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                Text(value.map(String.init) ?? (vm.hasLoaded ? "-" : "…"))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 卡片4：节点日志
    private var logSection: some View {
        Section(L10n.t("节点日志")) {
            Button {
                navPath.append(NodeManageView.Dest.log(vm.nodeName))
            } label: {
                HStack {
                    Label(L10n.t("查看系统日志"), systemImage: "doc.text.magnifyingglass")
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// 卡片5：节点信息
    private func infoSection(_ item: NodeDetailItem) -> some View {
        Section(L10n.t("节点信息")) {
            infoRow(L10n.t("节点名称"), item.name)
            infoRow(L10n.t("地址"), item.addr ?? "—")
            infoRow(L10n.t("版本"), item.version?.isEmpty == false ? item.version! : "—")
            infoRow(L10n.t("专业版"), item.isXpack == true ? L10n.t("是") : L10n.t("否"))
            infoRow(L10n.t("绑定状态"), item.isBound == true ? L10n.t("是") : L10n.t("否"))
        }
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }

    // MARK: - 操作（请求与业务判定在 VM；这里只按结果呈现/导航）

    private func syncNode() async {
        switch await vm.syncNode() {
        case .ok(let taskID):
            if let taskID {
                navPath.append(NodeManageView.Dest.taskProgress(taskID: taskID, title: L10n.t("同步节点")))
            }
            onReload()
        case .failed(let message):
            alertMessage = message
            showRestartAlert = true
        }
    }

    private func restart(_ target: RestartTarget) async {
        switch await vm.restartNode(service: target.rawValue) {
        case .ok:
            toastMessage = target.successToast
            onReload()
        case .failed(let message):
            alertMessage = message
            showRestartAlert = true
        }
    }

    private func deleteNode() async {
        switch await vm.deleteNode(force: deleteForce, withUninstall: deleteWithData) {
        case .ok:
            onReload()
            // 返回多机管理列表
            if !navPath.isEmpty { navPath.removeLast() }
        case .failed(let message):
            alertMessage = message
            showRestartAlert = true
        }
    }
}

// MARK: - 节点改名称（轻量：名称 / 分组 / 备注）

/// 对应网页端「节点改名称」表单，POST /core/xpack/nodes/update/base
private struct NodeRenameSheet: View {
    let server: ServerConfig
    let item: NodeDetailItem
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var descriptionText: String
    @State private var selectedGroupID: Int
    @State private var groups: [NodeGroup] = []
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig, item: NodeDetailItem, onDone: @escaping () -> Void) {
        self.server = server
        self.item = item
        self.onDone = onDone
        self.client = APIClient.shared(for: server)
        _name = State(initialValue: item.name)
        _descriptionText = State(initialValue: item.description ?? "")
        _selectedGroupID = State(initialValue: item.groupID ?? 0)
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.t("节点信息")) {
                    OutlinedTextField(label: L10n.t("名称"), text: $name)
                    if groups.isEmpty {
                        HStack {
                            Text(L10n.t("分组"))
                            Spacer()
                            Text(item.groupBelong ?? "Default")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Picker(L10n.t("分组"), selection: $selectedGroupID) {
                            ForEach(groups) { group in
                                Text(group.name ?? "#\(group.id)").tag(group.id)
                            }
                        }
                    }
                    OutlinedMultiLineField(label: L10n.t("备注"), prompt: L10n.t("可选"), lines: 1, text: $descriptionText)
                }
            }
            .navigationTitle(L10n.t("改名称"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button(L10n.t("保存")) { Task { await submit() } }
                            .disabled(!canSubmit)
                    }
                }
            }
            .alert(L10n.t("操作失败"), isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(L10n.t("好的"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                if let list: [NodeGroup] = try? await client.send(
                    path: APIEndpoint.nodeGroupsSearch.path,
                    body: NodeGroupSearchRequest(type: "node"),
                    as: [NodeGroup].self
                ) {
                    groups = list
                }
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            _ = try await client.send(
                path: APIEndpoint.nodesUpdateBase.path,
                body: NodeUpdateBaseRequest(
                    id: item.id,
                    name: name.trimmingCharacters(in: .whitespaces),
                    isLocal: item.name == "local",
                    groupID: selectedGroupID,
                    description: descriptionText
                ),
                as: EmptyResponse.self
            )
            dismiss()
            onDone()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 更新记录页

struct NodeUpgradeLogsView: View {
    let server: ServerConfig
    let nodeID: Int

    /// 复用日志列表通用 VM（单页展示：无追加 UI，loadMore 天然不触发），
    /// 经 PageVMStore 常驻——重访即时渲染、autoRefresh 静默刷新
    @StateObject private var vm: LogListViewModel<NodeUpgradeLogItem>

    init(server: ServerConfig, nodeID: Int) {
        self.server = server
        self.nodeID = nodeID
        let client = APIClient.shared(for: server)
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(
            key: PageVMStore.pageKey("nodeUpgradeLogs|\(nodeID)", server: server)) {
            LogListViewModel(pageSize: 50) { page in
                let resp: NodeUpgradeLogResponse = try await client.send(
                    path: APIEndpoint.nodesUpgradeLogs.path,
                    body: NodeUpgradeLogSearchRequest(page: page, pageSize: 50, nodeID: nodeID),
                    as: NodeUpgradeLogResponse.self
                )
                return (resp.items ?? [], resp.total)
            }
        })
    }

    var body: some View {
        List {
            Section {
                if vm.isLoading && vm.items.isEmpty {
                    HStack {
                        Spacer()
                        LoadingStateView()
                        Spacer()
                    }
                    .frame(minHeight: 160)
                    .listRowBackground(Color.clear)
                } else if let errorMessage = vm.errorMessage, vm.items.isEmpty {
                    VStack(spacing: 10) {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(L10n.t("重试")) { Task { await vm.load() } }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, minHeight: 140)
                    .listRowBackground(Color.clear)
                } else if vm.items.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.t("暂无更新记录"), systemImage: "tray")
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(vm.items, id: \.uid) { log in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(log.version?.isEmpty == false ? log.version! : "—")
                                    .font(.subheadline)
                                Spacer()
                                if let createdAt = log.createdAt, !createdAt.isEmpty {
                                    Text(LogDateFormat.short(createdAt))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let desc = log.description ?? log.message, !desc.isEmpty {
                                Text(desc)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } footer: {
                if !vm.isLoading && vm.errorMessage == nil && !vm.items.isEmpty {
                    Text(L10n.f("共 %ld 条", vm.total))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("更新记录"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.load() }
        .task { await PageVMStore.shared.autoRefresh(vm: vm) { await vm.load() } }
    }
}
