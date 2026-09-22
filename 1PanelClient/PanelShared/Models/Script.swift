//
//  Script.swift
//  1PanelClient
//
//  脚本库（POST /core/script/search），由计划任务右上角进入
//

import Foundation
import SwiftUI

/// 脚本库搜索请求
nonisolated struct ScriptSearchRequest: Encodable {
    let info: String
    let groupID: Int
    let page: Int
    let pageSize: Int
}

/// 创建脚本（POST /core/script；抓包 2026-09-22）：
/// groupList 数组与 groups 逗号串两个键都带；isInteractive 仅开时携带；
/// description 未配置省略
nonisolated struct ScriptCreateRequest: Encodable {
    let name: String
    let groupList: [Int]
    var isInteractive: Bool? = nil
    let script: String
    var description: String? = nil
    let groups: String
}

/// 删除脚本（系统脚本 isSystem=true 不可删）
nonisolated struct ScriptDeleteRequest: Encodable {
    let ids: [Int]
}

/// 编辑脚本（POST core/script/update；全量回传抓包 2026-09-22：
/// isInteractive 恒携带 bool、lable/createdAt/groupBelong 原样回传）
nonisolated struct ScriptUpdateRequest: Encodable {
    let id: Int
    let name: String
    let isInteractive: Bool
    let lable: String
    let script: String
    let groupList: [Int]
    let groupBelong: [String]
    let isSystem: Bool
    let description: String
    let createdAt: String
    let groups: String
}

/// 脚本库列表项（/core/script/search 返回 items）
nonisolated struct ScriptItem: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let isInteractive: Bool?
    let lable: String?
    let script: String?
    let isSystem: Bool?
    let description: String?
    let createdAt: String?
    /// 所属分组（id 数组与名称数组；编辑全量回传用，列表未返回时为 nil）
    let groupList: [Int]?
    let groupBelong: [String]?

    /// name/description 可能是 1Panel i18n 映射字符串（"{en:..., zh-hant:...}"），解析为中文
    var displayName: String { resolveI18n(name) }
    var displayDescription: String? { description.map { resolveI18n($0) } }
}

// MARK: - 脚本风险评估（客户端关键字评估，服务端无风险字段）

enum ScriptRisk {
    case low, medium, high

    var label: String {
        switch self {
        case .low:    return L10n.t("低风险")
        case .medium: return L10n.t("中风险")
        case .high:   return L10n.t("高风险")
        }
    }

    var color: Color {
        switch self {
        case .low:    return .statusRunning
        case .medium: return .semanticWarning
        case .high:   return .statusError
        }
    }
}

extension ScriptItem {
    /// 高风险：不可逆的破坏性命令（递归删除/磁盘写入/关机重启）
    /// 中风险：删除/终止进程/权限修改/网络下载直接执行
    static let highRiskPatterns = [
        "rm -rf", "rm -fr", " mkfs", "dd if=", "dd of=/dev/", "shutdown", "reboot", "init 0", "init 6", "halt"
    ]
    static let mediumRiskPatterns = [
        "rm ", "kill ", "killall", "chmod 777", "chown ", "systemctl stop", "systemctl disable",
        "curl ", "wget ", "| sh", "| bash", "yum remove", "apt remove", "apt-get remove"
    ]

    var riskLevel: ScriptRisk {
        guard let code = script?.lowercased(), !code.isEmpty else { return .low }
        if Self.highRiskPatterns.contains(where: { code.contains($0) }) { return .high }
        if Self.mediumRiskPatterns.contains(where: { code.contains($0) }) { return .medium }
        return .low
    }
}

// MARK: - 脚本库同步

/// POST /api/v2/core/script/sync：立即同步系统脚本库（异步任务，进度走任务日志）
nonisolated struct ScriptSyncRequest: Encodable {
    let taskID: String
}

/// POST /api/v2/core/settings/update：更新面板设置项 {key, value}
nonisolated struct CoreSettingUpdateRequest: Encodable {
    let key: String
    let value: String
}
