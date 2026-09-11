//
//  ClamRecordView.swift
//  1PanelClient
//
//  ClamAV 扫描报告：近 7 天执行记录分页列表（/toolbox/clam/record/search），
//  点击行查看任务日志（复用 /logs/tasks/read 任务日志读取）
//

import SwiftUI

struct ClamRecordView: View {
    let server: ServerConfig
    let clamID: Int
    let ruleName: String

    @State private var records: [ClamRecordItem] = []
    @State private var total = 0
    @State private var page = 1
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var loadGeneration = 0
    /// 行点击推入的任务日志页目标
    @State private var selectedRecord: ClamRecordItem?

    private let client: APIClient
    private static let pageSize = 10

    init(server: ServerConfig, clamID: Int, ruleName: String) {
        self.server = server
        self.clamID = clamID
        self.ruleName = ruleName
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        List {
            Section {
                if isLoading && records.isEmpty {
                    HStack {
                        Spacer()
                        LoadingStateView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else if let err = errorMessage, !err.isEmpty, records.isEmpty {
                    LoadErrorStateView(message: err) {
                        Task { await load() }
                    }
                    .listRowBackground(Color.clear)
                } else if records.isEmpty {
                    ContentUnavailableView(
                        L10n.t("暂无报告"),
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(L10n.f("规则「%@」近 7 天没有扫描记录", ruleName))
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(records) { record in
                        Button {
                            selectedRecord = record
                        } label: {
                            ClamRecordRow(record: record)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if record.id == records.last?.id {
                                Task { await loadMore() }
                            }
                        }
                    }

                    if records.count < total || isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .onAppear { Task { await loadMore() } }
                    }
                }
            } header: {
                SectionLabel(title: L10n.t("扫描报告"), systemImage: "doc.text.magnifyingglass")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("报告"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: Binding(
            get: { selectedRecord != nil },
            set: { if !$0 { selectedRecord = nil } }
        )) {
            if let record = selectedRecord {
                ClamTaskLogView(server: server, record: record, ruleName: ruleName)
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - 数据

    /// 近 7 天时间窗（本地自然日 → UTC ISO8601 毫秒串，对齐网页端请求格式）
    private static func dateRange() -> (start: String, end: String) {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        let end = (calendar.date(byAdding: .day, value: 1, to: todayStart) ?? Date()).addingTimeInterval(-0.001)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return (formatter.string(from: start), formatter.string(from: end))
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        page = 1
        loadGeneration += 1
        let range = Self.dateRange()
        let req = ClamRecordSearchRequest(
            page: 1, pageSize: Self.pageSize, clamID: clamID,
            status: "", startTime: range.start, endTime: range.end)
        do {
            let resp: PageResponse<ClamRecordItem> = try await client.send(
                path: APIEndpoint.clamRecordSearch.path, body: req, as: PageResponse<ClamRecordItem>.self)
            records = resp.items ?? []
            total = resp.total ?? 0
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard records.count < total, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let next = page + 1
        let generation = loadGeneration
        let range = Self.dateRange()
        let req = ClamRecordSearchRequest(
            page: next, pageSize: Self.pageSize, clamID: clamID,
            status: "", startTime: range.start, endTime: range.end)
        do {
            let resp: PageResponse<ClamRecordItem> = try await client.send(
                path: APIEndpoint.clamRecordSearch.path, body: req, as: PageResponse<ClamRecordItem>.self)
            guard generation == loadGeneration else { return }
            let existing = Set(records.map(\.id))
            let newItems = (resp.items ?? []).filter { !existing.contains($0.id) }
            records += newItems
            total = resp.total ?? total
            page = next
        } catch {
            // 追加失败不打断列表，下拉刷新可重试
        }
    }
}

// MARK: - 报告行

struct ClamRecordRow: View {
    let record: ClamRecordItem

    private var isDone: Bool { record.status == "Done" }
    private var infected: Int { Int(record.infectedFiles ?? "") ?? 0 }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(
                systemName: infected > 0 ? "exclamationmark.triangle.fill" : "checkmark.shield.fill",
                color: infected > 0 ? .red : .green,
                size: 36,
                cornerRadius: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(record.startTime ?? "—")
                    .font(.subheadline.bold())
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(L10n.f("感染 %ld", infected))
                        .font(.caption2)
                        .foregroundStyle(infected > 0 ? .red : .secondary)
                    if let scanTime = record.scanTime, !scanTime.isEmpty {
                        Text(scanTime)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            if let message = record.message, !message.isEmpty {
                Image(systemName: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            StatusBadge(
                text: isDone ? L10n.t("已完成") : (record.status?.isEmpty == false ? record.status! : "—"),
                color: isDone ? .statusRunning : .secondary)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - 任务日志详情（单次扫描）

/// 单次扫描的任务日志：状态 + 日志行（复用 /logs/tasks/read）
struct ClamTaskLogView: View {
    let server: ServerConfig
    let record: ClamRecordItem
    let ruleName: String

    @State private var lines: [String] = []
    @State private var taskStatus: String?
    @State private var logPath: String?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig, record: ClamRecordItem, ruleName: String) {
        self.server = server
        self.record = record
        self.ruleName = ruleName
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        Group {
            if isLoading && lines.isEmpty {
                LoadingStateView()
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
                        infoRow(L10n.t("规则名称"), ruleName)
                        infoRow(L10n.t("开始时间"), record.startTime ?? "—")
                        if let scanTime = record.scanTime, !scanTime.isEmpty {
                            infoRow(L10n.t("扫描耗时"), scanTime)
                        }
                        infoRow(L10n.t("感染文件"), record.infectedFiles ?? "—")
                        statusRow
                        if let msg = record.message, !msg.isEmpty {
                            infoRow(L10n.t("信息"), msg)
                        }
                    }

                    Section {
                        if lines.isEmpty {
                            ContentUnavailableView {
                                Label(L10n.t("该任务暂无日志"), systemImage: "tray")
                            }
                        } else {
                            LogLinesView(lines: lines)
                                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        }
                    } header: {
                        if let p = logPath, !p.isEmpty {
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

    private var statusRow: some View {
        HStack {
            Text(L10n.t("状态"))
                .foregroundStyle(.secondary)
            Spacer()
            StatusBadge(
                text: TaskUI.statusText(taskStatus ?? record.status ?? ""),
                color: TaskUI.statusColor(taskStatus ?? record.status ?? ""))
        }
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
        guard let taskID = record.taskID, !taskID.isEmpty else {
            errorMessage = L10n.t("该记录没有关联的任务日志")
            isLoading = false
            return
        }
        do {
            let resp: LogFileReadResponse = try await client.send(
                path: APIEndpoint.logsTaskRead.path,
                body: TaskCenterLogReadRequest(page: 1, pageSize: 500, latest: true, taskID: taskID),
                queryItems: client.operateNodeQuery,
                as: LogFileReadResponse.self)
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
