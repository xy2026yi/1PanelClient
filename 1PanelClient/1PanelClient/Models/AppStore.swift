//
//  AppStore.swift
//  1PanelClient
//
//  应用商店相关模型（与已安装应用 AppInstall 区分）
//  通过 logs/输出23.log + doc/1panel_json/apps.json 验证
//

import Foundation

// MARK: - 应用商店搜索

/// 应用商店搜索请求（request.AppSearch）
struct AppSearchRequest: Encodable {
    let name: String
    let page: Int
    let pageSize: Int
    let recommend: Bool
    let resource: String
    let showCurrentArch: Bool
    let tags: [String]
    let type: String
}

/// 应用商店搜索响应（response.AppRes）
struct AppSearchResponse: Decodable {
    let total: Int
    let items: [AppStoreApp]?
}

/// 应用商店列表项（response.AppItem）
struct AppStoreApp: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let key: String?
    let name: String?
    let type: String?
    let description: String?
    let tags: [String]?
    let installed: Bool?
    let recommend: Int?
    let status: String?
    let limit: Int?
    let gpuSupport: Bool?

    /// 类型显示名
    var typeDisplayName: String {
        switch (type ?? "").lowercased() {
        case "website": return "网站"
        case "runtime": return "运行环境"
        case "database": return "数据库"
        case "tool": return "工具"
        case "security": return "安全"
        case "ai": return "AI"
        default: return type ?? "其他"
        }
    }

    /// 类型对应的 SF Symbol
    var typeIcon: String {
        switch (type ?? "").lowercased() {
        case "website": return "globe"
        case "runtime": return "wrench.and.screwdriver"
        case "database": return "cylinder"
        case "tool": return "hammer"
        case "security": return "shield"
        case "ai": return "brain"
        default: return "app.dashed"
        }
    }
}

// MARK: - 应用商店详情

/// 应用商店应用详情（response.AppDTO）
struct AppStoreDetail: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let key: String?
    let name: String?
    let type: String?
    let description: String?
    let shortDescZh: String?
    let shortDescEn: String?
    let readMe: String?
    let website: String?
    let document: String?
    let github: String?
    let icon: String?
    let tags: [AppTag]?
    let versions: [String]?
    let installed: Bool?
    let recommend: Int?
    let resource: String?
    let crossVersionUpdate: Bool?
    let gpuSupport: Bool?
    let memoryRequired: Int?
    let requiredPanelVersion: Double?

    struct AppTag: Decodable, Hashable, Sendable {
        let id: Int?
        let key: String?
        let name: String?
    }

    /// 最新版本（versions 数组第一个）
    var latestVersion: String? {
        versions?.first
    }
}

// MARK: - 应用版本详情（含 docker-compose 和参数表单）

/// 应用版本详情（response.AppDetailDTO）
/// 包含 docker-compose 模板和参数表单字段定义
struct AppDetail: Decodable, Identifiable, Hashable, Sendable {
    let id: Int              // appDetailId
    let appId: Int?
    let version: String?
    let dockerCompose: String?
    let params: AppFormParams?
    let status: String?
    let enable: Bool?
    let update: Bool?
    let lastVersion: String?
    let hostMode: Bool?
    let gpuSupport: Bool?
    let memoryRequired: Int?
    let image: String?
    let downloadUrl: String?
}

/// 参数表单定义（AppDetail.params）
/// 1Panel 后端返回的结构：{ formFields: [...] }
struct AppFormParams: Decodable, Hashable, Sendable {
    let formFields: [AppFormField]?
}

/// 单个表单字段定义
struct AppFormField: Decodable, Hashable, Sendable {
    let envKey: String?
    let type: String?          // "number" / "text" / "select" 等
    let labelZh: String?
    let labelEn: String?
    let required: Bool?
    let `default`: FormFieldValue?
    let description: String?
    let values: [String]?      // select 类型的候选值

    /// 显示标签（优先中文）
    var displayLabel: String {
        labelZh ?? labelEn ?? envKey ?? "参数"
    }
}

/// 表单字段值（可能是数字、字符串等多种类型）
enum FormFieldValue: Decodable, Hashable, Sendable {
    case int(Int)
    case double(Double)
    case string(String)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        self = .string("")
    }

    /// 转换为字符串（安装请求 params 是 map[string]string）
    var stringValue: String {
        switch self {
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .string(let v): return v
        case .bool(let v): return v ? "true" : "false"
        }
    }
}

// MARK: - 安装请求

/// 应用安装请求（request.AppInstallCreate）
/// appDetailId 和 name 必填，params 由表单生成
struct AppInstallCreateRequest: Encodable {
    let appDetailId: Int
    let params: [String: String]
    let name: String
    let advanced: Bool
    let pullImage: Bool
}

// MARK: - 忽略升级

/// 忽略升级请求（request.AppIgnoreUpgradeReq）
struct AppIgnoreUpgradeRequest: Encodable {
    let appID: Int
    let scope: String           // "all" 或 "version"
    let appDetailID: Int?       // scope=version 时指定版本
}

/// 忽略升级记录（model.AppIgnoreUpgrade）
struct AppIgnoreUpgrade: Decodable, Identifiable, Sendable {
    let id: Int
    let appID: Int?
    let appDetailID: Int?
    let scope: String?
    let createdAt: String?
    let updatedAt: String?
}

/// 通用 ID 请求（request.ReqWithID）
struct ReqWithID: Encodable {
    let id: Int
}
