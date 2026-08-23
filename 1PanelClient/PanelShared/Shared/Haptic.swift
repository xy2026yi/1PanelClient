//
//  Haptic.swift
//  1PanelClient
//
//  触觉反馈轻封装 —— 埋点规则见 doc/UI设计规范.md 第六节：
//  危险操作确认执行=warning、操作成功/失败=success/warning、Tab 切换与选择器=selection。
//

import SwiftUI
import UIKit

enum Haptic {
    /// Tab 切换 / 选择器选中
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// 操作成功（成功 Toast 伴随）
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// 危险操作确认执行（删除/卸载/重启等 R1 场景）
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// 操作失败（失败提示伴随）
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

// MARK: - 动画时长 token

/// 全 App 动画只分两档：微交互反馈用 fast，面板/内容展开用 standard。
/// 散点时长（0.12/0.18/0.22/0.3/0.4 等）已全部收敛到这两档，新增动画勿再写裸时长。
enum Motion {
    /// 快：菜单开合、按压回弹、Toast（0.15s easeOut）
    static let fast = Animation.easeOut(duration: 0.15)
    /// 中：图表填充、面板展开、键盘跟随（0.25s easeInOut）
    static let standard = Animation.easeInOut(duration: 0.25)
}
