//
//  MetricFormatters.swift
//  1PanelClient
//
//  指标数值/字节的共享格式化：首页状态卡与服务器行的环下详情同源，
//  避免两处各自实现后逐渐漂移。
//

import Foundation

enum MetricFormat {
    /// 数值保留两位小数（nil 按 0 处理）
    static func f2(_ v: Double?) -> String {
        String(format: "%.2f", v ?? 0)
    }

    /// 字节数拆为 (数值, 单位)，自适应 GB/MB/KB/B
    static func byteParts(_ bytes: Int64?) -> (value: String, unit: String) {
        let b = bytes ?? 0
        if b >= 1024 * 1024 * 1024 {
            return (String(format: "%.2f", Double(b) / 1_073_741_824), "GB")
        }
        if b >= 1024 * 1024 {
            return (String(format: "%.2f", Double(b) / 1_048_576), "MB")
        }
        if b >= 1024 {
            return (String(format: "%.1f", Double(b) / 1024), "KB")
        }
        return ("\(b)", "B")
    }

    /// 已用/总量：同单位时单位只出现一次（6.83 / 58.90 GB），
    /// 跨单位时各自标注（1.02 MB / 3.86 GB）
    static func usedOverTotal(_ used: Int64?, _ total: Int64?) -> String {
        let u = byteParts(used)
        let t = byteParts(total)
        if u.unit == t.unit {
            return "\(u.value) / \(t.value) \(t.unit)"
        }
        return "\(u.value) \(u.unit) / \(t.value) \(t.unit)"
    }
}
