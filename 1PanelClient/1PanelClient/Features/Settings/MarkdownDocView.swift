//
//  MarkdownDocView.swift
//  1PanelClient
//
//  打包在主包内的单源文档通用渲染页：按行解析 markdown（标题/段落/列表/表格；
//  行内加粗/链接交给 AttributedString），List 分组呈现。内容资源在构建期由
//  docs/*.md 拷入主包（见工程 Embed Privacy Policy 脚本阶段），按 App 生效
//  语言选英文版、缺失回落中文版；资源缺失时兜底给在线版入口。
//

import SwiftUI

struct MarkdownDocView: View {
    /// 导航栏标题
    let navigationTitle: String
    /// 主包资源基名（如 "PrivacyPolicy"：中文取 <base>.md，英文取 <base>.en.md，
    /// 英文资源缺失回落 <base>.md）
    let resourceBaseName: String
    /// 在线版地址（资源缺失兜底入口用）
    let onlineURL: URL?

    // MARK: - 解析模型（init 一次成型，body 纯渲染）

    private enum Item {
        case quote(String)          // 文首引用块（维护说明/最后更新），小字弱化
        case paragraph(String)
        case bullet(String)
        case table(header: [String], rows: [[String]])
    }

    private struct DocSection {
        let heading: String?
        var items: [Item] = []
    }

    private let sections: [DocSection]

    init(navigationTitle: String, resourceBaseName: String, onlineURL: URL?) {
        self.navigationTitle = navigationTitle
        self.resourceBaseName = resourceBaseName
        self.onlineURL = onlineURL
        self.sections = Self.parse(Self.markdown(resourceBaseName: resourceBaseName))
    }

    /// 构建期资源：按 App 生效语言选英文版，英文资源缺失回落中文版
    private static func markdown(resourceBaseName: String) -> String {
        let name = L10n.shared.isEnglishEffective ? "\(resourceBaseName).en" : resourceBaseName
        let url = Bundle.main.url(forResource: name, withExtension: "md")
            ?? Bundle.main.url(forResource: resourceBaseName, withExtension: "md")
        guard let url else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func parse(_ md: String) -> [DocSection] {
        var sections: [DocSection] = []
        var quoteLines: [String] = []
        var current = DocSection(heading: nil)
        var tableHeader: [String]?
        var tableRows: [[String]] = []

        func flushTable() {
            if let header = tableHeader {
                current.items.append(.table(header: header, rows: tableRows))
            }
            tableHeader = nil
            tableRows = []
        }
        func flushSection() {
            flushTable()
            if current.heading != nil || !current.items.isEmpty {
                sections.append(current)
            }
            current = DocSection(heading: nil)
        }

        for raw in md.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("> ") {
                quoteLines.append(String(line.dropFirst(2)))
            } else if line.hasPrefix("# ") {
                continue // 主标题由导航栏承担
            } else if line.hasPrefix("## ") {
                flushSection()
                current = DocSection(heading: String(line.dropFirst(3)))
            } else if line.hasPrefix("|") {
                let cells = line.split(separator: "|", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                // |---|---| 分隔行
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 == "-" } }) { continue }
                if tableHeader == nil { tableHeader = cells } else { tableRows.append(cells) }
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushTable()
                current.items.append(.bullet(String(line.dropFirst(2))))
            } else if line.isEmpty {
                flushTable()
            } else {
                flushTable()
                current.items.append(.paragraph(line))
            }
        }
        flushSection()

        if !quoteLines.isEmpty {
            sections.insert(DocSection(heading: nil, items: [.quote(quoteLines.joined(separator: "\n"))]), at: 0)
        }
        return sections
    }

    // MARK: - 渲染

    var body: some View {
        List {
            if sections.isEmpty {
                // 资源缺失兜底（正常构建不会走到）：直接给在线版入口
                Section {
                    if let url = onlineURL {
                        Link(L10n.t("查看在线版本"), destination: url)
                    }
                }
            }
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                Section {
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                        itemRow(item)
                    }
                } header: {
                    if let heading = section.heading {
                        inlineText(heading, font: .footnote.weight(.semibold))
                    }
                }
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func itemRow(_ item: Item) -> some View {
        switch item {
        case .quote(let text):
            Text(text)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .paragraph(let text):
            inlineText(text, font: .subheadline)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .foregroundStyle(.secondary)
                inlineText(text, font: .subheadline)
            }
        case .table(let header, let rows):
            tableView(header, rows)
        }
    }

    /// 表格行内化渲染：表头列名合并为小字提示，数据行首列为条目名、
    /// 其余列合并为副行（兜底页可读优先，不还原四列网格）
    private func tableView(_ header: [String], _ rows: [[String]]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 2) {
                    inlineText(row.first ?? "", font: .subheadline.weight(.medium))
                    if row.count > 1 {
                        inlineText(row.dropFirst().joined(separator: " · "), font: .caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// 行内 markdown（加粗/链接/代码）解析，失败回落纯文本
    private func inlineText(_ text: String, font: Font) -> Text {
        let attributed: AttributedString? = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return Text(attributed ?? AttributedString(text)).font(font)
    }
}
