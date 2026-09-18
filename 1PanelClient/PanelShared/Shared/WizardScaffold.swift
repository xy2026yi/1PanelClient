//
//  WizardScaffold.swift
//  1PanelClient
//
//  分页向导公共骨架：步骤指示条（页名居中）+ 底部固定导航（返回/下一步/主操作）。
//  与描边表单组件（OutlinedField）配套用于多段新建流，见
//  docs/outlined-form-adoption-assessment-2026-09.md 的向导适用清单。
//

import SwiftUI

// MARK: - 步骤指示条

/// 标题下方横贯的步骤指示：段线 + 页名（当前页高亮加粗、已过段点亮）
struct WizardStepsBar: View {
    let pageNames: [String]
    let current: Int

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<pageNames.count, id: \.self) { i in
                VStack(spacing: 5) {
                    Capsule()
                        .fill(i <= current ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                        .frame(maxWidth: .infinity)
                    Text(pageNames[i])
                        .font(.caption2.weight(i == current ? .bold : .regular))
                        .foregroundStyle(i <= current ? Color.accentColor : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .animation(.easeInOut(duration: 0.22), value: current)
    }
}

// MARK: - 底部固定导航

/// 返回 / 下一步 / 主操作（最后页），safeAreaInset 固定底部不受滚动影响
struct WizardBottomBar: View {
    let page: Int
    let totalPages: Int
    /// 最后页按钮文案（如 创建 / 安装 / 保存）
    let primaryTitle: String
    /// 主操作进行中（显示进度圈）
    var isBusy = false
    /// 前进/主操作禁用（如必填未填）
    var primaryDisabled = false
    let onBack: () -> Void
    let onNext: () -> Void
    let onPrimary: () -> Void

    private var isLast: Bool { page == totalPages - 1 }

    var body: some View {
        HStack(spacing: 12) {
            if page > 0 {
                Button(L10n.t("返回"), action: onBack)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.secondary.opacity(0.4))
                    )
            }
            Button(action: isLast ? onPrimary : onNext) {
                if isBusy {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else {
                    Text(isLast ? primaryTitle : L10n.t("下一步"))
                        .bold()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(primaryDisabled || isBusy)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
