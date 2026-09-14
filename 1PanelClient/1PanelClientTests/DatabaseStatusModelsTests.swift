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
