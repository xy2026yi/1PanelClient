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

/// regular 宽度下按最小格宽自适应列数（列数随实际宽度浮动），
/// compact 保持手机固定列。适用于「按钮/指标个数不固定」的网格：
/// 固定列数在 iPad 竖屏（侧栏挤压内容宽度）下格宽不足会挤压重叠，
/// 且按钮少于列数时会缩在左边不满行铺开。
func adaptiveGridColumns(compact: Int, minimum: CGFloat, spacing: CGFloat = 12,
                        horizontal: UserInterfaceSizeClass?) -> [GridItem] {
    horizontal == .regular
        ? [GridItem(.adaptive(minimum: minimum), spacing: spacing)]
        : Array(repeating: GridItem(.flexible(), spacing: spacing), count: compact)
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
                // ignoresSafeArea：横屏时底部安全区外曾露出系统白底竖块
                .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
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

// MARK: - 半屏弹窗按尺寸类适配

/// iPad（regular 宽度）上 .sheet + presentationDetents 会以 formSheet 形态
/// 居中浮动呈现：距屏幕底部和左右两侧都有大块留白，观感破碎。
/// 系统没有让 detent sheet 在 iPad 上贴底全宽的 API，因此只在 compact 下
/// 保留半屏贴底 sheet，regular 下退掉 detents，以标准居中 pageSheet 呈现。
private struct BottomSheetDetentsModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var hSize
    let detents: Set<PresentationDetent>

    func body(content: Content) -> some View {
        if hSize == .regular {
            content
        } else {
            content.presentationDetents(detents)
        }
    }
}

extension View {
    /// presentationDetents 的尺寸类适配版：iPhone 半屏贴底，iPad 居中模态
    func bottomSheetDetents(_ detents: Set<PresentationDetent>) -> some View {
        modifier(BottomSheetDetentsModifier(detents: detents))
    }
}
