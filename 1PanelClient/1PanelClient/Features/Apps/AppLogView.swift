//
//  AppLogView.swift
//  1PanelClient
//

import SwiftUI

// MARK: - 应用日志查看（SSE 流式）

struct AppLogView: View {
    let app: AppInstall
    @ObservedObject var vm: AppsViewModel

    @State private var logLines: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isFollowing = true
    @State private var scrollToBottomTrigger = 0
    @State private var tail: Int = 200
    @State private var sinceMode = "all"
    @State private var streamTask: Task<Void, Never>?
    @State private var hasMoreAtTop = false

    /// 构造 compose 路径：path + /docker-compose.yml
    private var composePath: String {
        var p = app.path ?? ""
        if p.isEmpty {
            // 兜底：/opt/1panel/apps/<appKey>/<serviceName>/
            p = "/opt/1panel/apps/\(app.appKey ?? app.serviceName ?? "")/\(app.serviceName ?? "")"
        }
        if !p.hasSuffix("/") { p += "/" }
        return p + "docker-compose.yml"
    }

    private let sinceOptions: [(value: String, label: String)] = [
        ("all", L10n.t("全部")),
        ("30m", L10n.t("近30分钟")),
        ("2h", L10n.t("近2小时")),
        ("24h", L10n.t("近24小时")),
        ("7d", L10n.t("近7天"))
    ]

    var body: some View {
        VStack(spacing: 0) {
            // 工具条
            controlBar
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))

            Divider()

            // 日志内容
            logContent

            Divider()

            // 跟随尾部开关
            followBar
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemBackground))
        }
        .navigationTitle(L10n.t("应用日志"))
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
        .onDisappear { streamTask?.cancel() }
    }

    // 控制条
    private var controlBar: some View {
        HStack(spacing: 12) {
            // 时间范围
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

            // 行数
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
                .onChange(of: tail) { _, _ in
                    Task { await startStreaming() }
                }
            }
        }
    }

    // 跟随开关条
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
            FollowLatestButton(isFollowing: isFollowing) {
                isFollowing = true
                scrollToBottomTrigger += 1
            }
        }
    }

    // 日志内容主体
    @ViewBuilder
    private var logContent: some View {
        if logLines.isEmpty && isLoading {
            LoadingStateView(text: L10n.t("加载日志…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if logLines.isEmpty {
            ContentUnavailableView(
                L10n.t("暂无日志"),
                systemImage: "doc.text",
                description: Text(errorMessage ?? L10n.t("该应用暂未产生日志"))
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.dataMonospacedCaption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentWidthLimit(860)
                }
                .onChange(of: logLines.count) { _, _ in
                    if isFollowing {
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

    // 启动/重启流式拉取
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

        // 控制最大缓存行数，避免内存爆炸
        let maxLines = max(tail * 5, 1000)
        // 逐行写 @State 会在 SSE 高频到达时同一帧内多次触发
        // onChange(of: count) 滚动（"multiple times per frame" 警告）。
        // 消费任务只进缓冲，冲刷循环每 150ms 把缓冲一次性并入 @State
        let buffer = SSELineBuffer()
        streamTask = Task {
            let consume = Task {
                do {
                    for try await line in vm.client.streamSSELines(
                        path: "/api/v2/containers/search/log",
                        queryItems: queryItems
                    ) {
                        if Task.isCancelled { break }
                        buffer.append(line)
                    }
                    buffer.finish(error: nil)
                } catch {
                    buffer.finish(error: error)
                }
            }
            defer { consume.cancel() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                let (chunk, finished, streamError) = buffer.drain()
                if !chunk.isEmpty {
                    await MainActor.run {
                        let overflow = logLines.count + chunk.count - maxLines
                        if overflow > 0 {
                            logLines.removeFirst(min(overflow, logLines.count))
                        }
                        logLines.append(contentsOf: chunk)
                    }
                }
                if finished {
                    await MainActor.run {
                        isLoading = false
                        if logLines.isEmpty, let streamError {
                            errorMessage = streamError.localizedDescription
                        }
                    }
                    break
                }
            }
        }
    }
}

/// SSE 行缓冲：消费任务写入、冲刷循环读出（锁保护跨任务访问）
private final class SSELineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var finished = false
    private var streamError: Error?

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    /// 流结束（error=nil 正常结束）；取消中断不调用
    func finish(error: Error?) {
        lock.lock()
        streamError = error
        finished = true
        lock.unlock()
    }

    /// 取出全部积压行与结束状态
    func drain() -> (lines: [String], finished: Bool, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        let result = (lines, finished, streamError)
        lines = []
        return result
    }
}

