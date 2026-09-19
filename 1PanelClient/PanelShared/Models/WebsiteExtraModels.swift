//
//  WebsiteExtraModels.swift
//  1PanelClient
//
//  网站扩展功能模型（依据 logs/网站修改与增加-1.md 抓包 2026-09-17）：
//  域名设置（SSL 启停/删除）、防盗链、伪静态、真实 IP、跨域访问、负载均衡。
//

import Foundation

// MARK: - 域名设置

/// 域名 SSL 启停请求（POST /websites/domains/update）
nonisolated struct WebsiteDomainSSLRequest: Encodable {
    let id: Int
    let ssl: Bool
}

/// 域名删除请求（POST /websites/domains/del）
nonisolated struct WebsiteDomainDeleteRequest: Encodable {
    let id: Int
}

// MARK: - 防盗链

/// 防盗链配置（POST /websites/leech 响应 / leech/update 请求体）
nonisolated struct WebsiteLeechConfig: Codable {
    var enable: Bool = false
    /// 扩展名（逗号分隔）
    var extends: String = ""
    /// 响应资源（404/400/403）
    var `return`: String = ""
    /// 允许的域名（提交数组；domains 字符串多行为源）
    var serverNames: [String] = []
    /// 浏览器缓存
    var cache: Bool = false
    var cacheTime: Int = 0
    /// 缓存单位（"d"）
    var cacheUint: String = ""
    /// 允许 Referer 为空
    var noneRef: Bool = false
    /// 记录请求日志
    var logEnable: Bool = true
    /// 允许非标准 Referer
    var blocked: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enable = try c.decodeIfPresent(Bool.self, forKey: .enable) ?? false
        extends = try c.decodeIfPresent(String.self, forKey: .extends) ?? ""
        `return` = try c.decodeIfPresent(String.self, forKey: .return) ?? ""
        serverNames = try c.decodeIfPresent([String].self, forKey: .serverNames) ?? []
        cache = try c.decodeIfPresent(Bool.self, forKey: .cache) ?? false
        cacheTime = try c.decodeIfPresent(Int.self, forKey: .cacheTime) ?? 0
        cacheUint = try c.decodeIfPresent(String.self, forKey: .cacheUint) ?? ""
        noneRef = try c.decodeIfPresent(Bool.self, forKey: .noneRef) ?? false
        logEnable = try c.decodeIfPresent(Bool.self, forKey: .logEnable) ?? true
        blocked = try c.decodeIfPresent(Bool.self, forKey: .blocked) ?? false
    }
}

/// 防盗链保存请求（POST /websites/leech/update）
nonisolated struct WebsiteLeechUpdateRequest: Encodable {
    var enable: Bool
    var cache: Bool
    var cacheTime: Int
    var cacheUint: String
    var extends: String
    var `return`: String
    /// 域名多行文本（\n 分隔，与服务端双轨）
    var domains: String
    var noneRef: Bool
    var logEnable: Bool
    var blocked: Bool
    var serverNames: [String]
    var websiteID: Int
}

/// 防盗链查询请求（POST /websites/leech）
nonisolated struct WebsiteLeechReadRequest: Encodable {
    let websiteID: Int
}

// MARK: - 伪静态

/// 伪静态方案切换（POST /websites/rewrite，返回 {content}）
nonisolated struct WebsiteRewriteRequest: Encodable {
    let websiteID: Int
    let name: String
}

nonisolated struct WebsiteRewriteResponse: Decodable {
    let content: String?
}

/// 伪静态保存并重载（POST /websites/rewrite/update）
nonisolated struct WebsiteRewriteUpdateRequest: Encodable {
    let websiteID: Int
    let content: String
    let name: String
}

/// 伪静态另存模版 / 删除模版（POST /websites/rewrite/custom）
nonisolated struct WebsiteRewriteCustomRequest: Encodable {
    let name: String
    /// create / delete（delete 仅传 name）
    let operate: String
    var content: String = ""
}

/// 伪静态内置方案（与 1Panel 网页端一致；current/default 恒在首两位，
/// 自定义模版经 rewrite 查询流程插入两者之间）
enum WebsiteRewritePreset: String, CaseIterable, Identifiable {
    case current = "current"
    case `default` = "default"
    case wordpress, wp2, typecho, typecho2, thinkphp, yii2, laravel5
    case discuz, discuzx, discuzx2, discuzx3
    case eduSoho = "EduSoho"
    case empireCMS = "EmpireCMS"
    case shopWind = "ShopWind"
    case crmeb, dabr, dbshop, dedcms, drupal, ecshop, emlog
    case maccms, mvc, niushop, phpcms, sablog, seacms, shopex, zblog

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .current:  return L10n.t("当前")
        case .default:  return "default"
        default:        return rawValue
        }
    }
}

// MARK: - 真实 IP

/// 真实 IP 配置（GET /websites/realip/config/:id 响应 / realip/config 请求体）
nonisolated struct WebsiteRealIPConfig: Codable {
    var websiteID: Int = 0
    var open: Bool = false
    /// IP 来源（\n 分隔多行）
    var ipFrom: String = ""
    /// X-Real-IP / X-Forwarded-For / CF-Connecting-IP / other
    var ipHeader: String = ""
    /// 选「其他」时的自定义 Header
    var ipOther: String = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        websiteID = try c.decodeIfPresent(Int.self, forKey: .websiteID) ?? 0
        open = try c.decodeIfPresent(Bool.self, forKey: .open) ?? false
        ipFrom = try c.decodeIfPresent(String.self, forKey: .ipFrom) ?? ""
        ipHeader = try c.decodeIfPresent(String.self, forKey: .ipHeader) ?? ""
        ipOther = try c.decodeIfPresent(String.self, forKey: .ipOther) ?? ""
    }
}

// MARK: - 跨域访问

/// 跨域配置（GET /websites/cors/:id 响应 / cors/update 请求体）
nonisolated struct WebsiteCorsConfig: Codable {
    var cors: Bool = false
    var allowOrigins: String = "*"
    var allowMethods: String = "GET,POST,OPTIONS,PUT,DELETE"
    var allowHeaders: String = ""
    var allowCredentials: Bool = false
    var preflight: Bool = true
    var websiteID: Int = 0

    init() {}

    // 服务端可能省略字段（响应不含 websiteID 等），统一宽容解码
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cors = try c.decodeIfPresent(Bool.self, forKey: .cors) ?? false
        allowOrigins = try c.decodeIfPresent(String.self, forKey: .allowOrigins) ?? "*"
        allowMethods = try c.decodeIfPresent(String.self, forKey: .allowMethods) ?? "GET,POST,OPTIONS,PUT,DELETE"
        allowHeaders = try c.decodeIfPresent(String.self, forKey: .allowHeaders) ?? ""
        allowCredentials = try c.decodeIfPresent(Bool.self, forKey: .allowCredentials) ?? false
        preflight = try c.decodeIfPresent(Bool.self, forKey: .preflight) ?? true
        websiteID = try c.decodeIfPresent(Int.self, forKey: .websiteID) ?? 0
    }
}

// MARK: - 负载均衡

/// 负载均衡节点
nonisolated struct WebsiteLbsServer: Codable, Identifiable, Hashable {
    var server: String = ""
    var weight: Int = 0
    var failTimeout: Int = 0
    var failTimeoutUnit: String = "s"
    var maxFails: Int = 0
    var maxConns: Int = 0
    /// down / backup / 空串
    var flag: String = ""
    var id: String { "\(server)#\(weight)#\(flag)#\(maxFails)#\(failTimeout)#\(maxConns)" }
}

/// 负载均衡项（GET /websites/:id/lbs 数组元素）
nonisolated struct WebsiteLbsItem: Decodable, Identifiable, Hashable {
    let name: String?
    /// default / ip_hash / least_conn
    let algorithm: String?
    let servers: [WebsiteLbsServer]?
    let content: String?

    var id: String { name ?? UUID().uuidString }
}

/// 负载均衡创建/更新请求（POST /websites/lbs/create | lbs/update）
nonisolated struct WebsiteLbsSaveRequest: Encodable {
    let websiteID: Int
    let name: String
    let algorithm: String
    let servers: [WebsiteLbsServer]
}

/// 负载均衡源文保存（POST /websites/lbs/file）
nonisolated struct WebsiteLbsFileRequest: Encodable {
    let name: String
    let websiteID: Int
    let content: String
}

/// 负载均衡删除（POST /websites/lbs/del）
nonisolated struct WebsiteLbsDeleteRequest: Encodable {
    let websiteID: Int
    let name: String
}


// MARK: - PHP 运行环境切换（依据 docs/0919-修正1.md 抓包）

/// 运行环境列表查询（POST /runtimes/search {page,pageSize,type:"php"}）
nonisolated struct RuntimeSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let type: String
}

nonisolated struct RuntimeItem: Decodable, Identifiable, Hashable {
    let id: Int?
    let name: String?
    let type: String?
    let version: String?
    let status: String?

    var displayName: String { name ?? "—" }
}

/// 运行环境分页响应（data 直接是分页对象）
nonisolated struct RuntimeSearchResponse: Decodable {
    let total: Int?
    let items: [RuntimeItem]?
}

/// 切换 PHP 版本（POST /websites/php/version；runtimeID 0 = 切回静态网站）
nonisolated struct WebsitePhpVersionRequest: Encodable {
    let websiteID: Int
    let runtimeID: Int
}

/// 防跨站攻击开关（POST /websites/crosssite）
nonisolated struct WebsiteCrosssiteRequest: Encodable {
    let websiteID: Int
    /// Enable / Disable
    let operation: String
}

/// 可关联数据库（GET /websites/databases 数组元素）
nonisolated struct WebsiteDatabaseOption: Decodable, Identifiable, Hashable {
    let name: String?
    let databaseName: String?
    let type: String?
    let from: String?
    let id: Int?

    var displayName: String {
        // name=实例名、databaseName=类型；关联提交 db 用 name
        "\(name ?? "—") (\(databaseName ?? ""))"
    }

    var customID: String { "\(id ?? 0)-\(name ?? "")" }
}

/// 切换关联数据库（POST /websites/databases；不关联传 0/空）
nonisolated struct WebsiteDatabaseSwitchRequest: Encodable {
    let websiteID: Int
    let databaseID: Int
    let databaseType: String
    /// 关联时传数据库实例名（如 "1mysql"=id+name），不关联传 0
    let db: String
}
