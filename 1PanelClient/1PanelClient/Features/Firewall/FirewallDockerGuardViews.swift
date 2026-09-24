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

/// 容器端口规则只读展示（形态 8「行即 Section」对应式，不提供添加/删除）：
/// 每条规则 = 来源（形态 1）+ 目标（形态 1）+ 防护模式（标签为模式名，内容为
/// sources，形态 7.1）；点击规则进入防护策略编辑
struct DockerGuardEndpointsView: View {
    let container: DockerGuardContainer
    var onEditPolicy: (DockerGuardEndpoint) -> Void = { _ in }

    private let modeLabels = [
        "deny_sources": L10n.t("禁止指定来源"),
        "allow_sources": L10n.t("仅允许指定来源"),
        "deny_all": L10n.t("禁止所有访问"),
    ]

    private var endpoints: [DockerGuardEndpoint] {
        let groupEndpoints = (container.portGroups ?? []).compactMap { $0.endpoint }
        var seen = Set<String>()
        return ((container.endpoints ?? []) + groupEndpoints).filter { seen.insert($0.id).inserted }
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
                ForEach(endpoints) { endpoint in
                    endpointSection(endpoint)
                }
            }
        }
        .navigationTitle(container.name ?? "—")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func endpointSection(_ endpoint: DockerGuardEndpoint) -> some View {
        Section {
            OutlinedShape(label: L10n.t("来源"), isFocused: false,
                          hasValue: sourceText(endpoint) != L10n.t("未设置"),
                          trailing: { EmptyView() }) {
                Text(sourceText(endpoint))
                    .font(.dataMonospacedBody)
                    .lineLimit(1)
            }
            OutlinedShape(label: L10n.t("目标"), isFocused: false,
                          hasValue: targetText(endpoint) != L10n.t("未设置"),
                          trailing: { EmptyView() }) {
                Text(targetText(endpoint))
                    .font(.dataMonospacedBody)
                    .lineLimit(1)
            }
            OutlinedMultiLineField(
                label: endpoint.mode.flatMap { modeLabels[$0] } ?? L10n.t("防护模式"),
                text: .constant(sourcesText(endpoint)))
                .disabled(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { onEditPolicy(endpoint) }
    }

    /// 来源 = 主机 IP + 端口；缺任一显示未设置
    private func sourceText(_ endpoint: DockerGuardEndpoint) -> String {
        if let ip = endpoint.hostIP, let port = endpoint.hostPort {
            return "\(ip):\(port)"
        }
        return L10n.t("未设置")
    }

    /// 目标 = 容器端口 + 协议；缺任一显示未设置
    private func targetText(_ endpoint: DockerGuardEndpoint) -> String {
        if let port = endpoint.containerPort, let proto = endpoint.protocolField {
            return "\(port)/\(proto.uppercased())"
        }
        return L10n.t("未设置")
    }

    /// 防护模式内容 = sources（每行一条）；deny_all 无存储来源时显示固定全量
    /// 来源（0.0.0.0/0 与 ::/0），与策略表单同口径
    private func sourcesText(_ endpoint: DockerGuardEndpoint) -> String {
        let list = (endpoint.sources ?? []).filter { !$0.isEmpty }
        if list.isEmpty {
            return endpoint.mode == "deny_all"
                ? "0.0.0.0/0\n::/0"
                : L10n.t("未设置")
        }
        return list.joined(separator: "\n")
    }
}

struct DockerGuardEndpointRow: View {
    let endpoint: DockerGuardEndpoint
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(hostLabel)
                    .font(.dataMonospacedBody.bold())
                if let proto = endpoint.protocolField {
                    StatusBadge(text: proto.uppercased(), color: .blue)
                }
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(endpoint.containerName ?? "—")
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
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if endpoint.readOnly != true, endpoint.policyUUID?.isEmpty == false {
                Button(role: .destructive, action: onDelete) {
                    Label(L10n.t("删除"), systemImage: "trash")
                }
            }
        }
    }

    private var hostLabel: String {
        let ip = endpoint.hostIP ?? ""
        let port = endpoint.hostPort.map(String.init) ?? ""
        return ip.isEmpty ? port : "\(ip):\(port)"
    }

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
            StatusBadge(text: L10n.t("未设置"), color: .secondary)
        }
    }
}

// 端口白名单解析已上移至 Models/Firewall.swift（PanelShared 自包含，Widget target 可见）
