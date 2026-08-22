//
//  Haptic.swift
//  1PanelClient
//
//  触觉反馈轻封装 —— 埋点规则见 doc/UI设计规范.md 第六节：
//  危险操作确认执行=warning、操作成功/失败=success/warning、Tab 切换与选择器=selection。
//

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
