//
//  DatabaseStatusModelsTests.swift
//  1PanelClientTests
//
//  MySQL 状态/变量模型测试（样本取自 logs/MySQL 状态抓包 2026-09-14）：
//  请求编码 · 基础/性能指标口径（QPS/TPS/命中率）· 变量字节换算
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("MySQL 状态与参数")
struct DatabaseStatusModelsTests {

    /// 抓包 status 全量样本
    private var status: [String: String] {
        [
            "Aborted_clients": "0", "Aborted_connects": "0",
            "Bytes_received": "1823", "Bytes_sent": "33916",
            "Com_commit": "0", "Com_rollback": "0", "Connections": "13",
            "Created_tmp_disk_tables": "0", "Created_tmp_tables": "3",
            "Innodb_buffer_pool_pages_dirty": "0",
            "Innodb_buffer_pool_read_requests": "15744", "Innodb_buffer_pool_reads": "846",
            "Key_read_requests": "0", "Key_reads": "0",
            "Key_write_requests": "0", "Key_writes": "0",
            "Max_used_connections": "1", "Open_tables": "58",
            "Opened_files": "2", "Opened_tables": "139",
            "Qcache_hits": "", "Qcache_inserts": "", "Questions": "23",
            "Select_full_join": "0", "Select_range_check": "0",
            "Sort_merge_passes": "0", "Table_locks_waited": "0",
            "Threads_cached": "0", "Threads_connected": "1",
            "Threads_created": "1", "Threads_running": "2",
            "Uptime": "630", "Run": "2026-09-14 19:51:58",
            "File": "binlog.000003", "Position": "158",
        ]
    }

    @Test("请求编码 {type,name}")
    func encodeRequest() throws {
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            DatabaseStatusRequest(type: "mysql", name: "mysql"))) as? [String: Any])
        #expect(obj["type"] as? String == "mysql")
        #expect(obj["name"] as? String == "mysql")
    }

    @Test("基础参数口径（QPS=Questions/Uptime、直取项）")
    func basicMetrics() {
        let rows = MySQLStatusMetrics.basicRows(status)
        let map = Dictionary(uniqueKeysWithValues: rows)
        #expect(map["启动时间"] == "2026-09-14 19:51:58")
        #expect(map["总连接数"] == "13")
        #expect(map["发送"] == "33916")
        #expect(map["接收"] == "1823")
        #expect(map["File"] == "binlog.000003")
        #expect(map["Position"] == "158")
        // 23/630 = 0.0365…
        #expect(map["每秒查询"] == "0.04")
        // (0+0)/630 = 0
        #expect(map["每秒事务"] == "0.00")
    }

    @Test("性能参数口径（命中率公式与抓包注释一致）")
    func performanceMetrics() {
        let rows = MySQLStatusMetrics.performanceRows(status)
        let map = Dictionary(uniqueKeysWithValues: rows)
        // Innodb：1 - 846/15744 = 94.63%
        #expect(map["Innodb索引命中率"] == "94.63%")
        // MySQL 8 无 Qcache（空串）→ —
        #expect(map["查询缓存命中率"] == "—")
        // Key 缓存分母为 0 → —
        #expect(map["索引命中率"] == "—")
        // 线程缓存：1 - 1/13 = 92.31%
        #expect(map["线程缓存命中率"] == "92.31%")
        #expect(map["已打开表"] == "58")
        #expect(map["锁表次数"] == "0")
    }

    @Test("变量字节换算与键序（抓包样本）")
    func variablesDisplay() {
        let vars: [String: String] = [
            "innodb_buffer_pool_size": "134217728",
            "slow_query_log": "OFF",
            "long_query_time": "10.000000",
            "query_cache_size": "",
        ]
        #expect(MySQLVariablesDisplay.value("innodb_buffer_pool_size", vars["innodb_buffer_pool_size"]) == "128.00 MB")
        #expect(MySQLVariablesDisplay.value("slow_query_log", vars["slow_query_log"]) == "OFF")
        #expect(MySQLVariablesDisplay.value("query_cache_size", vars["query_cache_size"]) == "—")
        let keys = MySQLVariablesDisplay.displayKeys(vars)
        // 常用键在前，未知键按字典序追加
        #expect(keys.first == "innodb_buffer_pool_size")
        #expect(keys.last == "slow_query_log" || keys.contains("slow_query_log"))
        #expect(keys.count == 4)
    }

    // MARK: Redis（logs/Redis 状态抓包 2026-09-14）

    private var redisStatus: [String: String] {
        [
            "database": "", "tcp_port": "6379", "uptime_in_days": "0",
            "connected_clients": "1", "used_memory": "1504088",
            "used_memory_rss": "24322048", "used_memory_peak": "1952704",
            "mem_fragmentation_ratio": "16.37", "total_connections_received": "2",
            "total_commands_processed": "11", "instantaneous_ops_per_sec": "0",
            "keyspace_hits": "0", "keyspace_misses": "0", "latest_fork_usec": "0",
        ]
    }

    @Test("Redis 基础/性能参数口径（内存换算与网页端一致）")
    func redisMetrics() {
        let rows = RedisStatusMetrics.basicRows(redisStatus)
            + RedisStatusMetrics.performanceRows(redisStatus)
        let map = Dictionary(uniqueKeysWithValues: rows)
        #expect(map["已运行天数"] == "0")
        #expect(map["当前监听端口"] == "6379")
        #expect(map["连接的客户端数量"] == "1")
        // 字节换算（网页端 23.20 / 1.43 / 1.86 MB）
        #expect(map["向操作系统申请的内存大小"] == "23.20 MB")
        #expect(map["当前 Redis 使用的内存大小"] == "1.43 MB")
        #expect(map["Redis 的内存消耗峰值"] == "1.86 MB")
        #expect(map["内存碎片率"] == "16.37")
        // 0/(0+0)：网页端显示 NaN，App 显示 —
        #expect(map["查找数据库键命中率"] == "—")

        var withHits = redisStatus
        withHits["keyspace_hits"] = "8"
        withHits["keyspace_misses"] = "2"
        #expect(RedisStatusMetrics.hitRate(withHits) == "80.00%")
    }
}

@Suite("MySQL 性能调整与配置修改")
struct DatabaseMySQLTuneTests {

    private func encode(_ req: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(req)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @Test("优化参数应用编码 {type,database,variables[]}（抓包 2026-09-15）")
    func encodeVariablesUpdate() throws {
        let req = DatabaseVariablesUpdateRequest(
            type: "mysql", database: "mysql",
            variables: [
                MySQLVariableItem(param: "key_buffer_size", value: 33554432),
                MySQLVariableItem(param: "max_connections", value: 100),
            ])
        let obj = try encode(req)
        #expect(obj["type"] as? String == "mysql")
        #expect(obj["database"] as? String == "mysql")
        let vars = try #require(obj["variables"] as? [[String: Any]])
        #expect(vars.count == 2)
        #expect(vars[0]["param"] as? String == "key_buffer_size")
        #expect(vars[0]["value"] as? Int == 33554432)
    }

    @Test("配置文件请求编码（load/<db>-conf · update/conf · 默认配置）")
    func encodeConfRequests() throws {
        let load = try encode(DatabaseConfFileRequest(type: "mysql-conf", name: "mysql"))
        #expect(load["type"] as? String == "mysql-conf")
        #expect(load["name"] as? String == "mysql")

        let update = try encode(DatabaseConfUpdateRequest(
            type: "mysql", database: "mysql", file: "[mysqld]\nmax_connections=100\n"))
        #expect(update["type"] as? String == "mysql")
        #expect(update["database"] as? String == "mysql")
        #expect(update["file"] as? String == "[mysqld]\nmax_connections=100\n")

        let def = try encode(AppInstalledConfRequest(type: "mysql", name: "mysql"))
        #expect(def["type"] as? String == "mysql")
        #expect(def["name"] as? String == "mysql")
    }

    @Test("优化预设：5 档 × 13 参数，与网页端数值一致")
    func tunePresets() throws {
        #expect(MySQLTunePresets.all.count == 5)
        #expect(MySQLTunePresets.all.map(\.name) == ["1-2GB", "2-4GB", "4-8GB", "8-16GB", "16-32GB"])
        for preset in MySQLTunePresets.all {
            #expect(Set(preset.values.keys) == Set(MySQLTunePresets.paramOrder))
        }
        // 1-2GB 档锚定值（网页端口径）
        let low = MySQLTunePresets.all[0].values
        #expect(low["key_buffer_size"] == 32 * 1024 * 1024)
        #expect(low["innodb_buffer_pool_size"] == 64 * 1024 * 1024)
        #expect(low["join_buffer_size"] == 512 * 1024)
        #expect(low["binlog_cache_size"] == 64 * 1024)
        #expect(low["thread_cache_size"] == 64)
        #expect(low["table_open_cache"] == 128)
        #expect(low["max_connections"] == 100)
        // 16-32GB 档锚定值
        let high = MySQLTunePresets.all[4].values
        #expect(high["key_buffer_size"] == 1024 * 1024 * 1024)
        #expect(high["innodb_log_buffer_size"] == 64 * 1024 * 1024)
        #expect(high["thread_stack"] == 512 * 1024)
        #expect(high["max_connections"] == 500)
        // 档间单调性：buffer pool / 连接数随档位递增
        #expect(low["innodb_buffer_pool_size"]! < MySQLTunePresets.all[4].values["innodb_buffer_pool_size"]!)
        #expect(low["max_connections"]! < high["max_connections"]!)
    }

    @Test("预设值展示：字节换算 / 个数原样")
    func tuneDisplayValue() {
        #expect(MySQLTunePresets.displayValue(param: "key_buffer_size", 32 * 1024 * 1024) == "32.00 MB")
        #expect(MySQLTunePresets.displayValue(param: "binlog_cache_size", 64 * 1024) == "64.00 KB")
        #expect(MySQLTunePresets.displayValue(param: "max_connections", 100) == "100")
        #expect(MySQLTunePresets.displayValue(param: "table_open_cache", 128) == "128")
    }
}

@Suite("Redis 性能调整")
struct DatabaseRedisConfTests {

    private func encode(_ req: some Encodable) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as! [String: Any]
    }

    @Test("性能配置读取解码（抓包 2026-09-15 样本）")
    func decodeRedisConf() throws {
        let json = """
        {"database":"","name":"redis","port":6379,
         "containerName":"1Panel-redis-L9u5","timeout":"0",
         "maxclients":"10000","requirepass":"redis_e2H4RW","maxmemory":"0"}
        """.data(using: .utf8)!
        let conf = try JSONDecoder().decode(RedisConf.self, from: json)
        #expect(conf.timeout == "0")
        #expect(conf.maxclients == "10000")
        #expect(conf.maxmemory == "0")
        #expect(conf.port == 6379)
    }

    @Test("性能配置保存编码 {dbType,database,...}（读取 type/name 与保存 dbType/database 字段名不同）")
    func encodeRedisConfUpdate() throws {
        let obj = try encode(RedisConfUpdateRequest(
            dbType: "redis", database: "redis",
            timeout: "0", maxclients: "10000", maxmemory: "0mb"))
        #expect(obj["dbType"] as? String == "redis")
        #expect(obj["database"] as? String == "redis")
        #expect(obj["timeout"] as? String == "0")
        #expect(obj["maxclients"] as? String == "10000")
        #expect(obj["maxmemory"] as? String == "0mb")
    }

    @Test("maxmemory 字节↔MB 换算（非数字返回 nil，由调用方原样回传）")
    func maxmemoryConversion() {
        #expect(RedisConfUpdateRequest.mbFromBytes("0") == nil)
        #expect(RedisConfUpdateRequest.mbFromBytes(nil) == nil)
        #expect(RedisConfUpdateRequest.mbFromBytes("abc") == nil)
        #expect(RedisConfUpdateRequest.mbFromBytes("268435456") == 256)
        #expect(RedisConfUpdateRequest.mbFromBytes("1048576") == 1)
        #expect(RedisConfUpdateRequest.mbString(0) == "0mb")
        #expect(RedisConfUpdateRequest.mbString(512) == "512mb")
        #expect(RedisConfUpdateRequest.mbString(-3) == "0mb")
    }
}
