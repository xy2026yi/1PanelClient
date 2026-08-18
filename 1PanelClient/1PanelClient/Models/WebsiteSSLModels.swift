//
//  WebsiteSSLModels.swift
//  1PanelClient
//

import Foundation
import SwiftUI

// MARK: - SSL 证书（独立管理）

/// SSL 证书列表搜索请求
/// POST /api/v2/websites/ssl/search
nonisolated struct WebsiteSSLListRequest: Encodable {
    var page: Int = 1
    var pageSize: Int = 20
    var domain: String = ""
    var orderBy: String = "expire_date"
    var order: String = "ascending"
}

/// SSL 证书列表响应
nonisolated struct WebsiteSSLListResponse: Decodable {
    let total: Int
    let items: [WebsiteSSLCert]?
}

/// 完整的 SSL 证书（response.WebsiteSSLDTO）
/// 供列表 / 详情共用；pem/privateKey 在详情页才会请求并展示
nonisolated struct WebsiteSSLCert: Codable, Identifiable, Hashable {
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
nonisolated struct WebsiteSSLUploadRequest: Encodable {
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
nonisolated struct WebsiteSSLDeleteRequest: Encodable {
    let ids: [Int]
}

/// 下载 SSL 证书请求
/// POST /api/v2/websites/ssl/download
nonisolated struct WebsiteSSLDownloadRequest: Encodable {
    let id: Int
}

// MARK: - ACME 账户

/// Acme 账户搜索请求
nonisolated struct AcmeSearchRequest: Encodable {
    var page: Int = 1
    var pageSize: Int = 20
}

/// Acme 账户列表项（response.WebsiteAcmeDTO）
nonisolated struct AcmeAccount: Codable, Identifiable, Hashable {
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
nonisolated struct AcmeCreateRequest: Codable {
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
nonisolated struct DnsSearchRequest: Encodable {
    var page: Int = 1
    var pageSize: Int = 20
}

/// DNS 账户列表项（response.WebsiteDNSDTO）
nonisolated struct DNSAccount: Codable, Identifiable, Hashable {
    let id: Int
    let createdAt: String?
    let updatedAt: String?
    var name: String = ""
    var type: String = "AliYun"
    var authorization: DNSAuth?
}

/// DNS 账户的授权信息（灵活键值对）
nonisolated struct DNSAuth: Codable, Hashable {
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
nonisolated struct WebsiteSSLCreateRequest: Codable {
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
nonisolated struct WebsiteSSLObtainRequest: Encodable {
    let id: Int
}

/// SSL 日志读取请求
nonisolated struct WebsiteSSLLogRequest: Encodable {
    let id: Int
    let type: String = "ssl"
    let page: Int
    let pageSize: Int
    let latest: Bool
}

/// SSL 日志响应（response.FileRead）
nonisolated struct WebsiteSSLLogResponse: Decodable {
    let end: Bool?
    let path: String?
    let total: Int?
    let lines: [String]?
    let totalLines: Int?
    let taskStatus: String?
}

// MARK: - 自签证书（CA 机构）

/// 自签证书机构
nonisolated struct CertificateAuthority: Codable, Identifiable, Hashable {
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

nonisolated struct CASearchRequest: Encodable {
    var page: Int = 1
    var pageSize: Int = 20
}

nonisolated struct CACreateRequest: Encodable {
    var name: String
    var keyType: String
    var commonName: String
    var country: String
    var organization: String
    var organizationUint: String
    var province: String
    var city: String
}

nonisolated struct CAObtainRequest: Encodable {
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
