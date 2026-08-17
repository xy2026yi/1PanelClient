//
//  BackupModels.swift
//  1PanelClient
//
//  备份模块模型：应用 / 网站 / MySQL / MongoDB / PostgreSQL 备份
//  接口字段通过 logs/0817_修改与新增-2.md 抓包验证
//

import Foundation
import SwiftUI

// MARK: - 备份目标

/// 备份目标：把各详情页（应用/网站/数据库）的差异收敛为 type + name + detailName 三元组
/// - 应用：type="app"，name/detailName 均为安装名
/// - 网站：type="website"，name/detailName 均为主域名
/// - 数据库：type 为服务类型（mysql/mariadb/mongodb/postgresql），
///   name 为服务名（system.database），detailName 为数据库名
nonisolated struct BackupTarget {
    let type: String
    let name: String
    let detailName: String

    var isMySQLFamily: Bool {
        let t = type.lowercased()
        return t == "mysql" || t == "mariadb" || t == "mysql-cluster"
    }

    var isMongoDB: Bool { type.lowercased() == "mongodb" }
    var isPostgreSQL: Bool { type.lowercased() == "postgresql" }
    var isDatabase: Bool { isMySQLFamily || isMongoDB || isPostgreSQL }

    /// 数据库备份目标：type 为服务类型（cluster 变体归并为基础类型），
    /// name 为服务名（如 "mysql"），detailName 为数据库名（如 "YcHOX"）
    static func database(serviceType: String, serviceName: String, databaseName: String) -> BackupTarget {
        let t = serviceType.lowercased()
        let base: String
        switch t {
        case "mysql", "mysql-cluster":   base = "mysql"
        case "mariadb":                  base = "mariadb"
        case "postgresql", "postgresql-cluster": base = "postgresql"
        case "mongodb", "mongodb-cluster":      base = "mongodb"
        default:                         base = serviceType
        }
        return BackupTarget(type: base, name: serviceName, detailName: databaseName)
    }
}

// MARK: - 备份记录

/// 备份记录（POST /backups/record/search 返回的 items 元素）
nonisolated struct BackupRecord: Decodable, Identifiable, Equatable {
    let id: Int
    let createdAt: String?
    let accountType: String?
    let accountName: String?
    let downloadAccountID: Int?
    let fileDir: String?
    let fileName: String?
    let taskID: String?
    let status: String?
    let message: String?
    let description: String?

    /// 创建时间格式化（yyyy-MM-dd HH:mm）
    var displayCreatedAt: String {
        guard let t = createdAt, !t.isEmpty else { return "—" }
        return String(t.prefix(19)).replacingOccurrences(of: "T", with: " ")
    }

    /// 恢复用完整相对路径（fileDir/fileName）
    var fullPath: String {
        let dir = fileDir ?? ""
        let file = fileName ?? ""
        if dir.isEmpty { return file }
        return dir.hasSuffix("/") ? dir + file : dir + "/" + file
    }

    var statusColor: Color {
        switch (status ?? "").lowercased() {
        case "success": return .green
        case "failed":  return .red
        default:        return .orange
        }
    }
}

/// 备份记录分页查询请求（同时用于 record/size）
nonisolated struct BackupRecordSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let type: String
    let name: String
    let detailName: String
}

/// 备份记录分页响应
nonisolated struct BackupRecordListResponse: Decodable {
    let total: Int
    let items: [BackupRecord]?
}

/// 备份文件大小项（POST /backups/record/size 返回）
nonisolated struct BackupRecordSizeItem: Decodable {
    let id: Int
    let name: String?
    let size: Int64?
}

// MARK: - 备份操作请求

/// 创建备份（POST /backups/backup）
/// args：MySQL 系备份参数（与计划任务备份 MySQL 的参数一致）
nonisolated struct BackupCreateRequest: Encodable {
    let type: String
    let name: String
    let detailName: String
    var secret: String = ""
    let taskID: String
    var description: String = ""
    var args: [String] = []
    var stopBefore: Bool = false
}

/// 恢复备份（POST /backups/recover）
/// timeout：秒；dropAllCollections：MongoDB 恢复前清空当前数据库
nonisolated struct BackupRecoverRequest: Encodable {
    let downloadAccountID: Int
    let type: String
    let name: String
    let detailName: String
    let file: String
    var secret: String = ""
    let taskID: String
    let backupRecordID: Int
    let timeout: Int
    var dropAllCollections: Bool = false
}

/// 删除备份记录（POST /backups/record/del）
nonisolated struct BackupRecordDeleteRequest: Encodable {
    let ids: [Int]
    let node: String
}

/// 获取备份文件下载路径（POST /backups/record/download）
nonisolated struct BackupRecordDownloadRequest: Encodable {
    let downloadAccountID: Int
    let fileDir: String
    let fileName: String
}

// MARK: - 大小格式化

/// 备份大小展示：单位最低 KB（字节按 1024 进位）
nonisolated enum BackupSizeFormatter {
    static func format(_ bytes: Int64?) -> String {
        guard let bytes, bytes >= 0 else { return "—" }
        let kb = Double(bytes) / 1024
        if kb < 1 { return "1 KB" }
        if kb < 1024 { return String(format: "%.2f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.2f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }
}
