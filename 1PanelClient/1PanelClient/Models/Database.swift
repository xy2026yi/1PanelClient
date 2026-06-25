//
//  Database.swift
//  1PanelClient
//
//  数据库模块模型
//  MySQL / PostgreSQL / Redis
//

import Foundation

// MARK: - 数据库系统（已安装实例）

/// GET /api/v2/databases/db/list/<types> 返回的数据库系统
struct DatabaseSystem: Decodable, Identifiable, Hashable {
    let id: Int
    let type: String          // "mysql" / "postgresql" / "redis"
    let from: String          // "local"
    let database: String      // 服务名 "mysql" / "postgresql" / "redis"
    let version: String?
    let address: String?      // 容器内地址

    var displayName: String {
        switch type.lowercased() {
        case "mysql":           return "MySQL"
        case "mariadb":         return "MariaDB"
        case "mysql-cluster":   return "MySQL Cluster"
        case "postgresql":      return "PostgreSQL"
        case "postgresql-cluster": return "PostgreSQL Cluster"
        case "redis":           return "Redis"
        case "redis-cluster":   return "Redis Cluster"
        default:                return database
        }
    }

    var systemIcon: String {
        switch type.lowercased() {
        case "mysql", "mariadb", "mysql-cluster":         return "cylinder.split.1x2"
        case "postgresql", "postgresql-cluster":           return "cylinder"
        case "redis", "redis-cluster":                     return "server.rack"
        default:                                            return "cylinder"
        }
    }

    var systemColor: String {
        switch type.lowercased() {
        case "mysql", "mariadb", "mysql-cluster":         return "blue"
        case "postgresql", "postgresql-cluster":           return "indigo"
        case "redis", "redis-cluster":                     return "red"
        default:                                            return "purple"
        }
    }
}

// MARK: - 应用安装检查

/// POST /api/v2/apps/installed/check {key, name}
struct AppInstallCheck: Decodable {
    let isExist: Bool?
    let name: String?
    let app: String?
    let version: String?
    let status: String?          // "Running" / "Exited"
    let createdAt: String?
    let lastBackupAt: String?
    let appInstallId: Int?
    let containerName: String?
    let installPath: String?
    let httpPort: Int?
    let httpsPort: Int?
    let websiteDir: String?

    var isRunning: Bool { status?.lowercased() == "running" }
}

// MARK: - 连接信息

/// POST /api/v2/apps/installed/conninfo {type, name}
struct ConnInfo: Decodable {
    let status: String?
    let username: String?
    let password: String?
    let containerName: String?
    let serviceName: String?
    let port: Int?
}

// MARK: - 数据库条目（search 结果）

/// POST /api/v2/databases/search 或 /api/v2/databases/pg/search 返回的 items
struct DatabaseItem: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let from: String?
    let type: String?
    let database: String?
    let format: String?
    let collation: String?
    let username: String?
    let password: String?
    let permission: String?       // "%" = 所有人 / "ip" = 指定IP
    let permissionIPs: String?
    let description: String?
    let createdAt: String?

    /// 权限显示文本
    var permissionDisplay: String {
        let perm = permission ?? ""
        let ips = permissionIPs ?? ""
        if perm == "%" || perm.isEmpty {
            return ips.isEmpty ? "所有人(%)" : "指定IP"
        }
        return ips.isEmpty ? perm : ips
    }
}

// MARK: - 字符集 / 排序规则

/// POST /api/v2/databases/format/options {name}
struct FormatOption: Decodable, Identifiable, Hashable {
    let format: String
    let collations: [String]
    var id: String { format }
}

// MARK: - 请求体

struct AppCheckRequest: Encodable {
    let key: String
    let name: String
}

struct AppOpRequest: Encodable {
    let installId: Int
    let operate: String
}

struct ConnInfoRequest: Encodable {
    let type: String
    let name: String
}

struct DBSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let database: String
    let orderBy: String
    let order: String
}

struct FormatOptionsRequest: Encodable {
    let name: String
}

struct CreateDBRequest: Encodable {
    let name: String
    let from: String
    let type: String
    let database: String
    let format: String
    let collation: String
    let username: String
    let password: String        // base64
    let permission: String
    let permissionIPs: String
    let description: String
}

struct DelCheckRequest: Encodable {
    let id: Int
    let type: String
    let database: String
}

struct DelDBRequest: Encodable {
    let id: Int
    let type: String
    let database: String
    let deleteBackup: Bool
    let forceDelete: Bool
}

struct ChangeAccessRequest: Encodable {
    let id: Int
    let from: String
    let type: String
    let database: String
    let value: String
}

struct ChangePasswordRequest: Encodable {
    let id: Int
    let from: String
    let type: String
    let database: String
    let value: String           // base64
}
