//
//  SFSymbolAuditTests.swift
//  1PanelClientTests
//
//  SF Symbol 全量审计（B1）：扫描仓库源码中 systemName/systemImage 字面量，
//  逐个用 UIImage(systemName:) 断言有效（与 iOS 运行时渲染语义一致，
//  优于 NSImage 代理法）。无效符号在真机上渲染为空白，此前已发生过
//  `certificate`、`chevron.up.forward` 两例。
//  动态拼接名（三元/变量）无法静态提取，以 dynamicSymbolNames 人工清单固化断言
//  （2026-09-16 P3 落地），新增动态分支时同步补清单。
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

    /// 动态拼接名（switch/三元计算值）静态扫描抓不到，此清单为人工过目结果的固化
    /// （2026-09-16 四维审查 P3 落地）。新增动态图标分支时把取值补进本清单：
    /// 来源 = FilesView.fileIcon / Database.systemIcon / AppLock.biometryIcon /
    /// WebsiteLogType.icon 及全库三元切换（eye/chevron/pause 等）
    private static let dynamicSymbolNames = [
        // fileIcon（文件后缀映射）
        "doc.text", "doc.text.below.ecg", "curlybraces", "photo", "doc.zipper", "book", "doc",
        // Database.systemIcon（数据库系统）
        "cylinder.split.1x2", "cylinder", "server.rack",
        // AppLock.biometryIcon
        "faceid", "touchid", "eye.square", "lock.fill",
        // WebsiteLogType.icon
        "list.bullet.rectangle", "exclamationmark.triangle.fill",
        // 三元切换对（眼睛/箭头/播放/星标/拼图等）
        "eye", "eye.slash", "chevron.up", "chevron.down",
        "arrow.up.circle.fill", "arrow.down.circle.fill", "arrow.up.circle", "arrow.down.circle",
        "arrow.uturn.backward.circle.fill", "arrow.uturn.backward.circle", "arrow.down",
        "checkmark.circle.fill", "circle", "xmark.circle.fill", "xmark.octagon.fill",
        "checkmark.shield", "hand.raised", "checkmark.seal.fill", "checkmark.shield.fill",
        "exclamationmark.triangle", "chart.bar", "folder", "folder.fill",
        "icloud.slash", "icloud.and.arrow.up", "key.fill", "terminal.fill",
        "link.badge.plus", "link", "minus.circle.fill",
        "pause.circle", "play.circle", "pause.fill", "play.fill", "stop.fill",
        "puzzlepiece.extension.fill", "puzzlepiece.extension", "puzzlepiece",
        "shippingbox.fill", "star", "star.slash", "wand.and.stars", "xmark", "pencil", "tray",
    ]

    @Test("动态拼接的 SF Symbol 名（人工清单）在 iOS 运行时均有效")
    func dynamicSymbolNamesAreValid() {
        let invalid = Set(Self.dynamicSymbolNames).filter { UIImage(systemName: $0) == nil }
        #expect(invalid.isEmpty,
                "动态图标清单中的无效 SF Symbol（渲染为空白）：\(invalid.sorted().joined(separator: ", "))")
    }
}
