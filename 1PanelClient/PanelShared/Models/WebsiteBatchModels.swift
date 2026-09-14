//
//  WebsiteBatchModels.swift
//  1PanelClient
//
//  网站批量操作模型（logs/网站批量抓包 2026-09-14）：
//  批量启停/删除（任务进度）· 批量分组 · 批量设置证书（已有证书）
//

import Foundation

/// POST /websites/batch/operate {operate,ids,taskID}
/// operate：start / stop / delete（delete 与启停共用端点，抓包确认）
nonisolated struct WebsiteBatchOperateRequest: Encodable {
    let operate: String
    let ids: [Int]
    let taskID: String
}

/// POST /websites/batch/group {ids,groupID}
nonisolated struct WebsiteBatchGroupRequest: Encodable {
    let ids: [Int]
    let groupID: Int
}

/// POST /websites/ssl/list {acmeAccountID} → 该账户下证书（"0" = 全部）
nonisolated struct WebsiteSSLByAccountRequest: Encodable {
    let acmeAccountID: String
}

/// POST /websites/batch/ssl（全字段，抓包 2026-09-14：type=existed 选择已有证书）
/// httpConfig：HTTPToHTTPS（跳转，抓包确认）/ enable（可直接访问）/ disable（禁止，未抓包按 v1 取值）
nonisolated struct WebsiteBatchSSLRequest: Encodable {
    let ids: [Int]
    let acmeAccountID: Int
    let enable: Bool
    let websiteSSLId: Int
    let type: String
    let importType: String
    let privateKey: String
    let certificate: String
    let privateKeyPath: String
    let certificatePath: String
    let httpConfig: String
    let hsts: Bool
    let hstsIncludeSubDomains: Bool
    /// 加密算法串（网页端固定默认值，抓包原样）
    let algorithm: String
    let SSLProtocol: [String]
    let httpsPort: String
    let http3: Bool
    let taskID: String

    /// 抓包确认的默认加密算法
    static let defaultAlgorithm = "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES128-SHA256:!aNULL:!eNULL:!EXPORT:!DSS:!DES:!RC4:!3DES:!MD5:!PSK:!KRB5:!SRP:!CAMELLIA:!SEED"
}

/// 批量任务（taskID → 任务进度页）
struct WebsiteBatchTask: Identifiable, Hashable {
    let taskID: String
    let title: String
    var id: String { taskID }
}
