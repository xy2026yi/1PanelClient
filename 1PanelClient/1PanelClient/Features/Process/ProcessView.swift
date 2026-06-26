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
            modePicker
            contentView
        }
        .navigationTitle("进程")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: searchTextPrompt)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if monitor.mode == .processes {
                        Picker("排序", selection: $sortOption) {
                            ForEach(SortOption.allCases) { opt in
                                Text(opt.rawValue).tag(opt)
                            }
                        }
                        Divider()
                    }
                    Toggle("自动刷新", isOn: $monitor.isAutoRefresh)
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
                ProcessDetailView(process: proc) {
                    stopTarget = proc
                    showStopConfirm = true
                }
            }
        }
        .alert("结束进程", isPresented: $showStopConfirm) {
            Button("取消", role: .cancel) {}
            Button("结束", role: .destructive) {
                if let target = stopTarget {
                    Task { await monitor.stopProcess(pid: target.pid) }
                }
            }
        } message: {
            if let target = stopTarget {
                Text("确定要结束进程「\(target.name)」(PID: \(target.pid)) 吗？此操作不可撤销。")
            }
        }
        .alert("操作成功", isPresented: Binding(
            get: { monitor.successMessage != nil },
            set: { if !$0 { monitor.successMessage = nil } }
        )) {
            Button("好的") { monitor.successMessage = nil }
        } message: {
            Text(monitor.successMessage ?? "")
        }
    }

    private var searchTextPrompt: String {
        monitor.mode == .processes ? "搜索进程名称 / PID / 用户" : "搜索进程 / PID / 端口"
    }

    // MARK: - 模式切换

    private var modePicker: some View {
        Picker("", selection: $monitor.mode) {
            ForEach(ProcessMonitor.MonitorMode.allCases) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: - 状态栏

    private var statusBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 8, height: 8)
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
        if monitor.isConnected { return "已连接" }
        if monitor.isConnecting { return "连接中…" }
        return "未连接"
    }

    private var itemCountText: String {
        switch monitor.mode {
        case .processes: return "\(filteredProcesses.count) 个进程"
        case .network:   return "\(filteredConnections.count) 个连接"
        }
    }

    // MARK: - 内容区域

    @ViewBuilder
    private var contentView: some View {
        if let err = monitor.errorMessage {
            ContentUnavailableView {
                Label("连接失败", systemImage: "wifi.exclamationmark")
            } description: {
                Text(err)
            } actions: {
                Button("重试") { monitor.connect() }
                    .buttonStyle(.borderedProminent)
            }
        } else if monitor.isConnecting && isEmpty {
            ProgressView("正在连接…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isFilteredEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            if monitor.mode == .processes {
                processList
            } else {
                networkList
            }
        }
    }

    private var isEmpty: Bool {
        monitor.mode == .processes ? monitor.processes.isEmpty : monitor.connections.isEmpty
    }

    private var isFilteredEmpty: Bool {
        monitor.mode == .processes ? filteredProcesses.isEmpty : filteredConnections.isEmpty
    }

    // MARK: - 进程列表

    private var processList: some View {
        List {
            ForEach(filteredProcesses) { proc in
                ProcessRow(process: proc)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedProcess = proc }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - 网络连接列表

    private var networkList: some View {
        List {
            ForEach(filteredConnections) { conn in
                NetworkRow(connection: conn)
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - 进程行

private struct ProcessRow: View {
    let process: ProcessItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(process.name)
                    .font(.subheadline.weight(.medium))
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
                    memBadge(mem)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func cpuBadge(_ value: String) -> some View {
        let v = Double(value.replacingOccurrences(of: "%", with: "")) ?? 0
        let color: Color = v > 50 ? .red : v > 10 ? .orange : .blue
        return Text("CPU \(value)")
            .font(.caption2.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func memBadge(_ value: String) -> some View {
        Text(value)
            .font(.caption2.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.purple.opacity(0.15))
            .foregroundStyle(.purple)
            .clipShape(Capsule())
    }
}

// MARK: - 网络连接行

private struct NetworkRow: View {
    let connection: NetworkConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(connection.name)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("PID \(connection.pid)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Text(connection.type.uppercased())
                    .font(.caption2.monospaced().bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(connection.typeColor.opacity(0.15))
                    .foregroundStyle(connection.typeColor)
                    .clipShape(Capsule())

                statusBadge

                Spacer()

                Text("\(connection.localaddr.ip):\(connection.localaddr.port)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.primary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Text(connection.remoteaddr.port == 0 ? "*" : "\(connection.remoteaddr.ip):\(connection.remoteaddr.port)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
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
        Text(connection.status)
            .font(.caption2.bold())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - 进程详情

private struct ProcessDetailView: View {
    let process: ProcessItem
    let onStop: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("基本信息") {
                InfoRow(key: "PID", value: "\(process.pid)")
                InfoRow(key: "名称", value: process.name)
                InfoRow(key: "父进程 PID", value: "\(process.ppid)")
                InfoRow(key: "用户", value: process.username)
                InfoRow(key: "状态", value: process.status)
            }

            Section("资源使用") {
                if let cpu = process.cpuPercent, !cpu.isEmpty {
                    InfoRow(key: "CPU", value: cpu)
                }
                if let mem = process.rss, !mem.isEmpty {
                    InfoRow(key: "内存 (RSS)", value: mem)
                }
                if let threads = process.numThreads {
                    InfoRow(key: "线程数", value: "\(threads)")
                }
                if let conns = process.numConnections {
                    InfoRow(key: "连接数", value: "\(conns)")
                }
                if let dr = process.diskRead, !dr.isEmpty {
                    InfoRow(key: "磁盘读", value: dr)
                }
                if let dw = process.diskWrite, !dw.isEmpty {
                    InfoRow(key: "磁盘写", value: dw)
                }
            }

            if let time = process.startTime, !time.isEmpty {
                Section("时间") {
                    InfoRow(key: "启动时间", value: time)
                }
            }

            if let cmd = process.cmdLine, !cmd.isEmpty {
                Section("命令行") {
                    Text(cmd)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section {
                Button(role: .destructive) {
                    onStop()
                    dismiss()
                } label: {
                    HStack {
                        Spacer()
                        Label("结束进程", systemImage: "xmark.octagon")
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle(process.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
