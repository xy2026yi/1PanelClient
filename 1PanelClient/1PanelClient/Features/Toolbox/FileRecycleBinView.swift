//
//  FileRecycleBinView.swift
//  1PanelClient
//
//  文件回收站：启用状态开关 + 已删文件列表（还原 / 删除 / 清空）。
//  接口对齐网页端抓包（0909）：
//  - GET  files/recycle/status           → "Enable"/"Disable"
//  - POST settings/update                → FileRecycleBin Enable/Disable
//  - POST files/recycle/search           → {page, pageSize} 分页
//  - POST files/recycle/reduce           → {from, rName, name} 还原
//  - POST files/del                      → path=from/rName, forceDelete=true
//  - POST files/recycle/clear            → 清空
//

import SwiftUI

// MARK: - 请求模型

struct RecycleSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
}

struct RecycleSearchResponse: Decodable {
    let total: Int
    let items: [RecycleItem]?
}

/// 回收站内文件（search 返回的 items 元素）
struct RecycleItem: Decodable, Identifiable {
    let name: String?
    let size: Int64?
    let type: String?
    let deleteTime: String?
    /// 回收站内的物理文件名（uuid 重命名后）
    let rName: String?
    /// 删除前的原路径
    let sourcePath: String?
    let isDir: Bool?
    /// 回收站内的存放目录（如 /.1panel_clash/files）
    let from: String?

    var id: String { rName ?? sourcePath ?? name ?? UUID().uuidString }

    /// 还原请求路径（from + rName）
    var recyclePath: String {
        let base = from ?? ""
        guard let rn = rName, !rn.isEmpty else { return base }
        return base.hasSuffix("/") ? base + rn : base + "/" + rn
    }

    /// 删除时间格式化（yyyy-MM-dd HH:mm）
    var displayDeleteTime: String {
        guard let t = deleteTime, !t.isEmpty else { return "—" }
        return String(t.prefix(19)).replacingOccurrences(of: "T", with: " ")
    }

    var isFolder: Bool { isDir ?? (type == "dir") }
}

struct RecycleReduceRequest: Encodable {
    let from: String
    let rName: String
    let name: String
}

struct RecycleSettingUpdateRequest: Encodable {
    let key: String
    let value: String
}

// MARK: - 回收站页

struct FileRecycleBinView: View {
    let server: ServerConfig

    @State private var items: [RecycleItem] = []
    @State private var total = 0
    @State private var page = 1
    @State private var isLoading = false
    @State private var isLoadingMore = false
    /// 回收站启用状态（nil=尚未取到）
    @State private var isEnabled: Bool?
    @State private var isToggling = false
    @State private var isClearing = false
    /// 待确认还原 / 删除 / 清空
    @State private var reducingItem: RecycleItem?
    @State private var deletingItem: RecycleItem?
    @State private var showClearConfirm = false
    @State private var errorMessage: String?

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
            } else if let errorMessage, items.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button(L10n.t("重试")) { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
            } else if items.isEmpty {
                ContentUnavailableView(
                    L10n.t("回收站为空"),
                    systemImage: "trash.slash",
                    description: Text(L10n.t("删除的文件将在此显示，可还原或彻底删除"))
                )
            } else {
                recycleList
            }
        }
        .navigationTitle(L10n.t("回收站"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showClearConfirm = true
                } label: {
                    if isClearing {
                        ProgressView()
                    } else {
                        Text(L10n.t("清空"))
                    }
                }
                .disabled(items.isEmpty || isClearing)
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .alert(L10n.t("还原"), isPresented: Binding(
            get: { reducingItem != nil },
            set: { if !$0 { reducingItem = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { reducingItem = nil }
            Button(L10n.t("还原")) {
                if let item = reducingItem {
                    reducingItem = nil
                    Task { await reduce(item) }
                }
            }
        } message: {
            Text(L10n.t("如果原路径存在同名文件或目录，将会被覆盖，是否继续？"))
        }
        .alert(L10n.t("确认删除"), isPresented: Binding(
            get: { deletingItem != nil },
            set: { if !$0 { deletingItem = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { deletingItem = nil }
            Button(L10n.t("删除"), role: .destructive) {
                Haptic.warning()
                if let item = deletingItem {
                    deletingItem = nil
                    Task { await deleteFromRecycle(item) }
                }
            }
        } message: {
            if let item = deletingItem {
                Text(L10n.f("确定要彻底删除 \"%@\" 吗？删除后不可恢复。", item.name ?? "—"))
            }
        }
        .alert(L10n.t("清空回收站"), isPresented: $showClearConfirm) {
            Button(L10n.t("取消"), role: .cancel) { showClearConfirm = false }
            Button(L10n.t("删除"), role: .destructive) {
                Haptic.warning()
                showClearConfirm = false
                Task { await clearAll() }
            }
        } message: {
            Text(L10n.t("删除 操作不可回滚，是否继续？"))
        }
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { errorMessage != nil && !items.isEmpty },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - 列表

    private var recycleList: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { isEnabled ?? false },
                    set: { on in Task { await toggleRecycle(on) } }
                )) {
                    Label(L10n.t("启用回收站"), systemImage: "trash")
                }
                .disabled(isToggling || isEnabled == nil)
            } footer: {
                if isEnabled == false {
                    Text(L10n.t("回收站已停用：新删除的文件将不进入回收站，直接删除。"))
                } else {
                    Text(L10n.t("停用后删除文件将不进入回收站；已回收的文件仍可还原或删除。"))
                }
            }

            Section {
                ForEach(items) { item in
                    RecycleRow(item: item)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                reducingItem = item
                            } label: {
                                Label(L10n.t("还原"), systemImage: "arrow.uturn.backward")
                            }
                            .tint(.green)
                            Button(role: .destructive) {
                                deletingItem = item
                            } label: {
                                Label(L10n.t("删除"), systemImage: "trash")
                            }
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
                SectionLabel(title: L10n.f("已删除（%ld）", total), systemImage: "trash")
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - 数据

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        async let status: () = loadStatus()
        async let list: () = loadFirstPage()
        _ = await (status, list)
    }

    /// 启用状态（GET recycle/status，data 直接为 "Enable"/"Disable"）
    private func loadStatus() async {
        do {
            let value: String = try await client.send(
                path: APIEndpoint.filesRecycleStatus.path,
                method: APIEndpoint.filesRecycleStatus.method,
                as: String.self
            )
            isEnabled = value == "Enable"
        } catch {
            // 状态失败不阻断列表，Toggle 保持禁用
            isEnabled = nil
        }
    }

    private func loadFirstPage() async {
        let req = RecycleSearchRequest(page: 1, pageSize: pageSize)
        do {
            let resp: RecycleSearchResponse = try await client.send(
                path: APIEndpoint.filesRecycleSearch.path, body: req,
                as: RecycleSearchResponse.self
            )
            items = resp.items ?? []
            total = resp.total
            page = 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard items.count < total, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let req = RecycleSearchRequest(page: page + 1, pageSize: pageSize)
        do {
            let resp: RecycleSearchResponse = try await client.send(
                path: APIEndpoint.filesRecycleSearch.path, body: req,
                as: RecycleSearchResponse.self
            )
            let existing = Set(items.map(\.id))
            let newItems = (resp.items ?? []).filter { !existing.contains($0.id) }
            items += newItems
            if newItems.isEmpty {
                total = items.count
                return
            }
            total = resp.total
            page += 1
        } catch {
            // 追加失败不打断列表，下拉刷新可重试
        }
    }

    /// 启用/停用（settings/update FileRecycleBin）
    private func toggleRecycle(_ on: Bool) async {
        isToggling = true
        defer { isToggling = false }
        let req = RecycleSettingUpdateRequest(key: "FileRecycleBin", value: on ? "Enable" : "Disable")
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.settingsUpdate.path, body: req, as: EmptyResponse.self
            )
            isEnabled = on
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 还原（reduce：from/rName/name）
    private func reduce(_ item: RecycleItem) async {
        guard let rName = item.rName, let name = item.name, let from = item.from else { return }
        let req = RecycleReduceRequest(from: from, rName: rName, name: name)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.filesRecycleReduce.path, body: req, as: EmptyResponse.self
            )
            items.removeAll { $0.id == item.id }
            total = max(0, total - 1)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 彻底删除回收站内文件（files/del：path=from/rName，forceDelete=true）
    private func deleteFromRecycle(_ item: RecycleItem) async {
        let req = FileDeleteRequest(path: item.recyclePath, isDir: item.isFolder, forceDelete: true)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.filesDel.path, body: req, as: EmptyResponse.self
            )
            items.removeAll { $0.id == item.id }
            total = max(0, total - 1)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 清空回收站
    private func clearAll() async {
        isClearing = true
        defer { isClearing = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.filesRecycleClear.path, as: EmptyResponse.self
            )
            items = []
            total = 0
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 行

/// 回收站行：原文件名 / 原路径 / 删除时间 + 大小
private struct RecycleRow: View {
    let item: RecycleItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: item.isFolder ? "folder.fill" : "doc")
                    .foregroundStyle(item.isFolder ? Color.blue : Color.secondary)
                Text(item.name ?? "—")
                    .font(.subheadline.bold())
                    .lineLimit(1)
            }
            if let src = item.sourcePath, !src.isEmpty {
                Text(src)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 8) {
                Text(item.displayDeleteTime)
                if !item.isFolder, let size = item.size, size > 0 {
                    Text(RecycleSizeFormatter.format(size))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// 回收站大小展示（与文件页 formatSize 一致口径）
private enum RecycleSizeFormatter {
    static func format(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(bytes)
        var idx = 0
        while size >= 1024 && idx < units.count - 1 {
            size /= 1024
            idx += 1
        }
        return String(format: "%.1f %@", size, units[idx])
    }
}
