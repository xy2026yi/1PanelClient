//
//  Website.swift
//  1PanelClient
//

import Foundation

/// 网站搜索请求
struct WebsiteSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let name: String
    let websiteGroupID: Int?
    let orderBy: String
    let order: String

    enum CodingKeys: String, CodingKey {
        case page, pageSize, name
        case websiteGroupID = "websiteGroupId"
        case orderBy, order
    }
}

/// 网站列表响应
struct WebsiteListResponse: Decodable {
    let total: Int
    let items: [Website]?
}

/// 单个网站（基于 response.WebsiteDTO）
struct Website: Decodable, Identifiable {
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

    enum CodingKeys: String, CodingKey {
        case id, primaryDomain, type, alias, remark, status, expireDate
        case protocolStr = "protocol"
        case runtimeName, runtimeType, appName, siteDir
        case webSiteGroupId, createdAt, user
    }

    var displayName: String { primaryDomain ?? alias ?? "未知" }
}
