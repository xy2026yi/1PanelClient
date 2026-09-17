//
//  AIDownloaderSearchView.swift
//  1PanelClient
//
//  模型仓库搜索（AIDownloaderView 的「搜索」分段）：
//  手动仓库 ID 下载 + HuggingFace / ModelScope 搜索（排序切换、加载更多），
//  结果点击进入详情（模型卡 / 文件列表 / 下载）
//

import SwiftUI

// MARK: - 搜索分段

struct AIDownloaderSearchView: View {
    @ObservedObject var vm: AIDownloaderViewModel

    @State private var source: ModelRepoSource = .huggingface
    @State private var manualRepoID = ""
    @State private var isManualDownloading = false

    @State private var query = ""
    @State private var sort: ModelRepoSort = .downloads
    @State private var results: [ModelRepoItem] = []
    @State private var total = 0
    @State private var page = 1
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var hasSearched = false
    @State private var searchError: String?
    @State private var detailRepo: ModelRepoItem?

    private static let pageSize = 50
    private let client: APIClient

    init(vm: AIDownloaderViewModel) {
        self.vm = vm
        self.client = vm.client
    }

    var body: some View {
        List {
            Section {
                Picker(L10n.t("来源"), selection: $source) {
                    ForEach(ModelRepoSource.allCases) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                SectionLabel(title: L10n.t("模型仓库"), systemImage: "globe")
            }
            manualSection
            searchSection
        }
        .listStyle(.insetGrouped)
        .sheet(item: $detailRepo) { item in
            AIDownloaderRepoDetailView(source: source, repo: item, vm: vm)
        }
    }

    // MARK: 手动下载

    private var manualSection: some View {
        Section {
            HStack(spacing: 10) {
                FormTextField(label: L10n.t("仓库 ID，如 Qwen/Qwen3-0.6B"), text: $manualRepoID)
                    .font(.dataMonospacedBody)
                    .onSubmit { Task { await manualDownload() } }
                Button {
                    Task { await manualDownload() }
                } label: {
                    if isManualDownloading {
                        ProgressView()
                    } else {
                        Text(L10n.t("下载"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(manualRepoID.trimmingCharacters(in: .whitespaces).isEmpty || isManualDownloading)
            }
        } header: {
            SectionLabel(title: L10n.t("手动下载"), systemImage: "square.and.arrow.down")
        } footer: {
            Text(L10n.f("按当前来源（%@）直接下载指定仓库", source.displayName))
        }
    }

    private func manualDownload() async {
        let repoID = manualRepoID.trimmingCharacters(in: .whitespaces)
        guard !repoID.isEmpty else { return }
        isManualDownloading = true
        defer { isManualDownloading = false }
        if await vm.download(source: source, repoID: repoID) {
            manualRepoID = ""
        }
    }

    // MARK: 仓库搜索

    private var searchSection: some View {
        Section {
            HStack(spacing: 10) {
                FormTextField(label: L10n.t("搜索模型，如 Qwen"), text: $query)
                    .onSubmit { Task { await search(reset: true) } }
                Picker("", selection: $sort) {
                    ForEach(ModelRepoSort.allCases) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .pickerStyle(.menu)
                Button {
                    Task { await search(reset: true) }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .disabled(isLoading)
            }

            if isLoading && results.isEmpty {
                HStack {
                    Spacer()
                    LoadingStateView()
                    Spacer()
                }
            } else if let err = searchError, results.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("搜索失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                }
            } else if hasSearched && results.isEmpty {
                ContentUnavailableView(
                    L10n.t("无搜索结果"),
                    systemImage: "magnifyingglass",
                    description: Text(L10n.t("换个关键词或排序试试"))
                )
            } else {
                ForEach(results) { item in
                    Button {
                        detailRepo = item
                    } label: {
                        ModelRepoRow(item: item)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if item.id == results.last?.id {
                            Task { await search(reset: false) }
                        }
                    }
                }

                if results.count < total || isLoadingMore {
                    LoadingStateView(compact: true)
                    .onAppear { Task { await search(reset: false) } }
                }
            }
        } header: {
            SectionLabel(title: source.displayName, systemImage: "magnifyingglass")
        } footer: {
            if hasSearched, total > 0 {
                Text(L10n.f("共 %d 个仓库", total))
            }
        }
        .onChange(of: source) { _, _ in
            // 切换来源后旧结果属于另一平台，清空重搜
            results = []
            total = 0
            hasSearched = false
            searchError = nil
        }
    }

    private func search(reset: Bool) async {
        let keyword = query.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return }
        if reset {
            guard !isLoading else { return }
            isLoading = true
            searchError = nil
            defer { isLoading = false }
            await loadPage(keyword: keyword, targetPage: 1)
            hasSearched = true
        } else {
            guard !isLoading, !isLoadingMore, results.count < total else { return }
            isLoadingMore = true
            defer { isLoadingMore = false }
            await loadPage(keyword: keyword, targetPage: page + 1)
        }
    }

    private func loadPage(keyword: String, targetPage: Int) async {
        let req = ModelRepoSearchRequest(query: keyword, sort: sort.rawValue, page: targetPage, pageSize: Self.pageSize)
        let endpoint: APIEndpoint
        switch source {
        case .huggingface: endpoint = .modelDownloaderHFSearch
        case .modelscope: endpoint = .modelDownloaderMSSearch
        }
        do {
            let resp: PageResponse<ModelRepoItem> = try await client.send(
                path: endpoint.path, body: req, as: PageResponse<ModelRepoItem>.self)
            if targetPage == 1 {
                results = resp.items ?? []
            } else {
                let existing = Set(results.map(\.id))
                results += (resp.items ?? []).filter { !existing.contains($0.id) }
            }
            total = resp.total ?? 0
            page = targetPage
        } catch {
            guard !APIError.isCancellation(error) else { return }
            // 首页失败显示错误态；追加失败静默（保留已加载内容）
            if targetPage == 1 {
                searchError = error.localizedDescription
                results = []
            }
        }
    }
}

// MARK: - 搜索结果行

private struct ModelRepoRow: View {
    let item: ModelRepoItem

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "shippingbox", color: .indigo)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name ?? item.repoID)
                    .font(.body.bold())
                    .lineLimit(1)
                Text(item.repoID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 10) {
                    Label(item.downloadsCompact, systemImage: "arrow.down.circle")
                    if let likes = item.likes {
                        Label(String(likes), systemImage: "hand.thumbsup")
                    }
                    let size = item.displaySize
                    if !size.isEmpty {
                        Text(size)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - 仓库详情 Sheet

struct AIDownloaderRepoDetailView: View {
    let source: ModelRepoSource
    let repo: ModelRepoItem
    @ObservedObject var vm: AIDownloaderViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var detail: ModelRepoDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isDownloading = false
    @State private var showCard = false

    private let client: APIClient

    init(source: ModelRepoSource, repo: ModelRepoItem, vm: AIDownloaderViewModel) {
        self.source = source
        self.repo = repo
        self.vm = vm
        self.client = vm.client
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    LoadingStateView()
                } else if let err = errorMessage {
                    ContentUnavailableView {
                        Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(err)
                    } actions: {
                        Button(L10n.t("重试")) { Task { await load() } }
                    }
                } else if let detail {
                    detailList(detail)
                }
            }
            .navigationTitle(repo.name ?? repo.repoID)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("关闭")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await download() }
                    } label: {
                        if isDownloading {
                            ProgressView()
                        } else {
                            Text(L10n.t("下载"))
                        }
                    }
                    .disabled(isDownloading)
                }
            }
        }
        .task { await load() }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.large])
    }

    private func detailList(_ detail: ModelRepoDetail) -> some View {
        List {
            Section {
                InfoRow(L10n.t("仓库 ID"), value: repo.repoID, monospaced: true)
                if let downloads = detail.downloads {
                    InfoRow(L10n.t("下载量"), value: downloads.formatted(.number.notation(.compactName)))
                }
                if let likes = detail.likes {
                    InfoRow(L10n.t("点赞"), value: String(likes))
                }
                let size = detail.displaySize
                if !size.isEmpty {
                    InfoRow(L10n.t("大小"), value: size)
                }
            } header: {
                SectionLabel(title: L10n.t("仓库信息"), systemImage: "info.circle")
            }

            if let files = detail.files, !files.isEmpty {
                Section {
                    ForEach(files) { file in
                        HStack {
                            Image(systemName: file.name.hasSuffix(".safetensors") ? "shippingbox.fill" : "doc")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text(file.name)
                                .font(.dataMonospacedCaption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(file.displaySize)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } header: {
                    SectionLabel(
                        title: L10n.f("文件 · 共 %d 个", files.count),
                        systemImage: "folder"
                    )
                }
            }

            if let card = detail.modelCard, !card.isEmpty {
                Section {
                    Button {
                        showCard = true
                    } label: {
                        Label(L10n.t("查看模型卡"), systemImage: "doc.richtext")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .sheet(isPresented: $showCard) {
            ModelCardSheet(title: repo.name ?? repo.repoID, card: detail.modelCard ?? "")
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let endpoint: APIEndpoint
        switch source {
        case .huggingface: endpoint = .modelDownloaderHFInfo
        case .modelscope: endpoint = .modelDownloaderMSInfo
        }
        do {
            detail = try await client.send(
                path: endpoint.path,
                body: ModelRepoRequest(repoID: repo.repoID),
                as: ModelRepoDetail.self)
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func download() async {
        isDownloading = true
        defer { isDownloading = false }
        if await vm.download(source: source, repoID: repo.repoID) {
            dismiss()
        }
    }
}

// MARK: - 模型卡（Markdown 原文）

/// 模型卡原文查看：项目无 Markdown 渲染组件，以等宽纯文本滚动展示
private struct ModelCardSheet: View {
    let title: String
    let card: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(card)
                    .font(.dataMonospacedCaption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle(L10n.f("模型卡 · %@", title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("关闭")) { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.large])
    }
}
