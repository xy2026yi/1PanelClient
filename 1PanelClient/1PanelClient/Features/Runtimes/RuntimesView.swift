//
//  RuntimesView.swift
//  1PanelClient
//
//  运行环境列表页（网站 Hub 子页）：类型分段筛选、创建入口、
//  行点击进详情；滑动/长按快捷启停与删除（删除先查关联资源）。
//

import SwiftUI

struct RuntimesView: View {
    let server: ServerConfig

    @StateObject private var vm: RuntimesViewModel
    @State private var showCreate = false
    @State private var editTarget: RuntimeEntry?

    init(server: ServerConfig) {
        self.server = server
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(
            key: ManageItem.runtimes.storeKey(server: server)
        ) {
            RuntimesViewModel(server: server)
        })
    }

    private var hasTransitioning: Bool {
        vm.runtimes.contains { $0.isTransitional }
    }

    var body: some View {
        List {
            segmentSection
            listSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("运行环境"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("创建运行环境"))
            }
        }
        .task {
            await vm.syncStatus()
            await PageVMStore.shared.autoRefresh(vm: vm) { await vm.load() }
        }
        // 过渡态（创建中/构建中）自动轮询收敛
        .adaptivePolling(interval: 5, isActive: { hasTransitioning }) {
            await vm.load()
        }
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .navigationDestination(isPresented: $showCreate) {
            RuntimeFormView(mode: .create, initialType: nil, server: server, listVM: vm)
        }
        .navigationDestination(item: $editTarget) { entry in
            RuntimeFormView(mode: .edit(entry), initialType: nil, server: server, listVM: vm)
        }
        .navigationDestination(item: $vm.activeTask) { target in
            TaskProgressView(taskID: target.taskID, title: target.title, node: "local") { isDone in
                if isDone { Task { await vm.load() } }
                return false
            }
        }
        .sheet(item: $vm.deleteTarget) { entry in
            deleteConfirmSheet(entry)
        }
    }

    // MARK: - 类型分段

    private var segmentSection: some View {
        Section {
            Picker(L10n.t("类型"), selection: $vm.segment) {
                ForEach(RuntimesViewModel.Segment.allCases) { seg in
                    Text(seg.title).tag(seg)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - 列表

    @ViewBuilder
    private var listSection: some View {
        Section {
            if vm.isLoading && vm.runtimes.isEmpty {
                LoadingStateView(compact: true)
                    .padding(.vertical, 30)
                    .listRowBackground(Color.clear)
            } else if let err = vm.errorMessage {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button(L10n.t("重试")) { Task { await vm.load() } }
                }
                .listRowBackground(Color.clear)
            } else if vm.runtimes.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无运行环境"),
                    systemImage: "shippingbox",
                    description: Text(L10n.t("点击右上角 + 创建运行环境"))
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(vm.runtimes) { entry in
                    NavigationLink {
                        RuntimeDetailView(entry: entry, server: server, listVM: vm)
                    } label: {
                        RuntimeListRow(entry: entry,
                                       isOperating: vm.operatingIDs.contains(entry.id))
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        rowActions(entry)
                    }
                    .contextMenu {
                        rowMenuItems(entry)
                    }
                    .onAppear {
                        if entry.id == vm.runtimes.last?.id {
                            Task { await vm.loadMore() }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowActions(_ entry: RuntimeEntry) -> some View {
        Button(role: .destructive) {
            Task { await vm.requestDelete(entry) }
        } label: {
            Label(L10n.t("删除"), systemImage: "trash")
        }
        if entry.isRunning {
            Button {
                Task { await vm.operate(entry, operate: "down") }
            } label: {
                Label(L10n.t("停止"), systemImage: "stop")
            }
            Button {
                Task { await vm.operate(entry, operate: "restart") }
            } label: {
                Label(L10n.t("重启"), systemImage: "arrow.triangle.2.circlepath")
            }
        } else {
            Button {
                Task { await vm.operate(entry, operate: "up") }
            } label: {
                Label(L10n.t("启动"), systemImage: "play")
            }
        }
    }

    @ViewBuilder
    private func rowMenuItems(_ entry: RuntimeEntry) -> some View {
        if entry.isRunning {
            Button {
                Task { await vm.operate(entry, operate: "down") }
            } label: {
                Label(L10n.t("停止"), systemImage: "stop")
            }
            Button {
                Task { await vm.operate(entry, operate: "restart") }
            } label: {
                Label(L10n.t("重启"), systemImage: "arrow.triangle.2.circlepath")
            }
        } else {
            Button {
                Task { await vm.operate(entry, operate: "up") }
            } label: {
                Label(L10n.t("启动"), systemImage: "play")
            }
        }
        Button {
            editTarget = entry
        } label: {
            Label(L10n.t("编辑"), systemImage: "pencil")
        }
        Button(role: .destructive) {
            Task { await vm.requestDelete(entry) }
        } label: {
            Label(L10n.t("删除"), systemImage: "trash")
        }
    }

    // MARK: - 删除确认（含关联资源提示）

    private func deleteConfirmSheet(_ entry: RuntimeEntry) -> some View {
        TextInputConfirmSheet(
            title: L10n.f("删除运行环境 %@", entry.displayName),
            message: deleteConfirmMessage(entry),
            expectedText: entry.displayName,
            confirmTitle: L10n.t("确认删除")
        ) {
            await vm.confirmDelete(entry, force: false, deleteImage: false)
        } options: {
            if vm.isCheckingDelete {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text(L10n.t("正在检查关联资源…"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func deleteConfirmMessage(_ entry: RuntimeEntry) -> String {
        if vm.deleteBlockers.isEmpty {
            return L10n.t("删除后容器与配置将被移除，该操作无法回滚。输入名称确认删除。")
        }
        let names = vm.deleteBlockers
            .map { "\($0.type ?? ""): \($0.name ?? "")" }
            .joined(separator: "、")
        return L10n.f("以下资源仍在使用该运行环境：%@。删除后相关网站将不可用。输入名称确认删除。", names)
    }
}

// MARK: - 列表行

struct RuntimeListRow: View {
    let entry: RuntimeEntry
    let isOperating: Bool

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: typeIcon, color: typeColor)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.displayName)
                        .font(.body.bold())
                        .lineLimit(1)
                    if isOperating || entry.isTransitional {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
                HStack(spacing: 6) {
                    Text(entry.runtimeType?.displayName ?? (entry.type ?? "—"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let version = entry.version, !version.isEmpty {
                        Text("v\(version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let port = entry.port, !port.isEmpty {
                        Label(port, systemImage: "number")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let dir = entry.codeDir, !dir.isEmpty {
                    Text(dir)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let remark = entry.remark, !remark.isEmpty {
                    Text(remark)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            RuntimeStatusBadge(status: entry.status)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var typeIcon: String {
        switch entry.runtimeType {
        case .php: return "server.rack"
        case .node: return "triangle"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .go: return "goforward"
        case nil: return "shippingbox"
        }
    }

    private var typeColor: Color {
        switch entry.runtimeType {
        case .php: return .indigo
        case .node: return .green
        case .python: return .blue
        case .go: return .cyan
        case nil: return .gray
        }
    }
}

/// 运行状态徽标（Running 绿 / 过渡态蓝 / Stopped 灰 / Error 红 / 其余原样）
struct RuntimeStatusBadge: View {
    let status: String?

    var body: some View {
        StatusBadge(text: RuntimeStatusBadge.text(for: status),
                    color: RuntimeStatusBadge.color(for: status))
    }

    nonisolated static func text(for status: String?) -> String {
        let s = status?.lowercased() ?? ""
        switch s {
        case "running": return L10n.t("运行中")
        case "stopped": return L10n.t("已停止")
        case "error": return L10n.t("错误")
        case "creating": return L10n.t("创建中")
        case "building": return L10n.t("构建中")
        case "": return L10n.t("未知")
        default: return status ?? "—"
        }
    }

    nonisolated static func color(for status: String?) -> Color {
        let s = status?.lowercased() ?? ""
        switch s {
        case "running": return .statusRunning
        case "stopped": return .secondary
        case "error": return .statusError
        case "creating", "building": return .blue
        default: return .blue
        }
    }
}
