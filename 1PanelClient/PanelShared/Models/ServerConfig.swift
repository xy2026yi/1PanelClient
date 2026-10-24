//
//  ServerConfig.swift
//  1PanelClient
//

import Foundation

nonisolated struct ServerConfig: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var baseURL: String
    var apiKey: String
    /// 安全入口码（明文，如 "3f89948beb"）：引导流请求头 EntranceCode 用；
    /// 未设安全入口的面板为 nil。面板账号/密码只在引导弹窗内经 @State 短暂存在，
    /// 不进本模型（用完即弃，方案 §3.3）。Codable 合成 decode 为 decodeIfPresent，
    /// 老配置缺省零迁移
    var entranceCode: String?

    init(id: UUID = UUID(), name: String, baseURL: String, apiKey: String,
         entranceCode: String? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.entranceCode = entranceCode
    }

    var normalizedBaseURL: String {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    /// 是否为 HTTP 明文连接（无 TLS，API Key 与数据可被链路窃听）
    var isPlainHTTP: Bool {
        URLComponents(string: normalizedBaseURL)?.scheme?.lowercased() == "http"
    }
}
