//
//  AIAgentWeixinChannelView.swift
//  1PanelClient
//
//  微信频道（扫码对接 + 任务日志二维码）（自 AIAgentChannelViews.swift 拆出，内容未改动）
//

import SwiftUI

// MARK: - 微信（扫码对接 + 任务日志二维码）

struct AIAgentWeixinChannelView: View {
    let server: ServerConfig
    let agentId: Int
    let initialEnabled: Bool
    /// OpenClaw 的频道为插件（版本/卸载），抓包确认
    var agentType: String? = nil

    @State private var enabled = false
    /// 微信频道无 get 接口：插件 installed 作为对接状态的替代信号，
    /// 驱动「删除对接」入口（否则重进页面后入口消失）
    @State private var pluginInstalled = false
    @State private var isLoggingIn = false
    @State private var logLines: [String] = []
    @State private var qrURL: String?
    @State private var isPolling = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var confirmDelete = false

    private let client: APIClient

    /// Hermes 网页端频道无启用开关（核对隐藏）
    private var isHermes: Bool { agentType == "hermes-agent" }

    init(server: ServerConfig, agentId: Int, initialEnabled: Bool, agentType: String? = nil) {
        self.server = server
        self.agentId = agentId
        self.initialEnabled = initialEnabled
        self.agentType = agentType
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        List {
            if agentType == "openclaw" {
                ChannelPluginSection(client: client, agentId: agentId, type: "weixin",
                                     onUninstalled: {
                                         enabled = false
                                         pluginInstalled = false
                                         qrURL = nil
                                     },
                                     onStatus: { status in
                                         pluginInstalled = (status?.installed == true)
                                     })
            }

            // 顶层状态开关仅 QwenPaw 显示；Hermes（网页无开关）与
            // OpenClaw（网页核对：仅插件区信息，无顶层开关）均隐藏
            if agentType != "openclaw", !isHermes {
                Section {
                    Toggle(L10n.t("启用"), isOn: Binding(
                        get: { enabled },
                        set: { newValue in
                            if !newValue { return } // 微信经扫码对接启用，关闭走删除
                            enabled = newValue
                        }
                    ))
                    .disabled(true)
                } footer: {
                    Text(L10n.t("微信频道通过扫码对接启用，关闭需删除对接"))
                }
            }

            Section {
                if let url = qrURL {
                    VStack(spacing: 14) {
                        QRCodeView(text: url, side: 200)
                        Text(L10n.t("请使用微信扫描二维码"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } else if isLoggingIn || isPolling {
                    HStack {
                        Spacer()
                        ProgressView()
                        Text(L10n.t("正在生成二维码…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    Button {
                        Task { await startLogin() }
                    } label: {
                        Label(L10n.t("扫码对接"), systemImage: "qrcode.viewfinder")
                    }
                    .disabled(isLoggingIn)
                }
            } header: {
                SectionLabel(title: L10n.t("扫码对接"), systemImage: "qrcode")
            }

            if !logLines.isEmpty {
                Section {
                    ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } header: {
                    SectionLabel(title: L10n.t("对接日志"), systemImage: "doc.text")
                }
            }

            if enabled || pluginInstalled {
                Section {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label(L10n.t("删除对接"), systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(L10n.t("微信"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .task {
            enabled = initialEnabled || enabled
        }
        // 微信无 get 接口：下拉刷新插件安装状态（驱动「删除对接」入口可见性）
        .refreshable {
            if let resp: AIAgentPluginStatus = try? await client.send(
                path: APIEndpoint.aiAgentPluginCheck.path,
                body: AIAgentPluginCheckRequest(agentId: agentId, type: "weixin", checkLatest: false),
                as: AIAgentPluginStatus.self) {
                pluginInstalled = (resp.installed == true)
            }
        }
        .onDisappear { isPolling = false }
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(L10n.t("删除对接"), isPresented: $confirmDelete) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("删除"), role: .destructive) {
                Task { await deleteChannel() }
            }
        } message: {
            Text(L10n.t("确定删除微信频道对接吗？"))
        }
    }

    /// 发起扫码对接：taskID 由客户端生成随请求体发出（抓包确认响应 data 为 null），
    /// 按该 taskID 轮询任务日志提取二维码
    private func startLogin() async {
        isLoggingIn = true
        defer { isLoggingIn = false }
        let taskID = UUID().uuidString
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentWeixinLogin.path,
                body: AIAgentWeixinLoginRequest(agentId: agentId, taskID: taskID),
                as: EmptyResponse.self)
            startPolling(taskID: taskID)
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// 轮询任务日志：仅按 taskID 查询（taskType/taskOperate/name/resourceID
    /// 均为空、latest=false 从头读，抓包确认）
    private func startPolling(taskID: String) {
        isPolling = true
        Task {
            while isPolling && !Task.isCancelled {
                do {
                    let resp: TaskLogResponse = try await client.send(
                        path: APIEndpoint.logsTaskRead.path,
                        body: TaskLogReadRequest(
                            id: 0, type: "task", name: "",
                            page: 1, pageSize: 500, latest: false,
                            taskID: taskID,
                            taskType: "", taskOperate: "",
                            resourceID: 0),
                        queryItems: [URLQueryItem(name: "operateNode", value: "local")],
                        as: TaskLogResponse.self)
                    let lines = (resp.lines ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
                    await MainActor.run {
                        logLines = lines
                        if qrURL == nil {
                            qrURL = Self.extractQRURL(from: lines)
                            if qrURL != nil {
                                enabled = true
                            }
                        }
                    }
                    // 任务结束（Success/Failed）停止轮询
                    let status = (resp.taskStatus ?? "").lowercased()
                    if resp.end == true && status != "executing" { break }
                } catch {
                    // 轮询失败静默重试
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            await MainActor.run { isPolling = false }
        }
    }

    /// 从日志行提取二维码链接（优先微信 liteapp，兜底任意 http 链接）
    static func extractQRURL(from lines: [String]) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        var candidates: [String] = []
        for line in lines {
            guard let detector else { break }
            let range = NSRange(line.startIndex..., in: line)
            for match in detector.matches(in: line, range: range) {
                if let url = match.url?.absoluteString {
                    candidates.append(url)
                }
            }
        }
        return candidates.first { $0.contains("liteapp.weixin.qq.com") }
            ?? candidates.first { !$0.contains("1panel") }
    }

    private func deleteChannel() async {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAgentChannelDelete.path,
                body: AIAgentChannelDeleteRequest(agentId: agentId, type: AIChannelKind.weixin.rawValue),
                as: EmptyResponse.self)
            enabled = false
            qrURL = nil
            logLines = []
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

