//
//  ScriptLibraryView.swift
//  1PanelClient
//
//  脚本库：列表 / 搜索 / 查看脚本内容 / 执行脚本 / 选择脚本填充计划任务
//  POST /api/v2/core/script/search
//  执行：WS /api/v2/core/script/run?script_id=N
//

import SwiftUI
import Combine

@MainActor
final class ScriptLibraryViewModel: ObservableObject {
    @Published var scripts: [ScriptItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    func load(query: String = "") async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let req = ScriptSearchRequest(info: query, groupID: 0, page: 1, pageSize: 100)
        do {
            let resp: PageResponse<ScriptItem> = try await client.send(
                path: APIEndpoint.scriptSearch.path, body: req,
                as: PageResponse<ScriptItem>.self
            )
            self.scripts = resp.items ?? []
        } catch {
            self.errorMessage = error.localizedDescription
            self.scripts = []
        }
    }
}

// MARK: - 脚本库列表

struct ScriptLibraryView: View {
    @StateObject private var vm: ScriptLibraryViewModel
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    private let server: ServerConfig

    /// 选择模式：非 nil 时，点击脚本行调用 onPick 并返回（用于创建计划任务填充脚本）
    var onPick: ((ScriptItem) -> Void)?

    init(server: ServerConfig, onPick: ((ScriptItem) -> Void)? = nil) {
        _vm = StateObject(wrappedValue: ScriptLibraryViewModel(server: server))
        self.server = server
        self.onPick = onPick
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.scripts.isEmpty {
                ProgressView("加载中…")
            } else if vm.scripts.isEmpty {
                ContentUnavailableView(
                    "暂无脚本",
                    systemImage: "doc.text",
                    description: Text(vm.errorMessage ?? "脚本库为空")
                )
            } else {
                scriptList
            }
        }
        .searchIconMode(
            text: $searchText,
            isSearching: $isSearching,
            title: "脚本库",
            prompt: "搜索脚本名",
            showCloseButton: false,
            onClose: {}
        )
        .task { if vm.scripts.isEmpty { await vm.load() } }
        .onChange(of: searchText) { _, newValue in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { await vm.load(query: newValue) }
            }
        }
    }

    private var scriptList: some View {
        List {
            ForEach(vm.scripts) { script in
                if onPick != nil {
                    Button {
                        if let pick = onPick { pick(script) }
                    } label: {
                        ScriptRow(script: script)
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink {
                        ScriptDetailView(script: script, server: server)
                    } label: {
                        ScriptRow(script: script)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await vm.load(query: searchText) }
    }
}

// MARK: - 脚本列表项

struct ScriptRow: View {
    let script: ScriptItem

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "terminal", color: .purple, size: 36, cornerRadius: 9)

            VStack(alignment: .leading, spacing: 4) {
                Text(script.displayName)
                    .font(.body.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let desc = script.displayDescription, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if script.isSystem == true {
                        StatusBadge(text: "系统", color: .blue, backgroundOpacity: 0.12)
                    }
                    if script.isInteractive == true {
                        StatusBadge(text: "需交互", color: .orange, backgroundOpacity: 0.12)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 脚本详情

struct ScriptDetailView: View {
    let script: ScriptItem
    let server: ServerConfig
    @State private var showTerminal = false

    var body: some View {
        List {
            Section("基本信息") {
                LabeledRow("名称", value: script.displayName)
                if let desc = script.displayDescription, !desc.isEmpty {
                    LabeledRow("描述", value: desc)
                }
                if script.isInteractive == true {
                    LabeledRow("类型", value: "需要交互输入")
                }
                if let t = script.createdAt, !t.isEmpty {
                    LabeledRow("创建时间", value: t.prefix(19).description)
                }
            }

            if let code = script.script, !code.isEmpty {
                Section("脚本内容") {
                    Text(code)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle(script.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showTerminal = true
                } label: {
                    Text("安装").fontWeight(.medium)
                }
            }
        }
        .navigationDestination(isPresented: $showTerminal) {
            TerminalView(
                server: server,
                target: .scriptRun(scriptID: script.id, cols: 80, rows: 24),
                title: script.displayName
            )
        }
    }
}
