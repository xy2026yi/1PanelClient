//
//  ProcessView.swift
//  1PanelClient
//
//  进程监控视图：实时进程列表 + 搜索 + 排序 + 详情
//

import SwiftUI

struct ProcessView: View {
    @StateObject private var monitor: ProcessMonitor
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var sortOption: SortOption = .cpu
    @State private var selectedProcess: ProcessItem?

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

    /// 搜索 + 排序后的进程列表
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
        case .cpu:
            result.sort { ($0.cpuValue ?? 0) > ($1.cpuValue ?? 0) }
        case .memory:
            result.sort { ($0.rssValue ?? 0) > ($1.rssValue ?? 0) }
        case .pid:
            result.sort { $0.pid < $1.pid }
        case .name:
            result.sort { $0.name.lowercased() < $1.name.lowercased() }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            processList
        }
        .navigationTitle("进程")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索进程名称 / PID / 用户")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("排序", selection: $sortOption) {
                        ForEach(SortOption.allCases) { opt in
                            Text(opt.rawValue).tag(opt)
                        }
                    }
                    Divider()
                    Toggle("自动刷新", isOn: $monitor.isAutoRefresh)
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
                }
            }
        }
        .onAppear { monitor.connect() }
        .onDisappear { monitor.disconnect() }
        .sheet(item: $selectedProcess) { proc in
            ProcessDetailView(process: proc)
        }
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
            Text("\(filteredProcesses.count) 个进程")
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

    // MARK: - 进程列表

    private var processList: some View {
        Group {
            if let err = monitor.errorMessage {
                ContentUnavailableView {
                    Label("连接失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button("重试") { monitor.connect() }
                        .buttonStyle(.borderedProminent)
                }
            } else if monitor.processes.isEmpty && monitor.isConnecting {
                ProgressView("正在连接…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredProcesses.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    ForEach(filteredProcesses) { proc in
                        ProcessRow(process: proc)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedProcess = proc }
                    }
                }
                .listStyle(.plain)
            }
        }
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
        return Text(value)
            .font(.caption2.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.purple.opacity(0.15))
            .foregroundStyle(.purple)
            .clipShape(Capsule())
    }
}

// MARK: - 进程详情

private struct ProcessDetailView: View {
    let process: ProcessItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
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
            }
            .navigationTitle(process.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
