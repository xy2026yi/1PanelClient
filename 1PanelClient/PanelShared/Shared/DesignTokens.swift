//
//  DesignTokens.swift
//  1PanelClient
//
//  语义色 / 圆角 / 间距 设计 token —— 定义与使用规则见 doc/UI设计规范.md
//

import SwiftUI

// MARK: - 语义色（全部映射系统色，自动适配深色模式）

extension Color {
    /// nonisolated：PanelShared 的 Codable 模型（后台解码上下文）也会取状态色
    /// 运行中 / 健康
    nonisolated static let statusRunning = Color.green
    /// 正常停止（不是错误）
    nonisolated static let statusStopped = Color.gray
    /// 故障 / 错误 / 删除
    nonisolated static let statusError = Color.red
    /// 警告（警告三角、重试横幅、到期预警）
    nonisolated static let semanticWarning = Color.orange
    /// 成功提示
    nonisolated static let semanticSuccess = Color.green
}

// MARK: - 圆角三档

enum Radius {
    /// 小元素：二级图标块、小控件
    static let small: CGFloat = 8
    /// IconBadge 默认
    static let medium: CGFloat = 12
    /// 卡片
    static let large: CGFloat = 16
}

// MARK: - 数据类文本等宽（IP、端口、密码、ID、域名、路径）

extension Font {
    /// 数据值等宽：详情页 key-value 行的 value 侧
    static let dataMonospaced = Font.system(.subheadline, design: .monospaced)
    /// 数据值等宽（紧凑行）
    static let dataMonospacedCaption = Font.system(.caption, design: .monospaced)
    /// 数据值等宽（正文行：日志正文、终端回显等）
    static let dataMonospacedBody = Font.system(.body, design: .monospaced)
    /// 数据值等宽（脚注行）
    static let dataMonospacedFootnote = Font.system(.footnote, design: .monospaced)
    /// 数据值等宽（标题行：日志页大标题等，罕用）
    static let dataMonospacedHeadline = Font.system(.headline, design: .monospaced)
    /// 数据值等宽（说明行，罕用）
    static let dataMonospacedCallout = Font.system(.callout, design: .monospaced)
}

// MARK: - 服务端颜色字符串映射

extension Color {
    /// 1Panel 服务端下发的颜色名（数据库系统标识等）映射为系统色
    static func fromDBString(_ name: String) -> Color {
        switch name {
        case "blue":   return .blue
        case "indigo": return .indigo
        case "red":    return .red
        case "purple": return .purple
        case "green":  return .green
        case "orange": return .orange
        default:       return .purple
        }
    }
}
