//
//  ContainerResourceModelsTests.swift
//  1PanelClientTests
//
//  容器资源模型测试（样本取自 logs/推荐实现-容器.md 抓包 2026-09-14）：
//  网络/存储卷创建编码（NFS 推导参数）· 编排创建三来源与两段提交 · 操作/清理/模板请求
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("容器资源模型")
struct ContainerResourceModelsTests {

    private func encode(_ req: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
    }

    // MARK: 网络

    @Test("网络创建编码（bridge + IPv4 + 参数/标签双字段，抓包样本）")
    func encodeNetworkBridge() throws {
        let req = ContainerNetworkCreateRequest(
            name: "test-v4", parentNetworkCard: "",
            labelStr: "key11=value11\nkey12=value12",
            labels: ["key11=value11", "key12=value12"],
            optionStr: "key1=value1\nkey2=value2",
            options: ["key1=value1", "key2=value2"],
            driver: "bridge", ipv4: true,
            subnet: "172.190.0.0/24", gateway: "172.190.0.1", ipRange: "172.190.0.0/24",
            auxAddress: [ContainerKVPair(key: "1", value: "172.190.0.2"),
                         ContainerKVPair(key: "2", value: "172.190.0.3")],
            ipv6: false, subnetV6: "", gatewayV6: "", ipRangeV6: "", auxAddressV6: [])
        let obj = try encode(req)
        #expect(obj["driver"] as? String == "bridge")
        #expect(obj["ipv4"] as? Bool == true)
        #expect(obj["labelStr"] as? String == "key11=value11\nkey12=value12")
        #expect((obj["auxAddress"] as? [[String: String]])?.count == 2)
        #expect(obj["ipv6"] as? Bool == false)
    }

    @Test("网络创建编码（macvlan + IPv6 + 父网卡，抓包样本）")
    func encodeNetworkMacvlan() throws {
        let req = ContainerNetworkCreateRequest(
            name: "test-v6", parentNetworkCard: "lo",
            labelStr: "", labels: [], optionStr: "", options: ["parent=lo"],
            driver: "macvlan", ipv4: false,
            subnet: "", gateway: "", ipRange: "", auxAddress: [],
            ipv6: true, subnetV6: "2408:400e::/48", gatewayV6: "2408:400e::1",
            ipRangeV6: "2408:400e::/64",
            auxAddressV6: [ContainerKVPair(key: "1", value: "2408:400e::2")])
        let obj = try encode(req)
        #expect(obj["parentNetworkCard"] as? String == "lo")
        #expect(obj["subnetV6"] as? String == "2408:400e::/48")
        #expect((obj["auxAddressV6"] as? [[String: String]])?.count == 1)
    }

    @Test("容器重命名请求编码（抓包样本）")
    func encodeContainerRename() throws {
        let req = ContainerRenameRequest(name: "123", newName: "234")
        let obj = try encode(req)
        #expect(obj["name"] as? String == "123")
        #expect(obj["newName"] as? String == "234")
    }

    // MARK: 网站批量（logs/网站批量抓包 2026-09-14）

    @Test("网站批量操作编码（启停/删除共用端点 + taskID）")
    func encodeWebsiteBatchOperate() throws {
        let stop = try encode(WebsiteBatchOperateRequest(
            operate: "stop", ids: [25, 23], taskID: "41630b88"))
        #expect(stop["operate"] as? String == "stop")
        #expect(stop["ids"] as? [Int] == [25, 23])
        let del = try encode(WebsiteBatchOperateRequest(
            operate: "delete", ids: [22, 21], taskID: "295c1749"))
        #expect(del["operate"] as? String == "delete")
    }

    @Test("网站批量分组编码 {ids,groupID}")
    func encodeWebsiteBatchGroup() throws {
        let req = try encode(WebsiteBatchGroupRequest(ids: [25, 23], groupID: 6))
        #expect(req["ids"] as? [Int] == [25, 23])
        #expect(req["groupID"] as? Int == 6)
    }

    @Test("网站批量证书编码（全字段 + 默认加密算法串，抓包对齐）")
    func encodeWebsiteBatchSSL() throws {
        let req = WebsiteBatchSSLRequest(
            ids: [25, 23], acmeAccountID: 0, enable: false,
            websiteSSLId: 10, type: "existed", importType: "paste",
            privateKey: "", certificate: "", privateKeyPath: "", certificatePath: "",
            httpConfig: "HTTPToHTTPS", hsts: true, hstsIncludeSubDomains: false,
            algorithm: WebsiteBatchSSLRequest.defaultAlgorithm,
            SSLProtocol: ["TLSv1.3", "TLSv1.2"], httpsPort: "443",
            http3: true, taskID: "748ae5da")
        let obj = try encode(req)
        #expect(obj["websiteSSLId"] as? Int == 10)
        #expect(obj["type"] as? String == "existed")
        #expect(obj["httpConfig"] as? String == "HTTPToHTTPS")
        #expect(obj["SSLProtocol"] as? [String] == ["TLSv1.3", "TLSv1.2"])
        #expect(obj["httpsPort"] as? String == "443")
        #expect(obj["http3"] as? Bool == true)
        // 加密算法串与抓包一致（头尾锚定）
        let algo = try #require(obj["algorithm"] as? String)
        #expect(algo.hasPrefix("ECDHE-ECDSA-AES256-GCM-SHA384"))
        #expect(algo.hasSuffix(":!CAMELLIA:!SEED"))
    }

    // MARK: 存储卷

    @Test("存储卷创建编码（NFS4：options 由地址/版本/挂载点推导，抓包样本）")
    func encodeVolumeNFS() throws {
        var req = ContainerVolumeCreateRequest(
            name: "1234", driver: "local",
            labelStr: "", labels: [],
            optionStr: "", options: [
                "type=nfs4",
                "o=addr=192.168.50.20,rw,noatime,rsize=8192,wsize=8192,tcp,timeo=14",
                "device=:/1G"])
        req.nfsStatus = "enable"
        req.nfsAddress = "192.168.50.20"
        req.nfsVersion = "v4"
        req.nfsMount = "/1G"
        req.nfsOption = "rw,noatime,rsize=8192,wsize=8192,tcp,timeo=14"
        let obj = try encode(req)
        #expect(obj["nfsStatus"] as? String == "enable")
        #expect(obj["nfsVersion"] as? String == "v4")
        let options = try #require(obj["options"] as? [String])
        #expect(options.contains("type=nfs4"))
        #expect(options.contains { $0.hasPrefix("o=addr=192.168.50.20,") })
        #expect(options.contains("device=:/1G"))
    }

    // MARK: 编排

    @Test("编排列表解码（抓包样本：容器/端口/环境变量）")
    func decodeComposeList() throws {
        let json = """
        {"name":"hermes-agent","createdAt":"2026-09-12 21:49:11","createdBy":"Apps",
         "containerCount":1,"runningCount":1,
         "configFile":"/opt/1panel/apps/hermes-agent/Hermes-Agent/docker-compose.yml",
         "composeFileExists":true,"isPinned":false,
         "containers":[{"containerID":"571d81b5","name":"1Panel-hermes-agent-nWo9",
                        "createTime":"2026-09-12 21:49:11","state":"running",
                        "ports":["0.0.0.0:9119->9119/tcp"]}],
         "env":"HERMES_DASHBOARD_USERNAME='admin'\\n"}
        """
        let c = try JSONDecoder().decode(ContainerCompose.self, from: Data(json.utf8))
        #expect(c.name == "hermes-agent")
        #expect(c.runningCount == 1)
        let container = try #require(c.containers?.first)
        #expect(container.state == "running")
        #expect(container.ports?.first == "0.0.0.0:9119->9119/tcp")
    }

    @Test("编排创建编码（编辑来源：test 阶段 taskID 空，抓包样本）")
    func encodeComposeCreateFromEdit() throws {
        let req = ContainerComposeUpsertRequest(
            dirName: "123", from: "edit", file: "services:\n  nginx:\n    image: nginx:latest",
            env: "TZ=Asia/Shanghai")
        let obj = try encode(req)
        #expect(obj["taskID"] as? String == "")
        #expect(obj["from"] as? String == "edit")
        #expect(obj["template"] == nil)
        #expect(obj["forcePull"] as? Bool == false)
    }

    @Test("编排创建编码（模板来源带 template id；路径来源 name=目录名）")
    func encodeComposeCreateVariants() throws {
        let template = ContainerComposeUpsertRequest(
            dirName: "123", from: "template", file: "services:", template: 1)
        let templateObj = try encode(template)
        #expect(templateObj["template"] as? Int == 1)

        var path = ContainerComposeUpsertRequest(
            dirName: "", from: "path",
            path: "/opt/1panel/docker/compose/123/docker-compose.yml")
        path.taskID = "65891ebf"
        path.name = "123"
        let pathObj = try encode(path)
        #expect(pathObj["name"] as? String == "123")
        #expect(pathObj["path"] as? String == "/opt/1panel/docker/compose/123/docker-compose.yml")
    }

    @Test("编排操作编码（operation/withFile/force，抓包样本）")
    func encodeComposeOperate() throws {
        let req = ContainerComposeOperateRequest(
            name: "123", path: "/opt/1panel/docker/compose/123/docker-compose.yml",
            operation: "up")
        let obj = try encode(req)
        #expect(obj["operation"] as? String == "up")
        #expect(obj["withFile"] as? Bool == false)
        #expect(obj["force"] as? Bool == false)
    }

    @Test("清理请求编码（pruneType network/volume + taskID）")
    func encodePrune() throws {
        let req = ContainerPruneRequest(
            taskID: "288c9c0f-ee22-4132-8965-1d4e3e934437",
            pruneType: "network", withTagAll: false)
        let obj = try encode(req)
        #expect(obj["pruneType"] as? String == "network")
        #expect(obj["withTagAll"] as? Bool == false)
    }

    @Test("模板更新编码（createdAt 原值回传，抓包样本）")
    func encodeTemplateUpdate() throws {
        let req = ContainerTemplateUpdateRequest(
            id: 1, createdAt: "2026-09-14T12:01:49.771552337+08:00",
            name: "nginx", description: "默认nginx", content: "services:")
        let obj = try encode(req)
        #expect(obj["id"] as? Int == 1)
        #expect(obj["createdAt"] as? String == "2026-09-14T12:01:49.771552337+08:00")
    }
}
