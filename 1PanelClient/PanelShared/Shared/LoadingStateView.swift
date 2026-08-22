//
//  LoadingStateView.swift
//  1PanelClient
//
//  统一加载态组件 —— 全页分支用默认样式，Section 内行用 compact。
//  文案默认「加载中…」，语义特例（加载日志…/正在连接…）显式传入。
//

import SwiftUI

struct LoadingStateView: View {
    var text: String = L10n.t("加载中…")
    /// Section 内行：降低高度占位
    var compact: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 60 : 160)
    }
}
