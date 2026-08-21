//
//  WAFModels.swift
//  1PanelClient
//

import SwiftUI
import Combine

// MARK: - 数据模型

nonisolated struct WAFStatus: Decodable {
    let healthy: Bool
    let openrestyVersion: String?
    let open: Bool
}

nonisolated struct WAFConfig: Decodable {
    let waf: WAFCore?
    let ipWhite: WAFRuleItem?
    let ipBlack: WAFRuleItem?
    let urlWhite: WAFRuleItem?
    let urlBlack: WAFRuleItem?
    let uaWhite: WAFRuleItem?
    let uaBlack: WAFRuleItem?
    let xss: WAFRuleItem?
    let sql: WAFRuleItem?
    let cc: WAFCcRuleConfig?
    let attackCount: WAFCcRuleConfig?
    let notFoundCount: WAFCcRuleConfig?
    let args: WAFRuleItem?
    let cookie: WAFRuleItem?
    let header: WAFRuleItem?
    let fileExt: WAFRuleItem?
    let vuln: WAFRuleItem?
    let strict: WAFRuleItem?
    let allowSpider: WAFRuleItem?
    let defaultIpBlack: WAFRuleItem?
    let defaultUaBlack: WAFRuleItem?
    let defaultUrlBlack: WAFRuleItem?
    let unknownWebsite: WAFRuleItem?
}

nonisolated struct WAFCore: Decodable {
    let state: String?
    let mode: String?
}

nonisolated struct WAFRuleItem: Decodable {
    let state: String?
    let code: Int?
    let action: String?
    let type: String?
    let rules: [String]?

    var isOn: Bool { state == "on" }
}

nonisolated struct WAFGlobalStateRequest: Encodable {
    let scope: String
    let state: String
}

// MARK: 蜘蛛放行范围

nonisolated struct WAFSpiderSaveRequest: Encodable {
    let rules: [String]
}

// MARK: IP 规则

nonisolated struct WAFRuleIPSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let type: String
}

nonisolated struct WAFRuleIPItem: Decodable, Identifiable, Hashable {
    let name: String
    let state: String
    let type: String       // ipv4 / ipArr / ipv6 / ipGroup
    let ipv4: String?
    let ipv6: String?
    let ipStart: String?
    let ipEnd: String?
    let ipGroup: String?
    let description: String?

    var id: String { name }

    var displayValue: String {
        switch type {
        case "ipv4": return ipv4 ?? ""
        case "ipArr": return "\(ipStart ?? "") - \(ipEnd ?? "")"
        case "ipv6": return ipv6 ?? ""
        case "ipGroup": return ipGroup ?? ""
        default: return ""
        }
    }

    var typeLabel: String {
        switch type {
        case "ipv4": return "IPv4"
        case "ipArr": return L10n.t("IPv4范围")
        case "ipv6": return "IPv6"
        case "ipGroup": return L10n.t("IP组")
        default: return type
        }
    }
}

nonisolated struct WAFRuleIPCreateRequest: Encodable {
    let name: String
    let type: String
    let ipv4: String
    let ipStart: String
    let ipEnd: String
    let ipv6: String
    let state: String
    let description: String
    let scope: String
    let ipGroup: String
}

nonisolated struct WAFRuleIPUpdateRequest: Encodable {
    let name: String
    let state: String
    let type: String
    let ipv4: String
    let ipv6: String
    let ipStart: String
    let ipEnd: String
    let ipGroup: String
    let description: String
    let scope: String
}

nonisolated struct WAFRuleIPDeleteRequest: Encodable {
    let name: String
    let scope: String
}

// MARK: IP 组

nonisolated struct WAFIPGroupSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let type: String
    let name: String
    let all: Bool
}

nonisolated struct WAFIPGroupItem: Decodable, Identifiable, Hashable {
    let name: String
    let content: String?
    let source: String?
    let remoteURL: String?

    var id: String { name }
}

nonisolated struct WAFIPGroupCreateRequest: Encodable {
    let name: String
    let content: String
    let source: String
    let remoteURL: String
}

nonisolated struct WAFIPGroupDeleteRequest: Encodable {
    let name: String
}

// MARK: - 通用规则 (URL / UA)

nonisolated struct WAFCommonRuleSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let scope: String
    let websiteID: Int
}

nonisolated struct WAFCommonRuleItem: Decodable, Identifiable, Hashable {
    let name: String
    let state: String
    let rule: String
    let type: String?
    let description: String?

    var id: String { name }
}

nonisolated struct WAFCommonRuleCreateRequest: Encodable {
    let name: String
    let state: String
    let description: String
    let scope: String
    let rule: String
    let websiteID: Int
}

nonisolated struct WAFCommonRuleUpdateRequest: Encodable {
    let name: String
    let state: String
    let rule: String
    let type: String
    let description: String
    let scope: String
    let websiteID: Int
}

nonisolated struct WAFCommonRuleDeleteRequest: Encodable {
    let name: String
    let scope: String
    let websiteID: Int
}

// MARK: - CC / 频率限制配置

nonisolated struct WAFCcRuleConfig: Decodable {
    let state: String?
    let code: Int?
    let action: String?
    let type: String?
    let duration: Int?
    let threshold: Int?
    let ipBlockTime: Int?
    let mode: String?
    let ipBlock: String?

    var isOn: Bool { state == "on" }
}

nonisolated struct WAFCcRuleSaveRequest: Encodable {
    let state: String
    let code: Int
    let action: String
    let type: String
    let res: String
    let ipBlock: String
    let ipBlockTime: Int
    let threshold: Int
    let duration: Int
    let mode: String
    let scope: String
    let applyWebsite: Bool?

    enum CodingKeys: String, CodingKey {
        case state, code, action, type, res, ipBlock, ipBlockTime, threshold, duration, mode, scope, applyWebsite
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        try c.encode(code, forKey: .code)
        try c.encode(action, forKey: .action)
        try c.encode(type, forKey: .type)
        try c.encode(res, forKey: .res)
        try c.encode(ipBlock, forKey: .ipBlock)
        try c.encode(ipBlockTime, forKey: .ipBlockTime)
        try c.encode(threshold, forKey: .threshold)
        try c.encode(duration, forKey: .duration)
        try c.encode(mode, forKey: .mode)
        try c.encode(scope, forKey: .scope)
        try c.encodeIfPresent(applyWebsite, forKey: .applyWebsite)
    }
}

nonisolated struct WAFLocationUpdateRequest: Encodable {
    let type: String
}

