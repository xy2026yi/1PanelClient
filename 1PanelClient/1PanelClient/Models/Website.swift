//
//  Website.swift
//  1PanelClient
//

import Foundation
import SwiftUI

// MARK: - 网站列表搜索

/// 网站搜索请求（request.WebsiteSearch）
/// 通过 doc/网站功能-1.md 验证字段（注意 websiteGroupId、orderBy、order 默认值）
struct WebsiteSearchRequest: Encodable {
    let name: String
    let page: Int
    let pageSize: Int
    let orderBy: String
    let order: String
    let websiteGroupId: Int
    let type: String
}

/// 网站列表响应（dto.PageResult 包装）
struct WebsiteListResponse: Decodable {
    let total: Int
    let items: [Website]?
}

/// 单个网站（response.WebsiteDTO）
struct Website: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let primaryDomain: String?
    let type: String?
    let alias: String?
    let remark: String?
    let status: String?
    let expireDate: String?
    let protocolStr: String?
    let runtimeName: String?
    let runtimeType: String?
    let appName: String?
    let siteDir: String?
    let webSiteGroupId: Int?
    let createdAt: String?
    let user: String?
    let appType: String?
    let port: Int?
    let proxy: String?
    let proxyAddress: String?
    let ssl: Bool?

    enum CodingKeys: String, CodingKey {
        case id, primaryDomain, type, alias, remark, status, expireDate
        case protocolStr = "protocol"
        case runtimeName, runtimeType, appName, siteDir
        case webSiteGroupId, createdAt, user
        case appType, port, proxy, proxyAddress, ssl
    }

    /// 显示名（优先主域名，其次 alias）
    var displayName: String {
        if let d = primaryDomain, !d.isEmpty { return d }
        return alias ?? "未命名网站"
    }

    /// 类型显示名
    var typeDisplayName: String {
        switch (type ?? "").lowercased() {
        case "deployment": return "一键部署"
        case "proxy":      return "反向代理"
        case "runtime":    return "运行环境"
        case "static":     return "静态网站"
        case "subsite":    return "子网站"
        case "stream":     return "TCP/UDP"
        default:           return type ?? "未知"
        }
    }

    /// 类型对应的 SF Symbol
    var typeIcon: String {
        switch (type ?? "").lowercased() {
        case "deployment": return "square.and.arrow.down"
        case "proxy":      return "arrow.left.arrow.right"
        case "runtime":    return "wrench.and.screwdriver"
        case "static":     return "doc.text"
        case "subsite":    return "rectangle.stack"
        case "stream":     return "network"
        default:           return "globe"
        }
    }

    /// 状态颜色
    var statusColor: Color {
        switch (status ?? "").lowercased() {
        case "running", "normal": return .green
        case "stopped":           return .gray
        case "error", "failed":   return .red
        default:                  return .secondary
        }
    }

    /// 创建时间格式化
    var displayCreatedAt: String {
        guard let t = createdAt, !t.isEmpty else { return "-" }
        return String(t.prefix(19)).replacingOccurrences(of: "T", with: " ")
    }
}

// MARK: - SSL 证书（创建网站时选择用）

/// SSL 搜索请求（request.WebsiteSSLSearch）
struct WebsiteSSLSearchRequest: Encodable {
    let acmeAccountID: String
}

/// SSL 证书（response.WebsiteSSLDTO）
/// 仅声明创建网站列表所需字段，pem/privateKey 等大字段不解析
struct WebsiteSSL: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let primaryDomain: String?
    let domains: String?
    let type: String?
    let provider: String?
    let organization: String?
    let autoRenew: Bool?
    let expireDate: String?
    let startDate: String?
    let status: String?
    let message: String?

    /// 显示名
    var displayName: String {
        primaryDomain ?? "未知证书"
    }

    /// 过期日期格式化
    var displayExpireDate: String {
        guard let t = expireDate, !t.isEmpty else { return "-" }
        return String(t.prefix(10))
    }

    /// 是否已过期
    var isExpired: Bool {
        guard let t = expireDate, !t.isEmpty,
              let date = ISO8601DateFormatter().date(from: t) else {
            return false
        }
        return date < Date()
    }
}

// MARK: - 创建网站

/// 网站类型
enum WebsiteType: String, CaseIterable, Identifiable {
    case deployment = "deployment"
    case proxy = "proxy"
    case staticSite = "static"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deployment: return "一键部署"
        case .proxy:      return "反向代理"
        case .staticSite: return "静态网站"
        }
    }

    var icon: String {
        switch self {
        case .deployment: return "square.and.arrow.down"
        case .proxy:      return "arrow.left.arrow.right"
        case .staticSite: return "folder"
        }
    }

    var description: String {
        switch self {
        case .deployment: return "部署已安装的网站类应用（WordPress 等）"
        case .proxy:      return "将域名反向代理到指定地址"
        case .staticSite: return "提供静态文件托管（HTML/CSS/JS）"
        }
    }
}

/// 已安装应用搜索请求（创建网站时筛选可用应用）
struct WebsiteAppSearchRequest: Encodable {
    let type: String       // "website" / "proxy" 等
    let unused: Bool       // true = 未被其他网站使用
    let all: Bool
    let page: Int
    let pageSize: Int
}

/// 创建网站请求（request.WebsiteCreate）
/// 通过 doc/网站功能-1.md 验证字段
struct WebsiteCreateRequest: Encodable {
    var primaryDomain: String = ""
    var type: String = "deployment"
    var alias: String = ""
    var remark: String = ""
    var appType: String = "installed"
    var appInstallId: Int = 0
    var webSiteGroupId: Int = 1
    var otherDomains: String = ""
    var proxy: String = ""
    var appinstall: WebsiteAppInstallBody = WebsiteAppInstallBody()
    var IPV6: Bool = false
    var enableFtp: Bool = false
    var ftpUser: String = ""
    var ftpPassword: String = ""
    var proxyType: String = "tcp"
    var port: Int = 9000
    var proxyProtocol: String = "http://"
    var proxyAddress: String = ""
    var runtimeType: String = "php"
    var taskID: String = ""
    var createDb: Bool = false
    var dbName: String = ""
    var dbPassword: String = ""
    var dbFormat: String = "utf8mb4"
    var dbUser: String = ""
    var dbType: String = "mysql"
    var dbHost: String = ""
    var enableSSL: Bool = false
    var websiteSSLID: Int = 0
    var acmeAccountID: Int = 0
    var domains: [WebsiteDomainBody] = []
    var siteDir: String = ""
    var streamPorts: String = ""
    var name: String = ""
    var algorithm: String = ""
    var servers: [String] = []
}

/// 创建网站时附属的应用安装信息（保持空对象结构）
struct WebsiteAppInstallBody: Encodable {
    var appId: Int = 0
    var name: String = ""
    var appDetailId: Int = 0
    var params: [String: String] = [:]
    var version: String = ""
    var appkey: String = ""
    var advanced: Bool = false
    var cpuQuota: Int = 0
    var memoryLimit: Int = 0
    var memoryUnit: String = "MB"
    var containerName: String = ""
    var allowPort: Bool = false
    var format: String = "utf8mb4"
    var collation: String = ""
}

/// 创建网站时的域名条目
struct WebsiteDomainBody: Encodable {
    var domain: String
    var host: String
    var port: Int
    var ssl: Bool
}

/// 创建前检查的空请求体
struct WebsiteCheckRequest: Encodable {}

// MARK: - 删除网站

/// 删除网站请求（request.WebsiteDel）
/// 通过 doc/网站管理-1.md 验证字段
struct WebsiteDeleteRequest: Encodable {
    let id: Int
    var deleteApp: Bool = false
    var deleteBackup: Bool = false
    var forceDelete: Bool = false
    var deleteDB: Bool = false
}

// MARK: - 网站详情（完整）

/// 网站详情（response.WebsiteDTO 完整版）
/// 来自 GET /api/v2/websites/:id
struct WebsiteFull: Decodable {
    let id: Int
    let createdAt: String?
    let updatedAt: String?
    let protocolStr: String?
    let primaryDomain: String?
    let type: String?
    let alias: String?
    let remark: String?
    let status: String?
    let httpConfig: String?
    let expireDate: String?
    let proxy: String?
    let proxyType: String?
    let errorLog: Bool?
    let accessLog: Bool?
    let defaultServer: Bool?
    let ipv6: Bool?
    let rewrite: String?
    let webSiteGroupId: Int?
    let webSiteSSLId: Int?
    let runtimeID: Int?
    let appInstallId: Int?
    let ftpId: Int?
    let parentWebsiteID: Int?
    let user: String?
    let group: String?
    let dbType: String?
    let dbID: Int?
    let favorite: Bool?
    let streamPorts: String?
    let domains: [WebsiteFullDomain]?
    let errorLogPath: String?
    let accessLogPath: String?
    let sitePath: String?
    let appName: String?
    let runtimeName: String?
    let runtimeType: String?
    let siteDir: String?
    let openBaseDir: Bool?
    let algorithm: String?
    let servers: [String]?

    enum CodingKeys: String, CodingKey {
        case id, createdAt, updatedAt
        case protocolStr = "protocol"
        case primaryDomain, type, alias, remark, status, httpConfig, expireDate
        case proxy, proxyType, errorLog, accessLog, defaultServer
        case ipv6 = "IPV6"
        case rewrite, webSiteGroupId, webSiteSSLId
        case runtimeID, appInstallId, ftpId, parentWebsiteID
        case user, group, dbType, dbID, favorite, streamPorts, domains
        case errorLogPath, accessLogPath, sitePath
        case appName, runtimeName, runtimeType, siteDir, openBaseDir, algorithm, servers
    }
}

/// 网站域名（详情中的 domains 数组元素）
struct WebsiteFullDomain: Decodable, Hashable {
    let id: Int?
    let domain: String?
    let ssl: Bool?
    let port: Int?
}

// MARK: - Nginx 配置

/// Nginx 配置文件（response.WebsiteNginxConfig）
/// 来自 GET /api/v2/websites/:id/config/openresty
struct WebsiteNginxConfig: Decodable {
    let path: String?
    let name: String?
    let content: String?
    let size: Int?
    let modTime: String?
}

/// 更新 Nginx 配置请求
struct WebsiteNginxUpdateRequest: Encodable {
    let id: Int
    let content: String
}

// MARK: - 网站日志

/// 读取网站日志请求（request.WebsiteLogRead）
/// 复用 /api/v2/files/read 接口
struct WebsiteLogReadRequest: Encodable {
    let id: Int
    let type: String          // 固定 "website"
    let name: String          // "access.log" 或 "error.log"
    let page: Int
    let pageSize: Int
    let latest: Bool
}

/// 日志响应（response.FileRead）
struct WebsiteLogResponse: Decodable {
    let end: Bool?
    let path: String?
    let total: Int?
    let lines: [String]?
    let totalLines: Int?
}

// MARK: - HTTPS 配置

/// HTTPS 配置读取响应（response.WebsiteHTTPS）
/// 来自 GET /api/v2/websites/:id/https
struct WebsiteHTTPS: Decodable {
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
struct WebsiteHTTPSSSL: Decodable {
    let id: Int
    let primaryDomain: String?
}

/// HTTPS 配置更新请求（request.WebsiteHTTPSUpdate）
/// 发送到 POST /api/v2/websites/:id/https
struct WebsiteHTTPSUpdateRequest: Encodable {
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
struct WebsiteProxiesListRequest: Encodable {
    let id: Int
}

/// 反向代理项（response.WebsiteProxy）
struct WebsiteProxy: Decodable, Identifiable, Hashable {
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
struct WebsiteProxyUpdateRequest: Encodable {
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
struct WebsiteProxyFileRequest: Encodable {
    let name: String
    let websiteID: Int
    let content: String
}

/// 反向代理启用/停用请求
/// POST /api/v2/websites/proxies/status  {id, name, status}
struct WebsiteProxyStatusRequest: Encodable {
    let id: Int
    let name: String
    let status: String    // "enable" / "disable"
}

// MARK: - SSL 证书（独立管理）

/// SSL 证书列表搜索请求
/// POST /api/v2/websites/ssl/search
struct WebsiteSSLListRequest: Encodable {
    var page: Int = 1
    var pageSize: Int = 20
    var domain: String = ""
    var orderBy: String = "expire_date"
    var order: String = "ascending"
}

/// SSL 证书列表响应
struct WebsiteSSLListResponse: Decodable {
    let total: Int
    let items: [WebsiteSSLCert]?
}

/// 完整的 SSL 证书（response.WebsiteSSLDTO）
/// 供列表 / 详情共用；pem/privateKey 在详情页才会请求并展示
struct WebsiteSSLCert: Codable, Identifiable, Hashable {
    var id: Int
    var createdAt: String?
    var updatedAt: String?
    var primaryDomain: String?
    var privateKey: String?
    var pem: String?
    var domains: String?
    var certURL: String?
    var type: String?
    var provider: String?
    var organization: String?
    var autoRenew: Bool?
    var expireDate: String?
    var startDate: String?
    var status: String?
    var message: String?
    var description: String?
    var logPath: String?
    var acmeAccountId: Int?
    var dnsAccountId: Int?
    var keyType: String?
    var pushDir: Bool?
    var dir: String?
    var disableCNAME: Bool?
    var skipDNS: Bool?
    var nameserver1: String?
    var nameserver2: String?
    var execShell: Bool?
    var shell: String?
    var otherDomains: String?
    var acmeAccount: AcmeAccount?
    var dnsAccount: DNSAccount?

    /// 显示名（主域名）
    var displayName: String { primaryDomain ?? "未知证书" }

    /// 子域名集合
    var displayDomains: String { domains ?? "—" }

    /// 颁发机构（organization 优先，回退 provider）
    var displayOrganization: String {
        let org = organization ?? ""
        return org.isEmpty ? (provider ?? "—") : org
    }

    /// 证书类型描述
    var displayType: String {
        let t = type ?? ""
        return t.isEmpty ? "—" : t
    }

    /// 是否手动导入
    var isManual: Bool { (provider ?? "").lowercased() == "manual" }

    /// 申请方式显示名
    var providerDisplay: String {
        switch (provider ?? "").lowercased() {
        case "manual":     return "手动创建"
        case "dnsaccount": return "DNS 账号"
        case "dnsmanual":  return "手动解析"
        case "http":       return "HTTP"
        case "selfsigned": return "自签证书"
        default:           return provider ?? "—"
        }
    }

    /// 过期日期格式化（yyyy-MM-dd）
    var displayExpireDate: String {
        formatDate(expireDate)
    }

    /// 开始日期格式化
    var displayStartDate: String {
        formatDate(startDate)
    }

    /// 创建时间格式化
    var displayCreatedAt: String {
        formatDate(createdAt)
    }

    /// 是否已过期
    var isExpired: Bool {
        if (status ?? "").lowercased() == "applyerror" { return true }
        guard let t = expireDate, !t.isEmpty,
              let date = parseISODate(t) else {
            return false
        }
        return date < Date()
    }

    /// 剩余天数（负数表示已过期）
    var daysRemaining: Int {
        guard let t = expireDate, !t.isEmpty,
              let date = parseISODate(t) else {
            return Int.max
        }
        return Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
    }

    /// 状态颜色
    var statusColor: Color {
        if (status ?? "").lowercased() == "applyerror" { return .red }
        if isExpired { return .red }
        if daysRemaining <= 14 { return .orange }
        return .green
    }

    /// 状态描述
    var statusDisplay: String {
        if (status ?? "").lowercased() == "applyerror" { return "申请失败" }
        if isExpired { return "已过期" }
        if daysRemaining <= 0 { return "今天过期" }
        if daysRemaining <= 14 { return "即将过期" }
        return "有效"
    }

    private func parseISODate(_ str: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: str) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: str)
    }

    private func formatDate(_ str: String?) -> String {
        guard let s = str, !s.isEmpty else { return "—" }
        if let date = parseISODate(s) {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            return df.string(from: date)
        }
        return String(s.prefix(10))
    }
}

/// 上传 SSL 证书请求
/// POST /api/v2/websites/ssl/upload
/// - type="paste": 粘贴 privateKey + certificate
/// - type="local": 服务器文件路径 privateKeyPath + certificatePath
struct WebsiteSSLUploadRequest: Encodable {
    var privateKey: String = ""
    var certificate: String = ""
    var privateKeyPath: String = ""
    var certificatePath: String = ""
    var type: String = "paste"      // paste / local
    var sslID: Int = 0
    var description: String = ""
}

/// 删除 SSL 证书请求
/// POST /api/v2/websites/ssl/del
struct WebsiteSSLDeleteRequest: Encodable {
    let ids: [Int]
}

/// 下载 SSL 证书请求
/// POST /api/v2/websites/ssl/download
struct WebsiteSSLDownloadRequest: Encodable {
    let id: Int
}

// MARK: - ACME 账户

/// Acme 账户搜索请求
struct AcmeSearchRequest: Encodable {
    var page: Int = 1
    var pageSize: Int = 20
}

/// Acme 账户列表项（response.WebsiteAcmeDTO）
struct AcmeAccount: Codable, Identifiable, Hashable {
    let id: Int
    let createdAt: String?
    let updatedAt: String?
    var email: String = ""
    var url: String?
    var type: String = "letsencrypt"
    var eabKid: String = ""
    var eabHmacKey: String = ""
    var keyType: String = "EC256"
    var useProxy: Bool = false
    var caDirURL: String = ""
    var useEAB: Bool = false
}

/// 创建/更新 Acme 账户请求
struct AcmeCreateRequest: Codable {
    var email: String
    var type: String
    var eabKid: String
    var eabHmacKey: String
    var keyType: String
    var useProxy: Bool
    var caDirURL: String
    var useEAB: Bool
}

/// Acme 账户类型
enum AcmeType: String, CaseIterable, Identifiable {
    case letsencrypt = "letsencrypt"
    case zerossl = "zerossl"
    case buypass = "buypass"
    case googlecloud = "googlecloud"
    case custom = "custom"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .letsencrypt: return "Let's Encrypt"
        case .zerossl:     return "ZeroSSL"
        case .buypass:     return "Buypass"
        case .googlecloud: return "Google Cloud"
        case .custom:      return "自定义 ACME 服务"
        }
    }
}

/// 密钥算法
enum SSLKeyType: String, CaseIterable, Identifiable {
    case EC256 = "EC256"
    case EC384 = "EC384"
    case RSA2048 = "RSA2048"
    case RSA3072 = "RSA3072"
    case RSA4096 = "RSA4096"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .EC256:  return "EC 256"
        case .EC384:  return "EC 384"
        case .RSA2048: return "RSA 2048"
        case .RSA3072: return "RSA 3072"
        case .RSA4096: return "RSA 4096"
        }
    }
}

// MARK: - DNS 账户

/// DNS 账户搜索请求
struct DnsSearchRequest: Encodable {
    var page: Int = 1
    var pageSize: Int = 20
}

/// DNS 账户列表项（response.WebsiteDNSDTO）
struct DNSAccount: Codable, Identifiable, Hashable {
    let id: Int
    let createdAt: String?
    let updatedAt: String?
    var name: String = ""
    var type: String = "AliYun"
    var authorization: DNSAuth?
}

/// DNS 账户的授权信息（灵活键值对）
struct DNSAuth: Codable, Hashable {
    var accessKey: String?
    var secretKey: String?
    var apiKey: String?
    var apiUser: String?
    var secretID: String?
    var region: String?
    var email: String?
    var clientID: String?
    var password: String?

    /// 构造 authorization 字典（仅包含非空字段）
    func encodeToDict() -> [String: String] {
        var dict: [String: String] = [:]
        if let v = accessKey, !v.isEmpty { dict["accessKey"] = v }
        if let v = secretKey, !v.isEmpty { dict["secretKey"] = v }
        if let v = apiKey, !v.isEmpty { dict["apiKey"] = v }
        if let v = apiUser, !v.isEmpty { dict["apiUser"] = v }
        if let v = secretID, !v.isEmpty { dict["secretID"] = v }
        if let v = region, !v.isEmpty { dict["region"] = v }
        if let v = email, !v.isEmpty { dict["email"] = v }
        if let v = clientID, !v.isEmpty { dict["clientID"] = v }
        if let v = password, !v.isEmpty { dict["password"] = v }
        return dict
    }
}

/// DNS 服务商类型
enum DnsType: String, CaseIterable, Identifiable {
    case AliYun = "AliYun"
    case CloudFlare = "CloudFlare"
    case TencentCloud = "TencentCloud"
    case HuaweiCloud = "HuaweiCloud"
    case CloudDns = "CloudDns"
    case NameSilo = "NameSilo"
    case NameCheap = "NameCheap"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .AliYun:       return "阿里云"
        case .CloudFlare:   return "Cloudflare"
        case .TencentCloud: return "腾讯云"
        case .HuaweiCloud:  return "华为云"
        case .CloudDns:     return "CloudDNS"
        case .NameSilo:     return "NameSilo"
        case .NameCheap:    return "NameCheap"
        }
    }
}

// MARK: - 申请证书

/// SSL 证书验证方式
enum SSLProvider: String, CaseIterable, Identifiable {
    case dnsAccount = "dnsAccount"
    case dnsManual = "dnsManual"
    case http = "http"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .dnsAccount: return "DNS 账户"
        case .dnsManual:  return "手动解析"
        case .http:       return "HTTP"
        }
    }
}

/// 申请证书请求（request.WebsiteSSLCreate）
struct WebsiteSSLCreateRequest: Codable {
    var id: Int = 0
    var primaryDomain: String = ""
    var otherDomains: String = ""
    var provider: String = "dnsAccount"
    var websiteId: Int = 0
    var acmeAccountId: Int = 0
    var dnsAccountId: Int = 0
    var autoRenew: Bool = true
    var keyType: String = "EC256"
    var pushDir: Bool = false
    var dir: String = ""
    var description: String = ""
    var message: String = ""
    var disableCNAME: Bool = false
    var skipDNS: Bool = false
    var nameserver1: String = ""
    var nameserver2: String = ""
    var execShell: Bool = false
    var shell: String = ""
    var pushNode: Bool = false
    var pushNodes: [Int] = []
    var nodes: String = ""
    var isIP: Bool = false
}

/// 重新申请证书请求
struct WebsiteSSLObtainRequest: Encodable {
    let id: Int
}

/// SSL 日志读取请求
struct WebsiteSSLLogRequest: Encodable {
    let id: Int
    let type: String = "ssl"
    let page: Int
    let pageSize: Int
    let latest: Bool
}

/// SSL 日志响应（response.FileRead）
struct WebsiteSSLLogResponse: Decodable {
    let end: Bool?
    let path: String?
    let total: Int?
    let lines: [String]?
    let totalLines: Int?
    let taskStatus: String?
}

// MARK: - 自签证书（CA 机构）

/// 自签证书机构
struct CertificateAuthority: Codable, Identifiable, Hashable {
    let id: Int
    let createdAt: String?
    let updatedAt: String?
    var name: String = ""
    var keyType: String = "EC256"
    var csr: String?
    var privateKey: String?
    var commonName: String?
    var country: String?
    var organization: String?
    var organizationUint: String?
    var province: String?
    var city: String?
}

struct CASearchRequest: Encodable {
    var page: Int = 1
    var pageSize: Int = 20
}

struct CACreateRequest: Encodable {
    var name: String
    var keyType: String
    var commonName: String
    var country: String
    var organization: String
    var organizationUint: String
    var province: String
    var city: String
}

struct CAObtainRequest: Encodable {
    var keyType: String
    var domains: String
    var id: Int
    var time: Int
    var unit: String
    var pushDir: Bool
    var dir: String
    var autoRenew: Bool
    var description: String
    var execShell: Bool
    var shell: String
}
