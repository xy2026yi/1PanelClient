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
nonisolated struct AppSearchRequest: Encodable {
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
nonisolated struct AppSearchResponse: Decodable {
    let total: Int
    let items: [AppStoreApp]?
}

/// 应用商店列表项（response.AppItem）
nonisolated struct AppStoreApp: Decodable, Identifiable, Hashable, Sendable {
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
        case "website": return L10n.t("网站")
        case "runtime": return L10n.t("运行环境")
        case "database": return L10n.t("数据库")
        case "tool": return L10n.t("工具")
        case "security": return L10n.t("安全")
        case "ai": return "AI"
        default: return type ?? L10n.t("其他")
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
nonisolated struct AppStoreDetail: Decodable, Identifiable, Hashable, Sendable {
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

    nonisolated struct AppTag: Decodable, Hashable, Sendable {
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
nonisolated struct AppDetail: Decodable, Identifiable, Hashable, Sendable {
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
/// 部分应用可能返回 [] 或 null，自定义解码器兼容多种格式
nonisolated struct AppFormParams: Decodable, Hashable, Sendable {
    let formFields: [AppFormField]?

    init(formFields: [AppFormField]? = nil) {
        self.formFields = formFields
    }

    init(from decoder: Decoder) throws {
        // 尝试作为对象解码 { formFields: [...] }
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            self.formFields = try container.decodeIfPresent([AppFormField].self, forKey: .formFields)
            return
        }
        // 尝试作为数组直接解码 [...]
        if let array = try? decoder.singleValueContainer().decode([AppFormField].self) {
            self.formFields = array
            return
        }
        // 兜底：无参数
        self.formFields = nil
    }

    enum CodingKeys: String, CodingKey {
        case formFields
    }
}

/// 单个表单字段定义
/// 支持多种字段类型：number / text / select / apps / password / service
nonisolated struct AppFormField: Decodable, Hashable, Sendable {
    let envKey: String?
    let type: String?          // "number" / "text" / "select" / "apps" / "password" / "service"
    let labelZh: String?
    let labelEn: String?
    let required: Bool?
    let `default`: FormFieldValue?
    let values: [FormFieldValueItem]?   // select/apps 候选项（可能是 ["v1"] 或 [{label,value}]）
    let child: AppFormFieldChild?       // apps 类型字段的关联子字段（如 PANEL_DB_HOST）
    let random: Bool?                   // 是否支持随机生成（密码、用户名等）
    let rule: String?                   // 验证规则名（paramPort / paramCommon 等）

    /// 显示标签（优先中文）
    var displayLabel: String {
        labelZh ?? labelEn ?? envKey ?? L10n.t("参数")
    }
}

/// apps 类型字段的关联子字段（如数据库应用选择后需要填充 DB_HOST）
nonisolated struct AppFormFieldChild: Decodable, Hashable, Sendable {
    let envKey: String?
    let `default`: String?
    let required: Bool?
    let type: String?       // "service"
}

/// select/apps 候选项值
/// 可能是简单字符串 "mysql"，也可能是对象 {label:"MySQL", value:"mysql"}
nonisolated struct FormFieldValueItem: Decodable, Hashable, Sendable {
    let label: String?
    let value: String?

    /// 用于 Picker 显示
    var displayLabel: String { label ?? value ?? "" }
    /// 实际值
    var actualValue: String { value ?? "" }

    /// 从 JSON 解码：兼容字符串和对象两种格式
    init(from decoder: Decoder) throws {
        // 尝试作为纯字符串解码
        if let str = try? decoder.singleValueContainer().decode(String.self) {
            self.label = str
            self.value = str
            return
        }
        // 作为对象解码 {label, value}
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.label = try container.decodeIfPresent(String.self, forKey: .label)
        self.value = try container.decodeIfPresent(String.self, forKey: .value)
    }

    enum CodingKeys: String, CodingKey {
        case label, value
    }
}

/// 表单字段值（可能是数字、字符串等多种类型）
nonisolated enum FormFieldValue: Decodable, Hashable, Sendable {
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
/// 通过 doc/网页安装app请求抓取.log + doc/安装应用修复.md 完整抓包验证字段
nonisolated struct AppInstallCreateRequest: Encodable {
    let appDetailId: Int
    let params: [String: AnyCodableValue]
    let name: String
    let advanced: Bool
    let cpuQuota: Int
    let memoryLimit: Int
    let memoryUnit: String
    let containerName: String
    let allowPort: Bool
    let editCompose: Bool
    let dockerCompose: String
    let version: String
    let appID: String
    let pullImage: Bool
    let taskID: String
    let gpuConfig: Bool
    let specifyIP: String
    let format: String           // 顶层 format（数据库应用为 utf8mb4，其余为空）
    let collation: String        // 顶层 collation
    let restartPolicy: String
    let pushNode: Bool           // 是否推送到其他节点
    let nodes: [String]          // 目标节点列表（本地安装为空）
}

/// 通用值类型（params 可能是 Int 或 String，需要保持原类型）
enum AnyCodableValue: Encodable {
    case int(Int)
    case string(String)

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        }
    }
}

// MARK: - 忽略升级

/// 忽略升级请求（request.AppIgnoreUpgradeReq）
nonisolated struct AppIgnoreUpgradeRequest: Encodable {
    let appID: Int
    let scope: String           // "all" 或 "version"
    let appDetailID: Int?       // scope=version 时指定版本
}

/// 忽略升级记录（model.AppIgnoreUpgrade）
/// 通过 doc/取消升级以及卸载应用抓取信息.log 验证字段（注意 ID 为大写）
nonisolated struct AppIgnoreUpgrade: Decodable, Identifiable, Sendable {
    let id: Int
    let appID: Int?
    let appDetailID: Int?
    let scope: String?
    let version: String?
    let name: String?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case appID, appDetailID, scope, version, name
        case createdAt, updatedAt
    }
}

/// 通用 ID 请求（request.ReqWithID）
nonisolated struct ReqWithID: Encodable {
    let id: Int
}

/// 带 taskID 的请求（应用商店同步接口使用）
nonisolated struct ReqWithTaskID: Encodable {
    let taskID: String
}

// MARK: - 数据库服务（安装关联数据库应用时使用）

/// 数据库服务项（GET /api/v2/apps/services/:type 返回）
nonisolated struct AppServiceItem: Decodable, Identifiable, Hashable, Sendable {
    let label: String?
    let value: String?
    let config: [String: String]?
    let from: String?
    let status: String?

    var id: String { value ?? label ?? UUID().uuidString }
}

// MARK: - 应用商店设置（卸载/升级/安装默认选项）

/// 应用商店配置（GET /api/v2/core/settings/apps/store/config 返回）。
/// 字段值为 "Enable"/"Disable"；新版服务器可能额外返回 upgradeDeleteImage / installAllowPort，
/// 旧版不返回这两项，模型用可选 + 默认值兜底。
nonisolated struct AppStoreConfig: Decodable {
    var uninstallDeleteBackup: String?
    var uninstallDeleteImage: String?
    var upgradeBackup: String?
    var upgradeDeleteImage: String?
    var installAllowPort: String?

    var isUninstallDeleteBackup: Bool { (uninstallDeleteBackup ?? "Disable") == "Enable" }
    var isUninstallDeleteImage: Bool  { (uninstallDeleteImage ?? "Disable") == "Enable" }
    /// 应用升级前备份应用：文档默认为「开」
    var isUpgradeBackup: Bool         { (upgradeBackup ?? "Enable") == "Enable" }
    var isUpgradeDeleteImage: Bool    { (upgradeDeleteImage ?? "Disable") == "Enable" }
    var isInstallAllowPort: Bool      { (installAllowPort ?? "Disable") == "Enable" }
}

/// 应用商店设置 scope 枚举（POST /api/v2/core/settings/apps/store/update 的 scope 取值）
enum AppStoreSettingScope: String {
    case uninstallDeleteBackup = "UninstallDeleteBackup"
    case uninstallDeleteImage  = "UninstallDeleteImage"
    case upgradeBackup         = "UpgradeBackup"
    case upgradeDeleteImage    = "UpgradeDeleteImage"
    case installAllowPort      = "InstallAllowPort"
}

/// 更新应用商店设置请求（POST /api/v2/core/settings/apps/store/update）
nonisolated struct AppStoreSettingUpdateRequest: Encodable {
    let scope: String
    let status: String   // Enable / Disable
}

