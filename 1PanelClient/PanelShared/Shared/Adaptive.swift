//
//  Adaptive.swift
//  1PanelClient
//
//  iPad 适配（regular 宽度）的基础设施：
//    - horizontalSizeClass 是唯一分叉点：iPad 分屏半屏同样回落 compact，
//      因此不用 userInterfaceIdiom 判定
//    - contentWidthLimit：滚动内容（卡片/图表/日志）在 regular 下限宽居中
//    - formWidthLimit：Form/List 在 regular 下限宽居中并铺同色背景
//    - gridColumns：固定语义列数按尺寸类切换（compact 保持手机布局）
//

import SwiftUI

// MARK: - 网格列数

/// compact/regular 各自固定列数的网格列定义（语义布局用，如「每行固定 4 个指标环」）
func gridColumns(compact: Int, regular: Int, spacing: CGFloat = 12,
                 horizontal: UserInterfaceSizeClass?) -> [GridItem] {
    Array(repeating: GridItem(.flexible(), spacing: spacing), count: horizontal == .regular ? regular : compact)
}

// MARK: - 滚动内容限宽

/// regular 宽度下限制内容宽度并居中；compact 直通
private struct ContentWidthLimitModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var hSize

    var maxWidth: CGFloat

    func body(content: Content) -> some View {
        if hSize == .regular {
            content
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}

extension View {
    /// 滚动内容（卡片堆/图表/日志）在 iPad 上限宽居中，避免全宽拉伸
    func contentWidthLimit(_ maxWidth: CGFloat = 720) -> some View {
        modifier(ContentWidthLimitModifier(maxWidth: maxWidth))
    }
}

// MARK: - Form/List 限宽

/// regular 宽度下 Form/List 限宽居中，画布其余部分铺 grouped 背景色保持一致
private struct FormWidthLimitModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var hSize

    var maxWidth: CGFloat

    func body(content: Content) -> some View {
        if hSize == .regular {
            content
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
                .background(Color(uiColor: .systemGroupedBackground))
        } else {
            content
        }
    }
}

extension View {
    /// 表单/设置类页面在 iPad 上限宽居中（对齐系统设置的分组观感）
    func formWidthLimit(_ maxWidth: CGFloat = 680) -> some View {
        modifier(FormWidthLimitModifier(maxWidth: maxWidth))
    }
}
