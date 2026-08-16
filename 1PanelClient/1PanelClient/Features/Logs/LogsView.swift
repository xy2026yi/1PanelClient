//
//  LogsView.swift
//  1PanelClient
//
//  日志模块：面板日志（操作/访问/系统）、SSH 登陆日志、网站日志
//  基于网页端抓包（logs/日志/*.md）
//

import SwiftUI

// MARK: - 日志入口

struct LogsView: View {
    let server: ServerConfig

    var body: some View {
        List {
            Section("面板日志") {
                NavigationLink {
                    OperationLogView(server: server)
                } label: {
                    logMenuRow("操作日志", icon: "square.and.pencil", color: .blue, subtitle: "面板 API 操作记录")
                }
                NavigationLink {
                    LoginLogView(server: server)
                } label: {
                    logMenuRow("访问日志", icon: "person.badge.key", color: .green, subtitle: "面板登录记录")
                }
                NavigationLink {
                    SystemLogView(server: server)
                } label: {
                    logMenuRow("系统日志", icon: "gearshape.2", color: .orange, subtitle: "1Panel 运行日志")
                }
            }

            Section("服务器日志") {
                NavigationLink {
                    SSHLogView(server: server)
                } label: {
                    logMenuRow("SSH 登陆日志", icon: "terminal", color: .indigo, subtitle: "SSH 登陆成功/失败记录")
                }
                NavigationLink {
                    WebsiteLogsView(server: server)
                } label: {
                    logMenuRow("网站日志", icon: "globe", color: .teal, subtitle: "网站访问日志文件")
                }
            }
        }
        .navigationTitle("日志")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func logMenuRow(_ title: String, icon: String, color: Color, subtitle: String) -> some View {
        HStack(spacing: 14) {
            IconBadge(systemName: icon, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 操作日志

struct OperationLogView: View {
    let server: ServerConfig
    @State private var items: [OperationLogItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient(server: server)
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("加载中…").frame(maxWidth: .infinity, minHeight: 200)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
            } else if items.isEmpty {
                ContentUnavailableView("暂无操作日志", systemImage: "square.and.pencil")
            } else {
                List(items) { item in
                    row(item)
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("操作日志")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func row(_ item: OperationLogItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.detailZH ?? item.path ?? "—")
                .font(.subheadline)
                .lineLimit(2)

            HStack(spacing: 8) {
                if let source = item.source, !source.isEmpty {
                    StatusBadge(text: source, color: .blue)
                }
                Text(item.status ?? "")
                    .font(.caption2.bold())
                    .foregroundStyle(LogUI.statusColor(item.status))
                if !item.latencyDisplay.isEmpty {
                    Text(item.latencyDisplay)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(LogDateFormat.short(item.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text("\(item.method?.uppercased() ?? "") \(item.path ?? "")")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(item.ip ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        isLoading = items.isEmpty
        do {
            let resp: OperationLogResponse = try await client.send(
                path: APIEndpoint.logsOperation.path,
                body: OperationLogRequest(),
                as: OperationLogResponse.self
            )
            items = resp.items ?? []
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - 访问日志（面板登录）

struct LoginLogView: View {
    let server: ServerConfig
    @State private var items: [LoginLogItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient(server: server)
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("加载中…").frame(maxWidth: .infinity, minHeight: 200)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
            } else if items.isEmpty {
                ContentUnavailableView("暂无访问日志", systemImage: "person.badge.key")
            } else {
                List(items) { item in
                    row(item)
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("访问日志")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func row(_ item: LoginLogItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(item.user?.isEmpty == false ? item.user! : "未知用户")
                    .font(.subheadline.bold())
                Text(item.ip ?? "")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(LogDateFormat.short(item.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(item.status ?? "")
                    .font(.caption2.bold())
                    .foregroundStyle(LogUI.statusColor(item.status))
                Text(item.address ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if let msg = item.message, !msg.isEmpty {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        isLoading = items.isEmpty
        do {
            let resp: LoginLogResponse = try await client.send(
                path: APIEndpoint.logsLogin.path,
                body: LoginLogRequest(),
                as: LoginLogResponse.self
            )
            items = resp.items ?? []
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - 系统日志（按日期查看日志文件行）

struct SystemLogView: View {
    let server: ServerConfig
    @State private var dates: [String] = []
    @State private var selectedDate = ""
    @State private var lines: [String] = []
    @State private var logPath: String?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient(server: server)
    }

    var body: some View {
        Group {
            if isLoading && dates.isEmpty {
                ProgressView("加载中…").frame(maxWidth: .infinity, minHeight: 200)
            } else if let errorMessage, dates.isEmpty {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") { Task { await loadDates() } }
                        .buttonStyle(.borderedProminent)
                }
            } else if dates.isEmpty {
                ContentUnavailableView("暂无系统日志", systemImage: "gearshape.2")
            } else {
                List {
                    Section {
                        Picker("日期", selection: $selectedDate) {
                            ForEach(dates, id: \.self) { d in
                                Text(d).tag(d)
                            }
                        }
                        .onChange(of: selectedDate) { _, _ in
                            Task { await loadLines() }
                        }
                    }
                    Section {
                        if lines.isEmpty {
                            Text("该日期暂无日志")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
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
        .navigationTitle("系统日志")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await loadDates()
            await loadLines()
        }
        .task {
            await loadDates()
            selectedDate = dates.first ?? ""
            await loadLines()
        }
    }

    private func loadDates() async {
        do {
            let resp: [String] = try await client.send(
                path: APIEndpoint.logsSystemFiles.path,
                method: APIEndpoint.logsSystemFiles.method,
                as: [String].self
            )
            dates = resp
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadLines() async {
        guard !selectedDate.isEmpty else { return }
        do {
            let resp: LogFileReadResponse = try await client.send(
                path: APIEndpoint.logsReadSystem.path + "?operateNode=local",
                body: SystemLogReadRequest(name: selectedDate, page: 1, pageSize: 500, latest: true),
                as: LogFileReadResponse.self
            )
            lines = resp.lines ?? []
            logPath = resp.path
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - SSH 登陆日志

struct SSHLogView: View {
    let server: ServerConfig
    @State private var items: [SSHLogItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient(server: server)
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("加载中…").frame(maxWidth: .infinity, minHeight: 200)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
            } else if items.isEmpty {
                ContentUnavailableView("暂无 SSH 登陆日志", systemImage: "terminal")
            } else {
                List(items) { item in
                    row(item)
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("SSH 登陆日志")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func row(_ item: SSHLogItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(item.user ?? "—")
                    .font(.subheadline.bold())
                Text("\(item.address ?? ""):\(item.port ?? "")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(LogDateFormat.short(item.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(item.status ?? "")
                    .font(.caption2.bold())
                    .foregroundStyle(LogUI.statusColor(item.status))
                if let mode = item.authMode, !mode.isEmpty {
                    StatusBadge(text: mode, color: .indigo)
                }
                Text(item.area ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if let msg = item.message, !msg.isEmpty {
                Text(msg)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        isLoading = items.isEmpty
        do {
            let resp: SSHLogResponse = try await client.send(
                path: APIEndpoint.logsSSHLog.path,
                body: SSHLogRequest(),
                as: SSHLogResponse.self
            )
            items = resp.items ?? []
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - 网站日志（下拉选择网站，读取 access.log）

struct WebsiteLogsView: View {
    let server: ServerConfig
    @State private var sites: [Website] = []
    @State private var selectedSiteID = 0
    @State private var lines: [String] = []
    @State private var logPath: String?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient(server: server)
    }

    /// 当前选中网站
    private var selectedSite: Website? {
        sites.first { $0.id == selectedSiteID }
    }

    var body: some View {
        Group {
            if isLoading && sites.isEmpty {
                ProgressView("加载中…").frame(maxWidth: .infinity, minHeight: 200)
            } else if let errorMessage, sites.isEmpty {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") { Task { await loadSites() } }
                        .buttonStyle(.borderedProminent)
                }
            } else if sites.isEmpty {
                ContentUnavailableView("暂无网站", systemImage: "globe", description: Text("请先创建网站"))
            } else {
                List {
                    Section {
                        Picker("网站", selection: $selectedSiteID) {
                            ForEach(sites) { site in
                                Text(site.alias ?? site.primaryDomain ?? "\(site.id)")
                                    .tag(site.id)
                            }
                        }
                        .onChange(of: selectedSiteID) { _, _ in
                            Task { await loadLines() }
                        }
                    }
                    Section {
                        if lines.isEmpty {
                            Text("该网站暂无访问日志")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
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
        .navigationTitle("网站日志")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await loadSites()
            await loadLines()
        }
        .task {
            await loadSites()
            if selectedSiteID == 0, let first = sites.first {
                selectedSiteID = first.id
            }
            await loadLines()
        }
    }

    private func loadSites() async {
        do {
            let resp: [Website] = try await client.send(
                path: APIEndpoint.logsWebsitesList.path,
                method: APIEndpoint.logsWebsitesList.method,
                as: [Website].self
            )
            sites = resp
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadLines() async {
        guard selectedSiteID > 0 else { return }
        do {
            let resp: WebsiteLogResponse = try await client.send(
                path: APIEndpoint.logsReadWebsite.path + "?operateNode=local",
                body: WebsiteLogReadRequest(id: selectedSiteID, type: "website", name: "access.log", page: 1, pageSize: 500, latest: true),
                as: WebsiteLogResponse.self
            )
            lines = resp.lines ?? []
            logPath = resp.path
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - 共用组件

/// 等宽日志行列表（系统/网站日志共用）
struct LogLinesView: View {
    let lines: [String]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: .infinity)
    }
}

/// 日志状态颜色
enum LogUI {
    static func statusColor(_ status: String?) -> Color {
        (status ?? "").lowercased() == "success" ? .green : .red
    }
}

/// 日志时间格式化（ISO8601 纳秒 → "MM-dd HH:mm:ss"）
enum LogDateFormat {
    static let display: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    static func short(_ iso: String?) -> String {
        guard let iso, let date = MonitorDate.parse(iso) else { return iso ?? "" }
        return display.string(from: date)
    }
}
