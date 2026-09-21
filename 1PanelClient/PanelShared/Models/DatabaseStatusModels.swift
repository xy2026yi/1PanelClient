//
//  DatabaseStatusModels.swift
//  1PanelClient
//
//  MySQL 状态 / 系统变量（logs/MySQL 状态抓包 2026-09-14）：
//  status / variables 均返回 [String:String]；展示层指标（QPS、命中率等）
//  按网页端口径在客户端计算（用户抓包注释确认的映射）
//

import Foundation

/// POST /databases/status 与 /databases/variables 共用请求 {type,name}
/// type：mysql / mariadb；name：服务名（DatabaseSystem.database，如 "mysql"）
nonisolated struct DatabaseStatusRequest: Encodable {
    let type: String
    let name: String
}

/// SHOW STATUS 指标的展示口径（网页端「基础参数 / 性能参数」映射，抓包注释确认）：
/// - 每秒查询 = Questions / Uptime
/// - 每秒事务 = (Com_commit + Com_rollback) / Uptime
/// - 线程缓存命中率 = 1 - Threads_created / Connections
/// - 索引命中率 = 1 - Key_reads / Key_read_requests
/// - Innodb 索引命中率 = 1 - Innodb_buffer_pool_reads / Innodb_buffer_pool_read_requests
/// - 查询缓存命中率 = Qcache_hits / (Qcache_hits + Qcache_inserts)（MySQL 8 已移除，空值显示 —）
nonisolated enum MySQLStatusMetrics {

    static func number(_ dict: [String: String], _ key: String) -> Double? {
        guard let raw = dict[key], let v = Double(raw) else { return nil }
        return v
    }

    /// 两个数值相除（分母非正/缺失返回 nil）
    static func ratio(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b, b > 0 else { return nil }
        return a / b
    }

    /// "xx.xx%"（nil → 调用方显示 —）
    static func percent(_ dict: [String: String], _ key: String) -> String {
        guard let v = number(dict, key) else { return "—" }
        return String(format: "%.2f%%", v)
    }

    // MARK: 基础参数

    static func qps(_ dict: [String: String]) -> String {
        guard let v = ratio(number(dict, "Questions"), number(dict, "Uptime")) else { return "—" }
        return String(format: "%.2f", v)
    }

    static func tps(_ dict: [String: String]) -> String {
        let commit = number(dict, "Com_commit") ?? 0
        let rollback = number(dict, "Com_rollback") ?? 0
        guard let v = ratio(commit + rollback, number(dict, "Uptime")) else { return "—" }
        return String(format: "%.2f", v)
    }

    // MARK: 性能参数（命中率类）

    /// 线程缓存命中率
    static func threadCacheHitRate(_ dict: [String: String]) -> String {
        let created = number(dict, "Threads_created")
        let connections = number(dict, "Connections")
        guard let connections, connections > 0 else { return "—" }
        return String(format: "%.2f%%", max(0, (1 - (created ?? 0) / connections)) * 100)
    }

    /// 索引命中率（Key 缓存）
    static func keyHitRate(_ dict: [String: String]) -> String {
        let reads = number(dict, "Key_reads")
        let requests = number(dict, "Key_read_requests")
        guard let requests, requests > 0 else { return "—" }
        return String(format: "%.2f%%", max(0, (1 - (reads ?? 0) / requests)) * 100)
    }

    /// Innodb 缓冲池命中率
    static func innodbHitRate(_ dict: [String: String]) -> String {
        let reads = number(dict, "Innodb_buffer_pool_reads")
        let requests = number(dict, "Innodb_buffer_pool_read_requests")
        guard let requests, requests > 0 else { return "—" }
        return String(format: "%.2f%%", max(0, (1 - (reads ?? 0) / requests)) * 100)
    }

    /// 查询缓存命中率（Qcache 空串 = MySQL 8 已移除查询缓存 → —）
    static func queryCacheHitRate(_ dict: [String: String]) -> String {
        guard let hits = number(dict, "Qcache_hits"),
              let inserts = number(dict, "Qcache_inserts"),
              hits + inserts > 0 else { return "—" }
        return String(format: "%.2f%%", hits / (hits + inserts) * 100)
    }

    // MARK: 展示行定义

    /// 基础参数行（key → 取值）
    static func basicRows(_ dict: [String: String]) -> [(String, String)] {
        [
            ("启动时间", dict["Run"] ?? "—"),
            ("总连接数", dict["Connections"] ?? "—"),
            ("发送", dict["Bytes_sent"] ?? "—"),
            ("接收", dict["Bytes_received"] ?? "—"),
            ("每秒查询", qps(dict)),
            ("每秒事务", tps(dict)),
            ("File", dict["File"] ?? "—"),
            ("Position", dict["Position"] ?? "—"),
        ]
    }

    /// 性能参数行
    static func performanceRows(_ dict: [String: String]) -> [(String, String)] {
        [
            ("每秒查询", qps(dict)),
            ("线程缓存命中率", threadCacheHitRate(dict)),
            ("索引命中率", keyHitRate(dict)),
            ("Innodb索引命中率", innodbHitRate(dict)),
            ("查询缓存命中率", queryCacheHitRate(dict)),
            ("创建临时表到磁盘", dict["Created_tmp_disk_tables"] ?? "—"),
            ("已打开表", dict["Open_tables"] ?? "—"),
            ("没有使用索引的量", dict["Select_full_join"] ?? "—"),
            ("没有索引的JOIN量", dict["Select_range_check"] ?? "—"),
            ("排序后的合并次数", dict["Sort_merge_passes"] ?? "—"),
            ("锁表次数", dict["Table_locks_waited"] ?? "—"),
        ]
    }
}

/// SHOW VARIABLES 展示：按网页端顺序排列常用变量，其余按字典序追加；
/// 字节类变量做单位换算，开关类原样（ON/OFF）
nonisolated enum MySQLVariablesDisplay {    /// 网页端参数页顺序（抓包返回键序）
    static let orderedKeys: [String] = [
        "binlog_cache_size", "innodb_buffer_pool_size", "innodb_log_buffer_size",
        "join_buffer_size", "key_buffer_size", "max_connections", "max_heap_table_size",
        "query_cache_size", "query_cache_type", "read_buffer_size", "read_rnd_buffer_size",
        "sort_buffer_size", "table_open_cache", "thread_cache_size", "thread_stack",
        "tmp_table_size", "slow_query_log", "long_query_time",
    ]

    /// 字节单位键（换算 B/KB/MB/GB）
    static let byteKeys: Set<String> = [
        "binlog_cache_size", "innodb_buffer_pool_size", "innodb_log_buffer_size",
        "join_buffer_size", "key_buffer_size", "max_heap_table_size", "query_cache_size",
        "read_buffer_size", "read_rnd_buffer_size", "sort_buffer_size", "thread_stack",
        "tmp_table_size",
    ]

    /// 排序后的展示键序（常用在前，其余按字典序追加）
    static func displayKeys(_ dict: [String: String]) -> [String] {
        let known = orderedKeys.filter { dict[$0] != nil }
        let rest = dict.keys.filter { !orderedKeys.contains($0) }.sorted()
        return known + rest
    }

    /// 值格式化（字节换算；空串 → —）
    static func value(_ key: String, _ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "—" }
        if byteKeys.contains(key), let bytes = Double(raw) {
            return fmtBytes(bytes)
        }
        return raw
    }

    static func fmtBytes(_ bytes: Double) -> String {
        var size = bytes
        var idx = 0
        let units = ["B", "KB", "MB", "GB"]
        while size >= 1024 && idx < units.count - 1 {
            size /= 1024
            idx += 1
        }
        return String(format: "%.2f %@", size, units[idx])
    }
}

/// Redis INFO 状态展示口径（logs/Redis 状态抓包 2026-09-14）：
/// - used_memory / used_memory_rss / used_memory_peak 为字节 → MB
/// - 键命中率 hit = keyspace_hits / (keyspace_hits + keyspace_misses)
///   （网页端 0/0 显示 NaN，App 显示 —）
nonisolated enum RedisStatusMetrics {

    static func value(_ dict: [String: String], _ key: String) -> String {
        dict[key].flatMap { !$0.isEmpty ? $0 : nil } ?? "—"
    }

    /// 字节 → 可读单位（used_memory 1504088 → "1.43 MB"，抓包对照）
    static func bytes(_ dict: [String: String], _ key: String) -> String {
        guard let raw = dict[key], let v = Double(raw), !raw.isEmpty else { return "—" }
        return MySQLVariablesDisplay.fmtBytes(v)
    }

    /// 查找数据库键命中率（0/0 → —；网页端为 NaN）
    static func hitRate(_ dict: [String: String]) -> String {
        guard let hits = MySQLStatusMetrics.number(dict, "keyspace_hits"),
              let misses = MySQLStatusMetrics.number(dict, "keyspace_misses"),
              hits + misses > 0 else { return "—" }
        return String(format: "%.2f%%", hits / (hits + misses) * 100)
    }

    /// 基础参数行（网页端口径）
    static func basicRows(_ dict: [String: String]) -> [(String, String)] {
        [
            ("已运行天数", value(dict, "uptime_in_days")),
            ("当前监听端口", value(dict, "tcp_port")),
            ("连接的客户端数量", value(dict, "connected_clients")),
        ]
    }

    /// 性能参数行（网页端口径；内存三项换算 MB）
    static func performanceRows(_ dict: [String: String]) -> [(String, String)] {
        [
            ("向操作系统申请的内存大小", bytes(dict, "used_memory_rss")),
            ("当前 Redis 使用的内存大小", bytes(dict, "used_memory")),
            ("Redis 的内存消耗峰值", bytes(dict, "used_memory_peak")),
            ("内存碎片率", value(dict, "mem_fragmentation_ratio")),
            ("运行以来连接过的客户端的总数量", value(dict, "total_connections_received")),
            ("运行以来执行过的命令的总数量", value(dict, "total_commands_processed")),
            ("服务器每秒钟执行的命令数量", value(dict, "instantaneous_ops_per_sec")),
            ("查找数据库键成功的次数", value(dict, "keyspace_hits")),
            ("查找数据库键失败的次数", value(dict, "keyspace_misses")),
            ("查找数据库键命中率", hitRate(dict)),
            ("最近一次 fork() 操作耗费的微秒数", value(dict, "latest_fork_usec")),
        ]
    }
}

// MARK: - MySQL 性能调整 / 配置修改（抓包 2026-09-15）

/// POST /databases/variables/update {type,database,variables[]}
nonisolated struct DatabaseVariablesUpdateRequest: Encodable {
    let type: String
    let database: String
    let variables: [MySQLVariableItem]
}

/// 单个参数项（value 为数字：字节数 / 个数，抓包原样）
nonisolated struct MySQLVariableItem: Encodable {
    let param: String
    let value: Int
}

/// POST /databases/common/load/file {type:"<db>-conf",name}（读取当前配置文件）
nonisolated struct DatabaseConfFileRequest: Encodable {
    /// "<数据库类型>-conf"，如 mysql-conf
    let type: String
    let name: String
}

/// POST /databases/common/update/conf {type,database,file}（保存配置文件）
nonisolated struct DatabaseConfUpdateRequest: Encodable {
    /// 数据库类型（mysql / mariadb，不带 -conf 后缀）
    let type: String
    let database: String
    let file: String
}

/// POST /apps/installed/conf {type,name}（默认配置文件）
nonisolated struct AppInstalledConfRequest: Encodable {
    let type: String
    let name: String
}

/// 内存优化预设方案（1Panel 网页端口径；值为字节，个数为整数）
nonisolated struct MySQLTunePreset: Identifiable {
    let name: String
    let values: [String: Int]
    var id: String { name }
}

nonisolated enum MySQLTunePresets {
    /// 参数展示顺序（与网页端优化方案列表一致）
    static let paramOrder = [
        "key_buffer_size", "join_buffer_size", "tmp_table_size",
        "innodb_buffer_pool_size", "innodb_log_buffer_size",
        "sort_buffer_size", "read_buffer_size", "read_rnd_buffer_size",
        "thread_stack", "binlog_cache_size",
        "thread_cache_size", "table_open_cache", "max_connections",
    ]

    private static func MB(_ n: Int) -> Int { n * 1024 * 1024 }
    private static func KB(_ n: Int) -> Int { n * 1024 }

    static let all: [MySQLTunePreset] = [
        MySQLTunePreset(name: "1-2GB", values: [
            "key_buffer_size": MB(32), "join_buffer_size": KB(512), "tmp_table_size": MB(32),
            "innodb_buffer_pool_size": MB(64), "innodb_log_buffer_size": MB(64),
            "sort_buffer_size": KB(256), "read_buffer_size": KB(256), "read_rnd_buffer_size": KB(256),
            "thread_stack": KB(256), "binlog_cache_size": KB(64),
            "thread_cache_size": 64, "table_open_cache": 128, "max_connections": 100,
        ]),
        MySQLTunePreset(name: "2-4GB", values: [
            "key_buffer_size": MB(64), "join_buffer_size": KB(1024), "tmp_table_size": MB(64),
            "innodb_buffer_pool_size": MB(128), "innodb_log_buffer_size": MB(64),
            "sort_buffer_size": KB(512), "read_buffer_size": KB(512), "read_rnd_buffer_size": KB(512),
            "thread_stack": KB(256), "binlog_cache_size": KB(64),
            "thread_cache_size": 96, "table_open_cache": 192, "max_connections": 200,
        ]),
        MySQLTunePreset(name: "4-8GB", values: [
            "key_buffer_size": MB(128), "join_buffer_size": KB(2048), "tmp_table_size": MB(128),
            "innodb_buffer_pool_size": MB(256), "innodb_log_buffer_size": MB(64),
            "sort_buffer_size": KB(1024), "read_buffer_size": KB(1024), "read_rnd_buffer_size": KB(768),
            "thread_stack": KB(256), "binlog_cache_size": KB(128),
            "thread_cache_size": 128, "table_open_cache": 384, "max_connections": 300,
        ]),
        MySQLTunePreset(name: "8-16GB", values: [
            "key_buffer_size": MB(256), "join_buffer_size": KB(2048), "tmp_table_size": MB(256),
            "innodb_buffer_pool_size": MB(512), "innodb_log_buffer_size": MB(64),
            "sort_buffer_size": KB(1024), "read_buffer_size": KB(2048), "read_rnd_buffer_size": KB(1024),
            "thread_stack": KB(384), "binlog_cache_size": KB(192),
            "thread_cache_size": 192, "table_open_cache": 1024, "max_connections": 400,
        ]),
        MySQLTunePreset(name: "16-32GB", values: [
            "key_buffer_size": MB(1024), "join_buffer_size": KB(4096), "tmp_table_size": MB(1024),
            "innodb_buffer_pool_size": MB(1024), "innodb_log_buffer_size": MB(64),
            "sort_buffer_size": KB(4096), "read_buffer_size": KB(4096), "read_rnd_buffer_size": KB(2048),
            "thread_stack": KB(512), "binlog_cache_size": KB(256),
            "thread_cache_size": 256, "table_open_cache": 2048, "max_connections": 500,
        ]),
    ]

    /// 值展示：字节类参数换算 KB/MB，个数类原样
    static func displayValue(param: String, _ value: Int) -> String {
        switch param {
        case "thread_cache_size", "table_open_cache", "max_connections":
            return "\(value)"
        default:
            return MySQLVariablesDisplay.fmtBytes(Double(value))
        }
    }
}

// MARK: - Redis 性能调整（抓包 2026-09-15）

/// POST /databases/redis/conf {type,name} 响应
nonisolated struct RedisConf: Decodable {
    let database: String?
    let name: String?
    let port: Int?
    let containerName: String?
    /// 空闲连接超时（秒，字符串数字；0 = 不断开）
    let timeout: String?
    let maxclients: String?
    let requirepass: String?
    /// 最大内存（字节，字符串数字；0 = 不限制）
    let maxmemory: String?
}

/// POST /databases/redis/conf/update {dbType,database,timeout,maxclients,maxmemory}
/// （读取与保存的字段名不同：读 type/name，写 dbType/database；maxmemory 带 mb 后缀）
nonisolated struct RedisConfUpdateRequest: Encodable {
    let dbType: String
    let database: String
    let timeout: String
    let maxclients: String
    /// 数字 + kb/mb/gb 后缀（抓包 "0mb"；Redis memtoll 裸 m=10^6 与 mb=2^20 进制不同）
    let maxmemory: String
}
