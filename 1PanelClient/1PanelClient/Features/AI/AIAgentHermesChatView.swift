//
//  AIAgentHermesChatView.swift
//  1PanelClient
//
//  Hermes Agent 对话（/api/v2/ai/agents/hermes/chat/*，logs/会话.md 抓包）：
//  会话列表（标题/模型/消息数/最近活跃）+ 新对话与恢复会话（容器终端内
//  启动 hermes CLI，恢复用 --resume <会话id>）+ 下拉刷新 / 滑动重命名与删除
//

import SwiftUI

struct AIAgentHermesChatView: View {
    let server: ServerConfig
    let agentId: Int
    let agentName: String
    /// 新对话的终端目标容器（抓包：containerid=智能体容器名）
    let containerName: String

    @State private var sessions: [AIHermesChatSession] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var toastMessage: String?
    @State private var errorMessage: String?
    @State private var showError = false
    /// 当前打开的终端对话（nil = 未打开）
    @State private var activeChat: AIHermesChatTarget?
    /// 删除确认目标
    @State private var pendingDelete: AIHermesChatSession?
    /// 重命名目标
    @State private var renameTarget: AIHermesChatSession?

    private let client: APIClient

    init(server: ServerConfig, agentId: Int, agentName: String, containerName: String) {
        self.server = server
        self.agentId = agentId
        self.agentName = agentName
        self.containerName = containerName
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
            } else if sessions.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无会话"),
                    systemImage: "ellipsis.bubble",
                    description: Text(L10n.t("点击右上角 + 开始新对话"))
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(sessions) { session in
                    sessionRow(session)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("对话"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    startChat(.new(agentName))
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("新对话"))
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .toastOverlay(message: $toastMessage)
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(L10n.t("删除会话"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingDelete = nil }
            Button(L10n.t("删除"), role: .destructive) {
                if let session = pendingDelete {
                    Task { await delete(session) }
                }
            }
        } message: {
            Text(L10n.f("确定删除会话「%@」吗？删除后不可恢复。", pendingDelete?.displayTitle ?? ""))
        }
        .sheet(item: $renameTarget) { session in
            AIHermesRenameSheet(initialTitle: session.displayTitle) { newTitle in
                Task { await rename(session, to: newTitle) }
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { activeChat != nil },
            set: { if !$0 { activeChat = nil } }
        )) {
            if let chat = activeChat {
                TerminalScreen(
                    server: server,
                    // 抓包：user=hermes、command=/bin/bash，PTY 就绪后按目标执行
                    // 新对话 hermes；恢复会话 hermes --resume <id>
                    target: .container(
                        containerID: containerName,
                        user: "hermes",
                        command: "/bin/bash",
                        cols: 80,
                        rows: 24
                    ),
                    title: chat.title,
                    initialCommand: chat.initialCommand
                )
            }
        }
        // 终端关闭后刷新：对话在 CLI 内产生变更，列表需重拉（抓包「刷新」流程）
        .onChange(of: activeChat) { _, chat in
            if chat == nil { Task { await load() } }
        }
    }

    // MARK: 会话行

    private func sessionRow(_ session: AIHermesChatSession) -> some View {
        Button {
            startChat(.resume(session))
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayTitle)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let model = session.model, !model.isEmpty {
                        Text(model)
                            .font(.dataMonospacedCaption)
                    }
                    if let count = session.messageCount {
                        Text(L10n.f("%ld 条消息", count))
                            .font(.caption)
                    }
                    if let time = SessionTime.text(session.lastActive) {
                        Text(time)
                            .font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                renameTarget = session
            } label: {
                Label(L10n.t("重命名"), systemImage: "pencil")
            }
            Button(role: .destructive) {
                pendingDelete = session
            } label: {
                Label(L10n.t("删除"), systemImage: "trash")
            }
        }
    }

    // MARK: 操作

    /// 打开终端对话：新对话执行 hermes，点击已有会话用 --resume 恢复
    /// （logs/会话.md 抓包 2026-09-14：hermes --resume 20260914_094214_eedba8）
    private func startChat(_ chat: AIHermesChatTarget) {
        let container = containerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !container.isEmpty else {
            toastMessage = L10n.t("容器名称为空，无法进入对话")
            return
        }
        activeChat = chat
    }

    private func load() async {
        do {
            let resp: [AIHermesChatSession]? = try await client.send(
                path: APIEndpoint.aiAgentHermesSessions.path,
                body: AIAgentModelRequest(agentId: agentId),
                as: [AIHermesChatSession].self)
            sessions = (resp ?? [])
                .sorted { ($0.lastActive ?? "") > ($1.lastActive ?? "") }
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func delete(_ session: AIHermesChatSession) async {
        pendingDelete = nil
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentHermesSessionDelete.path,
                body: AIHermesChatSessionDeleteRequest(agentId: agentId, id: session.id),
                as: EmptyResponse.self)
            toastMessage = L10n.f("已删除「%@」", session.displayTitle)
            await load()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func rename(_ session: AIHermesChatSession, to title: String) async {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentHermesSessionRename.path,
                body: AIHermesChatSessionRenameRequest(agentId: agentId, id: session.id, title: title),
                as: EmptyResponse.self)
            toastMessage = L10n.t("已重命名")
            await load()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - 终端对话目标（新对话 / 恢复会话）

/// 容器终端内启动 hermes CLI 的参数：新对话执行 hermes，
/// 恢复会话执行 hermes --resume <会话id>（logs/会话.md 抓包 2026-09-14 确认）
struct AIHermesChatTarget: Equatable {
    /// PTY 就绪后自动执行的初始命令（带换行）
    let initialCommand: String
    /// 终端页标题
    let title: String

    static func new(_ agentName: String) -> AIHermesChatTarget {
        AIHermesChatTarget(
            initialCommand: "hermes\n",
            title: L10n.f("对话 · %@", agentName))
    }

    static func resume(_ session: AIHermesChatSession) -> AIHermesChatTarget {
        AIHermesChatTarget(
            initialCommand: "hermes --resume \(session.id)\n",
            title: session.displayTitle)
    }
}

// MARK: - 会话时间格式化

private enum SessionTime {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    static let display: DateFormatter = {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// "2026-09-14T01:08:32Z" → 本地时间文本；解析失败返回 nil
    static func text(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, let date = iso.date(from: raw) else { return nil }
        return display.string(from: date)
    }
}

// MARK: - 重命名 Sheet

private struct AIHermesRenameSheet: View {
    /// 进入时预填当前标题（空标题会话预填「新对话」占位，可清空重输）
    let initialTitle: String
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var appeared = false

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.t("会话名称"), text: $title)
                        .textInputAutocapitalization(.never)
                } header: {
                    SectionLabel(title: L10n.t("重命名"), systemImage: "pencil")
                }
            }
            .navigationTitle(L10n.t("重命名"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("保存")) {
                        onConfirm(trimmed)
                        dismiss()
                    }
                    .disabled(trimmed.isEmpty)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.medium])
        // 仅首次出现预填：sheet(item:) 复用视图结构时避免覆盖用户输入
        .onAppear {
            if !appeared {
                appeared = true
                title = initialTitle
            }
        }
    }
}
