//
//  LogsView.swift
//  1PanelClient
//
//  日志模块：日志记录（操作/访问/登陆 三段合一）、系统日志、网站日志
//  基于网页端抓包（logs/日志/*.md）
//

import SwiftUI

// MARK: - 日志入口

struct LogsView: View {
    let server: ServerConfig

    var body: some View {
        List {
            Section {
                NavigationLink {
                    RecordsLogView(server: server)
                } label: {
                    logMenuRow(L10n.t("日志记录"), icon: "square.and.pencil", color: .blue, subtitle: L10n.t("操作 / 访问 / 登陆记录"))
                }
                NavigationLink {
                    SystemLogView(server: server)
                } label: {
                    logMenuRow(L10n.t("系统日志"), icon: "gearshape.2", color: .orange, subtitle: L10n.t("1Panel 运行日志"))
                }
                NavigationLink {
                    WebsiteLogsView(server: server)
                } label: {
                    logMenuRow(L10n.t("网站日志"), icon: "globe", color: .teal, subtitle: L10n.t("网站运行与错误日志"))
                }
            }
        }
        .navigationTitle(L10n.t("日志"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func logMenuRow(_ title: String, icon: String, color: Color, subtitle: String) -> some View {
        HStack(spacing: 12) {
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

// MARK: - 日志记录（操作 / 访问 / 登陆 三段合一）

/// 记录类日志合一页：顶部全宽固定分段条（全站统一口径）。
/// 三段各持 PageVMStore 缓存的 VM——切换即显已缓存数据，autoRefresh 按需收敛
struct RecordsLogView: View {
    let server: ServerConfig
    @State private var segment = 0

    var body: some View {
        Group {
            switch segment {
            case 0: OperationLogView(server: server)
            case 1: LoginLogView(server: server)
            default: SSHLogView(server: server)
            }
        }
        // 分段条全宽固定顶部（KVM/运行环境同款）
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker(L10n.t("类型"), selection: $segment) {
                Text(L10n.t("操作日志")).tag(0)
                Text(L10n.t("访问日志")).tag(1)
                Text(L10n.t("登陆日志")).tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .navigationTitle(L10n.t("日志记录"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 操作日志

struct OperationLogView: View {
    let server: ServerConfig
    @StateObject private var vm: LogListViewModel<OperationLogItem>
    // 清空（操作日志段右上角）
    @State private var showCleanConfirm = false
    @State private var isCleaning = false
    @State private var toast: String?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        let client = APIClient.shared(for: server)
        self.client = client
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(
            key: PageVMStore.pageKey("logs.operation", server: server)) {
            LogListViewModel(pageSize: 100) { page in
                let resp: OperationLogResponse = try await client.send(
                    path: APIEndpoint.logsOperation.path,
                    body: OperationLogRequest(page: page, pageSize: 100),
                    as: OperationLogResponse.self
                )
                return (resp.items ?? [], resp.total)
            }
        })
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.items.isEmpty {
                LoadingStateView()
            } else if let errorMessage = vm.errorMessage, vm.items.isEmpty {
                LoadErrorStateView(message: errorMessage) {
                    Task { await vm.load() }
                }
            } else if vm.items.isEmpty {
                ContentUnavailableView(L10n.t("暂无操作日志"), systemImage: "square.and.pencil")
            } else {
                List {
                    ForEach(vm.items) { item in
                        row(item)
                            .onAppear {
                                if item.id == vm.items.last?.id {
                                    Task { await vm.loadMore() }
                                }
                            }
                    }
                    if vm.hasMore || vm.isLoadingMore {
                        logLoadMoreRow { Task { await vm.loadMore() } }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .refreshable { await vm.load() }
        .task { await PageVMStore.shared.autoRefresh(vm: vm) { await vm.load() } }
        // 操作日志段专属（段视图仅在分段激活时存在于层级，toolbar 随段显隐）
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCleanConfirm = true
                } label: {
                    if isCleaning {
                        ProgressView()
                    } else {
                        Image(systemName: "trash")
                    }
                }
                .disabled(isCleaning)
                .accessibilityLabel(L10n.t("清空日志"))
            }
        }
        .sheet(isPresented: $showCleanConfirm) {
            TextInputConfirmSheet(
                title: L10n.t("清空日志"),
                message: L10n.t("删除操作不可回滚，是否继续？\n如果确认操作，请手动输入 '清空日志'"),
                expectedText: L10n.t("清空日志"),
                confirmTitle: L10n.t("清空")
            ) {
                await cleanLogs()
            }
        }
        .toastOverlay(message: $toast)
    }

    /// 清空操作日志（logType=operation；成功刷新列表）
    private func cleanLogs() async {
        isCleaning = true
        defer { isCleaning = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.logsClean.path,
                body: CoreLogCleanRequest(logType: "operation"),
                as: EmptyResponse.self
            )
            await vm.load()
            toast = L10n.t("日志已清空")
            Haptic.success()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            toast = error.localizedDescription
        }
    }

    private func row(_ item: OperationLogItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
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
}

// MARK: - 访问日志（面板登录）

struct LoginLogView: View {
    let server: ServerConfig
    @StateObject private var vm: LogListViewModel<LoginLogItem>
    // 清空（访问日志段右上角）
    @State private var showCleanConfirm = false
    @State private var isCleaning = false
    @State private var toast: String?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        let client = APIClient.shared(for: server)
        self.client = client
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(
            key: PageVMStore.pageKey("logs.login", server: server)) {
            LogListViewModel(pageSize: 100) { page in
                let resp: LoginLogResponse = try await client.send(
                    path: APIEndpoint.logsLogin.path,
                    body: LoginLogRequest(page: page, pageSize: 100),
                    as: LoginLogResponse.self
                )
                return (resp.items ?? [], resp.total)
            }
        })
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.items.isEmpty {
                LoadingStateView()
            } else if let errorMessage = vm.errorMessage, vm.items.isEmpty {
                LoadErrorStateView(message: errorMessage) {
                    Task { await vm.load() }
                }
            } else if vm.items.isEmpty {
                ContentUnavailableView(L10n.t("暂无访问日志"), systemImage: "person.badge.key")
            } else {
                List {
                    ForEach(vm.items) { item in
                        row(item)
                            .onAppear {
                                if item.id == vm.items.last?.id {
                                    Task { await vm.loadMore() }
                                }
                            }
                    }
                    if vm.hasMore || vm.isLoadingMore {
                        logLoadMoreRow { Task { await vm.loadMore() } }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .refreshable { await vm.load() }
        .task { await PageVMStore.shared.autoRefresh(vm: vm) { await vm.load() } }
        // 访问日志段专属（段视图仅在分段激活时存在于层级，toolbar 随段显隐）
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCleanConfirm = true
                } label: {
                    if isCleaning {
                        ProgressView()
                    } else {
                        Image(systemName: "trash")
                    }
                }
                .disabled(isCleaning)
                .accessibilityLabel(L10n.t("清空日志"))
            }
        }
        .sheet(isPresented: $showCleanConfirm) {
            TextInputConfirmSheet(
                title: L10n.t("清空日志"),
                message: L10n.t("删除操作不可回滚，是否继续？\n如果确认操作，请手动输入 '清空日志'"),
                expectedText: L10n.t("清空日志"),
                confirmTitle: L10n.t("清空")
            ) {
                await cleanLogs()
            }
        }
        .toastOverlay(message: $toast)
    }

    /// 清空面板登录日志（logType=login；成功刷新列表）
    private func cleanLogs() async {
        isCleaning = true
        defer { isCleaning = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.logsClean.path,
                body: CoreLogCleanRequest(logType: "login"),
                as: EmptyResponse.self
            )
            await vm.load()
            toast = L10n.t("日志已清空")
            Haptic.success()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            toast = error.localizedDescription
        }
    }

    private func row(_ item: LoginLogItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(item.user?.isEmpty == false ? item.user! : L10n.t("未知用户"))
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
}

/// 日志列表滚动到底的加载更多行（操作/访问日志共用）
private func logLoadMoreRow(_ action: @escaping () -> Void) -> some View {
    LoadingStateView(compact: true)
    .onAppear { action() }
}

// MARK: - 系统日志（按日期查看日志文件行）

struct SystemLogView: View {
    let server: ServerConfig
    /// 指定节点名查看该节点系统日志（多机管理入口传入）；
    /// nil = 跟随当前操作节点（CurrentNode 请求头路由）
    var nodeName: String? = nil
    @State private var dates: [String] = []
    @State private var selectedDate = ""
    @State private var lines: [String] = []
    @State private var logPath: String?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig, nodeName: String? = nil) {
        self.server = server
        self.nodeName = nodeName
        self.client = APIClient.shared(for: server)
    }

    /// 显式指定节点时以查询参数路由（优先级高于请求头）
    private var nodeQuery: [URLQueryItem]? {
        nodeName.map { [URLQueryItem(name: "operateNode", value: $0)] }
    }

    var body: some View {
        Group {
            if isLoading && dates.isEmpty {
                LoadingStateView()
            } else if let errorMessage, dates.isEmpty {
                LoadErrorStateView(message: errorMessage) {
                    Task { await loadDates() }
                }
            } else if dates.isEmpty {
                ContentUnavailableView(L10n.t("暂无系统日志"), systemImage: "gearshape.2")
            } else {
                List {
                    Section {
                        Picker(L10n.t("日期"), selection: $selectedDate) {
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
                            // B3：空态形态统一为 ContentUnavailableView
                            ContentUnavailableView(L10n.t("该日期暂无日志"), systemImage: "doc.text.magnifyingglass")
                                .listRowBackground(Color.clear)
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
        .navigationTitle(L10n.t("系统日志"))
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
                queryItems: nodeQuery,
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
                path: APIEndpoint.logsReadSystem.path,
                body: SystemLogReadRequest(name: selectedDate, page: 1, pageSize: 500, latest: true),
                queryItems: nodeQuery,
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
    /// 非分页接口：fetchPage 忽略页码返回全量，loadMore 因 total 收敛空转
    @StateObject private var vm: LogListViewModel<SSHLogItem>
    // 清空 / 导出（登陆日志段右上角）
    @State private var showCleanConfirm = false
    @State private var showExportSheet = false
    @State private var isCleaning = false
    @State private var isExporting = false
    @State private var toast: String?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        let client = APIClient.shared(for: server)
        self.client = client
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(
            key: PageVMStore.pageKey("logs.ssh", server: server)) {
            LogListViewModel(pageSize: 100) { _ in
                let resp: SSHLogResponse = try await client.send(
                    path: APIEndpoint.logsSSHLog.path,
                    body: SSHLogRequest(),
                    as: SSHLogResponse.self
                )
                let items = resp.items ?? []
                return (items, items.count)
            }
        })
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.items.isEmpty {
                LoadingStateView()
            } else if let errorMessage = vm.errorMessage, vm.items.isEmpty {
                LoadErrorStateView(message: errorMessage) {
                    Task { await vm.load() }
                }
            } else if vm.items.isEmpty {
                ContentUnavailableView(L10n.t("暂无登陆日志"), systemImage: "terminal")
            } else {
                List(vm.items) { item in
                    row(item)
                }
                .listStyle(.insetGrouped)
            }
        }
        .refreshable { await vm.load() }
        .task { await PageVMStore.shared.autoRefresh(vm: vm) { await vm.load() } }
        // 登陆日志段专属操作（段视图仅在分段激活时存在于层级，toolbar 随段显隐）
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showExportSheet = true
                } label: {
                    if isExporting {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .disabled(isExporting)
                .accessibilityLabel(L10n.t("导出"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCleanConfirm = true
                } label: {
                    if isCleaning {
                        ProgressView()
                    } else {
                        Image(systemName: "trash")
                    }
                }
                .disabled(isCleaning)
                .accessibilityLabel(L10n.t("清空日志"))
            }
        }
        .sheet(isPresented: $showCleanConfirm) {
            TextInputConfirmSheet(
                title: L10n.t("清空日志"),
                message: L10n.t("删除操作不可回滚，是否继续？\n如果确认操作，请手动输入 '清空日志'"),
                expectedText: L10n.t("清空日志"),
                confirmTitle: L10n.t("清空")
            ) {
                await cleanLogs()
            }
        }
        .sheet(isPresented: $showExportSheet) {
            SSHLogExportSheet(client: client, isExporting: $isExporting) { message in
                toast = message
                Haptic.success()
            }
        }
        .toastOverlay(message: $toast)
    }

    /// 清空登陆日志（输字确认后调用；成功刷新列表）
    private func cleanLogs() async {
        isCleaning = true
        defer { isCleaning = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.logsSSHLogClean.path,
                body: SSHLogCleanRequest(),
                as: EmptyResponse.self
            )
            await vm.load()
            toast = L10n.t("日志已清空")
            Haptic.success()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            toast = error.localizedDescription
        }
    }

    private func row(_ item: SSHLogItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
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
}

// MARK: - 登陆日志导出（状态/条数筛选 → 服务器生成 csv → files/download 落盘）

private struct SSHLogExportSheet: View {
    let client: APIClient
    /// 导出进行中回写宿主按钮态
    @Binding var isExporting: Bool
    /// 成功提示回调（宿主 toast；已含保存位置）
    let onSaved: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var status = "All"
    @State private var pageSize = -1
    @State private var errorMessage: String?

    private let statusOptions: [(value: String, label: String)] = [
        ("All", L10n.t("所有")), ("Success", L10n.t("成功")), ("Failed", L10n.t("失败")),
    ]
    /// -1 = 所有（抓包口径：pageSize 传 -1 不限条数）
    private let sizeOptions: [(value: Int, label: String)] = [
        (-1, L10n.t("所有")), (100, "100"), (200, "200"), (500, "500"), (1000, "1000"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    OutlinedPicker(label: L10n.t("状态"),
                                   options: statusOptions.map(\.value),
                                   selection: $status,
                                   optionLabels: Dictionary(uniqueKeysWithValues:
                                       statusOptions.map { ($0.value, $0.label) }))
                    OutlinedPicker(label: L10n.t("条数"),
                                   options: sizeOptions.map { String($0.value) },
                                   selection: pageSizeText,
                                   optionLabels: Dictionary(uniqueKeysWithValues:
                                       sizeOptions.map { (String($0.value), $0.label) }))
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Section {
                    Button {
                        Task { await export() }
                    } label: {
                        HStack {
                            if isExporting { ProgressView() }
                            Text(L10n.t("导出"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(isExporting)
                }
            }
            .navigationTitle(L10n.t("导出日志"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var pageSizeText: Binding<String> {
        Binding(
            get: { String(pageSize) },
            set: { pageSize = Int($0) ?? -1 }
        )
    }

    /// 先导出拿服务器 csv 路径，再经 files/download 下载落盘（备份下载同款链路）
    private func export() async {
        isExporting = true
        errorMessage = nil
        defer { isExporting = false }
        do {
            let serverPath: String = try await client.send(
                path: APIEndpoint.logsSSHLogExport.path,
                body: SSHLogExportRequest(status: status, pageSize: pageSize),
                as: String.self
            )
            // 临时文件名只用最后一段，防止服务端异常数据拼出目录穿越路径
            let fileName = (serverPath as NSString).lastPathComponent
            let temp = try await client.downloadFile(
                path: APIEndpoint.filesDownload.path,
                queryItems: [
                    URLQueryItem(name: "operateNode", value: "local"),
                    URLQueryItem(name: "path", value: serverPath),
                ],
                fileName: fileName
            )
            let saved = try LocalDownloads.move(tempFile: temp, fileName: fileName, category: .exports)
            dismiss()
            onSaved(saved.successMessage)
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 网站日志（下拉选择网站，读取 access.log）

struct WebsiteLogsView: View {
    let server: ServerConfig
    @State private var sites: [Website] = []
    @State private var selectedSiteID = 0
    /// 日志文件名：access.log=运行日志 error.log=错误日志（顶部固定分段切换）
    @State private var logName = "access.log"
    @State private var lines: [String] = []
    @State private var logPath: String?
    @State private var isLoading = true
    @State private var errorMessage: String?
    // 清空 / 下载（右上角）
    @State private var showCleanConfirm = false
    @State private var isCleaning = false
    @State private var isDownloading = false
    @State private var toast: String?

    private let client: APIClient

    /// 日志类型（名称即 operate/delete 的 logType 与读取请求的 name）
    private let logTypes: [(name: String, label: String)] = [
        ("access.log", L10n.t("运行日志")),
        ("error.log", L10n.t("错误日志")),
    ]

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient.shared(for: server)
    }

    /// 当前选中网站
    private var selectedSite: Website? {
        sites.first { $0.id == selectedSiteID }
    }

    private var currentTypeLabel: String {
        logTypes.first { $0.name == logName }?.label ?? logName
    }

    var body: some View {
        Group {
            if isLoading && sites.isEmpty {
                LoadingStateView()
            } else if let errorMessage, sites.isEmpty {
                LoadErrorStateView(message: errorMessage) {
                    Task { await loadSites() }
                }
            } else if sites.isEmpty {
                ContentUnavailableView(L10n.t("暂无网站"), systemImage: "globe", description: Text(L10n.t("请先创建网站")))
            } else {
                List {
                    Section {
                        Picker(L10n.t("网站"), selection: $selectedSiteID) {
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
                            ContentUnavailableView(
                                L10n.f("该网站暂无%@", currentTypeLabel),
                                systemImage: "doc.text.magnifyingglass"
                            )
                            .listRowBackground(Color.clear)
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
                // 日志类型分段条全宽固定顶部（网站监控板块同款）：网站选择器保留列表首段
                .safeAreaInset(edge: .top, spacing: 0) {
                    Picker(L10n.t("日志类型"), selection: $logName) {
                        ForEach(logTypes, id: \.name) { t in
                            Text(t.label).tag(t.name)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .onChange(of: logName) { _, _ in
                        Task { await loadLines() }
                    }
                }
            }
        }
        .navigationTitle(L10n.t("网站日志"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await downloadLog() }
                } label: {
                    if isDownloading {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
                // 直连日志文件下载：路径来自读取响应，未加载到前不可用
                .disabled(isDownloading || (logPath ?? "").isEmpty)
                .accessibilityLabel(L10n.t("下载"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCleanConfirm = true
                } label: {
                    if isCleaning {
                        ProgressView()
                    } else {
                        Image(systemName: "trash")
                    }
                }
                .disabled(isCleaning)
                .accessibilityLabel(L10n.t("清空日志"))
            }
        }
        .sheet(isPresented: $showCleanConfirm) {
            TextInputConfirmSheet(
                title: L10n.t("清空日志"),
                message: L10n.t("删除操作不可回滚，是否继续？\n如果确认操作，请手动输入 '清空日志'"),
                expectedText: L10n.t("清空日志"),
                confirmTitle: L10n.t("清空")
            ) {
                await cleanLog()
            }
        }
        .toastOverlay(message: $toast)
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
                path: APIEndpoint.logsReadWebsite.path,
                body: WebsiteLogReadRequest(id: selectedSiteID, type: "website", name: logName, page: 1, pageSize: 500, latest: true),
                queryItems: client.operateNodeQuery,
                as: WebsiteLogResponse.self
            )
            lines = resp.lines ?? []
            logPath = resp.path
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// 清空当前网站的当前类型日志（websites/log/operate delete；成功重读）
    private func cleanLog() async {
        guard selectedSiteID > 0 else { return }
        isCleaning = true
        defer { isCleaning = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesLogOperate.path,
                body: WebsiteLogOperateRequest(id: selectedSiteID, operate: "delete", logType: logName),
                as: EmptyResponse.self
            )
            await loadLines()
            toast = L10n.t("日志已清空")
            Haptic.success()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            toast = error.localizedDescription
        }
    }

    /// 直连下载当前日志文件（单请求 files/download，路径来自读取响应）
    private func downloadLog() async {
        guard let path = logPath, !path.isEmpty else { return }
        isDownloading = true
        defer { isDownloading = false }
        do {
            let fileName = (path as NSString).lastPathComponent
            let temp = try await client.downloadFile(
                path: APIEndpoint.filesDownload.path,
                queryItems: [
                    URLQueryItem(name: "operateNode", value: "local"),
                    URLQueryItem(name: "path", value: path),
                ],
                fileName: fileName
            )
            let saved = try LocalDownloads.move(tempFile: temp, fileName: fileName, category: .exports)
            toast = saved.successMessage
            Haptic.success()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            toast = L10n.f("下载失败：%@", error.localizedDescription)
        }
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
            .contentWidthLimit(860)
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
        f.locale = L10n.locale
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    static func short(_ iso: String?) -> String {
        guard let iso, let date = MonitorDate.parse(iso) else { return iso ?? "" }
        return display.string(from: date)
    }
}
