//
//  SnapshotAndMonitorModelsTests.swift
//  1PanelClientTests
//
//  快照/监控设置/Swap 模型测试（样本取自 logs/推荐实现-计划任务和面板.md 抓包 2026-09-14）
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("快照与监控设置模型")
struct SnapshotAndMonitorModelsTests {

    private func encode(_ req: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
    }

    // MARK: 计划任务

    @Test("停止/预览/清空请求编码（抓包样本）")
    func cronjobRequests() throws {
        let stop = try encode(CronjobStopRequest(id: 1))
        #expect(stop["id"] as? Int == 1)

        let next = try encode(CronjobNextRequest(spec: "30 1 3 * *"))
        #expect(next["spec"] as? String == "30 1 3 * *")

        let clean = try encode(CronjobRecordsCleanRequest(cronjobID: 1))
        #expect(clean["cronjobID"] as? Int == 1)
    }

    // MARK: 快照

    @Test("快照数据树解码（load 响应：应用父子/禁用项，抓包样本节选）")
    func decodeSnapshotTree() throws {
        let json = """
        {"id":"51e6dbcd","label":"Ollama - ollama","key":"ollama","name":"ollama",
         "isLocal":false,"size":69632,"isCheck":false,"isDisable":false,
         "path":"","relationItemID":"",
         "children":[
           {"id":"e0bec65d","label":"appData","key":"ollama","name":"ollama",
            "isLocal":false,"size":69632,"isCheck":true,"isDisable":false,
            "path":"/opt/1panel/apps/ollama/ollama","relationItemID":"","children":null},
           {"id":"88129528","label":"appImage","key":"","name":"ollama/ollama:0.34.0",
            "isLocal":false,"size":7000509192,"isCheck":false,"isDisable":false,
            "path":"","relationItemID":"","children":null}]}
        """
        let node = try JSONDecoder().decode(SnapshotNode.self, from: Data(json.utf8))
        #expect(node.isLeaf == false)
        #expect(node.children?.count == 2)
        let appData = try #require(node.children?.first)
        #expect(appData.label == "appData")
        #expect(appData.isCheck == true)
        #expect(appData.isLeaf == true)
    }

    @Test("创建快照请求编码（全字段回传 + ignoreFiles，抓包对齐）")
    func encodeSnapshotCreate() throws {
        let leaf = SnapshotNode(
            id: "ai-node", label: "ai", key: "", name: "", isLocal: false,
            size: 1519251456, isCheck: true, isDisable: false,
            path: "/opt/1panel/ai", relationItemID: "", children: nil)
        let req = SnapshotCreateRequest(
            id: 0, taskID: "1340b3e7", downloadAccountID: 1,
            fromAccounts: [1], sourceAccountIDs: "1",
            description: "", secret: "",
            timeout: 3600, timeoutItem: 3600, timeoutUnit: "s",
            backupAllImage: false,
            withDockerConf: true, withLoginLog: false, withOperationLog: false,
            withSystemLog: false, withTaskLog: false, withMonitorData: false,
            panelData: [leaf], backupData: [], appData: [],
            ignoreFiles: ["*.log", "/etc"])
        let obj = try encode(req)
        #expect(obj["id"] as? Int == 0)
        #expect(obj["sourceAccountIDs"] as? String == "1")
        #expect(obj["timeout"] as? Int == 3600)
        #expect(obj["timeoutUnit"] as? String == "s")
        #expect(obj["backupAllImage"] as? Bool == false)
        #expect((obj["panelData"] as? [[String: Any]])?.count == 1)
        #expect(obj["ignoreFiles"] as? [String] == ["*.log", "/etc"])
    }

    @Test("快照删除/恢复请求编码（抓包样本）")
    func encodeSnapshotDeleteRecover() throws {
        let del = try encode(SnapshotDeleteRequest(ids: [3], deleteWithFile: true))
        #expect(del["ids"] as? [Int] == [3])
        #expect(del["deleteWithFile"] as? Bool == true)

        let recover = try encode(SnapshotRecoverRequest(
            id: 2, taskID: "9e37d0aa", isNew: true, reDownload: false, secret: ""))
        #expect(recover["id"] as? Int == 2)
        #expect(recover["isNew"] as? Bool == true)
        #expect(recover["reDownload"] as? Bool == false)
    }

    // MARK: 监控设置

    @Test("监控单项设置编码（key/value 五项，抓包样本）")
    func encodeMonitorSettingUpdate() throws {
        let req = MonitorSettingUpdateRequest(key: "MonitorStatus", value: "Enable")
        let obj = try encode(req)
        #expect(obj["key"] as? String == "MonitorStatus")
        #expect(obj["value"] as? String == "Enable")
    }

    @Test("监控设置读取防御性解析（键大小写不敏感 + 默认值）")
    func monitorSettingsParsing() {
        let s = MonitorSettings.from(dict: [
            "MonitorStatus": "Enable", "MonitorStoreDays": "5",
            "MonitorInterval": "600", "DefaultNetwork": "all", "DefaultIO": "sda"])
        #expect(s.monitorStatus == true)
        #expect(s.storeDays == 5)
        #expect(s.interval == 600)
        #expect(s.defaultNetwork == "all")
        #expect(s.defaultIO == "sda")

        let lower = MonitorSettings.from(dict: [
            "monitorStatus": "disable", "monitorStoreDays": "7", "monitorInterval": "300"])
        #expect(lower.monitorStatus == false)
        #expect(lower.storeDays == 7)
        #expect(lower.defaultNetwork == "all")

        let empty = MonitorSettings.from(dict: [:])
        #expect(empty.monitorStatus == true)
        #expect(empty.interval == 300)
    }

    // MARK: Swap

    @Test("Swap 明细解码（size 为 KB、used 为数值字符串，抓包样本）")
    func decodeSwapDetail() throws {
        let json = """
        {"path":"/dev/dm-1","size":1961980,"used":"469612","isNew":false,"taskID":""}
        """
        let d = try JSONDecoder().decode(SwapDetail.self, from: Data(json.utf8))
        #expect(d.size == 1961980)
        #expect(d.usedKB == 469612)
        #expect(d.sizeGB > 1.8 && d.sizeGB < 1.9)
    }

    @Test("Swap 更新请求编码（size KB + used 原样回传 + taskID）")
    func encodeSwapUpdate() throws {
        let req = SwapUpdateRequest(
            path: "/dev/dm-1", size: 2097152, used: "0", isNew: false,
            taskID: "eaee42df-3fb2-450f-95a9-fb9607855844")
        let obj = try encode(req)
        #expect(obj["path"] as? String == "/dev/dm-1")
        #expect(obj["size"] as? Int == 2097152)
        #expect(obj["used"] as? String == "0")
        #expect(obj["isNew"] as? Bool == false)
    }
}
