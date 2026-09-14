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
        case .error:  return "exclamationmark.triangle.fill"
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
    let website: Website
    @ObservedObject var vm: WebsitesViewModel

    @State private var selectedTab: WebsiteLogType = .access
    @State private var lines: [String] = []
    @State private var isLoading = false
    /// 日志加载失败（渲染页内错误态 + 重试）
    @State private var loadError: String?
    @State private var isTracking = false
    // 下载 / 清空（logs/网站日志抓包 2026-09-14）
    @State private var showClearConfirm = false
    @State private var isOperatingLog = false
    @State private var downloadDone: String?

    /// 日志文件服务器路径（1Panel 站点目录约定：<www>/sites/<域名>/log/<文件>）
    private var logFilePath: String {
        let domain = website.primaryDomain ?? website.alias ?? ""
        return "/opt/1panel/www/sites/\(domain)/log/\(selectedTab.fileName)"
    }

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
                LoadingStateView(text: L10n.t("加载日志…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = loadError, lines.isEmpty {
                LoadErrorStateView(message: err) {
                    Task { await load() }
                }
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
                        .contentWidthLimit(860)
                    }
                    .onChange(of: lines.count) { _, _ in
                        withAnimation(Motion.standard) {
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
                    Label(L10n.t("追踪"), systemImage: "waveform")
                }
                .toggleStyle(.button)
                .tint(isTracking ? .green : .secondary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await downloadLog() }
                    } label: {
                        Label(L10n.t("下载"), systemImage: "arrow.down.circle")
                    }
                    .disabled(isOperatingLog)
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label(L10n.t("清空日志"), systemImage: "trash")
                    }
                    .disabled(isOperatingLog)
                } label: {
                    if isOperatingLog {
                        ProgressView()
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .accessibilityLabel(L10n.t("更多操作"))
            }
        }
        .alert(L10n.t("清空日志"), isPresented: $showClearConfirm) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("清空"), role: .destructive) {
                Task { await clearLog() }
            }
        } message: {
            Text(L10n.f("确定清空「%@」吗？该操作无法回滚。", selectedTab.displayName))
        }
        .toastOverlay(message: $downloadDone)
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
        do {
            lines = try await vm.loadLog(websiteId: website.id, name: selectedTab.fileName)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// 清空当前类型日志（POST /websites/log/operate {id,operate:delete,logType}）
    private func clearLog() async {
        isOperatingLog = true
        defer { isOperatingLog = false }
        do {
            let _: EmptyResponse = try await vm.client.send(
                path: APIEndpoint.websitesLogOperate.path,
                body: WebsiteLogOperateRequest(
                    id: website.id, operate: "delete", logType: selectedTab.fileName),
                as: EmptyResponse.self)
            lines = []
            downloadDone = L10n.t("已清空")
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
    }

    /// 下载日志文件（GET /files/download?path=<站点日志路径>，保存到「文件」App）
    private func downloadLog() async {
        isOperatingLog = true
        defer { isOperatingLog = false }
        do {
            let tempURL = try await vm.client.downloadFile(
                path: APIEndpoint.filesDownload.path,
                queryItems: [
                    URLQueryItem(name: "operateNode", value: "local"),
                    URLQueryItem(name: "path", value: logFilePath),
                ],
                fileName: "\(website.primaryDomain ?? website.alias ?? "site")-\(selectedTab.fileName)",
                progress: nil)
            let destDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let finalURL = destDir.appendingPathComponent(tempURL.lastPathComponent)
            try? FileManager.default.removeItem(at: finalURL)
            try FileManager.default.moveItem(at: tempURL, to: finalURL)
            downloadDone = L10n.t("已保存到「文件」App · 我的 iPhone/1PanelClient")
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
    }

    private func startTracking() async {
        while isTracking {
            try? await Task.sleep(for: .seconds(2))
            guard isTracking else { break }
            // 追踪轮询失败静默跳过，下轮继续
            guard let fresh = try? await vm.loadLog(websiteId: website.id, name: selectedTab.fileName) else { continue }
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
    /// 日志加载失败（渲染页内错误态 + 重试）
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && lines.isEmpty {
                    LoadingStateView(text: L10n.t("加载日志…"))
                } else if let err = loadError, lines.isEmpty {
                    LoadErrorStateView(message: err) {
                        Task { await load() }
                    }
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
                        .contentWidthLimit(860)
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
                    .accessibilityLabel(L10n.t("刷新"))
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
        do {
            lines = try await vm.loadLog(websiteId: websiteId, name: logType.fileName)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

