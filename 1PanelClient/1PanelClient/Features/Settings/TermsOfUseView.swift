//
//  TermsOfUseView.swift
//  1PanelClient
//
//  App 内使用条款页：内容在构建期由 docs/terms-of-use.md 打包为主包资源
//  TermsOfUse.md（单一源头——改文案只改 md，重新构建即同步），渲染由通用
//  MarkdownDocView 承担；本地直开不走在线探测（轻量版，在线版即仓库文件）。
//

import SwiftUI

struct TermsOfUseView: View {

    /// 在线版地址（跟随 App 语言；资源缺失兜底入口用）
    static var onlineURL: URL? {
        let file = L10n.shared.isEnglishEffective ? "terms-of-use.en.md" : "terms-of-use.md"
        return URL(string: "https://github.com/xy2026yi/1PanelClient/blob/main/docs/\(file)")
    }

    var body: some View {
        MarkdownDocView(
            navigationTitle: L10n.t("使用条款"),
            resourceBaseName: "TermsOfUse",
            onlineURL: Self.onlineURL)
    }
}
