//
//  TaskProgressView.swift
//  1PanelClient
//
//  任务进度视图：轮询任务日志，实时展示安装/卸载进度
//

import SwiftUI

/// 任务日志读取请求
struct TaskLogReadRequest: Encodable {
    let id: Int
    let type: String
    let name: String
    let page: Int
    let pageSize: Int
    let latest: Bool
    let taskID: String
    let taskType: String
    let taskOperate: String
    let resourceID: Int
}

/// 任务日志读取响应
struct TaskLogResponse: Decodable {
    let end: Bool?
    let taskStatus: String?      // Executing / Success / Failed
    let lines: [String]?
    let total: Int?
    let totalLines: Int?
}

/// 任务进度视图（轮询日志直到任务完成）
struct TaskProgressView: View {
    let taskID: String
    let title: String
    /// 参数 isDone=true 表示任务已完成，isDone=false 表示用户选择后台运行
    var onComplete: ((Bool) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []
    @State private var taskStatus = "Executing"
    @State private var pollCount = 0
    @State private var hasError = false

    private var server: ServerConfig {
        ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
    }

    private var isDone: Bool {
        taskStatus.lowercased() != "executing"
    }

    var body: some View {
        VStack(spacing: 0) {
            // 状态头部
            HStack(spacing: 12) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(statusColor)
                }
                Spacer()
            }
            .padding()
            .background(.regularMaterial)

            Divider()

            // 日志区域
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                        if !isDone {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("等待中…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding()
                }
                .onChange(of: lines.count) { _, _ in
                    withAnimation {
                        proxy.scrollTo(lines.count - 1, anchor: .bottom)
                    }
                }
            }

            Divider()

            // 底部按钮
            HStack {
                if isDone {
                    Button {
                        onComplete?(true)
                        dismiss()
                    } label: {
                        Text("完成")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        onComplete?(false)
                        dismiss()
                    } label: {
                        Text("后台运行")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .navigationTitle("任务进度")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isDone)
        .task {
            await startPolling()
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isDone {
            if taskStatus.lowercased() == "success" {
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
            }
        } else {
            ProgressView()
                .scaleEffect(1.2)
        }
    }

    private var statusText: String {
        switch taskStatus.lowercased() {
        case "executing": return "正在执行…"
        case "success":   return "执行成功"
        case "failed":    return "执行失败"
        default:          return taskStatus
        }
    }

    private var statusColor: Color {
        switch taskStatus.lowercased() {
        case "success": return .green
        case "failed":  return .red
        default:        return .secondary
        }
    }

    private func startPolling() async {
        let client = APIClient(server: server)
        let req = TaskLogReadRequest(
            id: 0, type: "task", name: "",
            page: 1, pageSize: 500,
            latest: true,
            taskID: taskID,
            taskType: "", taskOperate: "", resourceID: 0
        )

        // 轮询直到任务完成
        while !Task.isCancelled && !isDone {
            do {
                let resp: TaskLogResponse = try await client.send(
                    path: APIEndpoint.logsTaskRead.path,
                    body: req,
                    as: TaskLogResponse.self
                )
                lines = resp.lines ?? []
                if let status = resp.taskStatus {
                    taskStatus = status
                }
            } catch {
                // 偶发错误不中断轮询
                pollCount += 1
                if pollCount > 20 {
                    hasError = true
                    taskStatus = "Failed"
                    break
                }
            }
            if !isDone {
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }
}
