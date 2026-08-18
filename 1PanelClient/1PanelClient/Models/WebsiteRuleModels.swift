//
//  WebsiteRuleModels.swift
//  1PanelClient
//

import Foundation
import SwiftUI


// MARK: - 网站配置（默认文档 / 流量限制）

/// config 读取请求：默认文档读取带 operate=update + params={}，流量限制仅 scope + websiteId
nonisolated struct WebsiteConfigRequest: Encodable {
    var operate: String? = nil
    let scope: String
    let websiteId: Int
    var params: WebsiteConfigParams? = nil
}

/// config 更新请求：params 为对象（默认文档 index）或数组（流量限制 limit-conn）
nonisolated struct WebsiteConfigUpdateRequest: Encodable {
    let operate: String
    let scope: String
    let websiteId: Int
    let params: WebsiteConfigParams
}

/// params 多态：{"index":"..."} 或 [{"limit_conn":"perserver 300"},...]
nonisolated enum WebsiteConfigParams: Encodable {
    case object([String: String])
    case array([[String: String]])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let dict): try container.encode(dict)
        case .array(let arr):  try container.encode(arr)
        }
    }
}

/// config 读取响应：enable + params 项列表（name 如 index / limit_conn / limit_rate）
nonisolated struct WebsiteConfigResponse: Decodable {
    let enable: Bool?
    let params: [WebsiteConfigItem]?
}

nonisolated struct WebsiteConfigItem: Decodable {
    let name: String?
    let params: [String]?
}

// MARK: - 重定向

/// 重定向列表项（/websites/redirect 返回的 data 元素）
nonisolated struct WebsiteRedirect: Decodable, Identifiable, Hashable {
    let websiteID: Int?
    let name: String?
    let domains: [String]?
    let keepPath: Bool?
    let enable: Bool?
    let type: String?
    let redirect: String?
    let path: String?
    let target: String?
    let filePath: String?
    let content: String?
    let redirectRoot: Bool?

    var id: String { name ?? UUID().uuidString }
    var displayName: String { name ?? "(未命名)" }

    var typeDisplayName: String {
        switch type ?? "" {
        case "domain": return "域名"
        case "path":   return "路径"
        case "404":    return "404"
        default:       return type ?? "—"
        }
    }
}

nonisolated struct WebsiteRedirectListRequest: Encodable {
    let websiteID: Int
}

/// 重定向创建/编辑/删除/启停（operate 决定行为，编辑类操作需携带原记录全量字段）
nonisolated struct WebsiteRedirectUpdateRequest: Encodable {
    var websiteID: Int
    var operate: String      // create / edit / delete / enable / disable
    var enable: Bool = true
    var name: String
    var domains: [String] = []
    var keepPath: Bool = true
    var type: String         // domain / path / 404
    var redirect: String     // 301 / 302
    var path: String = ""
    var target: String = ""
    var filePath: String = ""
    var content: String = ""
    var redirectRoot: Bool = false
}

/// 重定向源文（content）保存请求
nonisolated struct WebsiteRedirectFileRequest: Encodable {
    let name: String
    let websiteID: Int
    let content: String
}

// MARK: - 密码访问

/// 密码访问配置（/websites/auths 返回）
nonisolated struct WebsiteAuthsResponse: Decodable {
    let enable: Bool?
    let items: [WebsiteAuthItem]?
}

nonisolated struct WebsiteAuthItem: Decodable, Identifiable, Hashable {
    let username: String?
    let remark: String?

    var id: String { username ?? UUID().uuidString }
}

nonisolated struct WebsiteAuthsListRequest: Encodable {
    let websiteID: Int
}

/// 密码访问账号操作（operate：create / edit / delete / enable / disable）
nonisolated struct WebsiteAuthsUpdateRequest: Encodable {
    let websiteID: Int
    let operate: String
    var username: String = ""
    var password: String = ""
    var remark: String = ""
    var scope: String = "root"
}

// MARK: - 网站域名列表（重定向创建时选择）

/// /websites/domains/:id 返回元素
nonisolated struct WebsiteDomainItem: Decodable, Identifiable {
    let id: Int?
    let domain: String?
    let port: Int?
}
