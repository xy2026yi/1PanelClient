//
//  FilesView.swift
//  1PanelClient
//
//  文件管理：浏览/创建/删除/重命名
//

import SwiftUI

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

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient(server: server)
    }

    var body: some View {
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
                    }
            }
        }
        .navigationTitle(currentPath == "/" ? "根目录" : (currentPath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    let parent = (currentPath as NSString).deletingLastPathComponent
                    if parent.isEmpty || parent == currentPath {
                        Task { await loadDir("/") }
                    } else {
                        Task { await loadDir(parent) }
                    }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(currentPath == "/")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await loadDir(currentPath) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                Menu {
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
                    Image(systemName: "plus.circle")
                }
            }
        }
        .refreshable { await loadDir(currentPath) }
        .task { await initialLoad() }
        .sheet(isPresented: $showCreate) {
            FileCreateSheet(isDir: createIsDir, currentPath: currentPath) {
                Task { await loadDir(currentPath) }
            }
        }
        .sheet(item: $renamingItem) { item in
            FileRenameSheet(item: item) {
                Task { await loadDir(currentPath) }
            }
        }
        .alert("确认删除", isPresented: Binding(
            get: { deletingItem != nil },
            set: { if !$0 { deletingItem = nil } }
        )) {
            Button("取消", role: .cancel) { deletingItem = nil }
            Button("删除", role: .destructive) {
                if let item = deletingItem {
                    Task { await deleteItem(item) }
                }
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
                if !target.isEmpty {
                    pathHistory = [target]
                    Task { await loadDir(target) }
                }
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
