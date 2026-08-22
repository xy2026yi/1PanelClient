//
//  NodeModels.swift
//  1PanelClient
//
//  多机管理模型：节点列表 / 节点实时状态 / 添加节点（含可用性检查）
//  基于网页端抓包（logs/多机管理/多机管理-1.md、多机管理-节点管理-1.md、节点切换.md）
//

import Foundation
import SwiftUI

// MARK: - 节点实时状态（GET /api/v2/core/xpack/nodes/current）

nonisolated struct NodeCurrentItem: Codable {
    let nodeName: String
    let status: String?
    let message: String?
    let isOK: Bool?
    let cpuUsedPercent: Double?
    let cpuTotal: Int?
    let memoryTotal: Double?
    let memoryUsedPercent: Double?
}

// MARK: - 节点列表（POST /api/v2/core/nodes/list，body {"type":"all"}）

nonisolated struct NodeListRequest: Encodable {
    let type: String
}

nonisolated struct NodeListItem: Decodable, Identifiable, Hashable {
    let id: Int
    let groupID: Int?
    let groupBelong: String?
    let name: String
    let alias: String?
    let addr: String?
    let status: String?
    let isOffline: Bool?
    let version: String?
    let isXpack: Bool?
    let isBound: Bool?
    let isAutoUpgrade: Bool?
    let isFavorite: Bool?

    /// 展示名：优先别名，其次名称
    var displayName: String { alias?.isEmpty == false ? alias! : name }
}

// MARK: - 添加节点（POST /api/v2/core/xpack/nodes/test/byinfo 与 /api/v2/core/xpack/nodes）

/// 密码 / 私钥需 base64 编码后传输（对齐网页端 encodeBase64Fields 行为）
nonisolated struct AddNodeRequest: Encodable {
    var addr: String
    var port: Int
    var user: String
    /// password / key
    var authMode: String
    var password: String
    var privateKey: String
    var name: String
    var baseDir: String
    var nodePort: Int
    var isXpack: Bool
    /// 数据同步项，逗号拼接：SyncSystemProxy,SyncBackupAccounts,SyncAlertSetting,SyncCustomApp
    var syncList: String
    var licenseID: Int
    var groupID: Int
    var rememberPassword: Bool
    var description: String
    /// 仅创建时携带
    var withDockerRestart: Bool?
    /// 仅创建时携带（客户端生成 UUID，供任务日志轮询）
    var taskID: String?
}

/// 可用性检查结果（POST .../nodes/test/byinfo 响应）
nonisolated struct NodeTestResult: Decodable {
    let isConnOk: Bool?
    let isLicenseOk: Bool?
    let connMsg: String?
    let isCoreExist: Bool?
    let isAgentExist: Bool?
    let isPanelExist: Bool?
    let isDockerExist: Bool?
    let isSyncFromNode: Bool?
    let syncNodePort: String?
    let syncBaseDir: String?
    let isPortAvailable: Bool?
    let isSyncPortAvailable: Bool?
    let isRoot: Bool?
}

// MARK: - 节点详情（POST /api/v2/core/xpack/nodes/search，字段比 nodes/list 全）

nonisolated struct NodeSearchRequest: Encodable {
    var page: Int = 1
    var pageSize: Int = 100
}

nonisolated struct NodeDetailItem: Decodable, Identifiable, Hashable {
    let id: Int
    let createdAt: String?
    let groupID: Int?
    let groupBelong: String?
    let name: String
    let alias: String?
    let version: String?
    let addr: String?
    let port: Int?
    let user: String?
    let authMode: String?
    /// rememberPassword=true 时服务端返回明文密码，编辑提交时需 base64 回传
    let password: String?
    let privateKey: String?
    let passPhrase: String?
    let rememberPassword: Bool?
    let useProxy: Bool?
    let baseDir: String?
    let nodePort: Int?
    let licenseID: Int?
    let isXpack: Bool?
    let isBound: Bool?
    let license: String?
    let syncList: String?
    let syncStatus: String?
    let syncMessage: String?
    let status: String?
    let message: String?
    let isFavorite: Bool?
    let description: String?

    var displayName: String { alias?.isEmpty == false ? alias! : name }
}

/// 完整编辑节点（POST /api/v2/core/xpack/nodes/update）：
/// 网页端把 search 返回的完整对象 + 表单修改 + 运行状态一起回传
nonisolated struct NodeUpdateRequest: Encodable {
    var id: Int
    var createdAt: String?
    var groupID: Int
    var groupBelong: String?
    var name: String
    var alias: String?
    var version: String?
    var addr: String
    var port: Int
    var user: String
    var authMode: String
    /// base64
    var password: String
    /// base64
    var privateKey: String
    var passPhrase: String?
    var rememberPassword: Bool
    var useProxy: Bool?
    var baseDir: String
    var nodePort: Int
    var licenseID: Int
    var isXpack: Bool
    var isBound: Bool?
    var license: String?
    var syncList: String
    var syncStatus: String?
    var syncMessage: String?
    var status: String?
    var message: String?
    var isFavorite: Bool?
    var description: String
    // 以下为提交时附加的运行状态/任务字段
    var hasLoad: Bool?
    var isOK: Bool?
    var node: NodeCurrentItem?
    var withDockerRestart: Bool?
    var taskID: String?
}

/// 轻量改名称（POST /api/v2/core/xpack/nodes/update/base）：仅名称/分组/备注
nonisolated struct NodeUpdateBaseRequest: Encodable {
    let id: Int
    let name: String
    let isLocal: Bool
    let groupID: Int
    let description: String
}

// MARK: - 节点分组（POST /api/v2/core/groups/search {"type":"node"}）

nonisolated struct NodeGroupSearchRequest: Encodable {
    let type: String
}

nonisolated struct NodeGroup: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let type: String?
    let isDefault: Bool?
}

// MARK: - 同步 / 重启 / 更新记录

nonisolated struct NodeSyncRequest: Encodable {
    let id: Int
    let taskID: String
}

nonisolated struct NodeRestartRequest: Encodable {
    let id: Int
    /// "1panel" 重启面板 / "system" 重启服务器
    let restartService: String
}

/// 删除节点（POST /api/v2/core/xpack/nodes/del）
nonisolated struct NodeDeleteRequest: Encodable {
    let ids: [Int]
    /// 强制删除（节点异常/离线时仍移除）
    let force: Bool
    /// 同时删除节点数据（卸载节点上的 1Panel 服务）
    let withUninstall: Bool
}

nonisolated struct NodeUpgradeLogSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let nodeID: Int
}

nonisolated struct NodeUpgradeLogResponse: Decodable {
    let total: Int
    let items: [NodeUpgradeLogItem]?
}

/// 抓包无记录样本（items=null），字段全部可选、按需展示
nonisolated struct NodeUpgradeLogItem: Decodable, Identifiable {
    let id: Int?
    let version: String?
    let createdAt: String?
    let description: String?
    let message: String?
    let status: String?

    var uid: String { "\(id ?? 0)-\(createdAt ?? "")-\(version ?? "")" }
}

// MARK: - 许可证选项（POST /api/v2/core/licenses/options，添加专业版节点用）

nonisolated struct LicenseOption: Decodable, Identifiable {
    let id: Int
    let licenseName: String?
    let totalFreeCount: Int?
    /// 专业版可选余量（添加/编辑节点选「专业版」时按此过滤）
    let availableXpackCount: Int?
    /// 社区版可选余量（选「社区版」时按此过滤）
    let availableFreeCount: Int?

    var displayName: String { licenseName?.isEmpty == false ? licenseName! : "#\(id)" }
}

// MARK: - 数据同步项

/// 添加节点时的数据同步选项（对应 syncList 的各分段）
nonisolated struct NodeSyncOption: Identifiable {
    let key: String
    let title: String
    var id: String { key }

    /// 抓包中的全量默认（网页端默认全开）
    static let all: [NodeSyncOption] = [
        NodeSyncOption(key: "SyncSystemProxy", title: L10n.t("系统代理")),
        NodeSyncOption(key: "SyncBackupAccounts", title: L10n.t("备份账号")),
        NodeSyncOption(key: "SyncAlertSetting", title: L10n.t("告警设置")),
        NodeSyncOption(key: "SyncCustomApp", title: L10n.t("自定义应用")),
    ]
}

// MARK: - 节点展示辅助

/// 节点状态文案/颜色（nodes/current 与 nodes/list 的 status：Healthy / UnHealthy / …）
enum NodeUI {
    static func statusColor(_ status: String?) -> Color {
        switch status ?? "" {
        case "Healthy": return .green
        case "UnHealthy": return .red
        default: return .secondary
        }
    }

    static func statusText(_ status: String?) -> String {
        switch status ?? "" {
        case "Healthy": return L10n.t("健康")
        case "UnHealthy": return L10n.t("异常")
        case "": return L10n.t("未知")
        default: return status ?? "—"
        }
    }
}
