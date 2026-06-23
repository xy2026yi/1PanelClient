//
//  CommonComponents.swift
//  1PanelClient
//
//  跨页面复用的轻量公共组件
//

import SwiftUI

// MARK: - 信息行（详情页 key-value 列表）

struct InfoRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .foregroundStyle(.secondary)
                .fixedSize()  // key 不截断，按内容自适应
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.subheadline)
    }
}

// MARK: - 圆角图标徽章（列表行首的彩色图标块）

/// 用于列表行首统一展示一个 SF Symbols 图标 + 背景色块。
/// 与 Apps/Websites/Cronjobs/Certificates 的行首图标视觉一致。
struct IconBadge: View {
    let systemName: String
    var color: Color = .accentColor
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 12
    var backgroundOpacity: Double = 0.15

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(color.opacity(backgroundOpacity))
                .frame(width: size, height: size)
            Image(systemName: systemName)
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(color)
        }
    }
}

// MARK: - 状态徽章（小胶囊标签）

/// 用于状态、类型等小标签，统一样式与色调。
struct StatusBadge: View {
    let text: String
    var color: Color = .secondary
    var icon: String? = nil
    var backgroundOpacity: Double = 0.15

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2.bold())
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.caption2.bold())
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(color.opacity(backgroundOpacity))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }
}

// MARK: - 错误重试横幅

struct ErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 72, height: 72)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
            }
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
            Button("重试", action: retry)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(.top, 48)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 区块标题（小节 header 内的图标 + 文字）

/// 给 Section header 一致的图标+文字风格
struct SectionLabel: View {
    let title: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption.bold())
            }
            Text(title)
        }
    }
}
