//
//  FilesTab.swift
//  1PanelClient
//

import SwiftUI
import Combine

struct FilesTab: View {
    @ObservedObject var manager: ServerManager
    @StateObject private var vm: FilesViewModel

    init(manager: ServerManager) {
        self.manager = manager
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: FilesViewModel(server: server))
    }

    var body: some View {
        NavigationStack {
            filesRootContent
        }
        .task { await vm.refresh() }
    }

    /// 供外部 NavigationStack 复用的根内容（不包含 NavigationStack/task）
    var filesRootContent: some View {
        Group {
            if vm.isLoading && vm.currentFiles.isEmpty {
                ProgressView("加载中…")
            } else if vm.currentFiles.isEmpty {
                ContentUnavailableView(
                    "空文件夹",
                    systemImage: "folder",
                    description: Text(vm.errorMessage ?? "没有文件")
                )
            } else {
                fileList
            }
        }
        .navigationTitle(vm.currentDirName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await vm.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            if vm.canGoBack {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        vm.goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                }
            }
        }
    }

    private var fileList: some View {
        List {
            ForEach(vm.currentFiles, id: \.name) { f in
                Button {
                    if f.isDir {
                        Task { await vm.enter(f) }
                    }
                } label: {
                    FileRow(file: f)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await vm.refresh()
        }
    }
}

/// 供工具箱/外层 NavigationStack 复用的「文件管理」内容视图
/// FilesTab 自身保留 NavigationStack 以兼容独立使用；
/// 在工具箱场景下用本视图，由外层提供 NavigationStack。
struct FilesTabContent: View {
    @ObservedObject var manager: ServerManager
    @StateObject private var vm: FilesViewModel

    init(manager: ServerManager) {
        self.manager = manager
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: FilesViewModel(server: server))
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.currentFiles.isEmpty {
                ProgressView("加载中…")
            } else if vm.currentFiles.isEmpty {
                ContentUnavailableView(
                    "空文件夹",
                    systemImage: "folder",
                    description: Text(vm.errorMessage ?? "没有文件")
                )
            } else {
                List {
                    ForEach(vm.currentFiles, id: \.name) { f in
                        Button {
                            if f.isDir {
                                Task { await vm.enter(f) }
                            }
                        } label: {
                            FileRow(file: f)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(vm.currentDirName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await vm.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            if vm.canGoBack {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        vm.goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                }
            }
        }
        .task { await vm.refresh() }
    }
}

struct FileRow: View {
    let file: FileInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.isDir ? "folder.fill" : iconName)
                .font(.title3)
                .foregroundStyle(file.isDir ? .blue : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !file.isDir {
                        Text(file.formattedSize)
                    }
                    if let u = file.user {
                        Text("· \(u)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if file.isDir {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp": return "photo"
        case "mp4", "mov", "avi": return "film"
        case "mp3", "wav": return "music.note"
        case "pdf": return "doc.text.fill"
        case "zip", "tar", "gz", "rar": return "doc.zipper"
        case "js", "ts", "swift", "py", "go", "java", "c", "cpp": return "chevron.left.forwardslash.chevron.right"
        case "json", "xml", "yaml", "yml": return "curlybraces"
        case "sh", "bash": return "terminal"
        default: return "doc"
        }
    }
}

// MARK: - ViewModel

@MainActor
final class FilesViewModel: ObservableObject {
    @Published private(set) var currentFiles: [FileInfo] = []
    @Published private(set) var currentPath = "/"
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var client: APIClient
    private var history: [String] = []

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    var currentDirName: String {
        if currentPath == "/" { return "根目录" }
        let parts = currentPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/")
        return parts.last.map(String.init) ?? "/"
    }

    var canGoBack: Bool { !history.isEmpty }

    func refresh() async {
        await load(path: currentPath)
    }

    func enter(_ dir: FileInfo) async {
        history.append(currentPath)
        await load(path: dir.path)
    }

    func goBack() {
        guard let prev = history.popLast() else { return }
        Task { await load(path: prev) }
    }

    private func load(path: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let req = FileSearchRequest(
            path: path,
            page: 1,
            pageSize: 200,
            search: "",
            containSubdirs: false,
            showHidden: false,
            sort: "name",
            order: "ascending"
        )
        do {
            let resp: FileInfo = try await client.send(
                path: APIEndpoint.filesSearch.path,
                body: req,
                as: FileInfo.self
            )
            self.currentPath = resp.path
            self.currentFiles = (resp.items ?? []).sorted { a, b in
                if a.isDir != b.isDir { return a.isDir && !b.isDir }
                return a.name < b.name
            }
        } catch let err as APIError {
            self.errorMessage = err.errorDescription
            self.currentFiles = []
        } catch {
            self.errorMessage = error.localizedDescription
            self.currentFiles = []
        }
    }
}
