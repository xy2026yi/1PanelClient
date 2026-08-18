//
//  WebsiteConfigModels.swift
//  1PanelClient
//

import Foundation
import SwiftUI

// MARK: - 网站基础信息更新

/// 更新网站基础信息（POST /api/v2/websites/update，request.WebsiteUpdate）
/// 接口 schema 仅含这些字段（1Panel v2 swagger）；除主域名/备注外全部按当前详情回填，避免零值覆盖
nonisolated struct WebsiteUpdateRequest: Encodable {
    let id: Int
    var primaryDomain: String
    var remark: String
    let ipv6: Bool
    let expireDate: String
    let favorite: Bool
    let webSiteGroupID: Int

    enum CodingKeys: String, CodingKey {
        case id, primaryDomain, remark, favorite, expireDate
        case ipv6 = "IPV6"
        case webSiteGroupID
    }

    init(from detail: WebsiteFull) {
        self.id = detail.id
        self.primaryDomain = detail.primaryDomain ?? ""
        self.remark = detail.remark ?? ""
        self.ipv6 = detail.ipv6 ?? false
        self.expireDate = detail.expireDate ?? ""
        self.favorite = detail.favorite ?? false
        self.webSiteGroupID = detail.webSiteGroupId ?? 1
    }
}

// MARK: - Nginx 配置

/// Nginx 配置文件（response.WebsiteNginxConfig）
/// 来自 GET /api/v2/websites/:id/config/openresty
nonisolated struct WebsiteNginxConfig: Decodable {
    let path: String?
    let name: String?
    let content: String?
    let size: Int?
    let modTime: String?
}

/// 更新 Nginx 配置请求
nonisolated struct WebsiteNginxUpdateRequest: Encodable {
    let id: Int
    let content: String
}

// MARK: - 网站日志

/// 读取网站日志请求（request.WebsiteLogRead）
/// 复用 /api/v2/files/read 接口
nonisolated struct WebsiteLogReadRequest: Encodable {
    let id: Int
    let type: String          // 固定 "website"
    let name: String          // "access.log" 或 "error.log"
    let page: Int
    let pageSize: Int
    let latest: Bool
}

/// 日志响应（response.FileRead）
nonisolated struct WebsiteLogResponse: Decodable {
    let end: Bool?
    let path: String?
    let total: Int?
    let lines: [String]?
    let totalLines: Int?
}

// MARK: - HTTPS 配置

/// HTTPS 配置读取响应（response.WebsiteHTTPS）
/// 来自 GET /api/v2/websites/:id/https
nonisolated struct WebsiteHTTPS: Decodable {
    let enable: Bool?
    let httpConfig: String?
    let ssl: WebsiteHTTPSSSL?
    let sslProtocol: [String]?
    let algorithm: String?
    let hsts: Bool?
    let hstsIncludeSubDomains: Bool?
    let httpsPort: String?
    let http3: Bool?

    enum CodingKeys: String, CodingKey {
        case enable, httpConfig
        case ssl = "SSL"
        case sslProtocol = "SSLProtocol"
        case algorithm, hsts, hstsIncludeSubDomains
        case httpsPort, http3
    }

    /// 当前证书 ID（SSL.id），没有启用 HTTPS 时为 0
    var currentSSLId: Int { ssl?.id ?? 0 }

    /// httpConfig 显示名
    var httpConfigDisplay: String {
        switch httpConfig ?? "" {
        case "HTTPToHTTPS": return "HTTP 自动跳转 HTTPS"
        case "HTTPOnly":    return "仅 HTTP"
        case "HTTPSOnly":   return "仅 HTTPS"
        default:            return httpConfig ?? "默认"
        }
    }
}

/// HTTPS 响应中嵌入的 SSL 证书（仅需 id 即可）
nonisolated struct WebsiteHTTPSSSL: Decodable {
    let id: Int
    let primaryDomain: String?
}

/// HTTPS 配置更新请求（request.WebsiteHTTPSUpdate）
/// 发送到 POST /api/v2/websites/:id/https
nonisolated struct WebsiteHTTPSUpdateRequest: Encodable {
    var acmeAccountID: Int = 0
    var enable: Bool
    var websiteId: Int
    var websiteSSLId: Int
    var type: String = "existed"
    var importType: String = "paste"
    var privateKey: String = ""
    var certificate: String = ""
    var privateKeyPath: String = ""
    var certificatePath: String = ""
    var httpConfig: String
    var hsts: Bool
    var hstsIncludeSubDomains: Bool
    var algorithm: String
    var sslProtocol: [String]
    var httpsPort: String = ""
    var http3: Bool

    enum CodingKeys: String, CodingKey {
        case acmeAccountID, enable, websiteId, websiteSSLId
        case type, importType, privateKey, certificate
        case privateKeyPath, certificatePath
        case httpConfig, hsts, hstsIncludeSubDomains, algorithm
        case sslProtocol = "SSLProtocol"
        case httpsPort, http3
    }
}

// MARK: - 反向代理路由

/// 反向代理列表请求（request.WebsiteProxyList）
nonisolated struct WebsiteProxiesListRequest: Encodable {
    let id: Int
}

/// 反向代理项（response.WebsiteProxy）
nonisolated struct WebsiteProxy: Decodable, Identifiable, Hashable {
    let name: String?
    let match: String?
    let proxyPass: String?
    let enable: Bool?
    let cache: Bool?
    let cors: Bool?
    let modifier: String?
    let content: String?
    let filePath: String?

    var id: String { name ?? UUID().uuidString }

    var displayName: String { name ?? "(未命名)" }
    var displayMatch: String { match ?? "—" }
    var displayProxyPass: String { proxyPass ?? "—" }
}

/// 反向代理操作类型
enum WebsiteProxyOperate: String {
    case create
    case edit
    case delete
}

/// 反向代理更新请求（request.WebsiteProxyUpdate）
/// 用于创建/编辑/删除（operate 决定行为）
nonisolated struct WebsiteProxyUpdateRequest: Encodable {
    var id: Int
    var operate: String          // create / edit / delete
    var enable: Bool
    var cache: Bool = false
    var cacheTime: Int = 0
    var cacheUnit: String = ""
    var serverCacheTime: Int = 0
    var serverCacheUnit: String = ""
    var name: String
    var modifier: String = ""
    var match: String
    var proxyPass: String
    var proxyHost: String = "$host"
    var content: String = ""
    var filePath: String = ""
    var replaces: [String: String]? = nil
    var sni: Bool = false
    var proxySSLName: String = "$proxy_host"
    var cors: Bool = false
    var allowOrigins: String = ""
    var allowMethods: String = ""
    var allowHeaders: String = ""
    var allowCredentials: Bool = false
    var preflight: Bool = false
    var browserCache: String = "noModify"
    var proxyProtocol: String
    var proxyAddress: String
}

/// 反向代理源文（content）读写请求
nonisolated struct WebsiteProxyFileRequest: Encodable {
    let name: String
    let websiteID: Int
    let content: String
}

/// 反向代理启用/停用请求
/// POST /api/v2/websites/proxies/status  {id, name, status}
nonisolated struct WebsiteProxyStatusRequest: Encodable {
    let id: Int
    let name: String
    let status: String    // "enable" / "disable"
}

