//
//  ComposeLogView.swift
//  1PanelClient
//
//  按 compose 文件的容器日志查看（SSE 流式 + 跟随尾部）：
//  智能体 / MCP Server 日志共用；行为对齐 Apps 模块的 AppLogView
//

import SwiftUI

struct ComposeLogView: View {
    let title: String
    let composePath: String
    let client: APIClient

    @State private var logLines: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isFollowing = true
    @State private var scrollToBottomTrigger = 0
    @State private var tail = 200
    @State private var sinceMode = "all"
    @State private var streamTask: Task<Void, Never>?
    /// 跟随滚动防抖（SSE 高频追加时合并同一帧内的多次滚动）
    @State private var followScrollTask: Task<Void, Never>?

    private let sinceOptions: [(value: String, label: String)] = [
        ("all", L10n.t("全部")),
        ("30m", L10n.t("近30分钟")),
        ("2h", L10n.t("近2小时")),
        ("24h", L10n.t("近24小时")),
        ("7d", L10n.t("近7天"))
    ]

    var body: some View {
        VStack(spacing: 0) {
            controlBar
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))

            Divider()
            logContent
            Divider()
            followBar
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemBackground))
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await startStreaming() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .accessibilityLabel(L10n.t("刷新"))
            }
        }
        .task { await startStreaming() }
        .refreshable { await startStreaming() }
        .onDisappear {
            streamTask?.cancel()
            followScrollTask?.cancel()
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $sinceMode) {
                ForEach(sinceOptions, id: \.value) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: sinceMode) { _, _ in
                Task { await startStreaming() }
            }

            Spacer()

            HStack(spacing: 4) {
                Text(L10n.t("行数"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $tail) {
                    Text("100").tag(100)
                    Text("200").tag(200)
                    Text("500").tag(500)
                    Text("1000").tag(1000)
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var followBar: some View {
        HStack {
            if isLoading {
                ProgressView()
                    .scaleEffect(0.7)
                Text(L10n.t("流式接收中…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text(L10n.t("已断开"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                isFollowing = true
                scrollToBottomTrigger += 1
            } label: {
                Label(L10n.t("跟随最新"), systemImage: "arrow.down")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(isFollowing ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
                    .foregroundStyle(isFollowing ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var logContent: some View {
        if logLines.isEmpty && isLoading {
            LoadingStateView(text: L10n.t("加载日志…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if logLines.isEmpty {
            ContentUnavailableView(
                L10n.t("暂无日志"),
                systemImage: "doc.text",
                description: Text(errorMessage ?? L10n.t("该容器暂未产生日志"))
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentWidthLimit(860)
                }
                .onChange(of: logLines.count) { _, _ in
                    guard isFollowing, !logLines.isEmpty else { return }
                    followScrollTask?.cancel()
                    followScrollTask = Task {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        guard !Task.isCancelled else { return }
                        withAnimation(Motion.standard) {
                            proxy.scrollTo(logLines.count - 1, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: scrollToBottomTrigger) { _, _ in
                    if !logLines.isEmpty {
                        withAnimation(Motion.standard) {
                            proxy.scrollTo(logLines.count - 1, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: isFollowing) { _, following in
                    if following && !logLines.isEmpty {
                        withAnimation(Motion.standard) {
                            proxy.scrollTo(logLines.count - 1, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    if isFollowing && !logLines.isEmpty {
                        proxy.scrollTo(logLines.count - 1, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func startStreaming() async {
        streamTask?.cancel()
        logLines.removeAll()
        errorMessage = nil
        isLoading = true

        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "compose", value: composePath),
            URLQueryItem(name: "since", value: sinceMode),
            URLQueryItem(name: "tail", value: String(tail)),
            URLQueryItem(name: "follow", value: "true"),
            URLQueryItem(name: "timestamp", value: "false"),
            URLQueryItem(name: "operateNode", value: "local")
        ]

        streamTask = Task {
            // 批量落地缓冲：同一帧内多次写 @State 会触发 onChange 告警
            final class LogBuffer { var pending: [String] = [] }
            let buffer = LogBuffer()
            let maxLines = max(tail * 5, 1000)
            @MainActor func flush() {
                guard !buffer.pending.isEmpty else { return }
                let chunk = buffer.pending
                buffer.pending.removeAll()
                if logLines.count + chunk.count > maxLines {
                    logLines.removeFirst(min(logLines.count, logLines.count + chunk.count - maxLines))
                }
                logLines.append(contentsOf: chunk)
            }
            do {
                let stream = client.streamSSELines(
                    path: "/api/v2/containers/search/log",
                    queryItems: queryItems
                )
                let flusher = Task { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        flush()
                    }
                }
                defer { flusher.cancel() }
                for try await line in stream {
                    if Task.isCancelled { break }
                    buffer.pending.append(line)
                }
                isLoading = false
            } catch {
                isLoading = false
                if logLines.isEmpty && buffer.pending.isEmpty {
                    errorMessage = error.localizedDescription
                }
            }
            // 正常结束 / 异常中断：落地剩余缓冲（catch 也走得到）
            flush()
        }
    }
}
