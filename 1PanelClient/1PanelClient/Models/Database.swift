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
nonisolated struct DatabaseSystem: Decodable, Identifiable, Hashable {
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
nonisolated struct AppInstallCheck: Decodable {
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
nonisolated struct ConnInfo: Decodable {
    let status: String?
    let username: String?
    let password: String?
    let containerName: String?
    let serviceName: String?
    let port: Int?
}

// MARK: - 数据库条目（search 结果）

/// POST /api/v2/databases/search 或 /api/v2/databases/pg/search 返回的 items
nonisolated struct DatabaseItem: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let from: String?
    let type: String?
    let database: String?
    let postgresqlName: String?   // PG 专用（替代 database）
    let format: String?
    let collation: String?
    let username: String?
    let password: String?
    let permission: String?       // MySQL: "%" = 所有人 / "ip" = 指定IP
    let permissionIPs: String?
    let superUser: Bool?          // PG 专用
    let isDelete: Bool?
    let description: String?
    let createdAt: String?

    /// 统一的服务名（PG 用 postgresqlName，MySQL 用 database）
    var databaseName: String {
        postgresqlName ?? database ?? ""
    }

    /// 是否为超级用户（PG）
    var isSuperUser: Bool {
        superUser ?? false
    }

    /// 权限显示文本
    var permissionDisplay: String {
        if superUser != nil {
            return isSuperUser ? "超级用户" : "普通用户"
        }
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
nonisolated struct FormatOption: Decodable, Identifiable, Hashable {
    let format: String
    let collations: [String]
    var id: String { format }
}

// MARK: - 请求体

nonisolated struct AppCheckRequest: Encodable {
    let key: String
    let name: String
}

nonisolated struct AppOpRequest: Encodable {
    let installId: Int
    let operate: String
}

nonisolated struct ConnInfoRequest: Encodable {
    let type: String
    let name: String
}

nonisolated struct DBSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let database: String
    let orderBy: String
    let order: String
}

nonisolated struct FormatOptionsRequest: Encodable {
    let name: String
}

nonisolated struct CreateDBRequest: Encodable {
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

nonisolated struct DelCheckRequest: Encodable {
    let id: Int
    let type: String
    let database: String
}

nonisolated struct DelDBRequest: Encodable {
    let id: Int
    let type: String
    let database: String
    let deleteBackup: Bool
    let forceDelete: Bool
}

nonisolated struct ChangeAccessRequest: Encodable {
    let id: Int
    let from: String
    let type: String
    let database: String
    let value: String
}

nonisolated struct ChangePasswordRequest: Encodable {
    let id: Int
    let from: String
    let type: String
    let database: String
    let value: String           // base64
}

// MARK: - PostgreSQL 专用请求体

nonisolated struct CreatePGDBRequest: Encodable {
    let name: String
    let from: String
    let type: String
    let database: String
    let format: String
    let username: String
    let password: String        // base64
    let superUser: Bool
    let description: String
}

nonisolated struct PGPrivilegesRequest: Encodable {
    let name: String
    let database: String
    let username: String
    let superUser: Bool
}

// MARK: - MySQL 用户与授权

/// POST /api/v2/databases/users/search 返回的数据库用户
nonisolated struct DatabaseUser: Decodable, Identifiable, Hashable {
    let username: String?
    let host: String?
    let password: String?
    let description: String?
    let isDelete: Bool?

    var id: String {
        "\(username ?? "")@\(host ?? "")"
    }

    var displayName: String {
        "\(username ?? "-")@\(host ?? "-")"
    }
}

/// POST /api/v2/databases/grants/search 返回的用户-数据库授权关系
nonisolated struct DatabaseGrant: Decodable, Hashable {
    let database: String?
    let username: String?
    let host: String?
}

/// 用户查询请求（{database: "mysql"}）
nonisolated struct DBUsersRequest: Encodable {
    let database: String
}

/// 创建用户请求
nonisolated struct CreateDBUserRequest: Encodable {
    let database: String
    let username: String
    let host: String
    let password: String        // base64
    let description: String
    let dbs: [String]
}

/// 删除用户请求
nonisolated struct DeleteDBUserRequest: Encodable {
    let database: String
    let username: String
    let host: String
}

/// 修改用户权限/描述请求
nonisolated struct UpdateDBUserRequest: Encodable {
    let database: String
    let username: String
    let host: String
    let newHost: String
    let description: String
}

/// 修改用户密码请求
nonisolated struct ChangeDBUserPasswordRequest: Encodable {
    let database: String
    let username: String
    let host: String
    let password: String        // base64
}

/// 增加/移除关联数据库请求
nonisolated struct DBGrantRequest: Encodable {
    let database: String
    let db: String
    let username: String
    let host: String
}

// MARK: - Redis 专用请求体

nonisolated struct RedisPasswordRequest: Encodable {
    let database: String
    let value: String           // base64
}
