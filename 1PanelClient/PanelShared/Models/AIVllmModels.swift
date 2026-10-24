//
//  AIVllmModels.swift
//  1PanelClient
//
//  vLLM 推理实例（/api/v2/xpack/vllm）：实例分页列表 / 创建（全字段 + taskID）/
//  compose 模板 / 启动命令模板；版本列表复用 AppStoreDetail（GET /api/v2/apps/vllm）
//
//  抓包来源：logs/vLLM与下载器.md（2026-09-12，含 operate/update 补充抓包）
//  实例监控（/api/v2/ai/vllm/monitor/*）：logs/2.4.0新增vllm.md（2026-10-23，
//  抓包机无 GPU，status=unavailable 全 null；字段按服务端 model.MonitorVLLM 对齐）
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

// MARK: - 实例监控（/api/v2/ai/vllm/monitor/*）

/// POST monitor/current 与 monitor/clean 共用请求 {appInstallID}
nonisolated struct VllmMonitorTargetRequest: Encodable {
    let appInstallID: Int
}

/// POST monitor/search {appInstallID, startTime, endTime, aggregation, group}
/// aggregation: avg | max；group: overview | latency | requests（服务端按组只聚合该组直方图）
nonisolated struct VllmMonitorSearchRequest: Encodable {
    let appInstallID: Int
    let startTime: String   // ISO8601 毫秒 Z，如 "2026-10-23T00:51:10.881Z"
    let endTime: String
    var aggregation: String = "avg"
    var group: String = "overview"
}

/// 单个采样点（current 响应与 search points 共用）。全部指标可空：
/// 实例未运行 / 无 GPU / 首个采样（无前值算不出速率）时为 null，status 为 "unavailable"
nonisolated struct VllmMonitorPoint: Decodable, Equatable {
    let createdAt: String?
    let appInstallID: Int?
    /// "ok" / "unavailable"
    let status: String?
    /// 分布直方图对应的采样区间秒数
    let intervalSeconds: Double?
    // 请求分析
    let completedRequests: Double?         // 区间内完成请求数
    let queueTime: Double?                 // 平均排队时间 s
    let averageGenerationTokens: Double?   // 平均生成 token 数
    let prefixCacheHitRate: Double?        // 前缀缓存命中率 %
    let finishReasons: [String: Double]?   // 完成原因 → req/s
    let promptDistribution: [String: Double]?      // 提示 token 直方桶 → req/s
    let generationDistribution: [String: Double]?  // 生成 token 直方桶 → req/s
    // 概览
    let running: Double?                   // 运行中请求数
    let waiting: Double?                   // 等待中请求数
    let cacheUsage: Double?                // KV 缓存使用率 %
    let promptThroughput: Double?          // 提示吞吐 tokens/s
    let generationThroughput: Double?      // 生成吞吐 tokens/s
    let requestThroughput: Double?         // 请求吞吐 req/s
    // 延迟分析（均为秒）
    let timeToFirstToken: Double?
    let timePerOutputToken: Double?
    let requestLatency: Double?
    let prefillTime: Double?
    let decodeTime: Double?
    let timeToFirstTokenP50: Double?
    let timeToFirstTokenP90: Double?
    let timeToFirstTokenP95: Double?
    let timeToFirstTokenP99: Double?
    let timePerOutputTokenP50: Double?
    let timePerOutputTokenP90: Double?
    let timePerOutputTokenP95: Double?
    let timePerOutputTokenP99: Double?
    let requestLatencyP50: Double?
    let requestLatencyP90: Double?
    let requestLatencyP95: Double?
    let requestLatencyP99: Double?

    var isAvailable: Bool { (status ?? "").lowercased() == "ok" }
}

/// POST monitor/search 响应 {sampleCount, bucketSeconds, points}
/// sampleCount>1200 时服务端按 bucketSeconds 分桶聚合（约 600 桶）；否则原样返回采样点，
/// 采样缺口处补入空点（全 null）用于断线
nonisolated struct VllmMonitorHistory: Decodable {
    let sampleCount: Int?
    let bucketSeconds: Int?
    let points: [VllmMonitorPoint]?
}

/// 历史查询分组（对应 search.group，服务端按组裁剪聚合范围）
nonisolated enum VllmMonitorGroup: String, CaseIterable, Identifiable {
    case overview
    case latency
    case requests

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .overview: return L10n.t("概览")
        case .latency: return L10n.t("延迟分析")
        case .requests: return L10n.t("请求分析")
        }
    }
}

/// 历史聚合方式（对应 search.aggregation）
nonisolated enum VllmMonitorAggregation: String, CaseIterable, Identifiable {
    case avg
    case max

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .avg: return L10n.t("平均值")
        case .max: return L10n.t("最大值")
        }
    }
}

/// 标量指标描述表：分组 / 标题 / 单位 / 取值；页面实时区与历史曲线共用。
/// 单位口径按服务端 utils/ai_tools/vllm 计算：缓存与命中率为百分比、吞吐为每秒速率、
/// 延迟类为秒（含 P50/P90/P95/P99 分位）
nonisolated enum VllmMonitorMetric: String, CaseIterable, Identifiable {
    // 概览
    case running, waiting, cacheUsage, promptThroughput, generationThroughput, requestThroughput
    // 延迟分析
    case timeToFirstToken, timePerOutputToken, requestLatency, prefillTime, decodeTime
    // 请求分析
    case completedRequests, queueTime, averageGenerationTokens, prefixCacheHitRate

    var id: String { rawValue }

    var group: VllmMonitorGroup {
        switch self {
        case .running, .waiting, .cacheUsage, .promptThroughput, .generationThroughput, .requestThroughput:
            return .overview
        case .timeToFirstToken, .timePerOutputToken, .requestLatency, .prefillTime, .decodeTime:
            return .latency
        case .completedRequests, .queueTime, .averageGenerationTokens, .prefixCacheHitRate:
            return .requests
        }
    }

    static func metrics(in group: VllmMonitorGroup) -> [VllmMonitorMetric] {
        allCases.filter { $0.group == group }
    }

    var title: String {
        switch self {
        case .running: return L10n.t("运行中请求")
        case .waiting: return L10n.t("等待中请求")
        case .cacheUsage: return L10n.t("KV 缓存使用率")
        case .promptThroughput: return L10n.t("提示吞吐")
        case .generationThroughput: return L10n.t("生成吞吐")
        case .requestThroughput: return L10n.t("请求吞吐")
        case .timeToFirstToken: return L10n.t("首 Token 延迟")
        case .timePerOutputToken: return L10n.t("Token 间延迟")
        case .requestLatency: return L10n.t("端到端延迟")
        case .prefillTime: return L10n.t("预填充耗时")
        case .decodeTime: return L10n.t("解码耗时")
        case .completedRequests: return L10n.t("完成请求数")
        case .queueTime: return L10n.t("排队时间")
        case .averageGenerationTokens: return L10n.t("平均生成 Token")
        case .prefixCacheHitRate: return L10n.t("前缀缓存命中率")
        }
    }

    /// 单位（空串为计数）
    var unit: String {
        switch self {
        case .running, .waiting, .completedRequests: return ""
        case .cacheUsage, .prefixCacheHitRate: return "%"
        case .promptThroughput, .generationThroughput: return "tokens/s"
        case .requestThroughput: return "req/s"
        case .averageGenerationTokens: return "tokens"
        case .timeToFirstToken, .timePerOutputToken, .requestLatency, .prefillTime, .decodeTime,
             .queueTime: return "s"
        }
    }

    /// 数值展示小数位：计数 0、百分比 1、速率/Token 2、秒 3
    var decimals: Int {
        switch self {
        case .running, .waiting, .completedRequests: return 0
        case .cacheUsage, .prefixCacheHitRate: return 1
        case .promptThroughput, .generationThroughput, .requestThroughput, .averageGenerationTokens: return 2
        case .timeToFirstToken, .timePerOutputToken, .requestLatency, .prefillTime, .decodeTime,
             .queueTime: return 3
        }
    }

    /// 百分比指标曲线 Y 固定 0...100，其余动态
    var fixedYDomain: ClosedRange<Double>? {
        switch self {
        case .cacheUsage, .prefixCacheHitRate: return 0...100
        default: return nil
        }
    }

    func value(in point: VllmMonitorPoint) -> Double? {
        switch self {
        case .running: return point.running
        case .waiting: return point.waiting
        case .cacheUsage: return point.cacheUsage
        case .promptThroughput: return point.promptThroughput
        case .generationThroughput: return point.generationThroughput
        case .requestThroughput: return point.requestThroughput
        case .timeToFirstToken: return point.timeToFirstToken
        case .timePerOutputToken: return point.timePerOutputToken
        case .requestLatency: return point.requestLatency
        case .prefillTime: return point.prefillTime
        case .decodeTime: return point.decodeTime
        case .completedRequests: return point.completedRequests
        case .queueTime: return point.queueTime
        case .averageGenerationTokens: return point.averageGenerationTokens
        case .prefixCacheHitRate: return point.prefixCacheHitRate
        }
    }

    /// 分位数（仅首 Token / Token 间 / 端到端三项有 P50/P90/P95/P99），按 (标签, 取值) 返回
    func percentiles(in point: VllmMonitorPoint) -> [(label: String, value: Double?)] {
        switch self {
        case .timeToFirstToken:
            return [("P50", point.timeToFirstTokenP50), ("P90", point.timeToFirstTokenP90),
                    ("P95", point.timeToFirstTokenP95), ("P99", point.timeToFirstTokenP99)]
        case .timePerOutputToken:
            return [("P50", point.timePerOutputTokenP50), ("P90", point.timePerOutputTokenP90),
                    ("P95", point.timePerOutputTokenP95), ("P99", point.timePerOutputTokenP99)]
        case .requestLatency:
            return [("P50", point.requestLatencyP50), ("P90", point.requestLatencyP90),
                    ("P95", point.requestLatencyP95), ("P99", point.requestLatencyP99)]
        default:
            return []
        }
    }

    /// 是否带 P50/P90/P95/P99 分位（首 Token / Token 间 / 端到端三项）
    var hasPercentiles: Bool {
        switch self {
        case .timeToFirstToken, .timePerOutputToken, .requestLatency: return true
        default: return false
        }
    }

    /// 指定分位（"P50"/"P90"/"P95"/"P99"）取值；无该分位或指标不带分位返回 nil
    func percentile(_ label: String, in point: VllmMonitorPoint) -> Double? {
        percentiles(in: point).first { $0.label == label }?.value
    }

    /// 带单位的数值文本（nil → "—"）
    func text(_ value: Double?) -> String {
        guard let value else { return "—" }
        let number = String(format: "%.\(decimals)f", value)
        return unit.isEmpty ? number : (unit == "%" ? number + "%" : number + " " + unit)
    }
}
