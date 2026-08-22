//
//  NodeModelsTests.swift
//  1PanelClientTests
//
//  多机管理模型的编解码验证：向量取自网页端抓包（logs/多机管理/*.md）
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("多机管理模型")
struct NodeModelsTests {
    // MARK: - 解码（抓包原始 JSON）

    @Test("NodeCurrentItem：nodes/current 响应解码")
    func decodeCurrentItem() throws {
        let json = """
        {"nodeName":"Node01","status":"Healthy","message":"","isOK":true,
         "cpuUsedPercent":0.32862306933947316,"cpuTotal":2,
         "memoryTotal":2061840384,"memoryUsedPercent":11.960769122271687}
        """
        let item = try JSONDecoder().decode(NodeCurrentItem.self, from: Data(json.utf8))
        #expect(item.nodeName == "Node01")
        #expect(item.status == "Healthy")
        #expect(item.isOK == true)
        #expect(item.cpuTotal == 2)
        #expect(item.memoryTotal == 2061840384)
    }

    @Test("NodeListItem：nodes/list 响应解码")
    func decodeListItem() throws {
        let json = """
        {"id":2,"groupID":2,"groupBelong":"Default","name":"192.168.50.20","alias":"",
         "addr":"192.168.50.20","status":"Healthy","isOffline":false,"version":"v2.2.5",
         "isXpack":false,"isBound":true,"isAutoUpgrade":false,"isFavorite":false}
        """
        let item = try JSONDecoder().decode(NodeListItem.self, from: Data(json.utf8))
        #expect(item.id == 2)
        #expect(item.name == "192.168.50.20")
        #expect(item.displayName == "192.168.50.20")  // alias 为空回退 name
        #expect(item.version == "v2.2.5")
        #expect(item.groupBelong == "Default")
    }

    @Test("NodeTestResult：test/byinfo 响应解码")
    func decodeTestResult() throws {
        let json = """
        {"isConnOk":true,"isLicenseOk":true,"connMsg":"","isCoreExist":false,
         "isAgentExist":false,"isPanelExist":false,"isDockerExist":false,
         "isSyncFromNode":false,"syncNodePort":"","syncBaseDir":"",
         "isPortAvailable":true,"isSyncPortAvailable":false,"isRoot":true}
        """
        let result = try JSONDecoder().decode(NodeTestResult.self, from: Data(json.utf8))
        #expect(result.isConnOk == true)
        #expect(result.isRoot == true)
        #expect(result.isPortAvailable == true)
        #expect(result.isLicenseOk == true)
    }

    @Test("LicenseOption：licenses/options 响应解码")
    func decodeLicenseOption() throws {
        let json = """
        {"id":2,"licenseName":"license-Panel-v3ssjivpk","totalFreeCount":1,
         "availableXpackCount":0,"availableFreeCount":0}
        """
        let option = try JSONDecoder().decode(LicenseOption.self, from: Data(json.utf8))
        #expect(option.displayName == "license-Panel-v3ssjivpk")
        #expect(option.availableXpackCount == 0)
        #expect(option.availableFreeCount == 0)

        let empty = try JSONDecoder().decode(LicenseOption.self, from: Data(
            #"{"id":3,"licenseName":"","availableXpackCount":0,"availableFreeCount":0}"#.utf8))
        #expect(empty.displayName == "#3")  // 名称缺失回退 #id
    }

    // MARK: - 编码（AddNodeRequest）

    @Test("AddNodeRequest：密码 base64，检查请求不含创建字段")
    func encodeTestRequest() throws {
        let req = AddNodeRequest(
            addr: "192.168.50.20", port: 22, user: "root", authMode: "password",
            password: Data("Admin1234567890".utf8).base64EncodedString(),
            privateKey: "", name: "192.168.50.20", baseDir: "/opt", nodePort: 9999,
            isXpack: false, syncList: "SyncSystemProxy,SyncBackupAccounts,SyncAlertSetting,SyncCustomApp",
            licenseID: 2, groupID: 2, rememberPassword: true, description: "",
            withDockerRestart: nil, taskID: nil
        )
        let data = try JSONEncoder().encode(req)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // 抓包向量：密码 base64("Admin1234567890") = QWRtaW4xMjM0NTY3ODkw
        #expect(obj["password"] as? String == "QWRtaW4xMjM0NTY3ODkw")
        #expect(obj["authMode"] as? String == "password")
        #expect(obj["nodePort"] as? Int == 9999)
        #expect(obj["baseDir"] as? String == "/opt")
        // 可用性检查请求不携带创建专用字段（nil → encodeIfPresent 省略）
        #expect(obj["withDockerRestart"] == nil)
        #expect(obj["taskID"] == nil)
    }

    @Test("AddNodeRequest：创建请求携带 taskID 与 withDockerRestart")
    func encodeCreateRequest() throws {
        let req = AddNodeRequest(
            addr: "192.168.50.20", port: 22, user: "root", authMode: "password",
            password: "", privateKey: "", name: "n", baseDir: "/opt", nodePort: 9999,
            isXpack: false, syncList: "", licenseID: 0, groupID: 0,
            rememberPassword: false, description: "",
            withDockerRestart: false, taskID: "e40558fb-5d6b-4380-a522-47e31e0572ed"
        )
        let data = try JSONEncoder().encode(req)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["taskID"] as? String == "e40558fb-5d6b-4380-a522-47e31e0572ed")
        #expect(obj["withDockerRestart"] as? Bool == false)
    }

    // MARK: - 节点详情 / 编辑（多机管理-2.md）

    @Test("NodeDetailItem：nodes/search 响应解码（含明文密码回填字段）")
    func decodeDetailItem() throws {
        let json = """
        {"id":2,"createdAt":"2026-08-22T10:58:09.646190733+08:00","groupID":2,
         "groupBelong":"Default","name":"Node01","alias":"","version":"v2.2.5",
         "addr":"192.168.50.20","port":22,"user":"root","authMode":"password",
         "password":"Admin1234567890","privateKey":"","passPhrase":"",
         "rememberPassword":true,"useProxy":false,"baseDir":"/opt","nodePort":9999,
         "licenseID":2,"isXpack":false,"isBound":true,"license":"license-Panel-v3jgivpk",
         "syncList":"SyncBackupAccounts","syncStatus":"Success","syncMessage":"",
         "status":"Healthy","message":"","isFavorite":false,"description":""}
        """
        let item = try JSONDecoder().decode(NodeDetailItem.self, from: Data(json.utf8))
        #expect(item.id == 2)
        #expect(item.name == "Node01")
        #expect(item.password == "Admin1234567890")
        #expect(item.rememberPassword == true)
        #expect(item.syncList == "SyncBackupAccounts")
        #expect(item.nodePort == 9999)
        #expect(item.displayName == "Node01")
    }

    @Test("NodeUpdateRequest：编辑提交的完整字段与密码 base64")
    func encodeUpdateRequest() throws {
        let req = NodeUpdateRequest(
            id: 2,
            createdAt: "2026-08-22T10:58:09.646190733+08:00",
            groupID: 2,
            groupBelong: "Default",
            name: "Node01",
            alias: "",
            version: "v2.2.5",
            addr: "192.168.50.20",
            port: 22,
            user: "root",
            authMode: "password",
            password: Data("Admin1234567890".utf8).base64EncodedString(),
            privateKey: "",
            passPhrase: "",
            rememberPassword: true,
            useProxy: false,
            baseDir: "/opt",
            nodePort: 9999,
            licenseID: 2,
            isXpack: false,
            isBound: true,
            license: "license-Panel-v3jgivpk",
            syncList: "SyncSystemProxy,SyncBackupAccounts",
            syncStatus: "Success",
            syncMessage: "",
            status: "Healthy",
            message: "",
            isFavorite: false,
            description: "",
            hasLoad: true,
            isOK: true,
            node: NodeCurrentItem(
                nodeName: "Node01", status: "Healthy", message: "", isOK: true,
                cpuUsedPercent: 1.75, cpuTotal: 2,
                memoryTotal: 2061840384, memoryUsedPercent: 18.67),
            withDockerRestart: false,
            taskID: "0a994baa-b843-4871-aaff-41fc16b33670"
        )
        let data = try JSONEncoder().encode(req)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["id"] as? Int == 2)
        #expect(obj["password"] as? String == "QWRtaW4xMjM0NTY3ODkw")
        #expect(obj["name"] as? String == "Node01")
        #expect(obj["hasLoad"] as? Bool == true)
        #expect(obj["withDockerRestart"] as? Bool == false)
        let node = try #require(obj["node"] as? [String: Any])
        #expect(node["nodeName"] as? String == "Node01")
    }

    @Test("NodeGroup / NodeUpgradeLogResponse：分组与更新记录解码")
    func decodeGroupAndUpgradeLogs() throws {
        let group = try JSONDecoder().decode(NodeGroup.self, from: Data(
            #"{"id":2,"name":"Default","type":"node","isDefault":true}"#.utf8))
        #expect(group.id == 2)
        #expect(group.name == "Default")
        #expect(group.isDefault == true)

        // 抓包中 items=null
        let empty = try JSONDecoder().decode(NodeUpgradeLogResponse.self, from: Data(
            #"{"total":0,"items":null}"#.utf8))
        #expect(empty.total == 0)
        #expect(empty.items == nil)
    }

    @Test("NodeUpdateBaseRequest：改名称请求编码（抓包向量）")
    func encodeUpdateBaseRequest() throws {
        let req = NodeUpdateBaseRequest(id: 2, name: "Node01", isLocal: false,
                                        groupID: 2, description: "")
        let data = try JSONEncoder().encode(req)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["id"] as? Int == 2)
        #expect(obj["name"] as? String == "Node01")
        #expect(obj["isLocal"] as? Bool == false)
        #expect(obj["groupID"] as? Int == 2)
        #expect(obj["description"] as? String == "")
    }

    @Test("NodeDeleteRequest：删除节点请求编码（勾选强删+删数据的抓包向量）")
    func encodeDeleteRequest() throws {
        let req = NodeDeleteRequest(ids: [2], force: true, withUninstall: true)
        let data = try JSONEncoder().encode(req)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["ids"] as? [Int] == [2])
        #expect(obj["force"] as? Bool == true)
        #expect(obj["withUninstall"] as? Bool == true)
    }
}
