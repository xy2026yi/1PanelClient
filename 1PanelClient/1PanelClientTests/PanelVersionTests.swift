//
//  PanelVersionTests.swift
//  1PanelClientTests
//
//  面板版本语义化比较（M0-2 L0 版本感知）：rc/beta 后缀、v 前缀、
//  缺段补零；替换旧的字符串不等判断（2.3.0-rc1 vs 2.3.0 曾误报有更新）
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("面板版本语义化比较")
struct PanelVersionTests {
    @Test("基本升序")
    func basicAscending() {
        #expect(PanelVersionTools.compare("v2.3.0", "v2.2.5") == .orderedDescending)
        #expect(PanelVersionTools.compare("2.2.4", "2.2.5") == .orderedAscending)
        #expect(PanelVersionTools.compare("v2.2.5", "2.2.5") == .orderedSame)
    }

    @Test("v/V 前缀与缺段补零")
    func prefixAndShortSegments() {
        #expect(PanelVersionTools.compare("V2.10.0", "v2.9.9") == .orderedDescending)
        #expect(PanelVersionTools.compare("2.3", "2.3.0") == .orderedSame)
        #expect(PanelVersionTools.compare("2.3.1", "2.3") == .orderedDescending)
    }

    @Test("预发布后缀：正式版 > rc/beta")
    func prereleaseRanking() {
        #expect(PanelVersionTools.compare("2.3.0-rc1", "2.3.0") == .orderedAscending)
        #expect(PanelVersionTools.compare("2.3.0", "2.3.0-beta2") == .orderedDescending)
        #expect(PanelVersionTools.compare("2.3.0-rc1", "2.3.0-rc2") == .orderedAscending)
        // 修复主诉：面板已装 2.3.0 正式版、上游 latest 误报回 rc → 不提示
        #expect(!PanelUpgradeInfo(latestVersion: "v2.3.0-rc1", releaseNote: nil)
            .hasUpdate(comparedTo: "v2.3.0"))
    }

    @Test("无法解析的容错")
    func unparseableFallback() {
        #expect(PanelVersionTools.compare(nil, "v2.2.5") == .orderedSame)
        #expect(PanelVersionTools.compare("abc", "v2.2.5") == .orderedSame)
        #expect(PanelVersionTools.compare("v2.3.0", nil) == .orderedDescending)
    }
}
