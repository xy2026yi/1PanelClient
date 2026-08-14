//
//  FilesView.swift
//  1PanelClient
//
//  文件管理：浏览/创建/删除/重命名
//

import SwiftUI
import UniformTypeIdentifiers

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

// MARK: - 文件管理视图

struct FilesView: View {
    let server: ServerConfig

    @State private var currentPath = "/"
    @State private var items: [FileItem] = []
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
    @State private var transfer: TransferState?
    @State private var transferTask: Task<Void, Never>?
    /// 分片大小：与 1Panel 网页端一致（5MB）
    private let uploadChunkSize = 5 * 1024 * 1024
    /// 超过此大小走分片上传
    private let directUploadLimit = 50 * 1024 * 1024

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient(server: server)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 路径面包屑：固定在导航栏下方，不随列表滚动
            breadcrumbBar
            // 文件列表
            fileList
        }
        .navigationTitle(currentPath == "/" ? "根目录" : (currentPath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottomTrailing) { floatingAddButton }
            .refreshable { await loadDir(currentPath) }
            .task { await initialLoad() }
            .modifier(FilesTransferModifier(
                showUploadPicker: $showUploadPicker,
                transfer: $transfer,
                onPickFiles: { result in
                    if case .success(let urls) = result {
                        transferTask = Task { await uploadFiles(urls) }
                    }
                },
                onCancel: { transferTask?.cancel() },
                onClose: { transfer = nil }
            ))
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
            deleteItem: { item in Task { await deleteItem(item) } }
        ))
    }

    /// 文件列表（仅文件项；路径面包屑通过 safeAreaInset 固定在顶部）
    private var fileList: some View {
        List {
            ForEach(items) { item in
                fileRow(item)
                    .swipeActions {
                        Button(role: .destructive) {
                            deletingItem = item
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            renamingItem = item
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        .tint(.blue)
                        if !item.isDir {
                            Button {
                                downloadFile(item)
                            } label: {
                                Label("下载", systemImage: "arrow.down.circle")
                            }
                            .tint(.green)
                        }
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
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            Button {
                Task { await loadDir(segment.path) }
            } label: {
                Text(segment.name == "/" ? "根目录" : segment.name)
                    .font(.subheadline.weight(isLast ? .semibold : .regular))
                    .foregroundStyle(isLast ? Color.primary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(isLast)
        }
    }

    // MARK: - 新建/操作菜单（右上角与悬浮按钮共用）

    private var addMenu: some View {
        Menu {
            Button {
                showUploadPicker = true
            } label: {
                Label("上传文件", systemImage: "arrow.up.circle")
            }
            Button {
                createIsDir = true
                showCreate = true
            } label: {
                Label("新建文件夹", systemImage: "folder.badge.plus")
            }
            Button {
                createIsDir = false
                showCreate = true
            } label: {
                Label("新建文件", systemImage: "doc.badge.plus")
            }
            Divider()
            Button {
                pathInput = currentPath
                showPathInput = true
            } label: {
                Label("前往路径", systemImage: "location")
            }
            Button {
                pathInput = "/"
                showPathInput = true
            } label: {
                Label("根目录", systemImage: "house")
            }
        } label: {
            Label("新建", systemImage: "plus.circle.fill")
        }
    }

    /// 右下角悬浮 + 按钮
    private var floatingAddButton: some View {
        addMenu
            .labelStyle(.iconOnly)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 52, height: 52)
            .background(Color.accentColor, in: Circle())
            .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 4)
            .padding(.trailing, 20)
            .padding(.bottom, 20)
            .accessibilityLabel("新建")
    }

    @ViewBuilder
    private func fileRow(_ item: FileItem) -> some View {
        if item.isDir {
            Button {
                pathHistory.append(item.path)
                Task { await loadDir(item.path) }
            } label: {
                fileRowContent(item)
            }
            .buttonStyle(.plain)
        } else {
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
        if let baseDir: String = try? await client.send(path: APIEndpoint.settingsBaseDir.path, method: "GET", as: String.self) {
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

    /// 上传单个文件：≤50MB 直传，>50MB 分片（5MB/片，与网页端一致）
    private func uploadOneFile(_ url: URL) async {
        let name = url.lastPathComponent
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        transfer = TransferState(kind: "上传", fileName: name, total: size)

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            try Task.checkCancellation()
            if size > Int64(directUploadLimit) {
                try await chunkUpload(url: url, name: name, size: size)
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
            transfer?.errorText = "已取消"
        } catch {
            transfer?.status = .failed
            transfer?.errorText = error.localizedDescription
        }
    }

    /// 分片上传：逐片读取（不整体载入内存），按 chunkIndex 顺序提交
    private func chunkUpload(url: URL, name: String, size: Int64) async throws {
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
                    "path": uploadTargetDir(),
                    "chunkIndex": String(index),
                    "chunkCount": String(chunkCount),
                ],
                fileFieldName: "chunk",
                fileName: name,
                mimeType: "application/octet-stream",
                fileData: data
            )
            transfer?.received += Int64(data.count)
            transfer?.progress = Double(transfer?.received ?? 0) / Double(max(size, 1))
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

    // MARK: - 下载

    /// 下载文件到本地临时目录，完成后可通过系统分享保存到「文件」App
    private func downloadFile(_ item: FileItem) {
        transfer = TransferState(kind: "下载", fileName: item.name, total: Int64(item.size ?? 0))
        let totalSize = Int64(item.size ?? 0)
        transferTask = Task {
            do {
                let url = try await client.downloadFile(
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
                transfer?.localURL = url
                transfer?.progress = 1
                transfer?.status = .done
            } catch {
                if Task.isCancelled {
                    transfer?.status = .failed
                    transfer?.errorText = "已取消"
                } else {
                    transfer?.status = .failed
                    transfer?.errorText = error.localizedDescription
                }
            }
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

    private func deleteItem(_ item: FileItem) async {
        let req = FileDeleteRequest(path: item.path, isDir: item.isDir, forceDelete: true)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.filesDel.path + "?operateNode=undefined",
                body: req, as: EmptyResponse.self
            )
            successMessage = "已删除"
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
    let deleteItem: (FileItem) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showCreate) {
                FileCreateSheet(isDir: createIsDir, currentPath: currentPath, onCreated: reload)
            }
            .sheet(item: $renamingItem) { item in
                FileRenameSheet(item: item, onRenamed: reload)
            }
            .alert("确认删除", isPresented: Binding(
                get: { deletingItem != nil },
                set: { if !$0 { deletingItem = nil } }
            )) {
                Button("取消", role: .cancel) { deletingItem = nil }
                Button("删除", role: .destructive) {
                    if let item = deletingItem { deleteItem(item) }
                }
            } message: {
                if let item = deletingItem {
                    Text("确定要删除\(item.isDir ? "文件夹" : "文件") \"\(item.name)\" 吗？")
                }
            }
            .alert("前往路径", isPresented: $showPathInput) {
                TextField("路径", text: $pathInput)
                Button("取消", role: .cancel) { }
                Button("前往") {
                    let target = pathInput.trimmingCharacters(in: .whitespaces)
                    if !target.isEmpty { jumpTo(target) }
                }
            }
            .alert("提示", isPresented: Binding(
                get: { successMessage != nil || errorMessage != nil },
                set: { _ in successMessage = nil; errorMessage = nil }
            )) {
                Button("好的") { successMessage = nil; errorMessage = nil }
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
    let fileName: String
    var progress: Double = 0  // 0...1；-1 表示总大小未知（转圈）
    var received: Int64 = 0
    var total: Int64 = 0
    var status: Status = .running
    var errorText: String?
    /// 下载完成后的本地文件 URL（用于分享/保存到「文件」App）
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
                .font(.system(size: 44))
                .foregroundStyle(statusColor)

            VStack(spacing: 6) {
                Text("\(state.kind)\(state.status == .running ? "中" : "")")
                    .font(.headline)
                Text(state.fileName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
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
                        Text("取消传输")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                }
                if state.status == .done, let url = state.localURL {
                    ShareLink(item: url) {
                        Label("保存到「文件」/ 分享", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                }
                if state.status != .running {
                    Button {
                        onClose()
                    } label: {
                        Text("关闭")
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
        .presentationDetents([.medium])
    }

    private var statusIcon: String {
        switch state.status {
        case .running: return state.kind == "上传" ? "arrow.up.circle" : "arrow.down.circle"
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
    @Binding var transfer: TransferState?
    let onPickFiles: (Result<[URL], Error>) -> Void
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
        self.client = APIClient(server: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(isDir ? "文件夹名称" : "文件名称") {
                    TextField(isDir ? "folder_name" : "file.txt", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle(isDir ? "新建文件夹" : "新建文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        Task { await create() }
                    }
                    .disabled(isSaving || name.isEmpty)
                }
            }
            .alert("错误", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好的") { errorMessage = nil }
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
        self.client = APIClient(server: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("当前名称") {
                    Text(item.name).foregroundStyle(.secondary)
                }
                Section("新名称") {
                    TextField("输入新名称", text: $newName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("重命名")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { newName = item.name }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task { await rename() }
                    }
                    .disabled(isSaving || newName.isEmpty || newName == item.name)
                }
            }
            .alert("错误", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好的") { errorMessage = nil }
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
