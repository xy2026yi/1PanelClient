//
//  BackupAccountModels.swift
//  1PanelClient
//
//  备份账号模型与类型枚举（自 BackupAccountsView.swift 拆出，内容未改动）
//

import SwiftUI
import Combine

// MARK: - 模型

/// 备份账号（POST /backups/search 返回的 items 元素）
nonisolated struct BackupAccount: Decodable, Identifiable {
    let id: Int
    let name: String?
    let type: String?
    let isPublic: Bool?
    let bucket: String?
    let accessKey: String?
    let credential: String?
    let backupPath: String?
    let vars: String?
    let createdAt: String?
    let rememberAuth: Bool?

    var isLocal: Bool { type == "LOCAL" }
    /// 本机账号（localhost/LOCAL）不可删除
    var isProtected: Bool { isLocal || name == "localhost" }
    /// 当前客户端支持编辑表单的类型
    var isEditable: Bool { BackupAccountType(rawValue: type ?? "") != nil || isLocal }

    var displayType: String { isLocal ? L10n.t("服务器磁盘") : (type ?? "—") }
    /// 名称（内置本机账号默认名显示「本机」；改名后显示真实名称，便于确认改名生效）
    var displayName: String {
        if isLocal {
            if let n = name, !n.isEmpty, n != "localhost" { return n }
            return L10n.t("本机")
        }
        return name ?? "—"
    }
    var displayCreatedAt: String {
        guard let t = createdAt, t.count >= 10 else { return "—" }
        return String(t.prefix(10))
    }
}

/// 客户端支持创建/编辑的备份账号类型（LOCAL 仅可编辑）
enum BackupAccountType: String, CaseIterable, Identifiable {
    case minio = "MINIO"
    case oss = "OSS"
    case webdav = "WebDAV"
    case sftp = "SFTP"
    case cos = "COS"
    case s3 = "S3"
    case kodo = "KODO"
    case upyun = "UPYUN"
    case aliyun = "ALIYUN"
    case oneDrive = "OneDrive"
    case googleDrive = "GoogleDrive"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .minio:  return "MINIO"
        case .oss:    return L10n.t("阿里云OSS")
        case .webdav: return "WebDAV"
        case .sftp:   return "SFTP"
        case .cos:    return L10n.t("腾讯云COS")
        case .s3:     return L10n.t("亚马逊S3云存储")
        case .kodo:   return L10n.t("七牛云Kodo")
        case .upyun:  return L10n.t("又拍云")
        case .aliyun: return L10n.t("阿里云盘")
        case .oneDrive: return L10n.t("微软 OneDrive")
        case .googleDrive: return L10n.t("谷歌云盘")
        }
    }

    // MARK: 表单形态分组（对齐官方 hasAccessKey/hasPassword/isUPYUN/hasClient 等谓词）

    /// AK/SK + Endpoint + 桶（KODO 的 Endpoint 键名为 domain）
    var hasAccessKey: Bool {
        switch self {
        case .minio, .oss, .cos, .s3, .kodo: return true
        default: return false
        }
    }
    var hasPasswordAuth: Bool { self == .webdav || self == .sftp }
    var isUpyun: Bool { self == .upyun }
    var isAliyun: Bool { self == .aliyun }
    /// OAuth 客户端类型（client_id/secret/redirect_uri + 授权码换 token）
    var isOAuthClient: Bool { self == .oneDrive || self == .googleDrive }

    /// 桶选择页（自动获取）；UPYUN 服务名手动输入、ALIYUN/OAuth 无桶概念
    var supportsBucketListing: Bool { hasAccessKey }

    /// 「记住认证信息」：OAuth/阿里云盘不存凭证（对齐官方 hasRemember）
    var showsRememberAuth: Bool { !isOAuthClient && !isAliyun }

    /// 三页向导（连接页凭证+Endpoint，存储页桶+类型设置）
    var isThreePageWizard: Bool { hasAccessKey }
}

/// 阿里云OSS 存储类型（vars.scType）
enum OSSStorageType: String, CaseIterable, Identifiable {
    case standard = "Standard"
    case ia = "IA"
    case archive = "Archive"
    case coldArchive = "ColdArchive"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .standard:    return L10n.t("标准存储")
        case .ia:          return L10n.t("低频存储")
        case .archive:     return L10n.t("归档存储")
        case .coldArchive: return L10n.t("深度归档存储")
        }
    }

    var remark: String {
        switch self {
        case .standard:
            return L10n.t("适用于实时访问的大量热点文件、频繁的数据交互等业务场景")
        case .ia:
            return L10n.t("适用于较低访问频率（例如平均每月访问频率1到2次）的业务场景，最少存储30天")
        case .archive:
            return L10n.t("适用于极低访问频率（例如半年访问1次）的业务场景")
        case .coldArchive:
            return L10n.t("适用于极低访问频率（例如1年访问1～2次）的业务场景")
        }
    }
}

/// SFTP 认证方式
enum SFTPAuthMode: String, CaseIterable, Identifiable {
    case password
    case key
    var id: String { rawValue }
    var displayName: String { self == .password ? L10n.t("密码认证") : L10n.t("私钥认证") }
}

/// 备份账号分页查询请求
nonisolated struct BackupAccountSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let type: String
    let name: String
}

nonisolated struct BackupAccountListResponse: Decodable {
    let total: Int
    let items: [BackupAccount]?
}

/// varsJson 动态值（字符串 / 整数 / 布尔）
nonisolated enum BackupVarsValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let i = try? container.decode(Int.self) { self = .int(i) }
        else { self = .string(try container.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i):    try container.encode(i)
        case .bool(let b):   try container.encode(b)
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }
}

/// varsJson / vars：同一份键值对象，提交时 vars 为其 JSON 字符串形式
nonisolated struct BackupVarsJSON: Encodable, Equatable {
    var values: [String: BackupVarsValue]

    init(_ values: [String: BackupVarsValue] = [:]) { self.values = values }

    subscript(key: String) -> BackupVarsValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    /// 直接编码为 JSON 对象（不包 values 外层键）
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    /// 紧凑 JSON 字符串（键排序，保证同一表单状态产出稳定）
    var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(values), let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    /// 从服务端 vars 字符串解析（编辑回显用）
    static func parse(_ json: String?) -> BackupVarsJSON {
        guard let json, let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: BackupVarsValue].self, from: data) else {
            return BackupVarsJSON()
        }
        return BackupVarsJSON(dict)
    }
}

/// 创建 / 更新 / 连接测试 共用的请求体（dto.BackupOperate + varsJson）
nonisolated struct BackupAccountOperate: Encodable {
    var id: Int = 0
    var name: String
    var type: String
    var isPublic: Bool = false
    var bucket: String = ""
    /// base64 编码后的凭证（后端 StdEncoding 解码）
    var accessKey: String
    var credential: String
    var backupPath: String
    /// varsJson 的 JSON 字符串形式（后端实际使用此字段）
    var vars: String
    var varsJson: BackupVarsJSON
    var rememberAuth: Bool = false
    /// 编辑时原样回传（后端会以库中值为准）
    var createdAt: String?
}

/// 获取存储桶请求（MINIO）
nonisolated struct BackupBucketsRequest: Encodable {
    let isPublic: Bool
    let type: String
    let vars: String
    let accessKey: String
    let credential: String
}

/// 连接测试响应
nonisolated struct BackupCheckResult: Decodable {
    let isOk: Bool
    let msg: String?
    let token: String?
}

nonisolated struct BackupAccountDeleteRequest: Encodable {
    let id: Int
}

