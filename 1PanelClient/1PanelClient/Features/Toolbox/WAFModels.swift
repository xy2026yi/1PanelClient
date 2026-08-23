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
    /// HTTP 方法白名单（默认规则-HTTP规则，scope=MethodWhite）
    let methodWhite: WAFRuleItem?
    let fileExt: WAFRuleItem?
    let cdn: WAFCdnConfig?
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


// MARK: - 网站设置

/// WAF 网站设置项（/waf/websites/search 返回，含各开关当前状态）
nonisolated struct WAFWebsiteItem: Decodable, Identifiable, Hashable {
    let id: Int
    let primaryDomain: String?
    let alias: String?
    let remark: String?
    /// WAF 总开关 "on"/"off"
    let wafState: String?
    /// 执行策略 "protection"/"observation"
    let wafMode: String?
    /// 检测强度 "on"=严格 / "off"=标准
    let strictState: String?
    /// 频率限制 "on"/"off"
    let ccState: String?
    let configError: Bool?
}

nonisolated struct WAFWebsiteSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let name: String
}

/// 网站级开关/模式切换（scope: Waf / Cc / Strict；mode 仅 Waf scope 携带
/// protection/observation，其余传 nil 省略）
nonisolated struct WAFWebsiteStateRequest: Encodable {
    let websiteID: Int
    let scope: String
    let state: String
    let mode: String?
}

/// 网站级 CC 频率限制规则（开启频率限制的附带请求与参数保存共用）
nonisolated struct WAFWebsiteCCRuleRequest: Encodable {
    let state: String
    let code: Int
    let action: String
    let type: String
    let res: String
    let ipBlock: String
    let ipBlockTime: Int
    let threshold: Int
    let duration: Int
    /// "uri"=URL模式 / "global"=全局模式
    let mode: String
    let websites: [Int]
}

// MARK: - 网站配置详情

/// 网站配置详情请求（/waf/config/website，body {"id": 网站ID}）
nonisolated struct WAFWebsiteConfigRequest: Encodable {
    let id: Int
}

/// 网站配置详情（/waf/config/website 响应）：网站级各规则块当前值。
/// cc 块用于频率限制表单回填真实参数，避免默认值覆盖服务器配置
nonisolated struct WAFWebsiteConfig: Decodable {
    let waf: WAFCore?
    let cc: WAFCcRuleConfig?
    let strict: WAFRuleItem?
}

// MARK: - CDN 真实 IP 获取

/// 全局配置里的 CDN 规则块（config/global 响应 cdn 字段）
nonisolated struct WAFCdnConfig: Decodable {
    let state: String?
    /// 真实 IP 获取方式：header / headers / xff1 / xff2 / xff3
    let type: String?
    /// type=header 时自定义的 Header 名（默认 x-real-ip）
    let header: String?
    let rules: [String]?
}

/// CDN 获取方式更新请求（/waf/cdn/update；rules 为固定 Header 列表回传）
nonisolated struct WAFCdnUpdateRequest: Encodable {
    let rules: [String]
    let state: String
    let type: String
    let header: String
    let websiteID: Int
}
