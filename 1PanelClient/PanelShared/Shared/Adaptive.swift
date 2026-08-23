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
//    - AdaptiveStatGrid：统计卡网格按实际宽度 4 列/2×2 切换
//    - bottomSheetDetents：半屏 sheet 仅 compact 生效（regular 退 detents 走居中模态）
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

/// sheet 内容里读到的系统 horizontalSizeClass 恒为 compact（iOS 26 iPad 实测，
/// detents 有无皆然），无法据此区分 iPad；而自定义环境值不会被展示容器重写，
/// 会从呈现视图一路传播进 sheet。故由主场景根部注入窗口尺寸类供弹层读取。
private struct PresenterSizeClassKey: EnvironmentKey {
    static let defaultValue: UserInterfaceSizeClass? = nil
}

extension EnvironmentValues {
    /// 呈现方（主窗口）的横向尺寸类；nil = 未注入（Widget/预览），消费方自行回落
    var presenterHorizontalSizeClass: UserInterfaceSizeClass? {
        get { self[PresenterSizeClassKey.self] }
        set { self[PresenterSizeClassKey.self] = newValue }
    }
}

/// iPad（regular 宽度）上 .sheet + presentationDetents 会以 formSheet 形态
/// 居中浮动呈现：距屏幕底部和左右两侧都有大块留白，观感破碎。
/// 系统没有让 detent sheet 在 iPad 上贴底全宽的 API，因此只在 compact 下
/// 保留半屏贴底 sheet，regular 下退掉 detents，以标准居中 pageSheet 呈现。
private struct BottomSheetDetentsModifier: ViewModifier {
    @Environment(\.presenterHorizontalSizeClass) private var presenter
    /// 兜底：根部未注入时按本地环境（与旧语义一致）
    @Environment(\.horizontalSizeClass) private var hSize

    let detents: Set<PresentationDetent>

    func body(content: Content) -> some View {
        if (presenter ?? hSize) == .regular {
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

/// 主场景根部注入：把窗口尺寸类写进自定义环境（见 PresenterSizeClassKey 说明）
private struct PresenterSizeClassHostModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var hSize

    func body(content: Content) -> some View {
        content.environment(\.presenterHorizontalSizeClass, hSize)
    }
}

extension View {
    /// 挂在 App 根视图上，为全 App 的 sheet 内容提供呈现方尺寸类
    func hostingPresenterSizeClass() -> some View {
        modifier(PresenterSizeClassHostModifier())
    }
}

// MARK: - 统计卡自适应网格

/// 固定按 4 张「图标+标题+数值」统计卡一行的网格：内容实际宽度 ≥600 用 4 列，
/// 不足回落 2×2（手机布局）。regular 下内容宽度随侧栏折叠/分屏浮动，
/// 固定 regular 列数在竖屏+侧栏（内容 ~500pt）会把卡片挤成 ~119pt 宽。
/// 首帧用尺寸类先猜列数（环境立即可得），布局后 onGeometryChange 校正。
struct AdaptiveStatGrid<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var hSize
    /// nil = 尚未测得实际宽度，先按尺寸类取值
    @State private var measuredColumns: Int?
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyVGrid(
            columns: gridColumns(compact: 2, regular: columns, spacing: spacing, horizontal: hSize),
            spacing: spacing
        ) {
            content()
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            measuredColumns = width >= 600 ? 4 : 2
        }
    }

    private var columns: Int {
        measuredColumns ?? (hSize == .regular ? 4 : 2)
    }
}
