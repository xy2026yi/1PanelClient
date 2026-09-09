//
//  FilesView.swift
//  1PanelClient
//
//  文件管理：浏览/创建/删除/重命名
//

import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - 请求模型

struct FileCreateRequest: Encodable {
    let path: String
    let name: String
    let isDir: Bool
    let isLink: Bool
    let isSymlink: Bool
    let linkPath: String
}

struct FileDeleteRequest: Encodable {
    let path: String
    let isDir: Bool
    let forceDelete: Bool
}

struct FileRenameRequest: Encodable {
    let newName: String
    let path: String
    let oldName: String
}

/// 上传文件夹前检查目标路径已存在文件（POST /files/batch/check）
struct FileBatchCheckRequest: Encodable {
    let paths: [String]
}

/// 待上传的本地文件（文件夹上传用）：本地 URL + 含顶层文件夹名的相对路径
struct FolderUploadFile {
    let url: URL
    let relativePath: String
    let size: Int64
}

// MARK: - 文件管理视图

struct FilesView: View {
    let server: ServerConfig

    @State private var currentPath = "/"
    @State private var items: [FileItem] = []
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var pathHistory: [String] = ["/"]
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
    /// 悬浮 + 号的半屏操作菜单
    @State private var showActionSheet = false
    /// 长按文件行弹出的半屏操作菜单对应的文件
    @State private var actionItem: FileItem?
    /// 分片大小：与 1Panel 网页端一致（5MB）
    private let uploadChunkSize = 5 * 1024 * 1024
    /// 超过此大小走分片上传
    private let directUploadLimit = 50 * 1024 * 1024

    private let client: APIClient
    /// 是否从外部指定了起始目录（指定后跳过「默认打开面板 baseDir」逻辑）
    private let hasCustomStart: Bool

    /// initialPath：外部跳转（如应用详情「目录」）指定的起始目录，默认 "/"
    init(server: ServerConfig, initialPath: String = "/") {
        self.server = server
        self.client = APIClient.shared(for: server)
        let start = initialPath.isEmpty ? "/" : initialPath
        _currentPath = State(initialValue: start)
        _pathHistory = State(initialValue: [start])
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
                    Button {
                        showActionSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L10n.t("操作菜单"))
                }
            }
            .refreshable { await loadDir(currentPath) }
            .task { await initialLoad() }
            .sheet(isPresented: $showActionSheet) {
                // onDismiss 必须关掉本 sheet：菜单项触发的下一级弹窗（fileImporter/
                // 创建/路径 alert/回收站 push）都要等它收起后经 delayedAction 再呈现，
                // 否则撞上 "only presenting a single sheet is supported" 被吞
                ActionBottomSheet(title: L10n.t("操作"), items: [
                    ActionMenuItem(title: L10n.t("上传文件"), icon: "arrow.up.circle", color: .blue) {
                        delayedAction { showUploadPicker = true }
                    },
                    ActionMenuItem(title: L10n.t("上传文件夹"), icon: "arrow.up.folder", color: .cyan) {
                        delayedAction { showFolderPicker = true }
                    },
                    ActionMenuItem(title: L10n.t("新建文件夹"), icon: "folder.badge.plus", color: .orange) {
                        delayedAction { createIsDir = true; showCreate = true }
                    },
                    ActionMenuItem(title: L10n.t("新建文件"), icon: "doc.badge.plus", color: .teal) {
                        delayedAction { createIsDir = false; showCreate = true }
                    },
                    ActionMenuItem(title: L10n.t("回收站"), icon: "trash", color: .gray) {
                        delayedAction { showRecycleBin = true }
                    },
                    ActionMenuItem(title: L10n.t("前往路径"), icon: "location", color: .indigo) {
                        delayedAction { pathInput = currentPath; showPathInput = true }
                    },
                    ActionMenuItem(title: L10n.t("根目录"), icon: "house", color: .green) {
                        delayedAction { pathInput = "/"; showPathInput = true }
                    }
                ], onDismiss: { showActionSheet = false })
                .bottomSheetDetents([.height(ActionBottomSheet.height(for: 7))])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $actionItem) { item in
                ActionBottomSheet(
                    title: item.name,
                    items: itemActions(item),
                    onDismiss: { actionItem = nil }
                )
                .bottomSheetDetents([.height(ActionBottomSheet.height(for: item.isDir ? 2 : 3))])
                .presentationDragIndicator(.visible)
            }
            .modifier(FilesTransferModifier(
                showUploadPicker: $showUploadPicker,
                showFolderPicker: $showFolderPicker,
                transfer: $transfer,
                onPickFiles: { result in
                    if case .success(let urls) = result {
                        transferTask = Task { await uploadFiles(urls) }
                    }
                },
                onPickFolder: { result in
                    if case .success(let urls) = result, let folder = urls.first {
                        prepareFolderUpload(folder)
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
            jumpTo: { target in pathHistory = [target]; Task { await loadDir(target) } },
            deleteItem: { item, force in Task { await deleteItem(item, forceDelete: force) } }
        ))
    }

    /// 文件列表（仅文件项；路径面包屑通过 safeAreaInset 固定在顶部）
    private var fileList: some View {
        List {
            ForEach(filteredItems) { item in
                fileRow(item)
                    .onLongPressGesture(minimumDuration: 0.5) {
                        // 触觉反馈 + 弹出半屏操作菜单（经 Haptic 封装，保持全局触觉埋点规则）
                        Haptic.selection()
                        actionItem = item
                    }
            }
        }
        .listSectionSpacing(8)
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
        if item.isDir {
            Button {
                pathHistory.append(item.path)
                Task { await loadDir(item.path) }
            } label: {
                fileRowContent(item)
                    // 整行命中：Button 的可点区跟随 label 的 contentShape，
                    // 必须挂在 label 内部（外挂对 buttonStyle 无效），Spacer 留白才可点
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            // 文件无下级页面：仅长按弹操作菜单
            fileRowContent(item)
        }
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

    private func initialLoad() async {
        // 外部指定了起始目录时不覆盖（应用目录等场景），仅默认进入时定位面板 baseDir
        if !hasCustomStart,
           let baseDir: String = try? await client.send(path: APIEndpoint.settingsBaseDir.path, method: "GET", as: String.self) {
            currentPath = baseDir
            pathHistory = [baseDir]
        }
        await loadDir(currentPath)
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

    /// 选中文件夹后先收集文件并弹确认（x 个文件 / 文件夹名 y），确认后才真正上传
    private func prepareFolderUpload(_ folder: URL) {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let files = collectFolderFiles(folder)
        guard !files.isEmpty else {
            errorMessage = L10n.t("该文件夹内没有文件")
            return
        }
        pendingFolderUpload = (url: folder, files: files)
    }

    /// 递归收集文件夹内全部文件（含 .DS_Store 等隐藏文件，与网页端一致），
    /// 相对路径含顶层文件夹名（如 "1/2/饮食统计.md"）
    private func collectFolderFiles(_ folder: URL) -> [FolderUploadFile] {
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
                    let data = try Data(contentsOf: file.url)
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
        } catch is CancellationError {
            transfer?.status = .failed
            transfer?.errorText = L10n.t("已取消")
        } catch {
            transfer?.status = .failed
            transfer?.errorText = error.localizedDescription
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
                let data = try Data(contentsOf: url)
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
        } catch is CancellationError {
            transfer?.status = .failed
            transfer?.errorText = L10n.t("已取消")
        } catch {
            transfer?.status = .failed
            transfer?.errorText = error.localizedDescription
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

    /// 延迟执行：等半屏操作菜单收起后再触发下一级弹窗（重命名 sheet/删除 alert），
    /// 避免 sheet 关闭动画与新的呈现竞争。
    /// Task@MainActor + sleep 替代 DispatchQueue.asyncAfter（Swift 6 下后者要求 @Sendable 闭包）
    private func delayedAction(_ action: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.35))
            action()
        }
    }

    /// 长按文件行的操作菜单项（下载/重命名/删除），与全站 ActionBottomSheet 风格一致
    private func itemActions(_ item: FileItem) -> [ActionMenuItem] {
        var items: [ActionMenuItem] = []
        if !item.isDir {
            items.append(ActionMenuItem(title: L10n.t("下载"), icon: "arrow.down.circle", color: .green) {
                delayedAction { downloadFile(item) }
            })
        }
        items.append(ActionMenuItem(title: L10n.t("重命名"), icon: "pencil", color: .blue) {
            delayedAction { renamingItem = item }
        })
        items.append(ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red, role: .destructive) {
            delayedAction { deletingItem = item }
        })
        return items
    }

    // MARK: - 下载

    /// 下载文件到本地 Documents 目录（通过 Info.plist 的 UIFileSharingEnabled
    /// 暴露到「文件」App 的 我的iPhone/1PanelClient），同名文件自动加序号
    private func downloadFile(_ item: FileItem) {
        transfer = TransferState(kind: L10n.t("下载"), fileName: item.name, total: Int64(item.size ?? 0))
        let totalSize = Int64(item.size ?? 0)
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
        isLoading = true
        currentPath = path
        let req = FileSearchRequest(path: path, expand: true, page: 1, pageSize: 200, showHidden: true)
        do {
            let resp: FileSearchResponse = try await client.send(
                path: APIEndpoint.filesSearch.path, body: req,
                as: FileSearchResponse.self
            )
            items = (resp.items ?? []).sorted { a, b in
                if a.isDir != b.isDir { return a.isDir && !b.isDir }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
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
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 弹窗/Sheet 集合（抽离为 ViewModifier 以减轻 body 类型推断负担）

/// 集中管理 FilesView 的 sheet 与 alert，避免 body 过长导致编译器无法类型推断。
private struct FilesDialogsModifier: ViewModifier {
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
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .alert(L10n.t("前往路径"), isPresented: $showPathInput) {
                TextField(L10n.t("路径"), text: $pathInput)
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
private struct FilesTransferModifier: ViewModifier {
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
                Section(L10n.t("当前名称")) {
                    Text(item.name).foregroundStyle(.secondary)
                }
                Section(L10n.t("新名称")) {
                    TextField(L10n.t("输入新名称"), text: $newName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
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
                            .font(.system(.headline, design: .monospaced))
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
