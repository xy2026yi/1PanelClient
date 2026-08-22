//
//  ServiceStatusCard.swift
//  1PanelClient
//
//  服务状态卡的统一形态：OpenResty / Docker / Fail2ban / SSH 等服务卡共用。
//  头部 = 图标 + 名称 + 副标题（版本等）+ StatusDot 状态 + 展开 chevron；
//  展开区 = 彩色图标网格操作按钮 + 可选附加内容（如「开机自启」Toggle）。
//

import SwiftUI

// MARK: - 操作项

/// 服务卡的图标网格操作按钮描述
struct ServiceAction: Identifiable {
    let title: String
    let icon: String
    let color: Color
    var isDisabled: Bool = false
    /// 自定义图标 asset 名（模板渲染），非空时优先于 SF Symbol
    var customIcon: String? = nil
    let action: () -> Void

    var id: String { title }
}

// MARK: - 服务状态卡

struct ServiceStatusCard<HeaderIcon: View, Extra: View>: View {
    let title: String
    var subtitle: String? = nil
    let statusText: String
    let statusColor: Color
    var isOperating: Bool = false
    @Binding var isExpanded: Bool
    let actions: [ServiceAction]
    @ViewBuilder let headerIcon: () -> HeaderIcon
    @ViewBuilder let extra: () -> Extra

    init(
        title: String,
        subtitle: String? = nil,
        statusText: String,
        statusColor: Color,
        isOperating: Bool = false,
        isExpanded: Binding<Bool>,
        actions: [ServiceAction],
        @ViewBuilder headerIcon: @escaping () -> HeaderIcon,
        @ViewBuilder extra: @escaping () -> Extra
    ) {
        self.title = title
        self.subtitle = subtitle
        self.statusText = statusText
        self.statusColor = statusColor
        self.isOperating = isOperating
        self._isExpanded = isExpanded
        self.actions = actions
        self.headerIcon = headerIcon
        self.extra = extra
    }

    var body: some View {
        Section {
            headerRow
            if isExpanded {
                actionsRow
                extra()
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            headerIcon()
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.bold())
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                StatusDot(color: statusColor)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(isOperating)
        }
        .padding(.vertical, 2)
    }

    /// 4 列自适应网格：≤4 个按钮单行展示，更多时自动换行
    private var actionsRow: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(actions) { act in
                actionButton(act)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private func actionButton(_ act: ServiceAction) -> some View {
        Button(action: act.action) {
            VStack(spacing: 4) {
                if isOperating {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 22, height: 22)
                } else {
                    actionIcon(act)
                        .foregroundStyle(act.color)
                        .frame(width: 22, height: 22)
                }
                Text(act.title)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(act.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(isOperating || act.isDisabled)
    }

    /// 自定义图标（如 logs/创建数据库.svg）与 SF Symbol 同尺寸着色展示
    @ViewBuilder
    private func actionIcon(_ act: ServiceAction) -> some View {
        if let custom = act.customIcon {
            Image(custom)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: act.icon)
                .font(.title3)
        }
    }
}

extension ServiceStatusCard where Extra == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        statusText: String,
        statusColor: Color,
        isOperating: Bool = false,
        isExpanded: Binding<Bool>,
        actions: [ServiceAction],
        @ViewBuilder headerIcon: @escaping () -> HeaderIcon
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            statusText: statusText,
            statusColor: statusColor,
            isOperating: isOperating,
            isExpanded: isExpanded,
            actions: actions,
            headerIcon: headerIcon,
            extra: { EmptyView() }
        )
    }
}

// MARK: - 加载/失败占位行

/// 服务卡加载占位行（状态接口请求中）
struct ServiceStatusLoadingRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// 服务卡失败占位行（未安装或加载失败）
struct ServiceStatusFailedRow: View {
    let text: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 4)
    }
}
