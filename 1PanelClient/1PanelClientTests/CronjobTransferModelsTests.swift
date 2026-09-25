//
//  CronjobTransferModelsTests.swift
//  1PanelClientTests
//
//  计划任务导入导出模型测试（样本取自 logs/可选增加-2.md 抓包 2026-09-16）：
//  导出数组解码 / 形状未定字段（apps/dbName/sourceAccounts）透传 / 编码回传
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("计划任务导入导出模型")
struct CronjobTransferModelsTests {

    /// 抓包样本（null 字段原样）
    private static let capturedJSON = """
    [{"name":"echo","type":"shell","groupID":7,"specCustom":false,"spec":"30 1 3 * *",
      "executor":"","scriptMode":"input","script":"#!/bin/bash\\necho .","command":"",
      "containerName":"","user":"","url":"","scriptName":"","apps":null,"websites":null,
      "dbType":"mysql","dbName":null,"exclusionRules":"","isDir":true,"sourceDir":"",
      "retainCopies":7,"retryTimes":3,"timeout":3600,"ignoreErr":false,
      "snapshotRule":{"withImage":false,"ignoreApps":null},"secret":"","args":"",
      "sourceAccounts":null,"downloadAccount":"","alertCount":0,"alertTitle":"","alertMethod":""}]
    """

    @Test("导出数组解码（抓包样本，null 字段全兼容）")
    func decodeCapturedExport() throws {
        let items = try JSONDecoder().decode([CronjobTransferItem].self, from: Data(Self.capturedJSON.utf8))
        #expect(items.count == 1)
        let item = items[0]
        #expect(item.name == "echo")
        #expect(item.type == "shell")
        #expect(item.spec == "30 1 3 * *")
        #expect(item.retainCopies == 7)
        #expect(item.groupID == 7)
        #expect(item.snapshotRule?.withImage == false)
        #expect(item.apps == nil && item.dbName == nil && item.sourceAccounts == nil)
    }

    @Test("快照任务提交：snapshotRule 与顶层 withImage/ignoreAppIDs 双写（抓包形状）")
    func encodeSnapshotDoubleWrite() throws {
        var req = CronjobCreateRequest()
        req.type = "snapshot"
        req.withImage = true
        req.ignoreAppIDs = [1, 2]
        req.snapshotRule = CronjobSnapshotRule(withImage: true, ignoreAppIDs: [1, 2])
        req.ignoreFiles = ["*.log", "*.log*"]
        req.exclusionRules = "*.log,*.log*"

        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any]
        #expect(obj?["withImage"] as? Bool == true)
        #expect(obj?["ignoreAppIDs"] as? [Int] == [1, 2])
        let rule = obj?["snapshotRule"] as? [String: Any]
        #expect(rule?["withImage"] as? Bool == true)
        #expect(rule?["ignoreAppIDs"] as? [Int] == [1, 2])
        #expect(obj?["ignoreFiles"] as? [String] == ["*.log", "*.log*"])
        #expect(obj?["exclusionRules"] as? String == "*.log,*.log*")
    }

    @Test("load/info 快照字段解码：snapshotRule 优先，顶层双写兜底")
    func decodeSnapshotInfo() throws {
        let json = """
        {"id":1,"name":"123124","type":"snapshot","spec":"30 1 * * 1",
         "exclusionRules":"*.log,*.log*","snapshotRule":{"withImage":true,"ignoreAppIDs":[1,2]},
         "ignoreAppIDs":[1,2],"withImage":true}
        """
        let info = try JSONDecoder().decode(CronjobInfo.self, from: Data(json.utf8))
        #expect(info.snapshotRule?.withImage == true)
        #expect(info.snapshotRule?.ignoreAppIDs == [1, 2])
        #expect(info.withImage == true)
        #expect(info.ignoreAppIDs == [1, 2])
        #expect((info.exclusionRules ?? "").split(separator: ",").count == 2)
    }

    @Test("各类型默认执行周期（对齐网页端；cronSpec 小时/分钟补零为既有格式）")
    func defaultSchedules() {
        // Shell：每月 3 日 01:30
        let shell = CreateCronjobView.defaultSchedule(for: .shell)
        #expect(shell.cronSpec == "30 01 3 * *")
        // 备份网站/备份日志/访问 URL/缓存清理/系统快照：每周一 01:30
        for t in [CronjobType.website, .log, .curl, .clean, .snapshot] {
            #expect(CreateCronjobView.defaultSchedule(for: t).cronSpec == "30 01 * * 1")
        }
        // 备份目录/切割日志/同步时间/同步 IP 组/清理日志：每天 01:30
        for t in [CronjobType.directory, .cutWebsiteLog, .ntp, .syncIpGroup, .cleanLog] {
            #expect(CreateCronjobView.defaultSchedule(for: t).cronSpec == "30 01 * * *")
        }
        // 备份应用/备份数据库：每天 02:30
        for t in [CronjobType.app, .database] {
            #expect(CreateCronjobView.defaultSchedule(for: t).cronSpec == "30 02 * * *")
        }
    }

    @Test("形状透传：字符串/数组/整数形状均不阻断解码，编码按原形状回传")
    func passthroughShapes() throws {
        let json = """
        [{"name":"t","type":"database","groupID":0,"specCustom":false,"spec":"0 2 * * *",
          "executor":"","scriptMode":"input","script":"","command":"","containerName":"",
          "user":"","url":"","scriptName":"","apps":"all","websites":["a.com"],
          "dbType":"mysql","dbName":["db1","db2"],"exclusionRules":"","isDir":false,
          "sourceDir":"","retainCopies":3,"retryTimes":0,"timeout":0,"ignoreErr":false,
          "snapshotRule":{"withImage":true,"ignoreApps":["x"]},"secret":"","args":"",
          "sourceAccounts":5,"downloadAccount":"","alertCount":0,"alertTitle":"","alertMethod":""}]
        """
        let items = try JSONDecoder().decode([CronjobTransferItem].self, from: Data(json.utf8))
        #expect(items[0].apps?.stringValue == "all")
        #expect(items[0].websites?.arrayValue == ["a.com"])
        #expect(items[0].dbName?.arrayValue == ["db1", "db2"])
        #expect(items[0].sourceAccounts?.intValue == 5)

        // 编码保持原形状：字符串仍是字符串、数组仍是数组
        let data = try JSONEncoder().encode(items)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"apps\":\"all\""))
        #expect(text.contains("\"dbName\":[\"db1\",\"db2\"]"))
        #expect(text.contains("\"sourceAccounts\":5"))
    }

    @Test("解码 → 编码 → 解码 round-trip 稳定")
    func roundTrip() throws {
        let items = try JSONDecoder().decode([CronjobTransferItem].self, from: Data(Self.capturedJSON.utf8))
        let data = try JSONEncoder().encode(items)
        let again = try JSONDecoder().decode([CronjobTransferItem].self, from: data)
        #expect(again == items)
    }
}
// 旧「iptables 链规则模型」套件已随 v2.3.0 防火墙重构移除
// （上游删除 filter/rule 系列端点与链规则模型，见 doc/references/v2.3.0-upstream-diff.md §2.1）
