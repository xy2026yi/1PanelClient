//
//  CleanView.swift
//  1PanelClient
//
//  缓存清理：扫描（/toolbox/scan）树形展示六类垃圾并勾选，
//  清理（/toolbox/clean）提交勾选节点扁平列表；目录勾选联动全选子孙，
//  合计按最深层选中入口计算避免父子重复累计
//

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class CleanViewModel: ObservableObject {
    @Published var scan: CleanScanResponse?
    @Published var selected: Set<String> = []
    @Published var isLoading = true
    @Published var isCleaning = false
    @Published var errorMessage: String?

    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var toastMessage: String?
    private var toastTask: Task<Void, Never>?

    private let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient.shared(for: server)
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let resp: CleanScanResponse = try await client.send(
                path: APIEndpoint.toolboxScan.path,
                body: EmptyRequest(),
                as: CleanScanResponse.self)
            scan = resp
            errorMessage = nil
            // 服务端预选项（isCheck）初始化勾选：勾选节点及其可删子孙全选
            var initial: Set<String> = []
            for root in Self.allRoots(resp) where root.isCheck == true {
                for node in Self.selectableNodes(root) {
                    initial.insert(node.id)
                }
            }
            selected = initial
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private static func allRoots(_ resp: CleanScanResponse) -> [CleanNode] {
        (resp.systemClean ?? []) + (resp.backupClean ?? []) + (resp.containerClean ?? [])
            + (resp.uploadClean ?? []) + (resp.downloadClean ?? []) + (resp.systemLogClean ?? [])
    }

    /// 节点及其子孙中可删（canDelete）的全部节点
    static func selectableNodes(_ node: CleanNode) -> [CleanNode] {
        var result: [CleanNode] = []
        if node.canDelete == true { result.append(node) }
        for child in node.children ?? [] {
            result += selectableNodes(child)
        }
        return result
    }

    /// 勾选切换：入口节点全选/全清其可删子孙
    func toggle(_ node: CleanNode) {
        let targets = Self.selectableNodes(node)
        guard !targets.isEmpty else { return }
        let allSelected = targets.allSatisfy { selected.contains($0.id) }
        if allSelected {
            targets.forEach { selected.remove($0.id) }
        } else {
            targets.forEach { selected.insert($0.id) }
        }
    }

    /// 目录勾选三态：全选 / 部分（indeterminate）/ 空
    func checkState(_ node: CleanNode) -> CleanCheckState {
        let targets = Self.selectableNodes(node)
        guard !targets.isEmpty else { return .disabled }
        let count = targets.filter { selected.contains($0.id) }.count
        if count == 0 { return .none }
        return count == targets.count ? .all : .partial
    }

    /// 清理请求项：勾选中的可删节点（含中间目录，对齐网页端提交）
    var cleanItems: [CleanItem] {
        guard let scan else { return [] }
        var items: [CleanItem] = []
        for root in Self.allRoots(scan) {
            for node in Self.selectableNodes(root) where selected.contains(node.id) {
                items.append(CleanItem(
                    treeType: node.type ?? "",
                    name: node.name ?? "",
                    size: node.size ?? 0))
            }
        }
        return items
    }

    /// 勾选数量与合计大小：大小按「最深层选中入口」累计，避免目录与子孙重复相加
    var selectionSummary: (count: Int, size: Int64) {
        guard let scan else { return (0, 0) }
        var count = 0
        var size: Int64 = 0
        for root in Self.allRoots(scan) {
            accumulate(root, into: &count, size: &size)
        }
        return (count, size)
    }

    /// 节点自身选中且无选中子孙时计一次（孙选中则目录不重复计）
    private func accumulate(_ node: CleanNode, into count: inout Int, size: inout Int64) {
        let selfSelected = node.canDelete == true && selected.contains(node.id)
        var descendantSelected = false
        for child in node.children ?? [] {
            let before = count
            accumulate(child, into: &count, size: &size)
            if count > before { descendantSelected = true }
        }
        if selfSelected && !descendantSelected {
            count += 1
            size += node.size ?? 0
        }
    }

    func clean() async {
        let items = cleanItems
        guard !items.isEmpty else { return }
        isCleaning = true
        defer { isCleaning = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.toolboxClean.path, body: items, as: EmptyResponse.self)
            showToast(L10n.t("清理完成"))
            await load()
        } catch let err as APIError {
            showAlert(message: L10n.f("清理失败：%@", err.errorDescription ?? L10n.t("未知错误")))
        } catch {
            showAlert(message: L10n.f("清理失败：%@", error.localizedDescription))
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

// MARK: - 勾选三态

enum CleanCheckState {
    case all, partial, none, disabled
}

// MARK: - 大小格式化

private let cleanByteFormatter = ByteCountFormatter()

/// 0 值直接显示 "0 KB"（系统格式化会输出 "Zero KB"）
private func cleanSizeText(_ bytes: Int64) -> String {
    bytes == 0 ? "0 KB" : cleanByteFormatter.string(fromByteCount: bytes)
}

// MARK: - 主视图

struct CleanView: View {
    @StateObject private var vm: CleanViewModel
    @State private var confirmClean = false

    init(server: ServerConfig) {
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(key: ManageItem.clean.storeKey(server: server)) {
            CleanViewModel(server: server)
        })
    }

    private var summary: (count: Int, size: Int64) { vm.selectionSummary }

    var body: some View {
        Group {
            if vm.isLoading && vm.scan == nil {
                LoadingStateView()
            } else if let scan = vm.scan {
                scanList(scan)
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
        .navigationTitle(L10n.t("缓存清理"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    confirmClean = true
                } label: {
                    if vm.isCleaning {
                        ProgressView()
                    } else {
                        Text(L10n.f("清理（%ld）", summary.count)).bold()
                    }
                }
                .disabled(summary.count == 0 || vm.isCleaning)
            }
        }
        .refreshable { await vm.load() }
        .task { await PageVMStore.shared.autoRefresh(vm: vm) { await vm.load() } }
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .alert(L10n.t("清理"), isPresented: $confirmClean) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("清理"), role: .destructive) {
                Haptic.warning()
                Task { await vm.clean() }
            }
        } message: {
            Text(L10n.f(
                "将清理 %ld 项垃圾文件，释放 %@ 磁盘空间。此操作不可恢复，是否继续？",
                summary.count,
                cleanSizeText(summary.size)))
        }
    }

    @ViewBuilder
    private func scanList(_ scan: CleanScanResponse) -> some View {
        List {
            categorySection(L10n.t("系统垃圾"), icon: "archivebox", nodes: scan.systemClean)
            categorySection(L10n.t("系统备份"), icon: "externaldrive.badge.icloud", nodes: scan.backupClean)
            categorySection(L10n.t("容器垃圾"), icon: "shippingbox", nodes: scan.containerClean)
            categorySection(L10n.t("临时上传文件"), icon: "icloud.and.arrow.up", nodes: scan.uploadClean)
            categorySection(L10n.t("临时下载文件"), icon: "icloud.and.arrow.down", nodes: scan.downloadClean)
            categorySection(L10n.t("日志文件"), icon: "doc.plaintext", nodes: scan.systemLogClean)
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func categorySection(_ title: String, icon: String, nodes: [CleanNode]?) -> some View {
        if let nodes, !nodes.isEmpty {
            Section {
                ForEach(nodes) { node in
                    CleanNodeRow(node: node, depth: 0, vm: vm)
                }
            } header: {
                SectionLabel(title: title, systemImage: icon)
            }
        }
    }
}

// MARK: - 树形节点行

struct CleanNodeRow: View {
    let node: CleanNode
    let depth: Int
    @ObservedObject var vm: CleanViewModel

    /// 分类默认收起，点开逐层查看
    @State private var expanded = false

    private var hasChildren: Bool {
        !(node.children ?? []).isEmpty
    }

    var body: some View {
        if hasChildren {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(node.children ?? []) { child in
                    CleanNodeRow(node: child, depth: depth + 1, vm: vm)
                }
            } label: {
                labelView
            }
        } else {
            labelView
        }
    }

    private var labelView: some View {
        HStack(spacing: 10) {
            checkBox

            VStack(alignment: .leading, spacing: 3) {
                Text(Self.displayTitle(node))
                    .font(.subheadline)
                    .lineLimit(1)
                if let name = node.name, !name.isEmpty, name != node.label {
                    Text(name)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if node.isRecommend == true {
                StatusBadge(text: L10n.t("推荐"), color: .green)
            }
            Text(cleanSizeText(node.size ?? 0))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    /// 勾选框：canDelete 才可交互；目录三态显示
    private var checkBox: some View {
        let state = vm.checkState(node)
        let icon: String
        let color: Color
        switch state {
        case .all: icon = "checkmark.circle.fill"; color = .accentColor
        case .partial: icon = "minus.circle.fill"; color = .accentColor
        case .none: icon = "circle"; color = .secondary
        case .disabled: icon = "circle"; color = Color.gray.opacity(0.35)
        }
        return Button {
            Haptic.selection()
            vm.toggle(node)
        } label: {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(color)
        }
        .buttonStyle(.borderless)
        .disabled(state == .disabled)
        .accessibilityLabel(L10n.t("选择"))
    }

    /// 服务端 label → 中文标题；未映射的（文件名/目录名/网站名）原样展示
    static func displayTitle(_ node: CleanNode) -> String {
        guard let label = node.label, !label.isEmpty else { return "—" }
        switch label {
        case "1panel_original": return L10n.t("系统快照恢复前备份文件")
        case "upgrade": return L10n.t("系统升级备份文件")
        case "agent_packages": return L10n.t("历史版本子节点升级 / 安装包")
        case "rollback": return L10n.t("恢复前备份目录")
        case "tmp_backup": return L10n.t("临时备份")
        case "unknown_app": return L10n.t("未关联应用备份")
        case "unknown_database": return L10n.t("未关联数据库备份")
        case "unknown_website": return L10n.t("未关联网站备份")
        case "unknown_snapshot": return L10n.t("未关联快照备份")
        case "unknown_website_log": return L10n.t("未关联网站日志备份文件")
        case "container_images": return L10n.t("镜像")
        case "container_containers": return L10n.t("容器")
        case "container_volumes": return L10n.t("存储卷")
        case "build_cache": return L10n.t("构建缓存")
        case "system_log": return L10n.t("系统日志")
        case "task_log": return L10n.t("任务日志")
        case "website_log": return L10n.t("网站日志")
        default: return label
        }
    }
}
