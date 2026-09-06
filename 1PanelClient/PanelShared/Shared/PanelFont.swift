//
//  PanelFont.swift
//  1PanelClient
//
//  审计 B2：固定字号收敛——所有历史 `.font(.system(size:))` 统一改走
//  `Font.panelScaled`，经 UIFontMetrics 挂到最近语义 TextStyle，随 Dynamic Type 缩放。
//

import SwiftUI
import UIKit

extension Font {
    /// 固定字号场景的唯一入口：保留原视觉字号（size/weight/design），
    /// 按 UIFontMetrics 就近挂语义档，Dynamic Type 缩放生效且默认视觉不变。
    /// 设计性字号（图表轴标 9pt、欢迎页 80pt 等）同步缩放，属 B2 的预期行为。
    static func panelScaled(
        _ size: CGFloat,
        weight: SwiftUI.Font.Weight? = nil,
        design: SwiftUI.Font.Design? = nil
    ) -> Font {
        // 就近映射语义档：字号区间 → TextStyle（区间边界参考 HIG 排版档位默认值）
        let style: UIFont.TextStyle
        switch size {
        case ..<10.5: style = .caption2      // 9–10：图表轴标/角标
        case ..<12.5: style = .footnote      // 11–12：终端/等宽小字
        case ..<14.5: style = .subheadline   // 13–14：次级强调
        case ..<18.5: style = .body          // 15–17
        case ..<23:   style = .title3
        case ..<31:   style = .title2
        case ..<41:   style = .title1
        default:      style = .largeTitle    // 44+：欢迎页/空态大字
        }
        let uiWeight: UIFont.Weight = weight.map {
            switch $0 {
            case .ultraLight: return .ultraLight
            case .thin:       return .thin
            case .light:      return .light
            case .regular:    return .regular
            case .medium:     return .medium
            case .semibold:   return .semibold
            case .bold:       return .bold
            case .heavy:      return .heavy
            case .black:      return .black
            default:          return .regular
            }
        } ?? .regular
        let base = UIFont.systemFont(ofSize: size, weight: uiWeight)
        if let design {
            let traits: UIFontDescriptor.SymbolicTraits =
                design == .monospaced ? .traitMonoSpace : []
            let desc = base.fontDescriptor.withSymbolicTraits(traits) ?? base.fontDescriptor
            let mono = UIFont(descriptor: desc, size: size)
            let scaled = UIFontMetrics(forTextStyle: style).scaledFont(for: mono)
            return Font(scaled)
        }
        return Font(UIFontMetrics(forTextStyle: style).scaledFont(for: base))
    }
}
