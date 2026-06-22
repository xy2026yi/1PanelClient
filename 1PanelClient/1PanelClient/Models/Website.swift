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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deployment: return "一键部署"
        case .proxy:      return "反向代理"
        }
    }

    var icon: String {
        switch self {
        case .deployment: return "square.and.arrow.down"
        case .proxy:      return "arrow.left.arrow.right"
        }
    }

    var description: String {
        switch self {
        case .deployment: return "部署已安装的网站类应用（WordPress 等）"
        case .proxy:      return "将域名反向代理到指定地址"
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
