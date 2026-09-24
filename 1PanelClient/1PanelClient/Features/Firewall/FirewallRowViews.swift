//
//  FirewallRowViews.swift
//  1PanelClient
//
//  规则行 / 转发行（自 FirewallView.swift 拆出）
//

import SwiftUI
import Combine

// MARK: - 规则行

struct FirewallRuleRowView: View {
    let item: FirewallInventoryItem
    var processName: String?
    /// 链内优先级（observed.locator.position；external 规则可能缺失）
    var priority: Int?
    /// 是否显示使用方徽标：导入/导出预览行没有监听数据（processName 恒
    /// nil），不传 false 会整列误显「未使用」
    var showsUsage: Bool = true

    private var rule: FirewallRule? { item.rule ?? item.desired?.rule }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                // 行格式对齐 Web 端：优先级 端口 协议 地址族 使用方 策略
                if let priority {
                    Text(String(priority))
                        .font(.dataMonospacedBody.bold())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 18, alignment: .trailing)
                }
                Text(mainToken)
                    .font(.dataMonospacedBody.bold())
                    .lineLimit(1)
                if let proto = rule?.protocolField, !proto.isEmpty {
                    StatusBadge(text: proto.uppercased(), color: .blue)
                }
                if let family = familyLabel {
                    StatusBadge(text: family.label, color: family.color)
                }
                Spacer()
                // 使用方：占用该端口的监听进程（/process/listening 按端口匹配）。
                // 纯 IP 规则无端口、匹配不适用，不显示徽标（否则恒显「未使用」）
                if showsUsage, rule?.destinationPort?.isEmpty == false {
                    StatusBadge(text: processName?.isEmpty == false ? processName! : L10n.t("未使用"),
                                color: processName?.isEmpty == false ? .blue : .secondary)
                }
                actionBadge
            }
            if !secondaryLine.isEmpty {
                Text(secondaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    /// 地址族徽标（scope.family；ipv6 → IPv6，其余非空 → IPv4）
    private var familyLabel: (label: String, color: Color)? {
        switch rule?.scope?.family {
        case "ipv6": return ("IPv6", .indigo)
        case "ipv4", "inet": return ("IPv4", .secondary)
        default: return nil
        }
    }

    private var mainToken: String {
        if let port = rule?.destinationPort, !port.isEmpty { return port }
        if let addr = rule?.sourceAddress, !addr.isEmpty { return addr }
        return "—"
    }

    private var secondaryLine: String {
        var parts: [String] = []
        if let addr = rule?.sourceAddress, !addr.isEmpty,
           rule?.destinationPort?.isEmpty == false {
            parts.append(L10n.f("来源：%@", addr))
        }
        if let dest = rule?.destinationAddress, !dest.isEmpty {
            parts.append(L10n.f("目标：%@", dest))
        }
        if let desc = rule?.descriptionText, !desc.isEmpty {
            parts.append(desc)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actionBadge: some View {
        if let action = rule?.action {
            StatusBadge(
                text: action == "accept" ? L10n.t("放行") : L10n.t("拒绝"),
                color: action == "accept" ? .statusRunning : .statusError
            )
        }
    }
}

// MARK: - 转发行

struct FirewallForwardRowView: View {
    let rule: FirewallForwardRule

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(rule.port ?? "-")
                    .font(.dataMonospacedBody.bold())
                if let proto = rule.protocolField, !proto.isEmpty {
                    StatusBadge(text: proto.uppercased(), color: .blue)
                }
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(target)
                    .font(.dataMonospaced)
                    .lineLimit(1)
                Spacer()
                // 转发无策略概念：状态只看 isRuntime（已生效/未生效）
                if rule.isRuntime == true {
                    StatusBadge(text: L10n.t("已生效"), color: .statusRunning)
                } else {
                    StatusBadge(text: L10n.t("未生效"), color: .secondary)
                }
            }
            if !secondaryLine.isEmpty {
                Text(secondaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var target: String {
        let ip = rule.targetIP ?? ""
        let port = rule.targetPort ?? ""
        if ip.isEmpty { return port }
        return "\(ip):\(port)"
    }

    private var secondaryLine: String {
        var parts: [String] = []
        if let family = rule.family, !family.isEmpty { parts.append(family.uppercased()) }
        if let iface = rule.interface, !iface.isEmpty, iface != "*" {
            parts.append(L10n.f("网卡：%@", iface))
        }
        if let used = rule.usedStatus, !used.isEmpty { parts.append(used) }
        if let desc = rule.descriptionText, !desc.isEmpty { parts.append(desc) }
        return parts.joined(separator: " · ")
    }
}
