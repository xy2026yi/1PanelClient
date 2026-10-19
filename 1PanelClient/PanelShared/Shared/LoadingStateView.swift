//
//  LoadingStateView.swift
//  1PanelClient
//
//  统一加载态组件 —— 全页分支用默认样式，Section 内行用 compact。
//  文案默认「加载中…」，语义特例（加载日志…/正在连接…）显式传入。
//  250ms 延迟淡入：连接池保温下短请求常在 300ms 内完成，转圈一闪而过
//  反成视觉噪音；等待期内容占位不变（frame 撑高），超时才淡入转圈。
//

import SwiftUI

struct LoadingStateView: View {
    var text: String = L10n.t("加载中…")
    /// Section 内行：降低高度占位
    var compact: Bool = false

    /// 250ms 内加载完成（视图即被移除、task 取消）则全程不显示
    @State private var visible = false

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        // 全页加载态必须撑满高度：FAB overlay 锚在内容容器上，
        // 高度只有 160 会让悬浮按钮贴在屏幕中部偏右，旋转才恢复
        .frame(maxWidth: .infinity, minHeight: compact ? 60 : 160, maxHeight: compact ? nil : .infinity)
        .opacity(visible ? 1 : 0)
        .accessibilityHidden(!visible)
        .task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.15)) { visible = true }
        }
    }
}
