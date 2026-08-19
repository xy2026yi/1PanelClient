//
//  SecurityGate.swift
//  1PanelClient
//
//  连接安全策略：设置页「仅允许 HTTPS」开启后，网络层统一拦截 HTTP 明文请求，
//  作为保存/测试入口校验之外的兜底（Info.plist 因需支持自托管面板的 http://
//  地址保留了 NSAllowsArbitraryLoads，由此在应用层收口）
//

import Foundation

enum SecurityGate {
    static let httpsOnlyKey = "security.httpsOnly"

    static var httpsOnly: Bool {
        UserDefaults.standard.bool(forKey: httpsOnlyKey)
    }

    /// 请求发出前校验：HTTP 明文地址在「仅允许 HTTPS」模式下直接拒绝
    static func check(_ server: ServerConfig) throws {
        guard httpsOnly, server.isPlainHTTP else { return }
        throw APIError.businessError(
            -1,
            L10n.t("已开启「仅允许 HTTPS 连接」：该服务器为 http:// 明文地址，请在 设置 → 安全 关闭该限制，或改用 https:// 地址")
        )
    }
}
