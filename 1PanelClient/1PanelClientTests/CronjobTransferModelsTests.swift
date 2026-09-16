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

@Suite("iptables 链规则模型")
struct FirewallChainModelsTests {

    @Test("链规则解码（端口为空串/数字字符串）+ 删除体端口转 Int")
    func decodeChainRuleAndBatchItem() throws {
        let json = """
        {"id":0,"chain":"1PANEL_INPUT","protocol":"udp","srcPort":"","dstPort":"53",
         "srcIP":"192.168.51.0/24","dstIP":"","strategy":"accept","description":""}
        """
        let rule = try JSONDecoder().decode(FirewallChainRule.self, from: Data(json.utf8))
        #expect(rule.apiID == 0)
        #expect(rule.protocolField == "udp")
        #expect(rule.dstPort == "53")

        let item = FirewallChainRuleBatchItem(rule: rule)
        #expect(item.srcPort == 0)
        #expect(item.dstPort == 53)
        #expect(item.chain == "1PANEL_INPUT")

        // 删除体编码：protocol 键名映射，无 description 键
        let data = try JSONEncoder().encode(FirewallChainRuleBatchRequest(rules: [item]))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"protocol\":\"udp\""))
        #expect(text.contains("\"dstPort\":53"))
        #expect(!text.contains("description"))
    }
}
