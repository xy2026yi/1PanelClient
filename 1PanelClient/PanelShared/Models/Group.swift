//
//  Group.swift
//  1PanelClient
//
//  分组（网站 / 计划任务 / 脚本库共用）：
//  agent 与 core 的 GroupInfo/GroupCreate/GroupUpdate DTO 逐字段一致，
//  仅路径不同（网站走 /api/v2/groups，计划任务与脚本走 /api/v2/core/groups），
//  见 logs/分组与类别.md 与 1Panel 源码 core/app/dto/group.go
//

import Foundation

// MARK: - 模型

/// 分组项（response.GroupInfo）
nonisolated struct PanelGroup: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let type: String?
    let isDefault: Bool?
}

extension PanelGroup {
    /// 展示名：面板内置的 Default 分组随 App 语言本地化（中文显示「默认」）。
    /// 仅用于界面展示——重命名/删除等请求仍提交原始 name。
    var displayName: String {
        if name == "Default" { return L10n.t("默认") }
        return name ?? "—"
    }
}

// MARK: - 请求

/// 分组查询（POST /groups/search 或 /core/groups/search）
nonisolated struct GroupSearchRequest: Encodable {
    let type: String
}

/// 分组创建（POST /groups 或 /core/groups）
nonisolated struct GroupCreateRequest: Encodable {
    var id: Int = 0
    var name: String
    var type: String
}

/// 分组更新（POST /groups/update 或 /core/groups/update；isDefault=true 即「设为默认」）
nonisolated struct GroupUpdateRequest: Encodable {
    var id: Int
    var name: String
    var type: String
    var isDefault: Bool
}

/// 分组删除（POST /groups/del 或 /core/groups/del）
nonisolated struct GroupDeleteRequest: Encodable {
    let id: Int
}

// MARK: - 分组范围

/// 分组所属模块：决定请求走 agent(/api/v2/groups) 还是 core(/api/v2/core/groups) 两套同构端点
enum GroupScope {
    /// 网站分组：/api/v2/groups，type=website
    case website
    /// 计划任务分组：/api/v2/core/groups，type=cronjob
    case cronjob
    /// 脚本库分组：/api/v2/core/groups，type=script
    case script

    var type: String {
        switch self {
        case .website: return "website"
        case .cronjob: return "cronjob"
        case .script:  return "script"
        }
    }

    var searchPath: String {
        self == .website ? APIEndpoint.websitesGroupsSearch.path : APIEndpoint.coreGroupsSearch.path
    }

    var createPath: String {
        self == .website ? APIEndpoint.websitesGroupsCreate.path : APIEndpoint.coreGroupsCreate.path
    }

    var updatePath: String {
        self == .website ? APIEndpoint.websitesGroupsUpdate.path : APIEndpoint.coreGroupsUpdate.path
    }

    var deletePath: String {
        self == .website ? APIEndpoint.websitesGroupsDelete.path : APIEndpoint.coreGroupsDelete.path
    }
}
