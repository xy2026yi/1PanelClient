//
//  FilesView.swift
//  1PanelClient
//
//  文件管理：浏览/创建/删除/重命名
//

import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - 文件管理视图

struct FilesView: View {
    let server: ServerConfig

    @State private var currentPath = "/"
    @State private var items: [FileItem] = []
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var isLoading = false
    @State private var showCreate = false
    @State private var createIsDir = true
    @State private var renamingItem: FileItem?
    @State private var deletingItem: FileItem?
    @State private var successMessage: String?
    @State private var errorMessage: String?
    @State private var showPathInput = false
    @State private var pathInput = "/"

    // 上传/下载
    @State private var showUploadPicker = false
    @State private var showFolderPicker = false
    /// 待确认的文件夹上传（收集完文件后弹确认，确认后才真正上传）
    @State private var pendingFolderUpload: (url: URL, files: [FolderUploadFile])?
    @State private var transfer: TransferState?
    @State private var transferTask: Task<Void, Never>?
    /// 回收站入口
    @State private var showRecycleBin = false
    /// 收藏夹入口（files/favorite/search）
    @State private var showFavorites = false
    /// 悬浮 + 号的半屏操作菜单
    @State private var showActionSheet = false
    /// 长按文件行弹出的半屏操作菜单对应的文件
    @State private var actionItem: FileItem?
    // 文件操作扩展（压缩/解压/移动/权限/远程下载，FilesOperations.swift）
    @State private var compressItem: FileItem?
    @State private var decompressItem: FileItem?
    @State private var moveItem: FileItem?
    @State private var permItem: FileItem?
    @State private var showWget = false
    @State private var archiveTask: FileArchiveTask?
    @State private var wgetProgress: FileWgetProgressTarget?
    /// 进行中的远程下载 key（GET wget/process/keys；非空时工具栏显示入口）
    @State private var activeWgetKeys: [String] = []
    // 多选批量（logs/文件多选抓包 2026-09-14：删除/移动/权限）
    @State private var isSelecting = false
    @State private var selectedPaths: Set<String> = []
    @State private var batchPermItems: [FileItem]?
    @State private var batchMoveItems: [FileItem]?
    @State private var showBatchDeleteConfirm = false
    @State private var isBatchOperating = false
    /// 挂起的菜单动作：菜单完全收起（sheet onDismiss）后再执行，
    /// 替代原先固定 0.35s 的延迟等待
    @State private var pendingMenuAction: (() -> Void)?
    /// 点击文件进入预览的文件（仅 previewableExtensions 内的扩展名）
    @State private var previewingItem: FileItem?
    /// 不支持预览的轻提示（toast，2 秒自动消失）
    @State private var previewToast: String?
    /// 分片大小：与 1Panel 网页端一致（5MB）
    private let uploadChunkSize = 5 * 1024 * 1024
    /// 超过此大小走分片上传
    private let directUploadLimit = 50 * 1024 * 1024
    /// 点击可预览的文本扩展名（其余格式点击仅提示不支持）
    private static let previewableExtensions: Set<String> = [
        "md", "txt", "log", "pem", "html", "json", "conf", "key", "yml", "yaml", "sh",
    ]
    /// 无扩展名的点文件按完整文件名匹配（shell / vim 环境与历史文件均为纯文本）
    private static let previewableDotFiles: Set<String> = [
        ".bash_history", ".bashrc", ".bash_profile", ".bash_logout", ".profile",
        ".viminfo", ".vimrc",
        ".zshrc", ".zshenv", ".zprofile", ".zsh_history",
    ]

    private let client: APIClient
    /// 是否从外部指定了起始目录（指定后跳过「默认打开面板 baseDir」逻辑）
    private let hasCustomStart: Bool

    /// initialPath：外部跳转（如应用详情「目录」）指定的起始目录，默认 "/"
    init(server: ServerConfig, initialPath: String = "/") {
        self.server = server
        self.client = APIClient.shared(for: server)
        let start = initialPath.isEmpty ? "/" : initialPath
        _currentPath = State(initialValue: start)
        hasCustomStart = start != "/"
    }

    /// 当前目录按名称过滤（搜索态）
    private var filteredItems: [FileItem] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 路径面包屑：固定在导航栏下方，不随列表滚动
            breadcrumbBar
            // 文件列表
            fileList
        }
        .searchIconMode(
            text: $searchText,
            isSearching: $isSearching,
            title: currentPath == "/" ? L10n.t("根目录") : (currentPath as NSString).lastPathComponent,
            prompt: L10n.t("搜索当前目录")
        )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        // 有进行中的远程下载时显示入口（网页端行为：下载中显示按钮）
                        if !activeWgetKeys.isEmpty {
                            Button {
                                wgetProgress = FileWgetProgressTarget(keys: activeWgetKeys)
                            } label: {
                                Image(systemName: "arrow.down.circle")
                            }
                            .accessibilityLabel(L10n.t("下载任务"))
                        }
                        // 多选的进入入口在长按菜单「多选」；工具栏仅保留退出按钮
                        if isSelecting {
                            Button {
                                exitSelecting()
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .accessibilityLabel(L10n.t("批量操作"))
                        }
                        if !isSelecting {
                            Button {
                                showActionSheet = true
                            } label: {
                                Image(systemName: "plus")
                            }
                            .accessibilityLabel(L10n.t("操作菜单"))
                        }
                    }
                }
            }
            .refreshable {
                await loadDir(currentPath)
                await checkActiveWgetKeys()
            }
            .task { await initialLoad() }
            .sheet(isPresented: $showActionSheet, onDismiss: {
                // 菜单完全收起后再执行挂起动作，避免与下一级弹窗的呈现竞争
                runPendingMenuAction()
            }) {
                ActionBottomSheet(title: L10n.t("操作"), items: [
                    ActionMenuItem(title: L10n.t("上传文件"), icon: "arrow.up.circle", color: .blue) {
                        pendingMenuAction = { showUploadPicker = true }
                    },
                    ActionMenuItem(title: L10n.t("上传文件夹"), icon: "arrow.up.folder", color: .cyan) {
                        pendingMenuAction = { showFolderPicker = true }
                    },
                    ActionMenuItem(title: L10n.t("新建文件夹"), icon: "folder.badge.plus", color: .orange) {
                        pendingMenuAction = { createIsDir = true; showCreate = true }
                    },
                    ActionMenuItem(title: L10n.t("新建文件"), icon: "doc.badge.plus", color: .teal) {
                        pendingMenuAction = { createIsDir = false; showCreate = true }
                    },
                    ActionMenuItem(title: L10n.t("远程下载"), icon: "arrow.down.circle", color: .blue) {
                        pendingMenuAction = { showWget = true }
                    },
                    ActionMenuItem(title: L10n.t("收藏夹"), icon: "star", color: .yellow) {
                        pendingMenuAction = { showFavorites = true }
                    },
                    ActionMenuItem(title: L10n.t("回收站"), icon: "trash", color: .gray) {
                        pendingMenuAction = { showRecycleBin = true }
                    },
                    ActionMenuItem(title: L10n.t("前往路径"), icon: "location", color: .indigo) {
                        pendingMenuAction = { pathInput = currentPath; showPathInput = true }
                    },
                    ActionMenuItem(title: L10n.t("根目录"), icon: "house", color: .green) {
                        // 直接跳根目录（不经「前往路径」弹窗确认）
                        pendingMenuAction = { Task { await loadDir("/") } }
                    }
                ], onDismiss: { showActionSheet = false })
                .bottomSheetDetents([.height(ActionBottomSheet.height(for: 9))])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $actionItem, onDismiss: {
                // 菜单完全收起后再执行挂起动作，避免与下一级弹窗的呈现竞争
                runPendingMenuAction()
            }) { item in
                ActionBottomSheet(
                    title: item.name,
                    items: itemActions(item),
                    onDismiss: { actionItem = nil }
                )
                .bottomSheetDetents([.height(ActionBottomSheet.height(for: itemActions(item).count))])
                .presentationDragIndicator(.visible)
            }
            .modifier(FilesTransferModifier(
                showUploadPicker: $showUploadPicker,
                showFolderPicker: $showFolderPicker,
                transfer: $transfer,
                onPickFiles: { result in
                    if case .success(let urls) = result {
                        // 覆盖前先取消旧任务：孤儿任务的回调会写坏新传输的状态
                        transferTask?.cancel()
                        transferTask = Task { await uploadFiles(urls) }
                    }
                },
                onPickFolder: { result in
                    if case .success(let urls) = result, let folder = urls.first {
                        transferTask?.cancel()
                        transferTask = Task { await prepareFolderUpload(folder) }
                    }
                },
                onCancel: { transferTask?.cancel() },
                onClose: { transfer = nil }
            ))
            // 文件夹上传确认（x 个文件 / 文件夹名 y，文案对齐网页端）
            .alert(L10n.t("上传文件夹"), isPresented: Binding(
                get: { pendingFolderUpload != nil },
                set: { if !$0 { pendingFolderUpload = nil } }
            )) {
                Button(L10n.t("取消"), role: .cancel) { pendingFolderUpload = nil }
                Button(L10n.t("上传")) {
                    if let pending = pendingFolderUpload {
                        pendingFolderUpload = nil
                        transferTask?.cancel()
                        transferTask = Task { await uploadFolder(pending.url, files: pending.files) }
                    }
                }
            } message: {
                if let pending = pendingFolderUpload {
                    Text(L10n.f(
                        "将 %ld 个文件上传至此网站？\n此操作会上传\"%@\"下的所有文件。请仅在您信任该网站的情况下执行此操作。",
                        pending.files.count, pending.url.lastPathComponent
                    ))
                }
            }
            .navigationDestination(isPresented: $showRecycleBin) {
                FileRecycleBinView(server: server)
            }
            // 收藏夹：点按回跳对应路径（目录 → 本身；文件 → 父目录，抓包行为）
            .navigationDestination(isPresented: $showFavorites) {
                FileFavoriteView(server: server) { target in
                    showFavorites = false
                    Task { await loadDir(target) }
                }
            }
            // 文本预览（仅可预览扩展名会进入）
            .navigationDestination(isPresented: Binding(
                get: { previewingItem != nil },
                set: { if !$0 { previewingItem = nil } }
            )) {
                if let item = previewingItem {
                    FilePreviewView(server: server, item: item)
                }
            }
            .toastOverlay(message: $previewToast, systemImage: "exclamationmark.triangle.fill", iconColor: .orange)
            .modifier(FilesDialogsModifier(
            showCreate: $showCreate,
            createIsDir: createIsDir,
            currentPath: currentPath,
            renamingItem: $renamingItem,
            deletingItem: $deletingItem,
            showPathInput: $showPathInput,
            pathInput: $pathInput,
            successMessage: $successMessage,
            errorMessage: $errorMessage,
            reload: { Task { await loadDir(currentPath) } },
            jumpTo: { target in Task { await loadDir(target) } },
            deleteItem: { item, force in Task { await deleteItem(item, forceDelete: force) } }
        ))
        .sheet(item: Binding(
            get: { batchPermItems.map { FileItemList(items: $0) } },
            set: { if $0 == nil { batchPermItems = nil } }
        )) { list in
            FilePermissionSheet(server: server, items: list.items) {
                Task { await loadDir(currentPath) }
            }
        }
        .sheet(item: Binding(
            get: { batchMoveItems.map { FileItemList(items: $0) } },
            set: { if $0 == nil { batchMoveItems = nil } }
        )) { list in
            FileBatchMoveSheet(server: server, items: list.items, defaultDst: currentPath) {
                exitSelecting()
                await loadDir(currentPath)
            }
        }
        .alert(L10n.t("批量删除"), isPresented: $showBatchDeleteConfirm) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("删除"), role: .destructive) {
                Haptic.warning()
                Task { await batchDelete() }
            }
        } message: {
            Text(L10n.f("将永久删除选中的 %ld 项（不进入回收站），该操作无法回滚，是否继续？", selectedPaths.count))
        }
        .modifier(FilesOperationsModifier(
            server: server,
            currentPath: currentPath,
            reload: { Task { await loadDir(currentPath) } },
            compressItem: $compressItem,
            decompressItem: $decompressItem,
            moveItem: $moveItem,
            permItem: $permItem,
            showWget: $showWget,
            archiveTask: $archiveTask,
            wgetProgress: $wgetProgress
        ))
    }

    /// 文件列表（仅文件项；路径面包屑通过 safeAreaInset 固定在顶部）
    private var fileList: some View {
        List {
            ForEach(filteredItems) { item in
                if isSelecting {
                    selectingRow(item)
                } else {
                    fileRow(item)
                        .onLongPressGesture(minimumDuration: 0.5) {
                            // 触觉反馈 + 弹出半屏操作菜单（经 Haptic 封装，保持全局触觉埋点规则）
                            Haptic.selection()
                            actionItem = item
                        }
                }
            }
        }
        .listSectionSpacing(8)
        // 多选模式底部批量操作栏
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                FilesBatchBar(
                    selectedCount: selectedPaths.count,
                    totalCount: filteredItems.count,
                    isOperating: isBatchOperating,
                    onSelectAll: {
                        if selectedPaths.count >= filteredItems.count {
                            selectedPaths.removeAll()
                        } else {
                            selectedPaths = Set(filteredItems.map(\.path))
                        }
                    },
                    onDelete: { showBatchDeleteConfirm = true },
                    onMove: {
                        batchMoveItems = filteredItems.filter { selectedPaths.contains($0.path) }
                    },
                    onPerm: {
                        batchPermItems = filteredItems.filter { selectedPaths.contains($0.path) }
                    },
                    onCompress: {
                        Task { await batchCompress() }
                    })
            }
        }
    }

    // MARK: - 路径面包屑

    /// 把 currentPath 拆成可点击的路径段。
    /// 例如 "/etc/apt" → [("/", "/"), ("/etc", "etc"), ("/etc/apt", "apt")]
    private var breadcrumbSegments: [(path: String, name: String)] {
        var segments: [(path: String, name: String)] = [("/", "/")]
        let parts = currentPath.split(separator: "/").map(String.init)
        var built = ""
        for part in parts {
            built += "/" + part
            segments.append((built, part))
        }
        return segments
    }

    /// 顶部路径面包屑条：固定在导航栏下方，不随列表滚动。
    /// 使用固定高度，避免在 VStack 中被贪婪的 List 挤压为 0 高度。
    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(breadcrumbSegments.enumerated()), id: \.offset) { idx, seg in
                    breadcrumbSegment(idx: idx, segment: seg)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(height: 36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    /// 单个路径段（分隔符 + 可点击按钮）
    private func breadcrumbSegment(idx: Int, segment: (path: String, name: String)) -> some View {
        let isLast = idx == breadcrumbSegments.count - 1
        return HStack(spacing: 4) {
            if idx > 0 {
                Image(systemName: "chevron.right")
                    .font(.panelScaled(10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            Button {
                Task { await loadDir(segment.path) }
            } label: {
                Text(segment.name == "/" ? L10n.t("根目录") : segment.name)
                    .font(.subheadline.weight(isLast ? .semibold : .regular))
                    .foregroundStyle(isLast ? Color.primary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(isLast)
        }
    }

    // MARK: - 操作菜单（右上角 + 弹出半屏菜单）

    @ViewBuilder
    private func fileRow(_ item: FileItem) -> some View {
        // 目录与文件统一用 Tap 手势导航/预览：目录若用 Button 包裹，
        // 外挂的 onLongPressGesture 会被 Button 吞掉（文件夹长按无反应）
        fileRowContent(item)
            .contentShape(Rectangle())
            .onTapGesture {
                if item.isDir {
                    Task { await loadDir(item.path) }
                } else {
                    openFile(item)
                }
            }
    }

    /// 点击文件：可预览扩展名（或已知文本点文件）push 预览页，其余 toast 提示
    /// （toast 组件自带触觉与 2 秒自动消失）
    private func openFile(_ item: FileItem) {
        if Self.isFilePreviewable(item.name) {
            Haptic.selection()
            previewingItem = item
        } else {
            previewToast = L10n.t("此文件不支持预览")
        }
    }

    /// 收藏 / 取消收藏（已收藏按 favoriteID 删除；成功后刷新当前目录更新星标）
    private func toggleFavorite(_ item: FileItem) async {
        do {
            if item.isFavorite, let fid = item.favoriteID {
                let _: EmptyResponse = try await client.send(
                    path: APIEndpoint.filesFavoriteDel.path,
                    body: FileFavoriteDeleteRequest(id: fid),
                    as: EmptyResponse.self)
            } else {
                let _: FileFavorite = try await client.send(
                    path: APIEndpoint.filesFavorite.path,
                    body: FileFavoriteAddRequest(path: item.path),
                    as: FileFavorite.self)
            }
            Haptic.success()
            await loadDir(currentPath)
        } catch {
            previewToast = error.localizedDescription
        }
    }

    /// 预览资格：按扩展名；无扩展名的点文件（.bashrc 等）按完整文件名
    private static func isFilePreviewable(_ name: String) -> Bool {
        let lower = name.lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty {
            return previewableExtensions.contains(ext)
        }
        return previewableDotFiles.contains(lower)
    }

    private func fileRowContent(_ item: FileItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.isDir ? "folder.fill" : fileIcon(item.name))
                .foregroundStyle(item.isDir ? .blue : .secondary)
                .font(.body)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.name)
                    if item.isSymlink == true {
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                HStack(spacing: 8) {
                    if let user = item.user, !user.isEmpty {
                        Text("\(user)").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let mode = item.mode, !mode.isEmpty {
                        Text(mode).font(.caption2).foregroundStyle(.secondary)
                            .font(.system(.caption2, design: .monospaced))
                    }
                    if !item.isDir, let size = item.size, size > 0 {
                        Text(formatSize(size)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
    }

    private func fileIcon(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "txt", "log", "conf", "cfg": return "doc.text"
        case "sh", "py", "js", "go", "rs", "c", "cpp", "java": return "doc.text.below.ecg"
        case "json", "xml", "yaml", "yml", "toml": return "curlybraces"
        case "jpg", "jpeg", "png", "gif", "svg", "webp": return "photo"
        case "zip", "tar", "gz", "bz2", "7z", "rar": return "doc.zipper"
        case "md": return "book"
        default: return "doc"
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(bytes)
        var idx = 0
        while size >= 1024 && idx < units.count - 1 {
            size /= 1024
            idx += 1
        }
        return String(format: "%.1f %@", size, units[idx])
    }

    /// 预览页返回时 .task 会重跑（视图离开层级再回来）：首次加载幂等，
    /// 否则从管理进入的浏览路径会被 baseDir 重置回 /opt/1panel
    @State private var didInitialLoad = false
    /// 目录请求代数：快速连点目录时丢弃过期响应，保证列表与路径栏一致
    @State private var loadGeneration = 0

    private func initialLoad() async {
        guard !didInitialLoad else { return }
        // 外部指定了起始目录时不覆盖（应用目录等场景），仅默认进入时定位面板 baseDir
        if !hasCustomStart,
           let baseDir: String = try? await client.send(path: APIEndpoint.settingsBaseDir.path, method: "GET", as: String.self) {
            currentPath = baseDir
        }
        await loadDir(currentPath)
        await checkActiveWgetKeys()
        // 加载真正完成才置位：途中 push 预览/回收站会取消 .task（loadDir 被
        // 取消守卫拦下），此时不置位，返回后 .task 重跑会重新加载——
        // 否则 guard 拦住重跑导致空列表 + 假错误卡死
        if !Task.isCancelled {
            didInitialLoad = true
        }
    }

    // MARK: - 上传

    /// 批量上传选中的文件，完成后刷新列表
    private func uploadFiles(_ urls: [URL]) async {
        for url in urls {
            await uploadOneFile(url)
            if transfer?.status != .done { break }   // 失败/取消则停止后续文件
        }
        if transfer?.status == .done {
            await loadDir(currentPath)
        }
    }

    // MARK: - 上传文件夹

    /// 选中文件夹后先收集文件并弹确认（x 个文件 / 文件夹名 y），确认后才真正上传。
    /// 枚举放后台线程（上千文件的目录在主线程同步枚举会冻结 UI），
    /// 期间用传输弹窗显示「扫描中」，可通过取消传输中断
    private func prepareFolderUpload(_ folder: URL) async {
        transfer = TransferState(kind: L10n.t("扫描"), fileName: folder.lastPathComponent, progress: -1)
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let files = await Task.detached(priority: .userInitiated) {
            Self.collectFolderFiles(at: folder)
        }.value
        transfer = nil
        if Task.isCancelled { return }
        guard !files.isEmpty else {
            errorMessage = L10n.t("该文件夹内没有文件")
            return
        }
        pendingFolderUpload = (url: folder, files: files)
    }

    /// 递归收集文件夹内全部文件（含 .DS_Store 等隐藏文件，与网页端一致），
    /// 相对路径含顶层文件夹名（如 "1/2/饮食统计.md"）；
    /// 无隔离要求，可在后台线程执行
    nonisolated private static func collectFolderFiles(at folder: URL) -> [FolderUploadFile] {
        let folderName = folder.lastPathComponent
        let prefix = folder.path + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]
        ) else { return [] }
        var files: [FolderUploadFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]),
                  values.isDirectory != true else { continue }
            let subPath = String(url.path.dropFirst(prefix.count))
            guard !subPath.isEmpty else { continue }
            files.append(FolderUploadFile(
                url: url,
                relativePath: "\(folderName)/\(subPath)",
                size: Int64(values.fileSize ?? 0)
            ))
        }
        return files.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    /// 上传文件夹（请求序列对齐网页端抓包）：
    /// 1. batch/check 检查目标路径（App 恒 overwrite=True，结果仅保持序列一致）
    /// 2. 逐文件 multipart upload：file 字段 filename=相对路径（含文件夹名前缀），
    ///    path=目标目录+该文件相对路径的父目录（服务器按 path/文件名落盘）
    private func uploadFolder(_ folder: URL, files: [FolderUploadFile]) async {
        let totalSize = files.reduce(Int64(0)) { $0 + $1.size }
        transfer = TransferState(kind: L10n.t("上传"), fileName: folder.lastPathComponent, total: totalSize)

        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        do {
            try Task.checkCancellation()
            let checkReq = FileBatchCheckRequest(paths: files.map { joinServerPath(currentPath, $0.relativePath) })
            let _: [String] = try await client.send(
                path: APIEndpoint.filesBatchCheck.path, body: checkReq, as: [String].self
            )
            for file in files {
                try Task.checkCancellation()
                transfer?.fileName = file.relativePath
                if file.size > Int64(directUploadLimit) {
                    let relParent = (file.relativePath as NSString).deletingLastPathComponent
                    try await chunkUpload(
                        url: file.url, name: (file.relativePath as NSString).lastPathComponent,
                        size: file.size, targetDir: joinServerPath(currentPath, relParent)
                    )
                } else {
                    // 整读放后台线程：大文件在主线程读会冻结 UI
                    let data = try await Task.detached(priority: .userInitiated) {
                        try Data(contentsOf: file.url)
                    }.value
                    let relParent = (file.relativePath as NSString).deletingLastPathComponent
                    try await client.uploadMultipart(
                        path: APIEndpoint.filesUpload.path,
                        fields: [
                            "path": joinServerPath(currentPath, relParent),
                            "overwrite": "True",
                        ],
                        fileFieldName: "file",
                        fileName: file.relativePath,
                        mimeType: mime(of: file.relativePath),
                        fileData: data
                    )
                    transfer?.received += file.size
                    transfer?.progress = Double(transfer?.received ?? 0) / Double(max(totalSize, 1))
                }
            }
            transfer?.status = .done
            await loadDir(currentPath)
        } catch {
            // 取消可能是裸 CancellationError，也可能是包在 APIError 里的
            // URLError.cancelled，统一按取消展示
            transfer?.status = .failed
            transfer?.errorText = APIError.isCancellation(error) ? L10n.t("已取消") : error.localizedDescription
        }
    }

    /// 服务器路径拼接（"/tmp" + "1/2" → "/tmp/1/2"；根目录 "/"+…）
    private func joinServerPath(_ dir: String, _ sub: String) -> String {
        if dir == "/" { return "/" + sub }
        return dir.hasSuffix("/") ? dir + sub : dir + "/" + sub
    }

    /// 上传单个文件：≤50MB 直传，>50MB 分片（5MB/片，与网页端一致）
    private func uploadOneFile(_ url: URL) async {
        let name = url.lastPathComponent
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        transfer = TransferState(kind: L10n.t("上传"), fileName: name, total: size)

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            try Task.checkCancellation()
            if size > Int64(directUploadLimit) {
                try await chunkUpload(url: url, name: name, size: size, targetDir: uploadTargetDir())
            } else {
                // 整读放后台线程：50MB 内直传在主线程读会冻结 UI
                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url)
                }.value
                try await client.uploadMultipart(
                    path: APIEndpoint.filesUpload.path,
                    fields: [
                        "path": uploadTargetDir(),
                        "overwrite": "True",
                    ],
                    fileFieldName: "file",
                    fileName: name,
                    mimeType: mime(of: name),
                    fileData: data
                )
                transfer?.received = size
                transfer?.progress = 1
            }
            transfer?.status = .done
        } catch {
            transfer?.status = .failed
            transfer?.errorText = APIError.isCancellation(error) ? L10n.t("已取消") : error.localizedDescription
        }
    }

    /// 分片上传：逐片读取（不整体载入内存），按 chunkIndex 顺序提交
    /// （targetDir 可指定子目录，文件夹上传的大文件落在对应子目录下）
    private func chunkUpload(url: URL, name: String, size: Int64, targetDir: String) async throws {
        let chunkCount = Int(ceil(Double(size) / Double(uploadChunkSize)))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        for index in 0..<chunkCount {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(index) * UInt64(uploadChunkSize))
            let length = min(uploadChunkSize, Int(size) - index * uploadChunkSize)
            guard let data = try handle.read(upToCount: length), !data.isEmpty else { break }
            try await client.uploadMultipart(
                path: APIEndpoint.filesChunkUpload.path,
                fields: [
                    "filename": name,
                    "path": targetDir,
                    "chunkIndex": String(index),
                    "chunkCount": String(chunkCount),
                ],
                fileFieldName: "chunk",
                fileName: name,
                mimeType: "application/octet-stream",
                fileData: data
            )
            transfer?.received += Int64(data.count)
            // 分母取整批任务总量（文件夹上传时 total 为全部文件合计）
            transfer?.progress = Double(transfer?.received ?? 0) / Double(max(transfer?.total ?? size, 1))
        }
    }

    /// 上传目标目录（保证尾部斜杠，与抓包格式一致，如 "/tmp/"）
    private func uploadTargetDir() -> String {
        currentPath.hasSuffix("/") ? currentPath : currentPath + "/"
    }

    /// 根据扩展名推断 MIME 类型
    private func mime(of fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// 执行挂起的菜单动作（由两个操作菜单 sheet 的 onDismiss 调用）：
    /// 等菜单完全收起后再呈现下一级弹窗，避免转场竞争
    private func runPendingMenuAction() {
        guard let action = pendingMenuAction else { return }
        pendingMenuAction = nil
        action()
    }

    /// 多选行：勾选圈 + 原行内容
    private func selectingRow(_ item: FileItem) -> some View {
        Button {
            if selectedPaths.contains(item.path) {
                selectedPaths.remove(item.path)
            } else {
                selectedPaths.insert(item.path)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedPaths.contains(item.path) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedPaths.contains(item.path) ? Color.accentColor : Color.secondary)
                fileRowContent(item)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func exitSelecting() {
        withAnimation(Motion.standard) {
            isSelecting = false
            selectedPaths.removeAll()
        }
    }

    /// 批量删除：逐条 files/del {forceDelete:true}（抓包确认，非 batch/del）
    private func batchDelete() async {
        let targets = filteredItems.filter { selectedPaths.contains($0.path) }
        guard !targets.isEmpty else { return }
        isBatchOperating = true
        defer { isBatchOperating = false }
        var failed: Int = 0
        for item in targets {
            let req = FileDeleteRequest(path: item.path, isDir: item.isDir, forceDelete: true)
            do {
                let _: EmptyResponse = try await client.send(
                    path: APIEndpoint.filesDel.path, body: req, as: EmptyResponse.self)
                selectedPaths.remove(item.path)
            } catch {
                if APIError.isCancellation(error) { return }
                failed += 1
            }
        }
        exitSelecting()
        if failed == 0 {
            successMessage = L10n.t("已删除")
        } else {
            errorMessage = L10n.f("%ld 项删除失败", failed)
        }
        await loadDir(currentPath)
    }

    /// 批量压缩：POST /files/compress {files[],type:zip,dst,name,replace:false,
    /// secret:"",taskID}（抓包 2026-09-15）；名称自动随机（区别于单个压缩的用户命名），
    /// 目标目录为当前目录，任务进度页轮询 taskID
    private func batchCompress() async {
        let targets = filteredItems.filter { selectedPaths.contains($0.path) }
        guard !targets.isEmpty else { return }
        isBatchOperating = true
        defer { isBatchOperating = false }
        let taskID = UUID().uuidString
        let req = FileCompressRequest(
            files: targets.map(\.path),
            type: "zip",
            dst: currentPath,
            name: FileCompressRequest.randomName(),
            replace: false,
            secret: "",
            taskID: taskID)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.filesCompress.path, body: req, as: EmptyResponse.self)
            exitSelecting()
            archiveTask = FileArchiveTask(taskID: taskID, title: L10n.t("批量压缩"))
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// 长按文件行的操作菜单项（多选/下载/压缩/解压/移动/权限/重命名/删除），
    /// 与全站 ActionBottomSheet 风格一致
    private func itemActions(_ item: FileItem) -> [ActionMenuItem] {
        var items: [ActionMenuItem] = []
        // 多选：从该行进入批量模式（预选中长按项）
        items.append(ActionMenuItem(title: L10n.t("多选"), icon: "checkmark.circle", color: .blue) {
            pendingMenuAction = {
                withAnimation(Motion.standard) {
                    isSelecting = true
                    selectedPaths = [item.path]
                }
            }
        })
        // 收藏 / 取消收藏（files/favorite、favorite/del；星标随目录刷新）
        items.append(ActionMenuItem(
            title: item.isFavorite ? L10n.t("取消收藏") : L10n.t("收藏"),
            icon: item.isFavorite ? "star.slash" : "star",
            color: .yellow
        ) {
            pendingMenuAction = { Task { await toggleFavorite(item) } }
        })
        if !item.isDir {
            items.append(ActionMenuItem(title: L10n.t("下载"), icon: "arrow.down.circle", color: .green) {
                pendingMenuAction = { downloadFile(item) }
            })
        }
        items.append(ActionMenuItem(title: L10n.t("压缩"), icon: "doc.zipper", color: .purple) {
            pendingMenuAction = { compressItem = item }
        })
        if Self.isArchiveFile(item.name) {
            items.append(ActionMenuItem(title: L10n.t("解压"), icon: "doc.badge.ellipsis", color: .indigo) {
                pendingMenuAction = { decompressItem = item }
            })
        }
        items.append(ActionMenuItem(title: L10n.t("移动"), icon: "arrow.right.square", color: .orange) {
            pendingMenuAction = { moveItem = item }
        })
        items.append(ActionMenuItem(title: L10n.t("权限"), icon: "lock.shield", color: .teal) {
            pendingMenuAction = { permItem = item }
        })
        items.append(ActionMenuItem(title: L10n.t("重命名"), icon: "pencil", color: .blue) {
            pendingMenuAction = { renamingItem = item }
        })
        items.append(ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red, role: .destructive) {
            pendingMenuAction = { deletingItem = item }
        })
        return items
    }

    /// 可解压的压缩包扩展名（决定行菜单是否显示「解压」）
    private static func isArchiveFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["zip", "gz", "bz2", "tar", "tgz", "xz", "rar", "7z", "zst", "lz4"].contains(ext)
    }

    /// 查询进行中的远程下载 key（下载完成后接口返回 null/空，入口随之隐藏）
    private func checkActiveWgetKeys() async {
        if let resp: FileWgetKeysResponse = try? await client.send(
            path: APIEndpoint.filesWgetProcessKeys.path, method: "GET", body: nil,
            as: FileWgetKeysResponse.self) {
            activeWgetKeys = resp.keys ?? []
        }
    }

    // MARK: - 下载

    /// 下载文件到本地 Documents 目录（通过 Info.plist 的 UIFileSharingEnabled
    /// 暴露到「文件」App 的 我的iPhone/1PanelClient），同名文件自动加序号
    private func downloadFile(_ item: FileItem) {
        transfer = TransferState(kind: L10n.t("下载"), fileName: item.name, total: Int64(item.size ?? 0))
        let totalSize = Int64(item.size ?? 0)
        transferTask?.cancel()
        transferTask = Task {
            do {
                let tempURL = try await client.downloadFile(
                    path: APIEndpoint.filesDownload.path,
                    queryItems: [
                        URLQueryItem(name: "operateNode", value: "local"),
                        URLQueryItem(name: "path", value: item.path),
                    ],
                    fileName: item.name,
                    progress: { fraction in
                        // 网络线程 → 主线程更新进度
                        Task { @MainActor in
                            guard transfer?.status == .running else { return }
                            if fraction >= 0 {
                                transfer?.progress = fraction
                                transfer?.received = Int64(fraction * Double(max(totalSize, 1)))
                            } else {
                                transfer?.progress = -1
                            }
                        }
                    }
                )
                // 移入 Documents 根目录（同名自动加序号）
                let destDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let finalName = uniqueFileName(item.name, in: destDir)
                let finalURL = destDir.appendingPathComponent(finalName)
                try? FileManager.default.removeItem(at: finalURL)
                try FileManager.default.moveItem(at: tempURL, to: finalURL)

                transfer?.fileName = finalName
                transfer?.localURL = finalURL
                transfer?.progress = 1
                transfer?.status = .done
            } catch {
                if Task.isCancelled {
                    transfer?.status = .failed
                    transfer?.errorText = L10n.t("已取消")
                } else {
                    transfer?.status = .failed
                    transfer?.errorText = error.localizedDescription
                }
            }
        }
    }

    /// 目标目录下不冲突的文件名：同名时追加序号（如 "a 1.txt"、"a 2.txt"）
    private func uniqueFileName(_ name: String, in dir: URL) -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.appendingPathComponent(name).path) { return name }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var index = 1
        while true {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if !fm.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
                return candidate
            }
            index += 1
        }
    }

    private func loadDir(_ path: String) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { isLoading = false }
        currentPath = path
        let req = FileSearchRequest(path: path, expand: true, page: 1, pageSize: 200, showHidden: true)
        do {
            let resp: FileSearchResponse = try await client.send(
                path: APIEndpoint.filesSearch.path, body: req,
                as: FileSearchResponse.self
            )
            // 已有更新的目录请求接管（快速连点目录）：丢弃过期响应
            guard generation == loadGeneration else { return }
            items = (resp.items ?? []).sorted { a, b in
                if a.isDir != b.isDir { return a.isDir && !b.isDir }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            errorMessage = nil
        } catch {
            // 取消（push 离开页面时 .task 被取消）不是失败；过期请求不写错误态
            guard generation == loadGeneration, !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func deleteItem(_ item: FileItem, forceDelete: Bool) async {
        let req = FileDeleteRequest(path: item.path, isDir: item.isDir, forceDelete: forceDelete)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.filesDel.path,
                body: req, as: EmptyResponse.self
            )
            // 先本地移除再刷新：若直接整表替换 items，会与滑动删除确认的
            // 行移除动画竞争，触发 List "attempt to delete item N from
            // section 0" 越界崩溃（同 dfaa430 数据库删除崩溃的修法）
            items.removeAll { $0.path == item.path }
            successMessage = forceDelete ? L10n.t("已删除") : L10n.t("已移入回收站")
            await loadDir(currentPath)
        } catch {
            if !APIError.isCancellation(error) {
                errorMessage = error.localizedDescription
            }
        }
    }
}

