//
//  FilesTransferViews.swift
//  1PanelClient
//
//  弹窗/Sheet 集中 ViewModifier + 上传/下载传输状态与进度（自 FilesView.swift 拆出，内容未改动）
//

import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - 弹窗/Sheet 集合（抽离为 ViewModifier 以减轻 body 类型推断负担）

/// 集中管理 FilesView 的 sheet 与 alert，避免 body 过长导致编译器无法类型推断。
struct FilesDialogsModifier: ViewModifier {
    @Binding var showCreate: Bool
    let createIsDir: Bool
    let currentPath: String
    @Binding var renamingItem: FileItem?
    @Binding var deletingItem: FileItem?
    @Binding var showPathInput: Bool
    @Binding var pathInput: String
    @Binding var successMessage: String?
    @Binding var errorMessage: String?
    let reload: () -> Void
    let jumpTo: (String) -> Void
    let deleteItem: (FileItem, Bool) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showCreate) {
                FileCreateSheet(isDir: createIsDir, currentPath: currentPath, onCreated: reload)
            }
            .sheet(item: $renamingItem) { item in
                FileRenameSheet(item: item, onRenamed: reload)
            }
            // 删除确认带「永久删除」勾选项（系统 alert 放不下 Toggle，用 sheet）
            .sheet(item: $deletingItem) { item in
                FileDeleteConfirmSheet(item: item) { forceDelete in
                    deleteItem(item, forceDelete)
                }
                .bottomSheetDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .alert(L10n.t("前往路径"), isPresented: $showPathInput) {
                OutlinedTextField(label: L10n.t("路径"), text: $pathInput, keyboardType: .URL)
                Button(L10n.t("取消"), role: .cancel) { }
                Button(L10n.t("前往")) {
                    let target = pathInput.trimmingCharacters(in: .whitespaces)
                    if !target.isEmpty { jumpTo(target) }
                }
            }
            .alert(L10n.t("提示"), isPresented: Binding(
                get: { successMessage != nil || errorMessage != nil },
                set: { _ in successMessage = nil; errorMessage = nil }
            )) {
                Button(L10n.t("好的"), role: .cancel) { successMessage = nil; errorMessage = nil }
            } message: {
                Text(errorMessage ?? successMessage ?? "")
            }
    }
}

// MARK: - 上传/下载传输状态与进度视图

/// 一次上传/下载任务的状态（驱动 TransferSheet 展示）
struct TransferState: Identifiable {
    enum Status { case running, done, failed }
    let id = UUID()
    let kind: String          // "上传" / "下载"
    var fileName: String
    var progress: Double = 0  // 0...1；-1 表示总大小未知（转圈）
    var received: Int64 = 0
    var total: Int64 = 0
    var status: Status = .running
    var errorText: String?
    /// 下载完成后的本地文件 URL（用于分享）
    var localURL: URL?
}

/// 上传/下载进度弹窗：进度条 + 已传大小 + 取消/分享/关闭
struct TransferSheet: View {
    let state: TransferState
    let onCancel: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: statusIcon)
                .font(.panelScaled(44))
                .foregroundStyle(statusColor)

            VStack(spacing: 6) {
                Text("\(state.kind)\(state.status == .running ? "中" : "")")
                    .font(.headline)
                Text(state.fileName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if state.status == .done, state.localURL != nil {
                    Text(L10n.t("已保存到「文件」App · 我的 iPhone/1PanelClient"))
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            if state.status == .running {
                if state.progress >= 0 {
                    ProgressView(value: state.progress)
                        .padding(.horizontal, 30)
                    Text("\(Int(state.progress * 100))%  \(fmt(state.received)) / \(fmt(state.total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            } else if state.status == .failed, let err = state.errorText {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer(minLength: 0)

            // 操作按钮
            VStack(spacing: 12) {
                if state.status == .running {
                    Button(role: .destructive) {
                        onCancel()
                    } label: {
                        Text(L10n.t("取消传输"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                }
                if state.status == .done, let url = state.localURL {
                    ShareLink(item: url) {
                        Label(L10n.t("分享 / 另存为"), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                }
                if state.status != .running {
                    Button {
                        onClose()
                    } label: {
                        Text(L10n.t("关闭"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 30)
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .bottomSheetDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var statusIcon: String {
        switch state.status {
        case .running: return state.kind == L10n.t("上传") ? "arrow.up.circle" : "arrow.down.circle"
        case .done:    return "checkmark.circle.fill"
        case .failed:  return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch state.status {
        case .running: return .accentColor
        case .done:    return .green
        case .failed:  return .red
        }
    }

    private func fmt(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var size = Double(bytes)
        var idx = 0
        while size >= 1024 && idx < units.count - 1 {
            size /= 1024
            idx += 1
        }
        return String(format: "%.1f %@", size, units[idx])
    }
}

/// 上传选择器 + 传输进度弹窗（独立 ViewModifier 以控制 body 复杂度）
struct FilesTransferModifier: ViewModifier {
    @Binding var showUploadPicker: Bool
    @Binding var showFolderPicker: Bool
    @Binding var transfer: TransferState?
    let onPickFiles: (Result<[URL], Error>) -> Void
    let onPickFolder: (Result<[URL], Error>) -> Void
    let onCancel: () -> Void
    let onClose: () -> Void

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $showUploadPicker,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true,
                onCompletion: onPickFiles
            )
            .fileImporter(
                isPresented: $showFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false,
                onCompletion: onPickFolder
            )
            .sheet(item: $transfer) { state in
                TransferSheet(state: state, onCancel: onCancel, onClose: onClose)
            }
    }
}

// MARK: - 创建文件/文件夹

struct FileCreateSheet: View {
    let isDir: Bool
    let currentPath: String
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let client: APIClient

    init(isDir: Bool, currentPath: String, onCreated: @escaping () -> Void) {
        self.isDir = isDir
        self.currentPath = currentPath
        self.onCreated = onCreated
        self.client = APIClient.shared(for: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(isDir ? L10n.t("文件夹名称") : L10n.t("文件名称")) {
                    TextField(isDir ? "folder_name" : "file.txt", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle(isDir ? L10n.t("新建文件夹") : L10n.t("新建文件"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("创建")) {
                        Task { await create() }
                    }
                    .disabled(isSaving || name.isEmpty)
                }
            }
            .alert(L10n.t("错误"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(L10n.t("好的"), role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func create() async {
        isSaving = true
        let fullPath = currentPath.hasSuffix("/") ? "\(currentPath)\(name)" : "\(currentPath)/\(name)"
        let req = FileCreateRequest(
            path: fullPath, name: name,
            isDir: isDir, isLink: false, isSymlink: false, linkPath: ""
        )
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.filesCreate.path, body: req, as: EmptyResponse.self)
            onCreated()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

// MARK: - 重命名

struct FileRenameSheet: View {
    let item: FileItem
    let onRenamed: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let client: APIClient

    init(item: FileItem, onRenamed: @escaping () -> Void) {
        self.item = item
        self.onRenamed = onRenamed
        self.client = APIClient.shared(for: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
    }

    var body: some View {
        NavigationStack {
            Form {
                // 无分组标题；字段标签即原分组名（当前名称 / 新名称）
                Section {
                    // 当前名称只读：描边框 + 锁标识
                    OutlinedShape(label: L10n.t("当前名称"), isFocused: false,
                                  hasValue: !item.name.isEmpty,
                                  trailing: {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }) {
                        Text(item.name)
                            .lineLimit(1)
                    }
                    OutlinedTextField(label: L10n.t("新名称"), text: $newName)
                        .onSubmit { Task { await rename() } }
                }
            }
            .navigationTitle(L10n.t("重命名"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { newName = item.name }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("保存")) {
                        Task { await rename() }
                    }
                    .disabled(isSaving || newName.isEmpty || newName == item.name)
                }
            }
            .alert(L10n.t("错误"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(L10n.t("好的"), role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func rename() async {
        isSaving = true
        let dir = (item.path as NSString).deletingLastPathComponent
        let newPath = dir == "/" ? "/\(newName)" : "\(dir)/\(newName)"
        let req = FileRenameRequest(newName: newPath, path: dir, oldName: item.path)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.filesRename.path, body: req, as: EmptyResponse.self)
            onRenamed()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

// MARK: - 删除确认（带「永久删除」勾选项）

/// 删除文件/文件夹确认：默认进回收站，勾选「永久删除」后直接删除
/// （files/del 的 forceDelete）。系统 alert 放不下 Toggle，用半屏 sheet。
struct FileDeleteConfirmSheet: View {
    let item: FileItem
    /// 确认回调（forceDelete = 是否勾选永久删除）
    let onDelete: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var forceDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name)
                            .font(.dataMonospacedHeadline)
                            .lineLimit(2)
                        Text(item.isDir ? L10n.t("文件夹") : L10n.t("文件"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle(isOn: $forceDelete) {
                        Label(L10n.t("永久删除文件（不进入回收站，直接删除）"), systemImage: "trash.slash")
                    }
                } footer: {
                    Text(L10n.t("不勾选时移入服务器回收站，可在回收站中还原。"))
                }
            }
            .navigationTitle(L10n.t("确认删除"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("删除"), role: .destructive) {
                        Haptic.warning()
                        dismiss()
                        onDelete(forceDelete)
                    }
                }
            }
        }
    }
}

// MARK: - 收藏夹（files/favorite/search）

/// 收藏夹列表：点按跳转对应路径（目录 → 本身；文件 → 父目录，网页端行为），
/// 左滑取消收藏
struct FileFavoriteView: View {
    let server: ServerConfig
    /// 跳转目标（父级 FilesView 负责回退并 loadDir）
    var onOpen: (String) -> Void

    @State private var favorites: [FileFavorite] = []
    @State private var isLoading = true
    @State private var loadError: String?
    /// 分页：滚动到底自动追加（收藏超过首页 200 条时不再截断）
    @State private var total = 0
    @State private var page = 1
    @State private var isLoadingMore = false
    private static let pageSize = 200

    private let client: APIClient

    init(server: ServerConfig, onOpen: @escaping (String) -> Void) {
        self.server = server
        self.onOpen = onOpen
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); LoadingStateView(); Spacer() }
                    .listRowBackground(Color.clear)
            } else if let err = loadError {
                LoadErrorStateView(message: err) {
                    Task { await load() }
                }
                .listRowBackground(Color.clear)
            } else if favorites.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无收藏"),
                    systemImage: "star",
                    description: Text(L10n.t("长按文件或文件夹添加到收藏"))
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(favorites) { fav in
                    Button {
                        openFavorite(fav)
                    } label: {
                        favoriteRow(fav)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task { await remove(fav) }
                        } label: {
                            Label(L10n.t("取消收藏"), systemImage: "star.slash")
                        }
                    }
                    .onAppear {
                        if fav.id == favorites.last?.id {
                            Task { await loadMore() }
                        }
                    }
                }
                if favorites.count < total || isLoadingMore {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .onAppear { Task { await loadMore() } }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("收藏夹"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func favoriteRow(_ fav: FileFavorite) -> some View {
        HStack(spacing: 10) {
            Image(systemName: (fav.isDir == true) ? "folder.fill" : "doc")
                .foregroundStyle((fav.isDir == true) ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(fav.name ?? (fav.path ?? "-"))
                    .font(.body)
                    .lineLimit(1)
                if let path = fav.path, path != "/" {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    /// 跳转：目录 → 目录本身；文件 → 父目录（网页端行为：展开所在目录）
    private func openFavorite(_ fav: FileFavorite) {
        guard let path = fav.path, !path.isEmpty else { return }
        Haptic.selection()
        if fav.isDir == true {
            onOpen(path)
        } else {
            let parent = (path as NSString).deletingLastPathComponent
            onOpen(parent.isEmpty ? "/" : parent)
        }
    }

    private func load() async {
        do {
            let resp: PageResponse<FileFavorite> = try await client.send(
                path: APIEndpoint.filesFavoriteSearch.path,
                body: FileFavoriteSearchRequest(page: 1, pageSize: Self.pageSize),
                as: PageResponse<FileFavorite>.self)
            favorites = resp.items ?? []
            total = resp.total ?? favorites.count
            page = 1
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    /// 追加下一页（滚动到底触发；id 去重防翻页间隙重复）
    private func loadMore() async {
        guard favorites.count < total, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let next = page + 1
        do {
            let resp: PageResponse<FileFavorite> = try await client.send(
                path: APIEndpoint.filesFavoriteSearch.path,
                body: FileFavoriteSearchRequest(page: next, pageSize: Self.pageSize),
                as: PageResponse<FileFavorite>.self)
            let existing = Set(favorites.map(\.id))
            let newItems = (resp.items ?? []).filter { !existing.contains($0.id) }
            favorites += newItems
            total = resp.total ?? total
            page = next
        } catch {
            // 追加失败不打断列表，下拉刷新可重试
        }
    }

    private func remove(_ fav: FileFavorite) async {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.filesFavoriteDel.path,
                body: FileFavoriteDeleteRequest(id: fav.id),
                as: EmptyResponse.self)
            favorites.removeAll { $0.id == fav.id }
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
    }
}
