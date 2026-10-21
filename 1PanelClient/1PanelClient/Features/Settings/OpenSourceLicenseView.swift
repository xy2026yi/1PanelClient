//
//  OpenSourceLicenseView.swift
//  1PanelClient
//
//  App 内开源许可页：GPLv3 全文在构建期由仓库根 LICENSE 原样打包为主包
//  资源 OpenSourceLicense.md（单一源头即许可文件本身，不存副本不会漂移），
//  渲染由通用 MarkdownDocView 承担。GPL 官方文本仅英文（译本均非正式），
//  故只打一份、中英界面共用；兑现 GPLv3 §4 随二进制分发附带许可文本。
//

import SwiftUI

struct OpenSourceLicenseView: View {

    /// 在线版地址（资源缺失兜底入口用；GitHub 原样渲染仓库根 LICENSE）
    static let onlineURL = URL(string: "https://github.com/xy2026yi/1PanelClient/blob/main/LICENSE")

    var body: some View {
        MarkdownDocView(
            navigationTitle: L10n.t("开源许可"),
            resourceBaseName: "OpenSourceLicense",
            onlineURL: Self.onlineURL)
    }
}
