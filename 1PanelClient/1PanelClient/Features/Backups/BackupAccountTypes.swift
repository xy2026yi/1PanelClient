//
//  BackupAccountTypes.swift
//  1PanelClient
//
//  新增备份账号类型支持（COS / S3 / KODO / UPYUN / 阿里云盘 / OneDrive / GoogleDrive）。
//  表单字段与 varsJson 键形状对齐 1Panel v2 官方前端
//  （frontend/src/views/setting/backup-account/operate/index.vue，dev-v2 取证 2026-09-21）：
//  - hasAccessKey 系（COS/KODO/MINIO/OSS/S3）：AK/SK + Endpoint（KODO 键名 domain）+ 桶
//  - UPYUN：操作员/密码 → accessKey/credential，服务名 → bucket，无 vars
//  - ALIYUN：粘贴 token JSON 解析出 drive_id / refresh_token
//  - OneDrive / GoogleDrive：client_id/secret/redirect_uri + 授权码粘贴换 token
//

import SwiftUI

// MARK: - 腾讯云 COS 存储类型（vars.scType）

enum COSScType: String, CaseIterable, Identifiable {
    case lighthouse = "DEFAULT"
    case standard = "Standard"
    case ia = "Standard_IA"
    case archive = "Archive"
    case deepArchive = "Deep_Archive"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lighthouse:    return L10n.t("默认存储（轻量）")
        case .standard:      return L10n.t("标准存储")
        case .ia:            return L10n.t("低频存储")
        case .archive:       return L10n.t("归档存储")
        case .deepArchive:   return L10n.t("深度归档存储")
        }
    }

    /// 归档类型不可直接下载（对齐网页端 archiveHelper 警示）
    var isArchive: Bool { self == .archive || self == .deepArchive }
}

// MARK: - 亚马逊 S3 存储类型（vars.scType）

enum S3ScType: String, CaseIterable, Identifiable {
    case standard = "STANDARD"
    case ia = "STANDARD_IA"
    case glacier = "GLACIER"
    case deepArchive = "DEEP_ARCHIVE"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard:    return L10n.t("标准存储")
        case .ia:          return L10n.t("低频存储")
        case .glacier:     return L10n.t("归档存储")
        case .deepArchive: return L10n.t("深度归档存储")
        }
    }

    var isArchive: Bool { self == .glacier || self == .deepArchive }
}

// MARK: - S3 寻址模式（vars.mode）

/// S3 桶寻址：Virtual Hosted（bucket.endpoint）/ Path（endpoint/bucket），
/// 兼容旧版 S3 网络时切 Path
enum S3EndpointMode: String, CaseIterable, Identifiable {
    case virtualHost = "virtual hosted"
    case path = "path"

    var id: String { rawValue }
    var displayName: String { self == .virtualHost ? "Virtual Hosted" : "Path" }
}

// MARK: - COS 地域（官方 cities 常用列表，也可手动输入其他）

enum COSRegions {
    static let all: [String] = [
        "ap-beijing-1", "ap-beijing", "ap-nanjing", "ap-shanghai", "ap-guangzhou",
        "ap-chengdu", "ap-chongqing", "ap-shenzhen_fsi", "ap-shanghai_fsi", "ap-beijing_fsi",
        "ap-hongkong", "ap-singapore", "ap-mumbai", "ap-jakarta", "ap-seoul",
        "ap-bangkok", "ap-tokyo", "na-siliconvalley", "na-ashburn", "na-toronto",
        "sa-saopaulo", "eu-frankfurt",
    ]
}

// MARK: - 各类型 vars 构造（键形状与官方前端逐键对齐，单测固化）

/// 表单输入 → 提交 varsJson。endpointItem（无协议 host）随 endpoint/domain 一并携带，
/// 与官方前端一致（拉桶时由调用方剥离 endpointItem）
enum BackupAccountVarsBuilder {

    static func minio(proto: String, host: String) -> BackupVarsJSON {
        var vars = BackupVarsJSON()
        vars["endpointItem"] = .string(host)
        vars["endpoint"] = .string("\(proto)://\(host)")
        return vars
    }

    static func oss(proto: String, host: String, scType: String) -> BackupVarsJSON {
        var vars = BackupVarsJSON()
        vars["scType"] = .string(scType)
        vars["endpointItem"] = .string(host)
        vars["endpoint"] = .string("\(proto)://\(host)")
        return vars
    }

    static func cos(proto: String, host: String, region: String, scType: String) -> BackupVarsJSON {
        var vars = BackupVarsJSON()
        vars["region"] = .string(region)
        vars["scType"] = .string(scType)
        vars["endpointItem"] = .string(host)
        vars["endpoint"] = .string("\(proto)://\(host)")
        return vars
    }

    static func s3(proto: String, host: String, region: String,
                   scType: String, mode: String) -> BackupVarsJSON {
        var vars = BackupVarsJSON()
        vars["region"] = .string(region)
        vars["scType"] = .string(scType)
        vars["mode"] = .string(mode)
        vars["endpointItem"] = .string(host)
        vars["endpoint"] = .string("\(proto)://\(host)")
        return vars
    }

    static func kodo(proto: String, host: String, timeoutHours: Int) -> BackupVarsJSON {
        var vars = BackupVarsJSON()
        vars["timeout"] = .int(timeoutHours)
        vars["endpointItem"] = .string(host)
        // KODO 的键名是 domain（下载域名），不是 endpoint
        vars["domain"] = .string("\(proto)://\(host)")
        return vars
    }

    /// UPYUN 无 vars 键（操作员/密码走 accessKey/credential，服务名走 bucket）
    static func upyun() -> BackupVarsJSON {
        BackupVarsJSON()
    }

    static func aliyun(driveID: String, refreshToken: String) -> BackupVarsJSON {
        var vars = BackupVarsJSON()
        vars["drive_id"] = .string(driveID)
        vars["refresh_token"] = .string(refreshToken)
        return vars
    }

    /// OAuth 客户端类型公共键；code 仅测试连接时携带（保存前由调用方剥离）
    static func oauthClient(clientID: String, clientSecret: String, redirectURI: String,
                            isCN: Bool?, code: String?) -> BackupVarsJSON {
        var vars = BackupVarsJSON()
        if let isCN { vars["isCN"] = .bool(isCN) }
        vars["client_id"] = .string(clientID)
        vars["client_secret"] = .string(clientSecret)
        vars["redirect_uri"] = .string(redirectURI)
        if let code, !code.isEmpty { vars["code"] = .string(code) }
        return vars
    }
}

// MARK: - OAuth 授权 URL / token 解析（官方 jumpForCode 与 loadFromTokenForAliyun 对齐）

enum BackupOAuth {

    /// OneDrive 授权页（国际版 / 世纪互联）
    static func oneDriveAuthorizeURL(clientID: String, redirectURI: String, isCN: Bool) -> URL? {
        let base = isCN
            ? "https://login.chinacloudapi.cn/common/oauth2/v2.0/authorize?"
            : "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?"
        var comps = URLComponents(string: base)
        comps?.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: "offline_access Files.ReadWrite.All User.Read"),
        ]
        return comps?.url
    }

    /// Google Drive 授权页（scope 驱动 + 相册，离线访问强制重新授权拿 refresh_token）
    static func googleDriveAuthorizeURL(clientID: String, redirectURI: String) -> URL? {
        var comps = URLComponents(
            string: "https://accounts.google.com/o/oauth2/auth/oauthchooseaccount")
        comps?.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope",
                  value: "openid profile https://www.googleapis.com/auth/drive https://www.googleapis.com/auth/photoslibrary"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "service", value: "lso"),
            .init(name: "o2v", value: "1"),
            .init(name: "ddm", value: "1"),
            .init(name: "flowName", value: "GeneralOAuthFlow"),
        ]
        return comps?.url
    }

    /// 阿里云盘 token JSON 解析：官方 loadFromTokenForAliyun 取
    /// default_drive_id / refresh_token 两个字段
    static func parseAliyunToken(_ raw: String) -> (driveID: String, refreshToken: String)? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let driveID = obj["default_drive_id"] as? String,
              let refreshToken = obj["refresh_token"] as? String,
              !driveID.isEmpty, !refreshToken.isEmpty else { return nil }
        return (driveID, refreshToken)
    }

    /// check 响应 token（Base64）→ refresh_token 明文（官方 Base64.decode 同款）
    static func decodeRefreshToken(_ base64: String) -> String {
        guard let data = Data(base64Encoded: base64) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - OAuth 默认客户端信息（GET /api/v2/backups/client/:type）

nonisolated struct BackupClientInfo: Decodable {
    let client_id: String?
    let client_secret: String?
    let redirect_uri: String?
}
