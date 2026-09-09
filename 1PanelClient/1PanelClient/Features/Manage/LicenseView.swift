//
//  LicenseView.swift
//  1PanelClient
//
//  许可证管理（设置 Hub 子页）：列表 / 上传授权文件 / 绑定 / 解绑 / 删除 / 同步。
//  接口对齐网页端抓包（0909）：licenses/search|upload|bind|unbind|del|sync，
//  绑定节点下拉来自 nodes/list。
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - 请求模型

struct LicenseSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
}

struct LicenseUnbindRequest: Encodable {
    let id: Int
    let withDockerRestart: Bool
}

struct LicenseBindRequest: Encodable {
    let licenseID: Int
    let nodeID: Int
    let syncList: String
    let withDockerRestart: Bool
}

struct LicenseIDRequest: Encodable {
    let id: Int
}

// MARK: - 响应模型

/// 许可证条目（licenses/search 返回的 items 元素）
struct LicenseItem: Decodable, Identifiable {
    let id: Int
    let createdAt: String?
    let licenseName: String?
    let assigneeName: String?
    /// "all" = 全部版本
    let versionConstraint: String?
    /// "no" = 正式版 / "yes" = 试用
    let trial: String?
    /// "Bound" 已绑定 / "Free" 未绑定
    let status: String?
    let message: String?
    let productPro: String?
    /// unix 秒（字符串）
    let lastSyncAt: String?
    let bindCount: Int?
    let freeCount: Int?
    let bindNode: String?
    let freeNodes: [LicenseNode]?
    let smsTotal: Int?
    let smsUsed: Int?

    var isBound: Bool { status == "Bound" }

    /// 创建时间（yyyy-MM-dd HH:mm）
    var displayCreatedAt: String {
        guard let t = createdAt, !t.isEmpty else { return "—" }
        return String(t.prefix(19)).replacingOccurrences(of: "T", with: " ")
    }

    /// 最近同步时间（unix 秒 → yyyy-MM-dd HH:mm）
    var displayLastSync: String? {
        guard let raw = lastSyncAt, let ts = TimeInterval(raw), ts > 0 else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}

/// 许可证可用节点（freeNodes 元素；与 nodes/list 同构，仅取绑定需要的字段）
struct LicenseNode: Decodable, Identifiable {
    let id: Int
    let name: String?
    let alias: String?
    let addr: String?
    let isBound: Bool?

    var displayName: String {
        (alias?.isEmpty == false ? alias : name) ?? "node-\(id)"
    }
}

// MARK: - 许可证页

struct LicenseView: View {
    let server: ServerConfig

    @State private var items: [LicenseItem] = []
    @State private var total = 0
    @State private var page = 1
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var loadError: String?
    /// 长按弹出的行操作菜单对应条目
    @State private var actionItem: LicenseItem?
    /// 待确认解绑 / 删除
    @State private var unbindingItem: LicenseItem?
    @State private var deletingItem: LicenseItem?
    /// 绑定表单（Free 状态条目）
    @State private var bindingItem: LicenseItem?
    /// 操作结果轻提示 / 错误提示
    @State private var toast: String?
    @State private var errorText: String?
    @State private var isOperating = false
    @State private var showUploadPicker = false

    private let pageSize = 20
    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                LoadingStateView()
            } else if let loadError, items.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(loadError)
                } actions: {
                    Button(L10n.t("重试")) { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
            } else if items.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无许可证"),
                    systemImage: "checkmark.seal",
                    description: Text(L10n.t("点击右上角 + 上传授权文件"))
                )
            } else {
                licenseList
            }
        }
        .navigationTitle(L10n.t("许可证"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showUploadPicker = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("上传授权文件"))
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .fileImporter(
            isPresented: $showUploadPicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await uploadLicense(url) }
            }
        }
        // 长按行操作：绑定(Free)/解绑(Bound)/同步/删除
        .sheet(item: $actionItem) { item in
            ActionBottomSheet(
                title: item.licenseName ?? "—",
                items: actionMenuItems(for: item),
                onDismiss: { actionItem = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: item.isBound ? 2 : 3))])
            .presentationDragIndicator(.visible)
        }
        // 绑定表单（节点下拉）
        .sheet(item: $bindingItem) { item in
            LicenseBindSheet(item: item, client: client) { nodeID in
                bindingItem = nil
                Task { await bind(item, nodeID: nodeID) }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .alert(L10n.t("解绑许可证"), isPresented: Binding(
            get: { unbindingItem != nil },
            set: { if !$0 { unbindingItem = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { unbindingItem = nil }
            Button(L10n.t("解绑"), role: .destructive) {
                Haptic.warning()
                if let item = unbindingItem {
                    unbindingItem = nil
                    Task { await unbind(item) }
                }
            }
        } message: {
            Text(L10n.t("解绑后专业版功能将不可用，绑定节点上的数据不会删除。"))
        }
        .alert(L10n.t("删除许可证"), isPresented: Binding(
            get: { deletingItem != nil },
            set: { if !$0 { deletingItem = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { deletingItem = nil }
            Button(L10n.t("删除"), role: .destructive) {
                Haptic.warning()
                if let item = deletingItem {
                    deletingItem = nil
                    Task { await delete(item) }
                }
            }
        } message: {
            Text(L10n.t("确定删除该许可证吗？已绑定的许可证需先解绑。"))
        }
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .toastOverlay(message: $toast)
    }

    private var licenseList: some View {
        List {
            Section {
                ForEach(items) { item in
                    LicenseRow(item: item)
                        .onLongPressGesture(minimumDuration: 0.5) {
                            Haptic.selection()
                            actionItem = item
                        }
                        .onAppear {
                            if item.id == items.last?.id {
                                Task { await loadMore() }
                            }
                        }
                }
                if items.count < total || isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .onAppear { Task { await loadMore() } }
                }
            } header: {
                SectionLabel(title: L10n.f("许可证（%ld）", max(total, items.count)), systemImage: "checkmark.seal")
            }
        }
        .listStyle(.insetGrouped)
    }

    /// 长按菜单项：状态相关（Free=绑定 / Bound=解绑）+ 同步 + 删除
    private func actionMenuItems(for item: LicenseItem) -> [ActionMenuItem] {
        var items: [ActionMenuItem] = []
        if item.isBound {
            items.append(ActionMenuItem(title: L10n.t("解绑"), icon: "arrow.uturn.backward.circle", color: .orange) {
                delayedMenuAction { unbindingItem = item }
            })
        } else {
            items.append(ActionMenuItem(title: L10n.t("绑定节点"), icon: "link.badge.plus", color: .green) {
                delayedMenuAction { bindingItem = item }
            })
        }
        items.append(ActionMenuItem(title: L10n.t("同步"), icon: "arrow.triangle.2.circlepath", color: .blue) {
            delayedMenuAction { Task { await sync(item) } }
        })
        items.append(ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red, role: .destructive) {
            delayedMenuAction { deletingItem = item }
        })
        return items
    }

    /// 等 ActionBottomSheet 收起后再触发下一级呈现（sheet/alert 竞争）
    private func delayedMenuAction(_ action: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.35))
            action()
        }
    }

    // MARK: - 数据

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let req = LicenseSearchRequest(page: 1, pageSize: pageSize)
        do {
            let resp: PageResponse<LicenseItem> = try await client.send(
                path: APIEndpoint.licensesSearch.path, body: req,
                as: PageResponse<LicenseItem>.self
            )
            guard !Task.isCancelled else { return }
            items = resp.items ?? []
            total = resp.total ?? resp.items?.count ?? 0
            page = 1
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error), !Task.isCancelled else { return }
            if items.isEmpty { loadError = error.localizedDescription }
        }
    }

    private func loadMore() async {
        guard items.count < total, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let req = LicenseSearchRequest(page: page + 1, pageSize: pageSize)
        do {
            let resp: PageResponse<LicenseItem> = try await client.send(
                path: APIEndpoint.licensesSearch.path, body: req,
                as: PageResponse<LicenseItem>.self
            )
            let existing = Set(items.map(\.id))
            let newItems = (resp.items ?? []).filter { !existing.contains($0.id) }
            if newItems.isEmpty {
                total = items.count
                return
            }
            items += newItems
            total = resp.total ?? total
            page += 1
        } catch {
            // 追加失败不打断列表，下拉刷新可重试
        }
    }

    /// 上传授权文件（multipart；网页端仅文件字段无其他表单值）
    private func uploadLicense(_ url: URL) async {
        isOperating = true
        defer { isOperating = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            try await client.uploadMultipart(
                path: APIEndpoint.licensesUpload.path,
                fields: [:],
                fileFieldName: "file",
                fileName: url.lastPathComponent,
                mimeType: "application/octet-stream",
                fileData: data
            )
            toast = L10n.t("授权文件已上传")
            await load()
        } catch {
            errorText = L10n.f("上传失败：%@", error.localizedDescription)
        }
    }

    /// 绑定节点（syncList 对齐网页端固定四项）
    private func bind(_ item: LicenseItem, nodeID: Int) async {
        isOperating = true
        defer { isOperating = false }
        let req = LicenseBindRequest(
            licenseID: item.id, nodeID: nodeID,
            syncList: "SyncSystemProxy,SyncAlertSetting,SyncCustomApp,SyncBackupAccounts",
            withDockerRestart: false
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.licensesBind.path, body: req, as: EmptyResponse.self
            )
            toast = L10n.t("已绑定")
            await load()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func unbind(_ item: LicenseItem) async {
        isOperating = true
        defer { isOperating = false }
        let req = LicenseUnbindRequest(id: item.id, withDockerRestart: false)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.licensesUnbind.path, body: req, as: EmptyResponse.self
            )
            toast = L10n.t("已解绑")
            await load()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func delete(_ item: LicenseItem) async {
        isOperating = true
        defer { isOperating = false }
        let req = LicenseIDRequest(id: item.id)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.licensesDel.path, body: req, as: EmptyResponse.self
            )
            items.removeAll { $0.id == item.id }
            total = max(0, total - 1)
            toast = L10n.t("已删除")
        } catch {
            // 服务端会拒绝删除已绑定许可证（需先解绑）：展示 message
            errorText = error.localizedDescription
        }
    }

    private func sync(_ item: LicenseItem) async {
        isOperating = true
        defer { isOperating = false }
        let req = LicenseIDRequest(id: item.id)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.licensesSync.path, body: req, as: EmptyResponse.self
            )
            toast = L10n.t("已同步")
            await load()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - 许可证行

private struct LicenseRow: View {
    let item: LicenseItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(item.licenseName ?? "—")
                    .font(.system(.body, design: .monospaced).bold())
                    .lineLimit(1)
                Spacer()
                StatusBadge(
                    text: item.isBound ? L10n.t("已绑定") : L10n.t("未绑定"),
                    color: item.isBound ? .statusRunning : .orange
                )
                if item.trial == "yes" {
                    StatusBadge(text: L10n.t("试用"), color: .purple)
                }
            }

            HStack(spacing: 12) {
                if let assignee = item.assigneeName, !assignee.isEmpty {
                    Label(assignee, systemImage: "person.crop.circle")
                }
                if let vc = item.versionConstraint, !vc.isEmpty {
                    Label(vc == "all" ? L10n.t("全部版本") : vc, systemImage: "shippingbox")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if item.isBound, let node = item.bindNode, !node.isEmpty {
                Label(L10n.f("绑定节点：%@", node), systemImage: "server.rack")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 节点配额：bindCount 已绑定 / freeCount 可用（0/0 时无意义不显示）
            if (item.bindCount ?? 0) + (item.freeCount ?? 0) > 0 {
                Label(
                    L10n.f("社区版: %ld/%ld", item.bindCount ?? 0, item.freeCount ?? 0),
                    systemImage: "person.2"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Text(L10n.f("创建：%@", item.displayCreatedAt))
                if let sync = item.displayLastSync {
                    Text(L10n.f("同步：%@", sync))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if let sms = item.smsTotal, sms > 0 {
                Text(L10n.f("短信：已用 %ld / %ld", item.smsUsed ?? 0, sms))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let msg = item.message, !msg.isEmpty {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 绑定表单（节点下拉）

private struct LicenseBindSheet: View {
    let item: LicenseItem
    let client: APIClient
    let onConfirm: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nodes: [LicenseNode] = []
    @State private var selectedNodeID: Int?
    @State private var isLoading = true
    @State private var loadFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isLoading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if loadFailed {
                        Text(L10n.t("节点列表加载失败，请重试"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button(L10n.t("重试")) { Task { await loadNodes() } }
                    } else {
                        Picker(L10n.t("绑定节点"), selection: Binding(
                            get: { selectedNodeID ?? nodes.first?.id ?? 0 },
                            set: { selectedNodeID = $0 }
                        )) {
                            ForEach(nodes) { node in
                                Text(node.displayName + " (\(node.addr ?? ""))").tag(node.id)
                            }
                        }
                    }
                } header: {
                    Text(L10n.t(item.licenseName ?? ""))
                } footer: {
                    Text(L10n.t("绑定后自动同步系统代理 / 告警设置 / 自定义应用 / 备份账号。"))
                }
            }
            .navigationTitle(L10n.t("绑定节点"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("绑定")) {
                        onConfirm(selectedNodeID ?? nodes.first?.id ?? 0)
                    }
                    .disabled(isLoading || loadFailed || nodes.isEmpty)
                }
            }
            .task { await loadNodes() }
        }
    }

    /// 可绑定节点（nodes/list type=all；与网页端下拉一致）
    private func loadNodes() async {
        isLoading = true
        loadFailed = false
        defer { isLoading = false }
        do {
            let list: [LicenseNode] = try await client.send(
                path: APIEndpoint.nodesList.path,
                body: NodeListRequest(type: "all"),
                as: [LicenseNode].self
            )
            nodes = list
            if selectedNodeID == nil {
                selectedNodeID = list.first?.id
            }
        } catch {
            loadFailed = true
        }
    }
}
