//
//  Clean.swift
//  1PanelClient
//
//  缓存清理（/toolbox/scan + /toolbox/clean）：扫描返回树形可清理项，
//  清理提交勾选节点扁平列表 [{treeType, name, size}]
//

import Foundation

/// 扫描树节点（递归；size 为自身或子孙聚合字节数）
nonisolated struct CleanNode: Decodable, Identifiable, Hashable {
    let id: String
    let label: String?
    let children: [CleanNode]?
    /// 清理请求的 treeType（如 tmp_backup / system_log / unknown_backup / images）
    let type: String?
    /// 清理请求的 name（顶层类目为空串，文件/目录为绝对路径或文件名）
    let name: String?
    let size: Int64?
    /// 服务端预选（临时备份 / 当日系统日志默认勾选）
    let isCheck: Bool?
    let isRecommend: Bool?
    /// false = 该节点本身不可删（仅作分组；子节点可能可删）
    let canDelete: Bool?
}

/// POST /api/v2/toolbox/scan 返回 data
nonisolated struct CleanScanResponse: Decodable {
    let systemClean: [CleanNode]?
    let backupClean: [CleanNode]?
    let uploadClean: [CleanNode]?
    let downloadClean: [CleanNode]?
    let systemLogClean: [CleanNode]?
    let containerClean: [CleanNode]?
}

/// POST /api/v2/toolbox/clean 请求项（勾选节点扁平化，目录与文件逐层提交）
nonisolated struct CleanItem: Encodable {
    let treeType: String
    let name: String
    let size: Int64
}
