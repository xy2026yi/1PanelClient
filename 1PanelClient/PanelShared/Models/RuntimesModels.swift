//
//  RuntimesModels.swift
//  1PanelClient
//
//  运行环境模块模型（PHP / Node.js / Python / Go）
//  全部字段经 logs/runtimes.md 抓包验证（面板 v2.4.1，2026-10-25）。
//  任务式操作：创建/编辑重建/删除/扩展安装返回后用自带 taskID 轮询任务日志；
//  扩展卸载、supervisor、Node 模块操作为同步请求（无任务）。
//

import Foundation

// MARK: - 类型枚举

/// 运行环境类型（java/dotnet 面板亦支持，未抓包验证，暂不开放）
nonisolated enum RuntimeType: String, CaseIterable, Identifiable, Hashable, Sendable {
    case php
    case node
    case python
    case go
    case java
    case dotnet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .php: return "PHP"
        case .node: return "Node.js"
        case .python: return "Python"
        case .go: return "Go"
        case .java: return "Java"
        case .dotnet: return ".NET"
        }
    }

    /// apps/search 与 runtimes/search 使用的 type 值
    var searchKey: String {
        switch self {
        case .php: return "php"
        case .node: return "node"
        case .python: return "python"
        case .go: return "go"
        case .java: return "java"
        case .dotnet: return "dotnet"
        }
    }

    /// 终端默认用户（抓包：PHP 传 www-data，其余默认）
    var terminalUser: String {
        self == .php ? "www-data" : "root"
    }

    /// 从服务端 type 字符串解析（未知值返回 nil，列表按未知类型展示原值）
    static func parse(_ raw: String?) -> RuntimeType? {
        guard let raw else { return nil }
        return RuntimeType(rawValue: raw.lowercased())
    }
}

// MARK: - 混型 JSON 值（params 字典）

/// 运行环境 params 混型值：字符串 / 整数 / 浮点 / 布尔 / 字符串数组（PHP_EXTENSIONS）/ null。
/// 读（RuntimeDTO.params）与写（创建/编辑请求 params）共用。
nonisolated enum RuntimeParamValue: Codable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([String])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode([String].self) { self = .array(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    /// 字符串视图（展示用；数值转字符串、数组逗号连接、null 空）
    var stringValue: String {
        switch self {
        case .string(let v): return v
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .bool(let v): return v ? "true" : "false"
        case .array(let v): return v.joined(separator: ",")
        case .null: return ""
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v)
        case .string(let v): return Int(v)
        default: return nil
        }
    }

    var arrayValue: [String] {
        if case .array(let v) = self { return v }
        return []
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

// MARK: - 容器高级配置四数组（创建/编辑与 PHP 容器配置共用）

nonisolated struct RuntimeExposedPort: Codable, Hashable, Sendable {
    var hostPort: Int
    var containerPort: Int
    var hostIP: String
    var `protocol`: String

    enum CodingKeys: String, CodingKey {
        case hostPort, containerPort
        case hostIP
        case `protocol`
    }
}

nonisolated struct RuntimeEnvironment: Codable, Hashable, Sendable {
    var key: String
    var value: String
}

nonisolated struct RuntimeVolume: Codable, Hashable, Sendable {
    var source: String
    var target: String
    var mode: String
}

nonisolated struct RuntimeExtraHost: Codable, Hashable, Sendable {
    var hostname: String
    var ip: String
}

// MARK: - 列表 / 详情

/// 列表查询（POST /runtimes/search；name/status 可选过滤，面板传空串）
nonisolated struct RuntimeListSearchRequest: Encodable {
    var name: String = ""
    var page: Int = 1
    var pageSize: Int = 20
    var type: String = ""
    var status: String = ""
}

/// 运行环境条目（列表与 GET /runtimes/:id 详情同构；详情多回填 appParams）
nonisolated struct RuntimeEntry: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String?
    let resource: String?
    let appDetailID: Int?
    let appID: Int?
    let source: String?
    let status: String?
    let type: String?
    let image: String?
    let params: [String: RuntimeParamValue]?
    let message: String?
    let version: String?
    let createdAt: String?
    let codeDir: String?
    /// 详情接口返回（带当前值的应用表单项）。不复用 Apps 的 InstalledParamField：
    /// 其 value 不认数组，而 PHP_EXTENSIONS 的当前值是 ["zip"]，会让整条解码失败
    let appParams: [RuntimeAppParam]?
    let port: String?
    let path: String?
    let exposedPorts: [RuntimeExposedPort]?
    let environments: [RuntimeEnvironment]?
    let volumes: [RuntimeVolume]?
    let extraHosts: [RuntimeExtraHost]?
    let containerStatus: String?
    let container: String?
    /// 列表内联编辑备注（就地回写用）
    var remark: String?

    var displayName: String { name ?? "—" }

    var runtimeType: RuntimeType? { RuntimeType.parse(type) }

    /// 状态徽章归类（Creating/Building 过渡态；其余原样展示）
    var isTransitional: Bool {
        let s = status?.lowercased() ?? ""
        return s == "creating" || s == "building"
    }

    var isRunning: Bool { status?.lowercased() == "running" }

    /// 容器名（终端连接用；params.CONTAINER_NAME，兜底 container 字段）
    var containerName: String {
        params?["CONTAINER_NAME"]?.stringValue ?? container ?? ""
    }

    /// Node 包管理器（模块管理用；默认 npm）
    var packageManager: String {
        params?["PACKAGE_MANAGER"]?.stringValue ?? "npm"
    }

    /// 编辑回填：是否安装依赖（Node；RUN_INSTALL !== "0"）
    var installDependencies: Bool {
        (params?["RUN_INSTALL"]?.stringValue ?? "1") != "0"
    }
}

typealias RuntimeListResponse = PageEnvelope<RuntimeEntry>

/// 详情 appParams 条目（value 为混型：PHP_EXTENSIONS 当前值是字符串数组）
nonisolated struct RuntimeAppParam: Decodable, Identifiable, Hashable, Sendable {
    let value: RuntimeParamValue?
    let edit: Bool?
    let key: String?
    let rule: String?
    let labelZh: String?
    let labelEn: String?
    let type: String?
    let values: [FormFieldValueItem]?
    let showValue: String?
    let required: Bool?
    let multiple: Bool?

    var id: String { key ?? "" }
    var displayLabel: String { labelZh ?? labelEn ?? key ?? "" }
}

// MARK: - 创建 / 编辑

/// 创建请求（POST /runtimes）。PHP 必带 image 与 source；Node/Python/Go image 传空、
/// source 视类型（Node npm 源 / Python pypi 源 / Go 抓包未带传空）。
nonisolated struct RuntimeCreateRequest: Encodable {
    var name: String
    var appDetailID: Int
    var image: String
    var params: [String: RuntimeParamValue]
    var type: String
    var resource: String = "appstore"
    var rebuild: Bool = false
    /// Node 专属：是否安装 node_modules（其余类型不传）
    var install: Bool? = nil
    var codeDir: String = ""
    var port: Int? = nil
    var source: String = ""
    var exposedPorts: [RuntimeExposedPort]? = nil
    var environments: [RuntimeEnvironment]? = nil
    var volumes: [RuntimeVolume]? = nil
    var extraHosts: [RuntimeExtraHost]? = nil
    var remark: String = ""
    var appID: Int
    var version: String
    var taskID: String
}

/// 编辑保存请求（POST /runtimes/update；rebuild 固定 true 触发重建，任务式）
nonisolated struct RuntimeUpdateRequest: Encodable {
    var id: Int
    var name: String
    var appDetailID: Int
    var image: String
    var params: [String: RuntimeParamValue]
    var type: String
    var resource: String = "appstore"
    var rebuild: Bool = true
    var install: Bool? = nil
    var codeDir: String = ""
    var port: Int? = nil
    var source: String = ""
    var exposedPorts: [RuntimeExposedPort]? = nil
    var environments: [RuntimeEnvironment]? = nil
    var volumes: [RuntimeVolume]? = nil
    var extraHosts: [RuntimeExtraHost]? = nil
    var remark: String = ""
    var appID: Int
    var version: String
    /// 面板原始请求同时携带 versionn（与 version 同值），照传对齐
    var versionn: String? = nil
}

// MARK: - 通用操作

/// 启动/停止/重启（POST /runtimes/operate；键为大写 ID，抓包口径）
nonisolated struct RuntimeOperateRequest: Encodable {
    let operate: String      // up / down / restart
    let ID: Int
}

/// 删除（POST /runtimes/del，任务式）
nonisolated struct RuntimeDeleteRequest: Encodable {
    let id: Int
    var forceDelete: Bool = false
    var deleteImage: Bool = false
    let taskID: String
}

/// 删除前检查（GET /runtimes/installed/delete/check/:id）
/// 返回 null 或 [AppDeleteCheckItem]（{type:"website",name:"域名:端口"}），复用 Apps 模块模型

/// 备注修改（POST /runtimes/remark）
nonisolated struct RuntimeRemarkRequest: Encodable {
    let id: Int
    let remark: String
}

/// 构建日志读取（POST /files/read/:type?operateNode=local；type=php/node/python/go，
/// 慢日志复用同端点 type=php-fpm-slow-logs）
nonisolated struct RuntimeLogReadRequest: Encodable {
    let id: Int
    let type: String
    var page: Int = 1
    var pageSize: Int = 500
    var latest: Bool = true
}

/// 日志行响应（end/path/lines/totalLines；任务日志同构复用 TaskLogResponse，此为文件日志）
nonisolated struct RuntimeLogReadResponse: Decodable, Sendable {
    let end: Bool?
    let path: String?
    let total: Int?
    let taskStatus: String?
    let lines: [String]?
    let totalLines: Int?
}

// MARK: - 应用商店辅助（创建表单数据源）

/// 应用商店类型搜索（POST /apps/search {type,page,pageSize,resource:remote}）
nonisolated struct RuntimeAppSearchRequest: Encodable {
    let type: String
    var page: Int = 1
    var pageSize: Int = 20
    var resource: String = "remote"
}

/// apps/search 条目（每类型通常 1 条；取 id 供 apps/:key 与详情用）
nonisolated struct RuntimeAppItem: Decodable, Identifiable, Hashable, Sendable {
    let id: Int?
    let name: String?
    let key: String?

    var displayName: String { name ?? key ?? "—" }
}

typealias RuntimeAppSearchResponse = PageEnvelope<RuntimeAppItem>

/// 应用详情（GET /apps/:key）versions 列表条目 —— 复用 AppStore.AppDetail 太重，
/// 仅取 versions 时用轻量模型
nonisolated struct RuntimeAppVersions: Decodable, Sendable {
    let versions: [String]?
}

// MARK: - PHP：扩展

/// 已加载 + 可装扩展（GET /runtimes/php/:id/extensions）
nonisolated struct RuntimePHPExtensionsResponse: Decodable, Sendable {
    let extensions: [String]?
    let supportExtensions: [RuntimePHPSupportExtension]?
}

nonisolated struct RuntimePHPSupportExtension: Decodable, Identifiable, Hashable, Sendable {
    let name: String?
    let description: String?
    let installed: Bool?
    let check: String?
    let versions: [String]?
    let file: String?

    var id: String { name ?? "" }
    var displayName: String { name ?? "—" }
}

/// 扩展安装（POST /runtimes/php/extensions/install，任务式带 taskID）
nonisolated struct RuntimePHPExtensionInstallRequest: Encodable {
    let id: Int
    let name: String
    let taskID: String
}

/// 扩展卸载（POST /runtimes/php/extensions/uninstall；抓包不带 taskID，同步）
nonisolated struct RuntimePHPExtensionUninstallRequest: Encodable {
    let id: Int
    let name: String
}

// MARK: - PHP：扩展模版

/// 模版查询（POST /runtimes/php/extensions/search {all,page,pageSize}）
nonisolated struct RuntimePHPTemplateSearchRequest: Encodable {
    var all: Bool = true
    var page: Int = 1
    var pageSize: Int = 100
}

nonisolated struct RuntimePHPTemplate: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String?
    /// 逗号分隔的扩展名串（创建 PHP 时选中模版自动带入）
    let extensions: String?

    var displayName: String { name ?? "—" }
    var extensionList: [String] {
        (extensions ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

typealias RuntimePHPTemplateListResponse = PageEnvelope<RuntimePHPTemplate>

nonisolated struct RuntimePHPTemplateCreateRequest: Encodable {
    let name: String
    let extensions: String
}

nonisolated struct RuntimePHPTemplateUpdateRequest: Encodable {
    let id: Int
    let name: String
    let extensions: String
}

nonisolated struct RuntimePHPTemplateDeleteRequest: Encodable {
    let id: Int
}

// MARK: - PHP：php.ini 配置

/// 配置读取（GET /runtimes/php/config/:id）
nonisolated struct RuntimePHPConfig: Decodable, Sendable {
    let params: [String: String]?
    let disableFunctions: [String]?
    let uploadMaxSize: String?
    let maxExecutionTime: String?

    /// 展示/编辑用禁用函数列表：服务端可整串逗号返回（如 ["bash,exec"] 单元素），
    /// 按逗号拆分并去空；保存仍按拆分后的数组全量提交（抓包口径）
    var disableFunctionList: [String] {
        (disableFunctions ?? [])
            .flatMap { $0.split(separator: ",").map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// 配置保存（POST /runtimes/php/config；按 scope 分四组）
/// - scope=params：params 带全部 11 项（服务端整组覆盖）
/// - scope=disable_functions：disableFunctions 全量数组（删除即从数组去掉）
/// - scope=upload_max_filesize：uploadMaxSize
/// - scope=max_execution_time：maxExecutionTime
nonisolated struct RuntimePHPConfigUpdateRequest: Encodable {
    var id: Int
    var params: [String: String]? = nil
    var scope: String
    var disableFunctions: [String]? = nil
    var uploadMaxSize: String? = nil
    var maxExecutionTime: String? = nil
}

/// 配置修改表单的 11 项键（logs/runtimes.md「配置修改」小节固定口径）
nonisolated enum RuntimePHPParamKey: String, CaseIterable, Identifiable {
    case shortOpenTag = "short_open_tag"
    case defaultSocketTimeout = "default_socket_timeout"
    case maxExecutionTime = "max_execution_time"
    case errorReporting = "error_reporting"
    case postMaxSize = "post_max_size"
    case displayErrors = "display_errors"
    case fileUploads = "file_uploads"
    case maxInputTime = "max_input_time"
    case uploadMaxFilesize = "upload_max_filesize"
    case memoryLimit = "memory_limit"
    case maxFileUploads = "max_file_uploads"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shortOpenTag: return L10n.t("短标签")
        case .defaultSocketTimeout: return L10n.t("Socket 超时")
        case .maxExecutionTime: return L10n.t("最大执行时间")
        case .errorReporting: return L10n.t("错误报告级别")
        case .postMaxSize: return L10n.t("POST 最大尺寸")
        case .displayErrors: return L10n.t("显示错误")
        case .fileUploads: return L10n.t("文件上传")
        case .maxInputTime: return L10n.t("最大输入时间")
        case .uploadMaxFilesize: return L10n.t("上传文件最大尺寸")
        case .memoryLimit: return L10n.t("内存限制")
        case .maxFileUploads: return L10n.t("最大上传文件数")
        }
    }

    /// On/Off 开关型键（形态 3 下拉）
    var isToggle: Bool {
        switch self {
        case .shortOpenTag, .displayErrors, .fileUploads: return true
        default: return false
        }
    }

    /// 尺寸值键（带 K/M/G 后缀，编辑时数值与单位拆分）
    var isSize: Bool {
        switch self {
        case .postMaxSize, .uploadMaxFilesize, .memoryLimit: return true
        default: return false
        }
    }

    /// 纯数字键（数字键盘）
    var isNumeric: Bool {
        switch self {
        case .defaultSocketTimeout, .maxExecutionTime, .maxInputTime, .maxFileUploads:
            return true
        default: return false
        }
    }
}

// MARK: - PHP：FPM

/// FPM 性能调整读取（GET /runtimes/php/fpm/config/:id）
nonisolated struct RuntimeFPMConfig: Decodable, Sendable {
    let id: Int?
    let params: [String: RuntimeParamValue]?
}

/// FPM 性能调整保存（POST /runtimes/php/fpm/config；数值项面板传数字）
nonisolated struct RuntimeFPMConfigUpdateRequest: Encodable {
    let id: Int
    let params: [String: RuntimeParamValue]
}

/// 负载状态（GET /runtimes/php/fpm/status/:id → [{key,value}]，value 字符串/数字混型）
nonisolated struct RuntimeFPMStatusItem: Decodable, Identifiable, Hashable, Sendable {
    let key: String?
    let value: RuntimeParamValue?

    var id: String { key ?? "" }
}

/// 并发方案预设（性能调整页一键回填；logs/runtimes.md 抓包固定口径）
/// (max_children, start_servers, min_spare_servers, max_spare_servers)
nonisolated enum RuntimeFPMPreset: String, CaseIterable, Identifiable {
    case g4 = "4GB"
    case g8 = "8GB"
    case g16 = "16GB"
    case g32 = "32GB"
    case g48 = "48GB"
    case g64 = "64GB"
    case g96 = "96GB"
    case g128 = "128GB"

    var id: String { rawValue }

    var values: (maxChildren: Int, startServers: Int, minSpare: Int, maxSpare: Int) {
        switch self {
        case .g4: return (80, 10, 10, 30)
        case .g8: return (120, 10, 10, 30)
        case .g16: return (200, 15, 15, 50)
        case .g32: return (300, 20, 20, 50)
        case .g48: return (400, 20, 20, 50)
        case .g64: return (500, 30, 30, 60)
        case .g96: return (700, 40, 40, 70)
        case .g128: return (1000, 50, 50, 100)
        }
    }
}

// MARK: - PHP：配置文件 / 容器配置

/// 配置文件读取（POST /runtimes/php/file {id,type}；type=php → php.ini，type=fpm → php-fpm.conf）
nonisolated struct RuntimePHPFileRequest: Encodable {
    let id: Int
    let type: String
}

/// 配置文件保存并重载（POST /runtimes/php/update）
nonisolated struct RuntimePHPFileUpdateRequest: Encodable {
    let id: Int
    let content: String
    let type: String
}

/// 文件信息响应（path/name/content；其余字段展示不需要，宽容丢弃）
nonisolated struct RuntimeFileInfo: Decodable, Sendable {
    let path: String?
    let name: String?
    let content: String?
    let size: Int?
}

/// 容器配置读取（GET /runtimes/php/container/:id）
nonisolated struct RuntimePHPContainerConfig: Decodable, Sendable {
    let id: Int?
    let containerName: String?
    let exposedPorts: [RuntimeExposedPort]?
    let environments: [RuntimeEnvironment]?
    let volumes: [RuntimeVolume]?
    let extraHosts: [RuntimeExtraHost]?
}

/// 容器配置保存（POST /runtimes/php/container/update；整组覆盖）
nonisolated struct RuntimePHPContainerUpdateRequest: Encodable {
    let id: Int
    let containerName: String
    let exposedPorts: [RuntimeExposedPort]
    let environments: [RuntimeEnvironment]
    let volumes: [RuntimeVolume]
    let extraHosts: [RuntimeExtraHost]
}

// MARK: - 进程守护（supervisor，PHP 专属入口）

/// 进程列表条目（GET /runtimes/supervisor/process/:id）
nonisolated struct RuntimeSupervisorProcess: Decodable, Identifiable, Hashable, Sendable {
    let name: String?
    let command: String?
    let user: String?
    let dir: String?
    let numprocs: String?
    let msg: String?
    let status: [RuntimeSupervisorProcessStatus]?
    let autoRestart: String?
    let autoStart: String?
    let environment: String?

    var id: String { name ?? "" }
    var displayName: String { name ?? "—" }
    var autoRestartOn: Bool { autoRestart == "true" }
    var autoStartOn: Bool { autoStart == "true" }
    /// 内置 php-fpm 进程：面板对其隐藏全部操作（编辑/重启/源文/删除）
    var isBuiltinPHPFPM: Bool { name == "php-fpm" }
}

/// 子进程运行状态（展开行）
nonisolated struct RuntimeSupervisorProcessStatus: Decodable, Hashable, Sendable {
    let name: String?
    let status: String?
    let PID: String?
    let uptime: String?
    let msg: String?

    enum CodingKeys: String, CodingKey {
        case name, status
        case PID
        case uptime, msg
    }

    var isRunning: Bool { status?.uppercased() == "RUNNING" }
}

/// 进程创建（POST /runtimes/supervisor/process operate=create；
/// autoRestart/autoStart 抓包为 "true"/"false" 字符串）
nonisolated struct RuntimeSupervisorCreateRequest: Encodable {
    var operate: String = "create"
    let name: String
    let command: String
    var user: String = "www-data"
    var dir: String = "/"
    var numprocsNum: Int = 1
    var numprocs: String = "1"
    let id: Int
    var autoRestart: String = "true"
    var autoStart: String = "true"
    var environment: String = ""
}

/// 进程操作（重启/删除；面板 UI 仅此两种，operate 亦支持 stop/start 但无入口）
nonisolated struct RuntimeSupervisorOperateRequest: Encodable {
    let operate: String      // restart / delete
    let name: String
    let id: Int
}

/// 进程配置文件读写（POST /runtimes/supervisor/process/file；
/// operate=get 读取（返回 data 为配置串）、update 保存；file 固定 "config"）
nonisolated struct RuntimeSupervisorFileRequest: Encodable {
    let name: String
    let file: String
    let operate: String
    var content: String = ""
    let id: Int
}

// MARK: - Node.js 专属

/// package.json scripts 解析（POST /runtimes/node/package {codeDir}）
nonisolated struct RuntimeNodePackageRequest: Encodable {
    let codeDir: String
}

nonisolated struct RuntimeNodeScript: Decodable, Identifiable, Hashable, Sendable {
    let name: String?
    let script: String?

    var id: String { name ?? "" }
    var displayName: String { name ?? "—" }
}

/// 已装模块列表（POST /runtimes/node/modules {ID}；键大写抓包口径）
nonisolated struct RuntimeNodeModulesRequest: Encodable {
    let ID: Int
}

nonisolated struct RuntimeNodeModule: Decodable, Identifiable, Hashable, Sendable {
    let name: String?
    let version: String?
    let license: String?
    let description: String?

    var id: String { name ?? "" }
    var displayName: String { name ?? "—" }
}

/// 模块安装/更新/卸载（POST /runtimes/node/modules/operate；同步等待，前端超时 10 分钟）
nonisolated struct RuntimeNodeModuleOperateRequest: Encodable {
    let ID: Int
    let Operate: String      // install / uninstall / update
    let Module: String
    let PkgManager: String   // npm / yarn
}
