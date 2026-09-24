//
//  FirewallRowViews.swift
//  1PanelClient
//
//  规则行 / 转发行（自 FirewallView.swift 拆出，内容未改动）
//

import SwiftUI
import Combine

// MARK: - 规则行

struct FirewallRuleRowView: View {
    let item: FirewallInventoryItem
    var processName: String?

    private var rule: FirewallRule? { item.rule ?? item.desired?.rule }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                // 端口（端口规则）或 源地址（IP 规则）为主标识
                Text(mainToken)
                    .font(.dataMonospacedBody.bold())
                    .lineLimit(1)
                if let proto = rule?.protocolField, !proto.isEmpty {
                    StatusBadge(text: proto.uppercased(), color: .blue)
                }
                Spacer()
                stateBadge
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
        if let sport = rule?.sourcePort, !sport.isEmpty {
            parts.append(L10n.f("源端口：%@", sport))
        }
        if let dest = rule?.destinationAddress, !dest.isEmpty {
            parts.append(L10n.f("目标：%@", dest))
        }
        if let pn = processName, !pn.isEmpty {
            parts.append(pn)
        }
        if let desc = rule?.descriptionText, !desc.isEmpty {
            parts.append(desc)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var stateBadge: some View {
        let mapping: [(String, String, Color)] = [
            ("managed", L10n.t("面板创建"), .statusRunning),
            ("adopted", L10n.t("外部纳管"), .blue),
            ("external", L10n.t("外部"), .secondary),
            ("drifted", L10n.t("异常"), .semanticWarning),
            ("protected", L10n.t("系统保护"), .purple),
        ]
        if let state = item.state,
           let entry = mapping.first(where: { $0.0 == state }) {
            StatusBadge(text: entry.1, color: entry.2)
        }
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
                if rule.strategy?.lowercased() == "accept" || rule.strategy == nil {
                    StatusBadge(text: L10n.t("放行"), color: .statusRunning)
                } else {
                    StatusBadge(text: L10n.t("拒绝"), color: .statusError)
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

