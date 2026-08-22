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
