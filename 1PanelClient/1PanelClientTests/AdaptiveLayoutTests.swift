//
//  AdaptiveLayoutTests.swift
//  1PanelClientTests
//
//  iPad 适配工具：网格列数按尺寸类切换（compact 保持手机布局、regular 加列、未知回落 compact）
//

import Testing
import SwiftUI
@testable import _PanelClient

@Suite("Adaptive 布局工具")
struct AdaptiveLayoutTests {
    @Test("列数随尺寸类切换")
    func columnsBySizeClass() {
        #expect(gridColumns(compact: 2, regular: 4, horizontal: .compact).count == 2)
        #expect(gridColumns(compact: 2, regular: 4, horizontal: .regular).count == 4)
        #expect(gridColumns(compact: 4, regular: 8, spacing: 4, horizontal: .regular).count == 8)
    }

    @Test("尺寸类未知（nil）时回落 compact 列数")
    func nilSizeClassFallsBackToCompact() {
        #expect(gridColumns(compact: 2, regular: 4, horizontal: nil).count == 2)
    }
    @Test("spacing 透传到每个 GridItem")
    func spacingPropagates() {
        let cols = gridColumns(compact: 2, regular: 6, spacing: 8, horizontal: .regular)
        #expect(cols.count == 6)
        for c in cols {
            #expect(c.spacing == 8)
        }
    }
}
