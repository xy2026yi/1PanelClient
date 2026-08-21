//
//  TaskCenterView.swift
//  1PanelClient
//
//  任务中心：异步任务列表（应用商店同步/镜像拉取/卸载清理等）+ 任务日志详情
//  基于网页端抓包（logs/任务中心-1.md），入口在 管理 → 面板 → 任务中心
//

import SwiftUI

// MARK: - 任务中心列表

struct TaskCenterView: View {
    let server: ServerConfig

    @State private var items: [TaskCenterItem] = []
    @State private var filter: TaskStatusFilter = .all
    @State private var page = 1
    @State private var total = 0
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorMessage: String?

    private let pageSize = 20
    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient(server: server)
    }

    private var hasMore: Bool { items.count < total }

    var body: some View {
        // 筛选条常驻：某状态结果为空/加载失败时也不隐藏，
        // 否则切到空筛选（如「执行中」）后无法再切回其他状态
        List {
            Section {
                Picker(L10n.t("状态"), selection: $filter) {
                    ForEach(TaskStatusFilter.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                if !isLoading && errorMessage == nil {
                    Text(L10n.f("共 %ld 条", total))
                }
            }

            Section {
                if isLoading && items.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView(L10n.t("加载中…"))
                        Spacer()
                    }
                    .frame(minHeight: 200)
                    .listRowBackground(Color.clear)
                } else if let errorMessage, items.isEmpty {
                    VStack(spacing: 10) {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(L10n.t("重试")) { Task { await load() } }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .listRowBackground(Color.clear)
                } else if items.isEmpty {
                    Text(L10n.t("暂无任务"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(items) { item in
                        NavigationLink {
                            TaskLogDetailView(server: server, task: item)
                        } label: {
                            row(item)
                        }
                        .onAppear {
                            if item.id == items.last?.id {
                                Task { await loadMore() }
                            }
                        }
                    }

                    if hasMore || isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .onAppear { Task { await loadMore() } }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("任务中心"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: filter) { _, _ in
            Task { await load() }
        }
    }

    private func row(_ item: TaskCenterItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.name ?? "—")
                .font(.subheadline)
                .lineLimit(2)

            HStack(spacing: 8) {
                StatusBadge(text: TaskUI.statusText(item.status), color: TaskUI.statusColor(item.status))
                if let type = item.type, !type.isEmpty {
                    StatusBadge(text: type, color: .blue)
                }
                if item.status == "Executing", let step = item.currentStep, !step.isEmpty {
                    Text(step)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(LogDateFormat.short(item.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// 重置并加载第一页（进入页面 / 切换筛选 / 下拉刷新）
    private func load() async {
        if items.isEmpty { isLoading = true }
        page = 1
        let currentFilter = filter
        do {
            let resp: TaskCenterResponse = try await client.send(
                path: APIEndpoint.logsTaskSearch.path + "?operateNode=local",
                body: TaskCenterSearchRequest(type: "", status: currentFilter.rawValue, page: 1, pageSize: pageSize),
                as: TaskCenterResponse.self
            )
            // 等待期间筛选已切换：丢弃过期响应，避免旧数据覆盖新筛选
            guard currentFilter == filter else { return }
            items = resp.items ?? []
            total = resp.total
            errorMessage = nil
        } catch {
            guard currentFilter == filter else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// 追加下一页（滚动到底部触发；按 id 去重，防止翻页期间新增任务导致跨页重复）
    private func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let next = page + 1
        let currentFilter = filter
        do {
            let resp: TaskCenterResponse = try await client.send(
                path: APIEndpoint.logsTaskSearch.path + "?operateNode=local",
                body: TaskCenterSearchRequest(type: "", status: currentFilter.rawValue, page: next, pageSize: pageSize),
                as: TaskCenterResponse.self
            )
            guard currentFilter == filter else { return }
            let existing = Set(items.map(\.id))
            items += (resp.items ?? []).filter { !existing.contains($0.id) }
            total = resp.total
            page = next
            errorMessage = nil
        } catch {
            // 追加失败不打断列表，下拉刷新可重试
        }
    }
}

// MARK: - 任务日志详情

struct TaskLogDetailView: View {
    let server: ServerConfig
    let task: TaskCenterItem

    @State private var lines: [String] = []
    @State private var taskStatus: String?
    @State private var logPath: String?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig, task: TaskCenterItem) {
        self.server = server
        self.task = task
        self.client = APIClient(server: server)
    }

    var body: some View {
        Group {
            if isLoading && lines.isEmpty {
                ProgressView(L10n.t("加载中…")).frame(maxWidth: .infinity, minHeight: 200)
            } else if let errorMessage, lines.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button(L10n.t("重试")) { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    Section {
                        infoRow(L10n.t("任务名称"), task.name ?? "—")
                        if let type = task.type, !type.isEmpty {
                            infoRow(L10n.t("类型"), type)
                        }
                        statusRow
                        infoRow(L10n.t("创建时间"), LogDateFormat.short(task.createdAt))
                        if let end = task.endAt, !end.isEmpty {
                            infoRow(L10n.t("结束时间"), LogDateFormat.short(end))
                        }
                        if let msg = task.errorMsg, !msg.isEmpty {
                            infoRow(L10n.t("错误信息"), msg)
                        }
                    }

                    Section {
                        if lines.isEmpty {
                            Text(L10n.t("该任务暂无日志"))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            LogLinesView(lines: lines)
                                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        }
                    } header: {
                        if let p = logFileDisplay, !p.isEmpty {
                            Text(p).font(.caption2).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.t("任务日志"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    /// 状态行：读取后以最新 taskStatus 为准（执行中任务完成后刷新可见）
    private var statusRow: some View {
        HStack {
            Text(L10n.t("状态"))
                .foregroundStyle(.secondary)
            Spacer()
            StatusBadge(
                text: TaskUI.statusText(taskStatus ?? task.status),
                color: TaskUI.statusColor(taskStatus ?? task.status)
            )
        }
    }

    /// 日志文件路径：优先读取响应里的实时 path，回退列表项的 logFile
    private var logFileDisplay: String? {
        logPath ?? task.logFile
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }

    private func load() async {
        do {
            let resp: LogFileReadResponse = try await client.send(
                path: APIEndpoint.logsTaskRead.path + "?operateNode=local",
                body: TaskCenterLogReadRequest(page: 1, pageSize: 500, latest: true, taskID: task.id),
                as: LogFileReadResponse.self
            )
            lines = resp.lines ?? []
            logPath = resp.path
            taskStatus = resp.taskStatus
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - 任务状态展示

enum TaskUI {
    /// 状态徽章颜色：成功绿 / 失败红 / 执行中蓝
    static func statusColor(_ status: String?) -> Color {
        switch status ?? "" {
        case "Success": return .green
        case "Failed": return .red
        case "Executing": return .blue
        default: return .secondary
        }
    }

    /// 状态文案：接口返回 Success/Failed/Executing，中文环境翻译展示
    static func statusText(_ status: String?) -> String {
        switch status ?? "" {
        case "Success": return L10n.t("成功")
        case "Failed": return L10n.t("失败")
        case "Executing": return L10n.t("执行中")
        default: return status ?? "—"
        }
    }
}

// MARK: - 状态筛选

private enum TaskStatusFilter: String, CaseIterable, Identifiable {
    case all = ""
    case success = "Success"
    case failed = "Failed"
    case executing = "Executing"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L10n.t("所有")
        case .success: return L10n.t("成功")
        case .failed: return L10n.t("失败")
        case .executing: return L10n.t("执行中")
        }
    }
}
