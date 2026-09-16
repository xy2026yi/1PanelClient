//
//  ProcessView.swift
//  1PanelClient
//
//  进程监控视图：实时进程列表 + 网络连接 + 搜索 + 排序 + 结束进程
//

import SwiftUI

struct ProcessView: View {
    @StateObject private var monitor: ProcessMonitor

    @State private var searchText = ""
    @State private var isSearching = false
    @State private var sortOption: SortOption = .cpu
    @State private var selectedProcess: ProcessItem?
    @State private var showStopConfirm = false
    @State private var stopTarget: ProcessItem?

    enum SortOption: String, CaseIterable, Identifiable {
        case cpu = "CPU"
        case memory = "内存"
        case pid = "PID"
        case name = "名称"
        var id: String { rawValue }
    }

    init(server: ServerConfig) {
        _monitor = StateObject(wrappedValue: ProcessMonitor(server: server))
    }

    private var filteredProcesses: [ProcessItem] {
        var result = monitor.processes
        let keyword = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !keyword.isEmpty {
            result = result.filter {
                $0.name.lowercased().contains(keyword) ||
                String($0.pid).contains(keyword) ||
                $0.username.lowercased().contains(keyword)
            }
        }
        switch sortOption {
        case .cpu:    result.sort { ($0.cpuValue ?? 0) > ($1.cpuValue ?? 0) }
        case .memory: result.sort { ($0.rssValue ?? 0) > ($1.rssValue ?? 0) }
        case .pid:    result.sort { $0.pid < $1.pid }
        case .name:   result.sort { $0.name.lowercased() < $1.name.lowercased() }
        }
        return result
    }

    private var filteredConnections: [NetworkConnection] {
        let keyword = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if keyword.isEmpty { return monitor.connections }
        return monitor.connections.filter {
            $0.name.lowercased().contains(keyword) ||
            String($0.pid).contains(keyword) ||
            "\($0.localaddr.port)".contains(keyword) ||
            "\($0.remoteaddr.port)".contains(keyword)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            contentView
        }
        .navigationTitle(L10n.t("进程"))
        .navigationBarTitleDisplayMode(.inline)
        .searchIconMode(
            text: $searchText,
            isSearching: $isSearching,
            title: L10n.t("进程"),
            prompt: searchTextPrompt
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if monitor.mode == .processes {
                        Picker(L10n.t("排序"), selection: $sortOption) {
                            ForEach(SortOption.allCases) { opt in
                                Text(L10n.t(opt.rawValue)).tag(opt)
                            }
                        }
                        Divider()
                    }
                    Toggle(L10n.t("自动刷新"), isOn: $monitor.isAutoRefresh)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear { monitor.connect() }
        .onDisappear { monitor.disconnect() }
        .navigationDestination(isPresented: Binding(
            get: { selectedProcess != nil },
            set: { if !$0 { selectedProcess = nil } }
        )) {
            if let proc = selectedProcess {
                ProcessDetailView(process: proc, monitor: monitor) {
                    stopTarget = proc
                    showStopConfirm = true
                }
            }
        }
        .alert(L10n.t("结束进程"), isPresented: $showStopConfirm) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("结束"), role: .destructive) {
                Haptic.warning()
                if let target = stopTarget {
                    Task { await monitor.stopProcess(pid: target.pid) }
                }
            }
        } message: {
            if let target = stopTarget {
                Text(L10n.f("确定要结束进程「%@」(PID: %ld) 吗？此操作不可撤销。", target.name, target.pid))
            }
        }
        .localToast(message: $monitor.successMessage)
    }

    private var searchTextPrompt: String {
        monitor.mode == .processes ? L10n.t("搜索进程名称 / PID / 用户") : L10n.t("搜索进程 / PID / 端口")
    }

    // MARK: - 模式切换（List 首个 Section，与监控/证书详情一致）

    private var modePicker: some View {
        Picker("", selection: $monitor.mode) {
            // 仅进程/网络：会话模式（type=ssh）由 SSH 服务管理的会话页专用，不进本页切换器
            ForEach([ProcessMonitor.MonitorMode.processes, .network]) { m in
                Text(L10n.t(m.rawValue)).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .segmentedPickerRow()
        .listRowSeparator(.hidden)
    }

    // MARK: - 状态栏

    private var statusBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                StatusDot(color: connectionColor)
                Text(connectionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(itemCountText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if monitor.isAutoRefresh && monitor.isConnected {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var connectionColor: Color {
        if monitor.isConnected { return .green }
        if monitor.isConnecting { return .orange }
        return .red
    }

    private var connectionText: String {
        if monitor.isConnected { return L10n.t("已连接") }
        if monitor.isConnecting { return L10n.t("连接中…") }
        return L10n.t("未连接")
    }

    private var itemCountText: String {
        switch monitor.mode {
        case .processes: return L10n.f("%ld 个进程", filteredProcesses.count)
        case .network:   return L10n.f("%ld 个连接", filteredConnections.count)
        case .sessions:  return ""  // 会话模式不在本页展示
        }
    }

    // MARK: - 内容区域

    /// 单 List 容器：错误/加载/空态与正常态都收进 Section，
    /// 正常态首个 Section 为模式切换（与监控页的时间范围一致）
    @ViewBuilder
    private var contentView: some View {
        List {
            if let err = monitor.errorMessage {
                Section {
                    ContentUnavailableView {
                        Label(L10n.t("连接失败"), systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(err)
                    } actions: {
                        Button(L10n.t("重试")) { monitor.connect() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 30)
                }
            } else if monitor.isConnecting && isEmpty {
                Section {
                    LoadingStateView(text: L10n.t("正在连接…"), compact: true)
                        .padding(.vertical, 30)
                }
            } else if isFilteredEmpty {
                Section {
                    ContentUnavailableView.search(text: searchText)
                        .padding(.vertical, 30)
                }
            } else {
                Section {
                    modePicker
                }
                if monitor.mode == .processes {
                    ForEach(filteredProcesses) { proc in
                        ProcessRow(process: proc)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedProcess = proc }
                    }
                } else {
                    ForEach(filteredConnections) { conn in
                        NetworkRow(connection: conn)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var isEmpty: Bool {
        monitor.mode == .processes ? monitor.processes.isEmpty : monitor.connections.isEmpty
    }

    private var isFilteredEmpty: Bool {
        monitor.mode == .processes ? filteredProcesses.isEmpty : filteredConnections.isEmpty
    }
}

// MARK: - 进程行

private struct ProcessRow: View {
    let process: ProcessItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(process.name)
                    .font(.body.bold())
                    .lineLimit(1)
                Spacer()
                Text("PID \(process.pid)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Label(process.username, systemImage: "person.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let threads = process.numThreads, threads > 1 {
                    Label("\(threads)", systemImage: "circle.hexagongrid.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let cpu = process.cpuPercent, !cpu.isEmpty {
                    cpuBadge(cpu)
                }
                if let mem = process.rss, !mem.isEmpty {
                    StatusBadge(text: mem, color: .purple, monospaced: true)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func cpuBadge(_ value: String) -> some View {
        let v = Double(value.replacingOccurrences(of: "%", with: "")) ?? 0
        let color: Color = v > 50 ? .red : v > 10 ? .orange : .blue
        return StatusBadge(text: "CPU \(value)", color: color, monospaced: true)
    }
}

// MARK: - 网络连接行

private struct NetworkRow: View {
    let connection: NetworkConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(connection.name)
                    .font(.body.bold())
                    .lineLimit(1)
                Spacer()
                Text("PID \(connection.pid)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                // 服务端 ProcessConnect.Type 恒为空串（源码未赋值）：空值不渲染徽章
                if !connection.type.isEmpty {
                    StatusBadge(text: connection.type.uppercased(), color: connection.typeColor)
                }

                statusBadge

                Spacer()

                Text("\(connection.localaddr.ip):\(connection.localaddr.port)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.primary)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(connection.remoteaddr.port == 0 ? "*" : "\(connection.remoteaddr.ip):\(connection.remoteaddr.port)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusBadge: some View {
        let color: Color = {
            switch connection.status.uppercased() {
            case "LISTEN":      return .green
            case "ESTABLISHED": return .blue
            case "TIME_WAIT":   return .orange
            case "CLOSE_WAIT":  return .red
            default:            return .secondary
            }
        }()
        StatusBadge(text: connection.status, color: color)
    }
}

// MARK: - 进程详情

/// 列表快照即时展示，进入后拉取 GET /process/:pid 增强为完整详情
/// （内存明细 / 网络连接 / 环境变量 / 打开文件），接口失败时静默保留快照
private struct ProcessDetailView: View {
    let process: ProcessItem
    let monitor: ProcessMonitor
    let onStop: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var detail: ProcessDetail?

    /// 环境变量 / 打开文件行数上限：openFiles 可达上万行，超出截断并在
    /// 区尾提示总数（List 惰性渲染可承受，截断避免极端进程拖垮滚动）
    private static let detailRowLimit = 200

    var body: some View {
        List {
            Section(L10n.t("基本信息")) {
                InfoRow(key: "PID", value: "\(process.pid)")
                InfoRow(key: L10n.t("名称"), value: pick(detail?.name, process.name))
                InfoRow(key: L10n.t("父进程 PID"), value: "\(detail?.ppid ?? process.ppid)")
                InfoRow(key: L10n.t("用户"), value: pick(detail?.username, process.username))
                InfoRow(key: L10n.t("状态"), value: pick(detail?.status, process.status))
                if let time = pick(detail?.startTime, process.startTime), !time.isEmpty {
                    InfoRow(key: L10n.t("启动时间"), value: time)
                }
            }

            Section(L10n.t("资源使用")) {
                if let cpu = pick(detail?.cpuPercent, process.cpuPercent), !cpu.isEmpty {
                    InfoRow(key: "CPU", value: cpu)
                }
                if let mem = pick(detail?.rss, process.rss), !mem.isEmpty {
                    InfoRow(key: L10n.t("内存 (RSS)"), value: mem)
                }
                if let threads = detail?.numThreads ?? process.numThreads {
                    InfoRow(key: L10n.t("线程数"), value: "\(threads)")
                }
                if let conns = detail?.numConnections ?? process.numConnections {
                    InfoRow(key: L10n.t("连接数"), value: "\(conns)")
                }
                if let dr = pick(detail?.diskRead, process.diskRead), !dr.isEmpty {
                    InfoRow(key: L10n.t("磁盘读"), value: dr)
                }
                if let dw = pick(detail?.diskWrite, process.diskWrite), !dw.isEmpty {
                    InfoRow(key: L10n.t("磁盘写"), value: dw)
                }
            }

            if let mem = detail, hasMemoryDetail(mem) {
                Section(L10n.t("内存明细")) {
                    memoryRow(L10n.t("虚拟内存 (VMS)"), mem.vms)
                    memoryRow(L10n.t("峰值驻留 (HWM)"), mem.hwm)
                    memoryRow(L10n.t("比例分摊 (PSS)"), mem.pss)
                    memoryRow(L10n.t("进程独占 (USS)"), mem.uss)
                    memoryRow(L10n.t("共享内存"), mem.shared)
                    memoryRow(L10n.t("数据段"), mem.data)
                    memoryRow(L10n.t("栈"), mem.stack)
                    memoryRow(L10n.t("代码段"), mem.text)
                    memoryRow(L10n.t("锁定"), mem.locked)
                    memoryRow(L10n.t("交换分区"), mem.swap)
                    memoryRow(L10n.t("脏页"), mem.dirty)
                }
            }

            if let connects = detail?.connects, !connects.isEmpty {
                Section(L10n.t("网络连接")) {
                    ForEach(NetworkConnection.deduplicated(connects)) { conn in
                        NetworkRow(connection: conn)
                    }
                }
            }

            if let envs = detail?.envs, !envs.isEmpty {
                Section {
                    ForEach(Array(envs.prefix(Self.detailRowLimit)), id: \.self) { env in
                        Text(env)
                            .font(.dataMonospacedCaption)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if envs.count > Self.detailRowLimit {
                        Text(L10n.f("共 %ld 项，仅显示前 %ld 项", envs.count, Self.detailRowLimit))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    SectionLabel(title: L10n.f("环境变量（%ld）", envs.count), systemImage: "gearshape")
                }
            }

            if let files = detail?.openFiles, !files.isEmpty {
                Section {
                    ForEach(Array(files.prefix(Self.detailRowLimit).enumerated()), id: \.offset) { _, file in
                        HStack {
                            Text(file.path ?? "-")
                                .font(.dataMonospacedCaption)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer()
                            if let fd = file.fd {
                                Text("fd \(fd)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if files.count > Self.detailRowLimit {
                        Text(L10n.f("共 %ld 项，仅显示前 %ld 项", files.count, Self.detailRowLimit))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    SectionLabel(
                        title: L10n.f("打开文件（%ld）", files.count),
                        systemImage: "doc.on.doc")
                }
            }

            if let cmd = detail?.cmdLine ?? process.cmdLine, !cmd.isEmpty {
                Section(L10n.t("命令行")) {
                    Text(cmd)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

        }
        .navigationTitle(pick(detail?.name, process.name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    onStop()
                    dismiss()
                } label: {
                    Label(L10n.t("结束进程"), systemImage: "xmark.octagon")
                }
                .tint(.red)
            }
        }
        .task { detail = await monitor.loadDetail(pid: process.pid) }
    }

    /// 详情值优先，缺省/为空回退列表快照
    private func pick(_ detailValue: String?, _ snapshotValue: String) -> String {
        if let v = detailValue, !v.isEmpty { return v }
        return snapshotValue
    }

    private func pick(_ detailValue: String?, _ snapshotValue: String?) -> String? {
        if let v = detailValue, !v.isEmpty { return v }
        return snapshotValue
    }

    private func hasMemoryDetail(_ mem: ProcessDetail) -> Bool {
        [mem.vms, mem.hwm, mem.pss, mem.uss, mem.shared, mem.data,
         mem.stack, mem.text, mem.locked, mem.swap, mem.dirty]
            .contains { !($0 ?? "").isEmpty }
    }

    @ViewBuilder
    private func memoryRow(_ key: String, _ value: String?) -> some View {
        if let v = value, !v.isEmpty {
            InfoRow(key: key, value: v)
        }
    }
}
