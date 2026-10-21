//
//  OpenSourceLicenseView.swift
//  1PanelClient
//
//  开源许可条目页：本项目与第三方组件一行一项（组件名 + 许可证），
//  整行点击经应用内浏览器打开对应仓库——GPL 全文走项目仓库 LICENSE
//  在线版，不再打包进主包（许可文本随仓库与 IPA 同源发布）。
//

import SwiftUI

struct OpenSourceLicenseView: View {

    @EnvironmentObject private var safari: InAppSafariPresenter

    /// 许可条目：组件名 + 许可证 + 仓库标识（owner/repo）+ 打开地址。
    /// 行样式：首行「组件名 …… 许可证」、次行仓库路径（migueldeicaza/SwiftTerm 式）
    private struct Item {
        let name: String
        let license: String
        let repo: String
        var repoURL: URL? { URL(string: "https://github.com/\(repo)") }
    }

    private let items: [Item] = [
        // 本项目：仓库标识指向 LICENSE 全文页（GPL 条目以许可文本为目标）
        Item(name: "1PanelClient", license: "GPL-3.0",
             repo: "xy2026yi/1PanelClient/blob/main/LICENSE"),
        Item(name: "SwiftTerm", license: "MIT",
             repo: "migueldeicaza/SwiftTerm"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(items, id: \.name) { item in
                    Button {
                        if let url = item.repoURL {
                            safari.open(url)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(item.name)
                                    Spacer()
                                    Text(item.license)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Text(item.repo)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } footer: {
                Text(L10n.t("点击整行打开对应仓库"))
            }
        }
        .navigationTitle(L10n.t("开源许可"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
