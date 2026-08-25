//
//  OpenRestyManage.swift
//  1PanelClient
//
//  OpenResty 管理增强：运行状态 / 性能参数 / HTTPS 其他设置 / 模块管理
//  字段已通过 doc（OpenResty增加功能.md 抓包）验证
//

import Foundation

// MARK: - 运行状态（GET /api/v2/openresty/status）

nonisolated struct OpenRestyStatus: Decodable, Sendable {
    let active: Int
    let accepts: Int
    let handled: Int
    let requests: Int
    let reading: Int
    let writing: Int
    let waiting: Int
}

// MARK: - 性能参数（POST /api/v2/openresty/scope, scope=http-per）

nonisolated struct OpenRestyScopeRequest: Encodable, Sendable {
    let scope: String
}

/// scope 返回项：{name: "client_max_body_size", params: ["50m"]}
nonisolated struct OpenRestyScopeItem: Decodable, Sendable {
    let name: String
    let params: [String]?
}

/// 性能参数保存（POST /api/v2/openresty/update）
nonisolated struct OpenRestyParamsUpdateRequest: Encodable, Sendable {
    let scope: String
    let operate: String
    let params: [String: String]
}

// MARK: - 其他设置（GET/POST /api/v2/openresty/https）

nonisolated struct OpenRestyHTTPSConfig: Decodable, Sendable {
    var https: Bool?
    var sslRejectHandshake: Bool?
}

/// POST /openresty/https：operate 由 HTTPS 开关决定（on=enable / off=disable），
/// sslRejectHandshake 始终回传当前值
nonisolated struct OpenRestyHTTPSUpdateRequest: Encodable, Sendable {
    let operate: String
    let sslRejectHandshake: Bool
}

// MARK: - 模块（GET /api/v2/openresty/modules）

nonisolated struct OpenRestyModulesResponse: Decodable, Sendable {
    let mirror: String?
    let dynamicSupported: Bool?
    let modules: [OpenRestyModule]?
}

/// 模块构建产物（服务端 dto.NginxModuleArtifact：name/path/checksum）
nonisolated struct OpenRestyModuleArtifact: Decodable, Hashable, Sendable {
    var name: String?
    var path: String?
    var checksum: String?
}

/// OpenResty 模块；开启/关闭时需把完整对象原样回传并附加 operate。
/// 逐字段宽松解码（try?）：单个字段类型变化（如 artifacts null ↔ 数组）
/// 不应拖垮整个模块列表。
nonisolated struct OpenRestyModule: Decodable, Hashable, Sendable, Identifiable {
    var name: String
    var custom: Bool?
    var script: String?
    var packages: String?
    var params: String?
    var enable: Bool?
    var buildMode: String?
    var provider: String?
    var loadOrder: Int?
    var buildStatus: String?
    var loadStatus: String?
    /// 构建前为 null，构建后为产物数组（服务端 []dto.NginxModuleArtifact）
    var artifacts: [OpenRestyModuleArtifact]?
    var lastError: String?

    var id: String { name }

    /// 是否动态模块（静态模块无开关，构建走全量重建）
    var isDynamic: Bool { buildMode?.lowercased() == "dynamic" }

    init(name: String,
         custom: Bool? = nil,
         script: String? = nil,
         packages: String? = nil,
         params: String? = nil,
         enable: Bool? = nil,
         buildMode: String? = nil,
         provider: String? = nil,
         loadOrder: Int? = nil,
         buildStatus: String? = nil,
         loadStatus: String? = nil,
         artifacts: [OpenRestyModuleArtifact]? = nil,
         lastError: String? = nil) {
        self.name = name
        self.custom = custom
        self.script = script
        self.packages = packages
        self.params = params
        self.enable = enable
        self.buildMode = buildMode
        self.provider = provider
        self.loadOrder = loadOrder
        self.buildStatus = buildStatus
        self.loadStatus = loadStatus
        self.artifacts = artifacts
        self.lastError = lastError
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        custom = try? c.decode(Bool.self, forKey: .custom)
        script = try? c.decode(String.self, forKey: .script)
        packages = try? c.decode(String.self, forKey: .packages)
        params = try? c.decode(String.self, forKey: .params)
        enable = try? c.decode(Bool.self, forKey: .enable)
        buildMode = try? c.decode(String.self, forKey: .buildMode)
        provider = try? c.decode(String.self, forKey: .provider)
        loadOrder = try? c.decode(Int.self, forKey: .loadOrder)
        buildStatus = try? c.decode(String.self, forKey: .buildStatus)
        loadStatus = try? c.decode(String.self, forKey: .loadStatus)
        artifacts = try? c.decode([OpenRestyModuleArtifact].self, forKey: .artifacts)
        lastError = try? c.decode(String.self, forKey: .lastError)
    }

    enum CodingKeys: String, CodingKey {
        case name, custom, script, packages, params, enable
        case buildMode, provider, loadOrder, buildStatus, loadStatus
        case artifacts, lastError
    }
}

/// POST /openresty/modules/update：字段对齐服务端 request.NginxModuleUpdate
/// （operate/name/script/packages/enable/params/buildMode/provider/loadOrder，
/// 有 oneof 校验；其余字段服务端不接收）
nonisolated struct OpenRestyModuleUpdateRequest: Encodable, Sendable {
    let operate: String
    let name: String
    let script: String
    let packages: String
    let enable: Bool
    let params: String
    let buildMode: String
    let provider: String
    let loadOrder: Int

    init(module: OpenRestyModule, enable: Bool) {
        self.operate = "update"
        self.name = module.name
        self.script = module.script ?? ""
        self.packages = module.packages ?? ""
        self.enable = enable
        self.params = module.params ?? ""
        self.buildMode = module.buildMode ?? "dynamic"
        self.provider = module.provider ?? "local"
        self.loadOrder = module.loadOrder ?? 0
    }
}

/// POST /openresty/build：构建目标为所有 enable=true 的模块
nonisolated struct OpenRestyBuildRequest: Encodable, Sendable {
    let taskID: String
    let mirror: String
    let modules: [String]
    let force: Bool
}
