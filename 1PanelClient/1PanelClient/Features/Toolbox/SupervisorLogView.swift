//
//  SupervisorLogView.swift
//  1PanelClient
//
//  守护进程日志（运行/错误页签 + 追踪轮询 + 清空）与 Supervisor 设置页
//  （配置修改 / 服务日志 / 初始化入口）
//

import SwiftUI

// MARK: - 进程日志（运行 / 错误）

struct SupervisorProcessLogView: View {
    let server: ServerConfig
    let processName: String

    /// out.log 运行日志 / err.log 错误日志
    @State private var logFile = "out.log"
    @State private var lines: [String] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// 追踪：开启后每 3 秒刷新一次
    @State private var isTracking = false
    @State private var confirmClear = false
    @State private var isClearing = false

    private let client: APIClient

    init(server: ServerConfig, processName: String) {
        self.server = server
        self.processName = processName
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        List {
            Section {
                Picker(L10n.t("日志类型"), selection: $logFile) {
                    Text(L10n.t("运行日志")).tag("out.log")
                    Text(L10n.t("错误日志")).tag("err.log")
                }
                .pickerStyle(.segmented)
                .onChange(of: logFile) { _, _ in
                    Task { await load() }
                }

                Toggle(L10n.t("追踪"), isOn: $isTracking)

                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    HStack {
                        Label(L10n.t("清空当前日志"), systemImage: "trash")
                        if isClearing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isClearing)
            }

            Section {
                if isLoading && lines.isEmpty {
                    HStack {
                        Spacer()
                        LoadingStateView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else if let err = errorMessage, !err.isEmpty, lines.isEmpty {
                    LoadErrorStateView(message: err) {
                        Task { await load() }
                    }
                    .listRowBackground(Color.clear)
                } else if lines.isEmpty {
                    ContentUnavailableView(
                        L10n.t("暂无日志"),
                        systemImage: "doc.plaintext",
                        description: Text(L10n.f("进程「%@」暂无日志内容", processName))
                    )
                    .listRowBackground(Color.clear)
                } else {
                    LogLinesView(lines: lines)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                }
            } header: {
                Text(L10n.f("%@.%@", processName, logFile))
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("日志"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        // 追踪：定时拉取最新日志
        .task(id: isTracking) {
            guard isTracking else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { break }
                await load()
            }
        }
        .alert(L10n.t("清空日志"), isPresented: $confirmClear) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("清空"), role: .destructive) {
                Task { await clearLog() }
            }
        } message: {
            Text(L10n.t("确定清空当前日志吗？清空后不可恢复。"))
        }
    }

    private func load() async {
        let req = SupervisorLogReadRequest(
            type: "supervisor",
            name: "\(processName).\(logFile)",
            page: 1, pageSize: 500, latest: true)
        do {
            let resp: LogFileReadResponse = try await client.send(
                path: APIEndpoint.supervisorLogRead.path,
                body: req,
                queryItems: client.operateNodeQuery,
                as: LogFileReadResponse.self)
            lines = resp.lines ?? []
            errorMessage = nil
            // 追踪模式下不显示全屏 loading，静默刷新
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func clearLog() async {
        isClearing = true
        defer { isClearing = false }
        let req = SupervisorProcessFileRequest(
            name: processName, operate: "clear", file: logFile)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.supervisorProcessFile.path, body: req, as: EmptyResponse.self)
            lines = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 设置入口

struct SupervisorSettingsView: View {
    let server: ServerConfig
    @ObservedObject var vm: SupervisorViewModel

    var body: some View {
        List {
            Section {
                NavigationLink {
                    SupervisorConfigEditView(server: server)
                } label: {
                    Label(L10n.t("配置"), systemImage: "slider.horizontal.3")
                }
                NavigationLink {
                    SupervisorServiceLogView(server: server)
                } label: {
                    Label(L10n.t("服务日志"), systemImage: "doc.text.magnifyingglass")
                }
            } header: {
                SectionLabel(title: L10n.t("Supervisor 设置"), systemImage: "gearshape")
            }

            Section {
                NavigationLink {
                    SupervisorInitForm(vm: vm)
                } label: {
                    Label(L10n.t("初始化"), systemImage: "wand.and.stars")
                }
            } footer: {
                Text(L10n.t("重新执行初始化会再次接管配置文件并重启服务"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("Supervisor 设置"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 主配置编辑

/// supervisord.conf 全文编辑：config/get 加载，config/set 直接保存
struct SupervisorConfigEditView: View {
    let server: ServerConfig

    @State private var content = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var successMessage: String?
    @State private var errorMessage: String?
    /// 加载失败文案：编辑器不落地（防止把加载失败的空内容保存上去覆盖配置）
    @State private var loadErrorMessage: String?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else if let loadError = loadErrorMessage {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(loadError)
                } actions: {
                    Button(L10n.t("重试")) {
                        Task { await loadConfig() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                TextEditor(text: $content)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }
        .navigationTitle(L10n.t("配置"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("保存")) {
                    Task { await save() }
                }
                .disabled(isSaving || isLoading)
            }
        }
        .task { await loadConfig() }
        .localToast(message: $successMessage)
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func loadConfig() async {
        isLoading = true
        do {
            let resp: SupervisorConfigContent = try await client.send(
                path: APIEndpoint.supervisorConfigGet.path,
                body: SupervisorConfigGetRequest(type: "supervisord"),
                as: SupervisorConfigContent.self)
            content = resp.content ?? ""
            loadErrorMessage = nil
        } catch {
            loadErrorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.supervisorConfigSet.path,
                body: SupervisorConfigSetRequest(type: "supervisord", content: content),
                as: EmptyResponse.self)
            successMessage = L10n.t("已保存，重启服务后生效")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 服务日志

/// supervisord 服务日志（files/read/supervisord），支持追踪
struct SupervisorServiceLogView: View {
    let server: ServerConfig

    @State private var lines: [String] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isTracking = false

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        List {
            Section {
                Toggle(L10n.t("追踪"), isOn: $isTracking)
            }

            Section {
                if isLoading && lines.isEmpty {
                    HStack {
                        Spacer()
                        LoadingStateView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else if let err = errorMessage, !err.isEmpty, lines.isEmpty {
                    LoadErrorStateView(message: err) {
                        Task { await load() }
                    }
                    .listRowBackground(Color.clear)
                } else if lines.isEmpty {
                    ContentUnavailableView(L10n.t("暂无日志"), systemImage: "doc.plaintext")
                        .listRowBackground(Color.clear)
                } else {
                    LogLinesView(lines: lines)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("服务日志"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .task(id: isTracking) {
            guard isTracking else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { break }
                await load()
            }
        }
    }

    private func load() async {
        let req = SupervisorLogReadRequest(
            id: 0,
            type: "supervisord",
            name: "supervisor",
            page: 1, pageSize: 500, latest: true)
        do {
            let resp: LogFileReadResponse = try await client.send(
                path: APIEndpoint.supervisorLogRead.path,
                body: req,
                queryItems: client.operateNodeQuery,
                as: LogFileReadResponse.self)
            lines = resp.lines ?? []
            errorMessage = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
