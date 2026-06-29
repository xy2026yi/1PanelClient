//
//  Script.swift
//  1PanelClient
//
//  脚本库（POST /core/script/search），由计划任务右上角进入
//

import Foundation

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
