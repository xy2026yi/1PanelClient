//
//  PrivacyPolicyView.swift
//  1PanelClient
//
//  App 内隐私政策本地兜底页：内容在构建期由 docs/privacy-policy.md 打包为
//  主包资源 PrivacyPolicy.md（单一源头——改文案只改 md，重新构建即同步），
//  渲染由通用 MarkdownDocView 承担。在线可达时关于页直接跳 GitHub，本页仅离线兜底。
//

import SwiftUI

struct PrivacyPolicyView: View {

    /// 在线版地址（跟随 App 语言；资源缺失兜底页与关于页探测共用）
    static var onlineURL: URL? {
        let file = L10n.shared.isEnglishEffective ? "privacy-policy.en.md" : "privacy-policy.md"
        return URL(string: "https://github.com/xy2026yi/1PanelClient/blob/main/docs/\(file)")
    }

    var body: some View {
        MarkdownDocView(
            navigationTitle: L10n.t("隐私政策"),
            resourceBaseName: "PrivacyPolicy",
            onlineURL: Self.onlineURL)
    }
}
