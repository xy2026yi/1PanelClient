//
//  WebsiteLogViews.swift
//  1PanelClient
//

import SwiftUI

// MARK: - 日志类型

enum WebsiteLogType {
    case access, error

    var displayName: String {
        switch self {
        case .access: return L10n.t("访问日志")
        case .error:  return L10n.t("错误日志")
        }
    }

    var fileName: String {
        switch self {
        case .access: return "access.log"
        case .error:  return "error.log"
        }
    }

    var icon: String {
        switch self {
        case .access: return "list.bullet.rectangle"
        case .error:  return "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .access: return .blue
        case .error:  return .orange
        }
    }
}


// MARK: - 网站日志（合并页）

struct WebsiteLogPage: View {
    let websiteId: Int
    @ObservedObject var vm: WebsitesViewModel

    @State private var selectedTab: WebsiteLogType = .access
    @State private var lines: [String] = []
    @State private var isLoading = false
    @State private var isTracking = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text(L10n.t("访问日志")).tag(WebsiteLogType.access)
                Text(L10n.t("错误日志")).tag(WebsiteLogType.error)
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            if isLoading && lines.isEmpty {
                ProgressView(L10n.t("加载日志…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if lines.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无日志"),
                    systemImage: selectedTab.icon,
                    description: Text(L10n.f("暂未产生%@记录", selectedTab.displayName))
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .id(idx)
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
            }
        }
        .navigationTitle(L10n.t("日志"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $isTracking) {
                    Label(L10n.t("追踪"), systemImage: "waveform.badge.eye")
                }
                .toggleStyle(.button)
                .tint(isTracking ? .green : .secondary)
            }
        }
        .task { await load() }
        .onChange(of: selectedTab) { _, _ in
            lines = []
            Task { await load() }
        }
        .onChange(of: isTracking) { _, tracking in
            if tracking {
                Task { await startTracking() }
            }
        }
        .onDisappear {
            isTracking = false
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        lines = await vm.loadLog(websiteId: websiteId, name: selectedTab.fileName)
    }

    private func startTracking() async {
        while isTracking {
            try? await Task.sleep(for: .seconds(2))
            guard isTracking else { break }
            let fresh = await vm.loadLog(websiteId: websiteId, name: selectedTab.fileName)
            guard isTracking else { break }
            if fresh.isEmpty { continue }
            let overlap = min(lines.count, fresh.count)
            let tail = Array(lines.suffix(overlap))
            let freshTail = Array(fresh.suffix(overlap))
            if tail == freshTail, fresh.count > lines.count {
                let newLines = Array(fresh.dropFirst(lines.count))
                lines.append(contentsOf: newLines)
            } else if fresh != lines {
                lines = fresh
            }
        }
    }
}

// MARK: - 网站日志（单类型）

struct WebsiteLogView: View {
    let websiteId: Int
    let logType: WebsiteLogType
    @ObservedObject var vm: WebsitesViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var lines: [String] = []
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && lines.isEmpty {
                    ProgressView(L10n.t("加载日志…"))
                } else if lines.isEmpty {
                    ContentUnavailableView(
                        L10n.t("暂无日志"),
                        systemImage: logType.icon,
                        description: Text(L10n.f("暂未产生%@记录", logType.displayName))
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding()
                    }
                    .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle(logType.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("关闭")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task {
                await load()
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        lines = await vm.loadLog(websiteId: websiteId, name: logType.fileName)
    }
}

