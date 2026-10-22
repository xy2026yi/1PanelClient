//
//  FirewallDockerGuardViews.swift
//  1PanelClient
//
//  Docker 端口守护（守护子视图 + 端口规则页）（自 FirewallView.swift 拆出，内容未改动）
//

import SwiftUI
import Combine

// MARK: - Docker 守护子视图

struct DockerGuardContainerSection: View {
    let container: DockerGuardContainer
    var onEditPolicy: (DockerGuardEndpoint) -> Void = { _ in }
    /// 长按「导出规则」入口
    var onExport: () -> Void = {}
    /// 点击行进入容器端口规则页（编程式推入；NavigationLink 与长按共存会误触）
    var onOpen: () -> Void = {}

    /// 容器下平铺 endpoints（ipv4/ipv6 各一条）；portGroups 为 DTO 保留形态，
    /// 两者并集、按 id 去重（抓包 2026-09-17）
    private var endpoints: [DockerGuardEndpoint] {
        let groupEndpoints = (container.portGroups ?? []).compactMap { $0.endpoint }
        var seen = Set<String>()
        return ((container.endpoints ?? []) + groupEndpoints).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        Section {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(container.name ?? "—")
                        .font(.subheadline.bold())
                    // 第二行：应用名（缺省回落 compose）
                    Text(container.application?.isEmpty == false
                         ? container.application! : (container.compose ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if endpoints.isEmpty {
                    Text(L10n.t("未发布端口"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.f("%ld 条", endpoints.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            // 单击进入端口规则页；长按弹半屏菜单（导出规则），松手不误触进入
            .rowTapAndLongPress(onTap: onOpen, onLongPress: onExport)
            // VoiceOver 无长按手势：以自定义操作暴露同一菜单
            .accessibilityAction(named: L10n.t("更多操作")) { onExport() }
        }
    }
}

// MARK: - 容器端口规则展示页（入口行进入）

/// 容器端口规则展示页（入口行进入）：每条规则一行「来源 → 目标」（形态与
/// 孤立策略行一致）；点击行进入防护策略表单（host_firewall 托管的 IPv6 端点
/// 点击弹提示），长按弹菜单（设置防护模式 / 删除——删除走
/// docker/policies/delete/batch {uuids}，已设策略才有，抓包 2026-10-22）。
/// 删除确认与提示弹窗都在本页内呈现：挂在宿主页的弹窗在推入页可见期间不显示
struct DockerGuardEndpointsView: View {
    /// 宿主 VM：容器数据按 id 实时查找（删除策略等操作完成刷新后本页立即
    /// 跟随，不残留旧行——传入的 container 仅作初值与 id 锚点）
    @ObservedObject var vm: FirewallViewModel
    let container: DockerGuardContainer
    var onEditPolicy: (DockerGuardEndpoint) -> Void = { _ in }
    /// 删除确认后的执行回调（确认弹窗在本页，宿主只负责调 VM）
    var onDeletePolicy: (DockerGuardEndpoint) -> Void = { _ in }

    @State private var actionEndpoint: DockerGuardEndpoint?
    @State private var pendingDelete: DockerGuardEndpoint?
    /// host_firewall 端点点按提示（2 秒自动消失的轻提示，无需确认）
    @State private var hostFirewallHint: String?

    /// 实时容器（刷新后从 VM 取最新；容器不在列表时回落传入快照）
    private var liveContainer: DockerGuardContainer {
        vm.dockerGuard?.containers?.first(where: { $0.id == container.id }) ?? container
    }

    private var endpoints: [DockerGuardEndpoint] {
        let groupEndpoints = (liveContainer.portGroups ?? []).compactMap { $0.endpoint }
        var seen = Set<String>()
        return ((liveContainer.endpoints ?? []) + groupEndpoints).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        Form {
            if endpoints.isEmpty {
                Section {
                    ContentUnavailableView(L10n.t("未发布端口"), systemImage: "shippingbox")
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(endpoints) { endpoint in
                        DockerGuardEndpointRow(endpoint: endpoint)
                            .contentShape(Rectangle())
                            .rowTapAndLongPress(onTap: { openPolicy(endpoint) },
                                                onLongPress: { actionEndpoint = endpoint })
                            // VoiceOver 无长按手势：以自定义操作暴露同一菜单
                            .accessibilityAction(named: L10n.t("更多操作")) {
                                actionEndpoint = endpoint
                            }
                    }
                }
            }
        }
        .navigationTitle(liveContainer.name ?? "—")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(
            get: { actionEndpoint != nil },
            set: { if !$0 { actionEndpoint = nil } }
        )) {
            if let endpoint = actionEndpoint {
                ActionBottomSheet(
                    title: endpoint.hostLabel,
                    items: actionItems(endpoint),
                    onDismiss: { actionEndpoint = nil }
                )
                .bottomSheetDetents([.height(ActionBottomSheet.height(for: actionItems(endpoint).count))])
                .presentationDragIndicator(.visible)
            }
        }
        .alert(L10n.t("删除防护策略"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingDelete = nil }
            Button(L10n.t("删除"), role: .destructive) {
                if let endpoint = pendingDelete {
                    pendingDelete = nil
                    onDeletePolicy(endpoint)
                }
            }
        } message: {
            Text(L10n.t("确定删除该端口的防护策略吗？删除后不可恢复。"))
        }
        // host_firewall 托管端点的点按提示：自动消失（弹窗式需手动确认，太重）
        .toastOverlay(message: $hostFirewallHint,
                      systemImage: "exclamationmark.triangle.fill",
                      iconColor: .orange)
    }

    /// host_firewall 托管（IPv6 输入链）端点不归守护策略管：点击弹提示而非表单
    private func openPolicy(_ endpoint: DockerGuardEndpoint) {
        if endpoint.managementTarget == "host_firewall" {
            hostFirewallHint = L10n.t("该端口需要通过主机防火墙设置访问规则，请前往主机防火墙进行配置。")
        } else {
            onEditPolicy(endpoint)
        }
    }

    /// 长按菜单项：设置防护模式恒有；已设策略（policyUUID）且非主机防火墙
    /// 托管的端点才可删除（未设策略无可删，host_firewall 归规则段管）
    private func actionItems(_ endpoint: DockerGuardEndpoint) -> [ActionMenuItem] {
        var items = [ActionMenuItem(title: L10n.t("设置防护模式"), icon: "slider.horizontal.3",
                                     color: .blue) {
            openPolicy(endpoint)
        }]
        if let uuid = endpoint.policyUUID, !uuid.isEmpty,
           endpoint.managementTarget != "host_firewall" {
            items.append(ActionMenuItem(title: L10n.t("删除"), icon: "trash",
                                        color: .red, role: .destructive) {
                Haptic.warning()
                pendingDelete = endpoint
            })
        }
        return items
    }
}

/// 主机 IP:端口 展示（行首、孤立策略菜单标题与防护表单共用）。
/// IPv6 地址含冒号，与端口拼接时加方括号（如 [::]:3002），与 Web 端一致
extension DockerGuardEndpoint {
    var hostLabel: String {
        let ip = hostIP ?? ""
        let port = hostPort.map(String.init) ?? ""
        guard !ip.isEmpty else { return port }
        let host = ip.contains(":") ? "[\(ip)]" : ip
        return port.isEmpty ? host : "\(host):\(port)"
    }
}

struct DockerGuardEndpointRow: View {
    let endpoint: DockerGuardEndpoint

    /// 已设置防护策略（有锁）：mode 由服务端随策略回填
    private var isConfigured: Bool { endpoint.mode != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                // 已设置/未设置以锁图标区分（行首；无策略不占位）
                if isConfigured {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(endpoint.hostLabel)
                    .font(.dataMonospacedBody.bold())
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // 目标 = 容器端口 + 协议（如 "9000 tcp"）；
                // 孤立策略无容器端口，回落容器名/占位
                Text(targetLabel)
                    .lineLimit(1)
                Spacer()
                modeBadge
            }
            if let sources = endpoint.sources, !sources.isEmpty {
                Text(L10n.f("来源：%@", sources.joined(separator: ", ")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var targetLabel: String {
        if let port = endpoint.containerPort, let proto = endpoint.protocolField {
            return "\(port) \(proto)"
        }
        if let port = endpoint.containerPort {
            return String(port)
        }
        return (endpoint.containerName?.isEmpty == false) ? endpoint.containerName! : "—"
    }

    /// 模式徽标仅已设置的策略显示（设置与否由行首锁图标表达）
    @ViewBuilder
    private var modeBadge: some View {
        switch endpoint.mode {
        case "deny_all":
            StatusBadge(text: L10n.t("全部拒绝"), color: .statusError)
        case "allow_sources":
            StatusBadge(text: L10n.t("白名单"), color: .statusRunning)
        case "deny_sources":
            StatusBadge(text: L10n.t("黑名单"), color: .semanticWarning)
        default:
            EmptyView()
        }
    }
}

// 端口白名单解析已上移至 Models/Firewall.swift（PanelShared 自包含，Widget target 可见）
