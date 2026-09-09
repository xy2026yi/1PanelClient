//
//  SFSymbolAuditTests.swift
//  1PanelClientTests
//
//  SF Symbol 全量审计（B1）：扫描仓库源码中 systemName/systemImage 字面量，
//  逐个用 UIImage(systemName:) 断言有效（与 iOS 运行时渲染语义一致，
//  优于 NSImage 代理法）。无效符号在真机上渲染为空白，此前已发生过
//  `certificate`、`chevron.up.forward` 两例。
//  动态拼接名（三元/变量）无法静态提取，仍走人工过目（审计计划 B1 保留项）。
//

import Testing
import UIKit
import Foundation

@Suite("SF Symbol 审计")
struct SFSymbolAuditTests {
    /// 覆盖的参数形态：Image/IconBadge 的 systemName、Label/ContentUnavailableView 的
    /// systemImage、AppShortcut 的 systemImageName、ActionBottomSheet/EllipsisMenuPopup
    /// 等菜单项的 icon（此前 certificate 空白一例正是经 icon: 传入、逃过了审计）
    private static let patterns = [
        #"systemName:\s*"([^"\\]+)""#,
        #"systemImage:\s*"([^"\\]+)""#,
        #"systemImageName:\s*"([^"\\]+)""#,
        #"icon:\s*"([^"\\]+)""#,
    ]

    /// 扫描这三个源码目录（app / 共享层 / Widget）
    private static let sourceDirs = ["1PanelClient", "PanelShared", "PanelWidgets"]

    /// 兜底阈值：防止源码目录定位失败时扫描结果为空、用例退化成恒真
    private static let minimumLiteralCount = 80

    private static func repoRoot() -> URL {
        // 本文件位于 <repo>/1PanelClient/1PanelClientTests/，仓库源码根在两级之上
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func extractLiterals() throws -> [String] {
        let root = repoRoot()
        var literals: [String] = []
        var regexes: [NSRegularExpression] = []
        for pattern in patterns {
            regexes.append(try NSRegularExpression(pattern: pattern))
        }

        for dir in sourceDirs {
            let dirURL = root.appendingPathComponent(dir)
            guard let enumerator = FileManager.default.enumerator(
                at: dirURL, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "swift",
                      let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                let range = NSRange(content.startIndex..., in: content)
                for regex in regexes {
                    for match in regex.matches(in: content, range: range) {
                        if let r = Range(match.range(at: 1), in: content) {
                            literals.append(String(content[r]))
                        }
                    }
                }
            }
        }
        return literals
    }

    @Test("源码中全部 SF Symbol 字面量在 iOS 运行时均有效")
    func allSymbolLiteralsAreValid() throws {
        let literals = try Self.extractLiterals()
        #expect(literals.count >= Self.minimumLiteralCount,
                "扫描到的字面量仅 \(literals.count) 处（阈值 \(Self.minimumLiteralCount)），疑似源码目录定位失败：\(Self.repoRoot().path)")

        let unique = Set(literals)
        let invalid = unique.filter { UIImage(systemName: $0) == nil }
        #expect(invalid.isEmpty,
                "无效 SF Symbol（iOS 渲染为空白）：\(invalid.sorted().joined(separator: ", "))")
    }

    @Test("历史踩坑符号不得回归")
    func knownInvalidSymbolsStayOut() {
        // 曾在本工程出现过的无效名（dc618c5 修 chevron.up.forward、本次修 certificate）
        #expect(UIImage(systemName: "certificate") == nil)
        #expect(UIImage(systemName: "chevron.up.forward") == nil)
        // 替换后的有效名
        #expect(UIImage(systemName: "checkmark.seal") != nil)
    }
}
