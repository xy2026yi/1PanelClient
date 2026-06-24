//
//  Container.swift
//  1PanelClient
//

import Foundation
import SwiftUI

/// 容器搜索请求（dto.PageContainer）
struct ContainerSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let name: String
    let state: String
    let orderBy: String
    let order: String
}

/// 容器列表响应
struct ContainerListResponse: Decodable {
    let total: Int
    let items: [Container]?
}

/// 单个容器（1Panel v2 实际返回的字段，已通过 logs/输出11.log 验证）
struct Container: Decodable, Identifiable, Hashable {
    let containerID: String
    let name: String
    let imageName: String?
    let imageID: String?
    let state: String
    let runTime: String?
    let network: [String]?
    let ports: [String]?
    let createTime: String?
    let isFromApp: Bool?
    let isFromCompose: Bool?
    let appName: String?
    let appInstallName: String?
    let websites: [String]?
    let isPinned: Bool?
    let description: String?

    /// 来自 list/stats 接口的运行时指标（合并后赋值）
    var cpuPercent: Double?
    var memoryUsage: Int64?
    var memoryLimit: Int64?
    var memoryPercent: Double?

    var id: String { containerID }

    /// 显示名固定使用 name 字段（如 1Panel-phpmyadmin-fl4L）
    var displayName: String { name }

    var displayImage: String { imageName ?? "unknown" }

    /// CPU 使用率展示文本
    var cpuDisplay: String {
        guard let v = cpuPercent else { return "—" }
        return String(format: "%.2f%%", v)
    }

    /// 端口映射展示（单行，逗号分隔）
    var portsDisplay: String {
        (ports ?? []).joined(separator: ", ")
    }

    var stateColor: Color {
        switch state.lowercased() {
        case "running": return .green
        case "exited", "stopped": return .gray
        case "paused": return .orange
        case "restarting": return .blue
        default: return .red
        }
    }

    var stateIcon: String {
        switch state.lowercased() {
        case "running": return "play.circle.fill"
        case "exited", "stopped": return "stop.circle.fill"
        case "paused": return "pause.circle.fill"
        case "restarting": return "arrow.triangle.2.circlepath.circle.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - Docker 服务状态（GET /containers/docker/status）

struct DockerStatus: Decodable {
    let isActive: Bool?
    let isExist: Bool?
}

// MARK: - 容器运行时指标（GET /containers/list/stats）

struct ContainerStats: Decodable {
    let containerID: String?
    let cpuPercent: Double?
    let memoryUsage: Int64?
    let memoryLimit: Int64?
    let memoryPercent: Double?
}

// MARK: - Docker 操作请求（POST /containers/docker/operate）

struct DockerOperateRequest: Encodable {
    let operation: String  // start / stop / restart
}

// MARK: - 清理请求（POST /containers/prune）

struct ContainerPruneRequest: Encodable {
    let taskID: String
    let pruneType: String  // container / image
    let withTagAll: Bool
}

// MARK: - 单容器操作请求（POST /containers/operate）

struct ContainerOperateRequest: Encodable {
    let names: [String]
    let operation: String  // stop / start / restart / kill
    let taskID: String
}

// MARK: - 按镜像查询容器（POST /containers/list/byimage）

struct ContainerByImageRequest: Encodable {
    let name: String
}

struct ContainerByImageItem: Decodable {
    let name: String?
    let state: String?
}

// MARK: - 容器升级请求（POST /containers/upgrade）

struct ContainerUpgradeRequest: Encodable {
    let taskID: String
    let names: [String]
    let image: String
    let forcePull: Bool
}

// MARK: - 镜像（GET /containers/image/all）

struct ContainerImage: Decodable, Identifiable {
    let id: String
    let createdAt: String?
    let isUsed: Bool?
    let tags: [String]?
    let size: Int64?
    let isPinned: Bool?
    let description: String?

    /// 展示名（取第一个 tag，否则截断 id）
    var displayName: String {
        if let tag = tags?.first, !tag.isEmpty { return tag }
        return String(id.dropFirst("sha256:".count).prefix(12))
    }

    /// 体积展示
    var sizeDisplay: String {
        formatImageSize(size ?? 0)
    }

    private func formatImageSize(_ bytes: Int64) -> String {
        let f = Double(bytes)
        if f > 1_073_741_824 { return String(format: "%.2f GB", f / 1_073_741_824) }
        if f > 1_048_576 { return String(format: "%.2f MB", f / 1_048_576) }
        if f > 1024 { return String(format: "%.2f KB", f / 1024) }
        return "\(bytes) B"
    }
}

// MARK: - 容器详情配置（POST /containers/info）

/// 容器网络挂载信息（info.networks）
struct ContainerNetworkInfo: Codable {
    var network: String
    var ipv4: String?
    var ipv6: String?
    var macAddr: String?
}

/// 容器端口映射（info.exposedPorts）
struct ContainerPortInfo: Codable {
    var hostIP: String
    var hostPort: String
    var containerPort: String
    var protocolField: String

    enum CodingKeys: String, CodingKey {
        case hostIP, hostPort, containerPort
        case protocolField = "protocol"
    }
}

/// 容器卷映射（info.volumes）
struct ContainerVolumeInfo: Codable {
    var type: String
    var sourceDir: String
    var containerDir: String
    var mode: String
    var shared: String
}

/// 容器完整配置（POST /containers/info 返回）
/// 字段名严格对齐 1Panel v2 返回；多数字段用于回写 update 接口
struct ContainerInfo: Decodable {
    let taskID: String?
    let forcePull: Bool?
    let name: String
    let image: String
    let hostname: String?
    let domainName: String?
    let dns: [String]?
    let networks: [ContainerNetworkInfo]?
    let publishAllPorts: Bool?
    let exposedPorts: [ContainerPortInfo]?
    let tty: Bool?
    let openStdin: Bool?
    let workingDir: String?
    let user: String?
    let cmd: [String]?
    let entrypoint: [String]?
    let cpuShares: Int?
    let nanoCPUs: Double?
    let memory: Int64?
    let privileged: Bool?
    let autoRemove: Bool?
    let volumes: [ContainerVolumeInfo]?
    let labels: [String]?
    let env: [String]?
    let restartPolicy: String?
}

// MARK: - 镜像选项（GET /containers/image 返回 [{option:"..."}]）

struct ContainerOption: Decodable {
    let option: String
}

// MARK: - 更新端口（update.exposedPorts 比 info 多 host 字段）

struct ContainerUpdatePort: Encodable {
    let hostIP: String
    let hostPort: String
    let containerPort: String
    let protocolField: String
    let host: String

    enum CodingKeys: String, CodingKey {
        case hostIP, hostPort, containerPort
        case protocolField = "protocol"
        case host
    }
}

// MARK: - 更新容器请求（POST /containers/update）

struct ContainerUpdateRequest: Encodable {
    let taskID: String
    let name: String
    let image: String
    let imageInput: Bool
    let forcePull: Bool
    let networks: [ContainerNetworkInfo]
    let hostname: String
    let domainName: String
    let dns: [String]
    let cmdStr: String
    let entrypointStr: String
    let memoryItem: Int
    let cmd: [String]
    let workingDir: String
    let user: String
    let openStdin: Bool
    let tty: Bool
    let entrypoint: [String]
    let publishAllPorts: Bool
    let exposedPorts: [ContainerUpdatePort]
    let nanoCPUs: Double
    let cpuShares: Int
    let memory: Int64
    let volumes: [ContainerVolumeInfo]
    let privileged: Bool
    let autoRemove: Bool
    let labels: [String]
    let env: [String]
    let restartPolicy: String
}
