//
//  EllipsisMenu.swift
//  1PanelClient
//
//  自绘三点菜单：系统 Menu 弹出的气泡有约半屏的最小宽度下限，
//  文字再短也无法变窄；此组件用自绘气泡替代，宽度自适应菜单项文字。
//  仅支持纯文字动作项（含分隔线/破坏性样式/禁用态），
//  含 Toggle / Picker 的菜单仍需使用系统 Menu。
//  已知限制：点击遮罩可关闭，但导航栏区域点不到遮罩（SwiftUI
//  overlay 无法覆盖 UIKit 导航栏），再点省略号按钮可关闭。
//

import SwiftUI

// MARK: - 菜单项

/// 自绘菜单条目：动作或分隔线
enum EllipsisMenuEntry {
    case action(
        title: String,
        role: ButtonRole? = nil,
        isDisabled: Bool = false,
        handler: () -> Void
    )
    case divider
}

// MARK: - 触发按钮（放在 toolbar 的 topBarTrailing）

/// 省略号触发按钮：点击后由页面展示 EllipsisMenuPopup
struct EllipsisMenuButton: View {
    var isLoading: Bool = false
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            if isLoading {
                ProgressView()
            } else {
                Image(systemName: "ellipsis.circle")
            }
        }
        .accessibilityLabel(isLoading ? "加载中" : "更多操作")
    }
}

// MARK: - 气泡面板

/// 自绘菜单气泡：右上角锚定、点击遮罩关闭；宽度收窄自适应内容
struct EllipsisMenuPopup: View {
    let entries: [EllipsisMenuEntry]
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // 近乎透明的全屏点击层：点菜单外任意处关闭
            Color.black.opacity(0.01)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    switch entry {
                    case .action(let title, let role, let isDisabled, let handler):
                        rowButton(title: title, role: role, isDisabled: isDisabled, handler: handler)
                    case .divider:
                        Divider()
                    }
                }
            }
            .frame(minWidth: 108, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 5)
            .padding(.trailing, 12)
            .padding(.top, 6)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
    }

    private func rowButton(
        title: String,
        role: ButtonRole?,
        isDisabled: Bool,
        handler: @escaping () -> Void
    ) -> some View {
        Button {
            onDismiss()
            handler()
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(role == .destructive ? Color.red : Color.primary)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
    }
}
