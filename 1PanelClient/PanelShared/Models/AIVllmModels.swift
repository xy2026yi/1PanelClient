//
//  AIVllmModels.swift
//  1PanelClient
//
//  vLLM 推理实例（/api/v2/xpack/vllm）：实例分页列表 / 创建（全字段 + taskID）/
//  compose 模板 / 启动命令模板；版本列表复用 AppStoreDetail（GET /api/v2/apps/vllm）
//
//  抓包来源：logs/vLLM与下载器.md（2026-09-12，含 operate/update 补充抓包）
//

import Foundation

// MARK: - 加速器类型

/// vLLM 加速器类型（决定版本列表过滤 / compose 模板 / 命令模板）
nonisolated enum VllmImageType: String, CaseIterable, Identifiable {
    case nvidia
    case intel
    case ascend

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .nvidia: return "NVIDIA"
        case .intel: return "Intel"
        case .ascend: return "Ascend"
        }
    }

    /// 版本列表里的版本号前缀（如 "nvidia-0.27.1"）
    var versionPrefix: String { rawValue + "-" }
}

// MARK: - 实例

/// POST /api/v2/xpack/vllm/search 返回的实例项
nonisolated struct VllmInstance: Decodable, Identifiable, Hashable {
    let id: Int
    let appInstallId: Int?
    let agentAccountId: Int?
    let name: String?
    let appVersion: String?
    let imageType: String?
    let image: String?
    let commandTemplateID: Int?
    let port: Int?
    let modelDir: String?
    let command: String?
    let containerName: String?
    /// Installing / Running / Stopped / Error 等
    let status: String?
    let message: String?
    /// compose 目录（日志查看用）
    let path: String?
    let restartPolicy: String?
    let allowPort: Bool?
    let specifyIP: String?
    /// 核心数，服务端可能返回小数
    let cpuQuota: Double?
    let memoryLimit: Double?
    let memoryUnit: String?
    let syncModelAccount: Bool?
    let modelAccountBaseURLType: String?
    let modelAccountBaseURL: String?
    let pullImage: Bool?
    let editCompose: Bool?
    let dockerCompose: String?
    let upgradable: Bool?
    let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case id, appInstallId, agentAccountId, name, appVersion, imageType, image
        case commandTemplateID, port, modelDir, command, containerName, status, message, path
        case restartPolicy, allowPort, specifyIP, cpuQuota, memoryLimit, memoryUnit
        case syncModelAccount, modelAccountBaseURLType, modelAccountBaseURL
        case pullImage, editCompose, dockerCompose, upgradable, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        appInstallId = try? c.decode(Int.self, forKey: .appInstallId)
        agentAccountId = try? c.decode(Int.self, forKey: .agentAccountId)
        name = try? c.decode(String.self, forKey: .name)
        appVersion = try? c.decode(String.self, forKey: .appVersion)
        imageType = try? c.decode(String.self, forKey: .imageType)
        image = try? c.decode(String.self, forKey: .image)
        commandTemplateID = try? c.decode(Int.self, forKey: .commandTemplateID)
        port = try? c.decode(Int.self, forKey: .port)
        modelDir = try? c.decode(String.self, forKey: .modelDir)
        command = try? c.decode(String.self, forKey: .command)
        containerName = try? c.decode(String.self, forKey: .containerName)
        status = try? c.decode(String.self, forKey: .status)
        message = try? c.decode(String.self, forKey: .message)
        path = try? c.decode(String.self, forKey: .path)
        restartPolicy = try? c.decode(String.self, forKey: .restartPolicy)
        allowPort = try? c.decode(Bool.self, forKey: .allowPort)
        specifyIP = try? c.decode(String.self, forKey: .specifyIP)
        cpuQuota = (try? c.decode(Double.self, forKey: .cpuQuota))
            ?? (try? c.decode(Int.self, forKey: .cpuQuota)).map(Double.init)
        memoryLimit = (try? c.decode(Double.self, forKey: .memoryLimit))
            ?? (try? c.decode(Int.self, forKey: .memoryLimit)).map(Double.init)
        memoryUnit = try? c.decode(String.self, forKey: .memoryUnit)
        syncModelAccount = try? c.decode(Bool.self, forKey: .syncModelAccount)
        modelAccountBaseURLType = try? c.decode(String.self, forKey: .modelAccountBaseURLType)
        modelAccountBaseURL = try? c.decode(String.self, forKey: .modelAccountBaseURL)
        pullImage = try? c.decode(Bool.self, forKey: .pullImage)
        editCompose = try? c.decode(Bool.self, forKey: .editCompose)
        dockerCompose = try? c.decode(String.self, forKey: .dockerCompose)
        upgradable = try? c.decode(Bool.self, forKey: .upgradable)
        createdAt = try? c.decode(String.self, forKey: .createdAt)
    }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return "vLLM #" + String(id)
    }

    var typeDisplay: String {
        VllmImageType(rawValue: imageType ?? "")?.displayName ?? (imageType ?? "-")
    }

    var isRunning: Bool { (status ?? "").lowercased() == "running" }
    /// Installing / Rebuilding 等过渡态：列表轮询刷新
    var isTransitioning: Bool {
        ["installing", "rebuilding", "upgrading", "restarting", "deleting"]
            .contains((status ?? "").lowercased())
    }
}

// MARK: - 创建 / 编辑请求

/// POST /api/v2/xpack/vllm/create（编辑复用同一结构，update 携带 id）
nonisolated struct VllmCreateRequest: Encodable {
    var name: String
    var appVersion: String
    var imageType: String
    var image: String
    var commandTemplateID: Int
    var port: Int
    var modelDir: String
    var command: String
    var advanced: Bool
    var containerName: String
    var allowPort: Bool
    var specifyIP: String
    var restartPolicy: String
    var cpuQuota: Double
    var memoryLimit: Double
    var memoryUnit: String
    var syncModelAccount: Bool
    var modelAccountBaseURLType: String
    var modelAccountBaseURL: String
    var pullImage: Bool
    var editCompose: Bool
    var dockerCompose: String
    var syncAgents: Bool
    var taskID: String
    /// 仅编辑（update）时携带
    var id: Int? = nil
}

/// POST /api/v2/xpack/vllm/operate
/// 启动/停止/重启 {id, operate, taskID}；删除复用同端点 operate="delete"
/// 并携带 forceDelete（抓包 2026-09-12 确认）
nonisolated struct VllmOperateRequest: Encodable {
    let id: Int
    let operate: String
    let taskID: String
    /// 仅 delete 时携带；nil 不编码（start/stop/restart 无此字段）
    var forceDelete: Bool? = nil
}

// MARK: - compose / 命令模板

/// POST /api/v2/xpack/vllm/compose 返回 {dockerCompose}
nonisolated struct VllmComposeResponse: Decodable {
    let dockerCompose: String?
}

/// POST /api/v2/xpack/vllm/command-template/list 返回的模板项
nonisolated struct VllmCommandTemplate: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let remark: String?
    let imageType: String?
    let model: String?
    let command: String?
    let builtin: Bool?
    let createdAt: String?
}

/// POST /api/v2/xpack/vllm/search 请求 {page, pageSize, info}
nonisolated struct VllmSearchRequest: Encodable {
    var page: Int = 1
    var pageSize: Int = 20
    var info: String = ""
}

// MARK: - 版本 → 镜像推导

/// 服务端版本列表（/api/v2/apps/vllm）不返回镜像，创建请求需要 image 字段。
/// 按 1Panel 应用仓库的命名约定从版本号推导默认镜像（网页端抓包对照表验证），
/// 表单允许手动覆盖；新版本只需符合既有前缀规律即可自动推导
nonisolated enum VllmImageMapper {
    /// "nvidia-0.27.1" → "vllm/vllm-openai:v0.27.1"
    /// "ascend-0.23.0-310p" → "quay.io/ascend/vllm-ascend:v0.23.0-310p"
    /// "intel-0.14.0-b8.3.1" → "intel/llm-scaler-vllm:0.14.0-b8.3.1"
    static func defaultImage(appVersion: String) -> String? {
        for type in VllmImageType.allCases {
            guard appVersion.hasPrefix(type.versionPrefix) else { continue }
            let rest = String(appVersion.dropFirst(type.versionPrefix.count))
            guard !rest.isEmpty else { return nil }
            switch type {
            case .nvidia: return "vllm/vllm-openai:v" + rest
            case .ascend: return "quay.io/ascend/vllm-ascend:v" + rest
            case .intel:  return "intel/llm-scaler-vllm:" + rest
            }
        }
        return nil
    }

    /// 从版本列表中筛出某类型的版本（保持服务端排序）
    static func versions(of type: VllmImageType, in all: [String]) -> [String] {
        all.filter { $0.hasPrefix(type.versionPrefix) }
    }
}

// MARK: - 模型账号 Base URL 选项

/// 创建表单「访问地址」四选一：选中后自动填充 Base URL；
/// 四个取值均已被抓包确认（container/systemIP/localhost/custom，2026-09-13）
nonisolated enum VllmBaseURLType: String, CaseIterable, Identifiable {
    case container
    case localhost
    case systemIP
    case custom

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .container: return L10n.t("容器地址")
        case .localhost: return "127.0.0.1"
        case .systemIP: return L10n.t("默认访问地址")
        case .custom: return L10n.t("自定义地址")
        }
    }

    /// 按选项推导 Base URL；custom 返回 nil（由用户手动填写）
    func baseURL(port: Int, containerName: String, panelHost: String) -> String? {
        switch self {
        case .container:
            let name = containerName.isEmpty ? "vllm" : containerName
            return "http://\(name):\(port)/v1"
        case .localhost:
            return "http://127.0.0.1:\(port)/v1"
        case .systemIP:
            return "http://\(panelHost):\(port)/v1"
        case .custom:
            return nil
        }
    }
}
