//
//  ServersView.swift
//  1PanelClient
//
//  服务器页面：展示全部服务器，单击切换当前服务器，长按弹出操作面板
//  （编辑 / 重启面板 / 重启服务器 / 删除），右下角 + 添加
//

import SwiftUI

struct ServersView: View {
    @ObservedObject var manager: ServerManager
    @ObservedObject private var health = ServerHealthMonitor.shared
    @StateObject private var cardMonitor = ServerCardMonitor()
    @State private var showAdd = false
    @State private var editingServer: ServerConfig?
    @State private var serverToRemove: ServerConfig?
    /// 长按弹出的操作面板目标
    @State private var actionServer: ServerConfig?
    @State private var toastMessage: String?
    @State private var alertMessage: String?
    @State private var showAlert = false

    var body: some View {
        List {
            // 每台服务器独立 Section：insetGrouped 下一个 Section 即一张卡片
            ForEach(manager.servers) { server in
                Section {
                    ServerRow(
                        server: server,
                        isCurrent: server.id == manager.currentServerID,
                        health: health.state(for: server.id),
                        metrics: cardMonitor.currents[server.id],
                        onTap: {
                            if server.id != manager.currentServerID {
                                Haptic.selection()
                            }
                            manager.select(server)
                        },
                        onLongPress: {
                            actionServer = server
                        }
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            serverToRemove = server
                        } label: {
                            Label(L10n.t("移除"), systemImage: "trash")
                        }
                    }
                }
            }
            // 无行的 Section 只渲染 footer 文本，不带卡片背景
            Section {
            } footer: {
                Text(L10n.t("单击切换服务器，长按更多操作，左滑移除；下拉刷新健康状态"))
            }
        }
        .refreshable {
            await health.checkAll()
            await cardMonitor.refresh()
        }
        // 指标轮询：与首页状态卡同频（5 秒），页面存在期间持续，
        // pop 离开时 task 自动取消；运行时长包含在同一条 dashboard/current 响应内随刷新更新
        .task {
            await cardMonitor.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                await cardMonitor.refresh()
            }
        }
        .onAppear {
            health.start()
        }
        .onDisappear {
            health.stop()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("添加服务器"))
            }
        }
        .navigationTitle(L10n.t("服务器"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showAdd) {
            ServerEditView(manager: manager, presentedAsSheet: false)
        }
        .navigationDestination(item: $editingServer) { server in
            ServerEditView(manager: manager, editing: server, presentedAsSheet: false)
        }
        .sheet(item: $actionServer) { server in
            ServerActionsSheet(server: server) { action in
                actionServer = nil
                handle(action, for: server)
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .toastOverlay(message: $toastMessage)
        // 移除服务器前确认（会连带清除 Keychain 中的 API 密钥）—— 居中 alert
        .alert(L10n.t("移除服务器"), isPresented: Binding(
            get: { serverToRemove != nil },
            set: { if !$0 { serverToRemove = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) {
                serverToRemove = nil
            }
            Button(L10n.t("移除"), role: .destructive) {
                if let server = serverToRemove {
                    manager.remove(server)
                }
                serverToRemove = nil
            }
        } message: {
            Text(L10n.f("将移除「%@」的连接配置与已保存的 API 密钥，此操作不可恢复。", serverToRemove?.name ?? ""))
        }
        .alert(L10n.t("提示"), isPresented: $showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private func handle(_ action: ServerAction, for server: ServerConfig) {
        switch action {
        case .edit:
            editingServer = server
        case .remove:
            serverToRemove = server
        case .restart(let target):
            Task { await restart(target, on: server) }
        }
    }

    /// 重启指令用目标服务器自己的凭据直发其 API——多机场景下对非当前服务器同样可执行
    private func restart(_ target: ServerRestartTarget, on server: ServerConfig) async {
        let path = APIEndpoint.dashboardSystemRestart.path
            .replacingOccurrences(of: ":target", with: target.rawValue)
        do {
            let _: EmptyResponse = try await APIClient(server: server).send(path: path, as: EmptyResponse.self)
            toastMessage = target.successToast
        } catch let err as APIError {
            // 重启面板/服务器时，服务端收到请求后会主动断开连接（自身正在重启），
            // 抓包表现为无响应。此时指令实际已送达，按成功处理而非报错。
            if case .networkError = err {
                toastMessage = target.successToast
            } else {
                alertMessage = L10n.f("操作失败：%@", err.errorDescription ?? L10n.t("未知错误"))
                showAlert = true
            }
        } catch {
            toastMessage = target.successToast
        }
    }

}

// MARK: - 长按操作面板

/// 长按服务器的操作：编辑 / 删除 / 重启（重启目标另带参数）
enum ServerAction {
    case edit
    case remove
    case restart(ServerRestartTarget)
}

/// 重启目标（rawValue 对应路径参数 :target）
enum ServerRestartTarget: String, Identifiable {
    case panel = "1panel"
    case system = "system"

    var id: String { rawValue }

    var title: String {
        self == .panel ? L10n.t("重启面板") : L10n.t("重启服务器")
    }

    /// 完成后的提示文案
    var successToast: String {
        self == .panel
            ? L10n.t("重启指令已发送，面板服务正在重启，几秒后恢复")
            : L10n.t("重启指令已发送，服务器将失联 1-2 分钟")
    }
}

/// 服务器长按操作面板（半屏）：编辑 / 重启面板 / 重启服务器 / 删除。
/// 重启沿用「输入 立即重启 确认」高危确认；指令执行与提示由外页负责
private struct ServerActionsSheet: View {
    let server: ServerConfig
    var onAction: (ServerAction) -> Void

    @State private var restartTarget: ServerRestartTarget?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(server.name)
                            .font(.headline)
                        Text(server.normalizedBaseURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                Section {
                    actionRow(title: L10n.t("编辑"), icon: "pencil", color: .blue) {
                        onAction(.edit)
                    }
                    actionRow(
                        title: ServerRestartTarget.panel.title,
                        icon: "arrow.triangle.2.circlepath",
                        color: .red,
                        subtitle: L10n.t("重启 1Panel 面板服务，几秒后自动恢复")
                    ) {
                        restartTarget = .panel
                    }
                    actionRow(
                        title: ServerRestartTarget.system.title,
                        icon: "power.dotted",
                        color: .red,
                        subtitle: L10n.t("重启整个服务器，期间将失联 1-2 分钟")
                    ) {
                        restartTarget = .system
                    }
                }

                Section {
                    actionRow(title: L10n.t("删除"), icon: "trash", color: .red) {
                        onAction(.remove)
                    }
                }
            }
            .navigationTitle(L10n.t("服务器操作"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: $restartTarget) { target in
            TextInputConfirmSheet(
                title: target.title,
                message: L10n.t("此操作不可恢复。如果确认操作，请手动输入「立即重启」。"),
                expectedText: L10n.t("立即重启"),
                fieldLabel: L10n.t("确认输入"),
                fieldPlaceholder: L10n.t("请输入 立即重启"),
                confirmTitle: L10n.t("确认重启")
            ) {
                onAction(.restart(target))
            }
        }
    }

    private func actionRow(
        title: String,
        icon: String,
        color: Color,
        subtitle: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 2)
        }
    }
}

/// 服务器行：标题行 = 名称 + 健康点 + 运行时长 + 当前绿勾；副行 = 地址；
/// 指标行 = 负载/CPU/内存/各磁盘挂载点小圆环（与首页状态卡同源同色，可横滑）
private struct ServerRow: View {
    let server: ServerConfig
    let isCurrent: Bool
    let health: ServerHealth
    /// dashboard/current 实时指标（nil=未加载/离线）
    let metrics: DashboardCurrent?
    let onTap: () -> Void
    let onLongPress: () -> Void

    /// 标题行健康点：在线绿 / 离线红 / 其余灰
    private var healthColor: Color {
        switch health {
        case .online:  return .statusRunning
        case .offline: return .statusError
        default:       return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 标题行：名称靠左，健康点 + 运行时长 + 当前绿勾 整体靠右贴边
            HStack(spacing: 6) {
                Text(server.name)
                    .font(.headline)
                Spacer(minLength: 8)
                StatusDot(color: healthColor, diameter: 8)
                    .accessibilityLabel(health.label)
                if let rt = metrics?.runningTime {
                    Text(rt.compactText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            // 副行：地址（含 API Key 失效 / HTTP 明文提示）
            HStack(spacing: 4) {
                if server.apiKey.isEmpty {
                    Label(L10n.t("API Key 已失效，长按重新录入"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                if server.isPlainHTTP {
                    Label("HTTP", systemImage: "lock.open")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Text(server.normalizedBaseURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // 指标行：负载/CPU/内存 + 逐磁盘挂载点，复用首页状态卡 RingStatView（compact 同等大小），单行可横滑
            if let cur = metrics {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ring(L10n.t("负载"), percent: cur.loadUsagePercent, footer: MetricFormat.f2(cur.load1), color: .teal)
                        ring("CPU", percent: cur.cpuUsedPercent, footer: L10n.f("%@ / %ld 核", MetricFormat.f2(cur.cpuUsed), cur.cpuTotal ?? 0), color: .blue)
                        ring(L10n.t("内存"), percent: cur.memoryUsedPercent, footer: MetricFormat.usedOverTotal(cur.memoryUsed, cur.memoryTotal), color: .purple)
                        ForEach(Array((cur.diskData ?? []).enumerated()), id: \.offset) { _, disk in
                            ring(
                                disk.path?.isEmpty == false ? disk.path! : L10n.t("存储"),
                                percent: disk.usedPercent,
                                footer: MetricFormat.usedOverTotal(disk.used, disk.total),
                                color: .orange
                            )
                        }
                    }
                    // 垂直 6pt：环描边（线宽 6）向外溢出约 3pt，留足余量防 ScrollView 裁剪上下弧
                    .padding(.vertical, 6)
                }
                .frame(height: 86)  // 环 54 + footer 14 + 间距与描边余量；显式高度防 List 行高压缩
                .fixedSize(horizontal: false, vertical: true)
            } else if health.isOnline {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onLongPressGesture(perform: onLongPress)
    }

    /// 指标环：首页状态卡同款 RingStatView（compact 54pt + 环下详情），定宽以适配横滑行
    private func ring(_ label: String, percent: Double?, footer: String, color: Color) -> some View {
        RingStatView(
            percent: percent ?? 0,
            color: color,
            topText: percent.map { String(format: "%.0f%%", $0) } ?? "—",
            bottomText: label,
            footer: footer,
            compact: true
        )
        .frame(width: 64)
    }
}
