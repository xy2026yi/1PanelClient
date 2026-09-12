//
//  AIVllmModelsTests.swift
//  1PanelClientTests
//
//  vLLM 模型测试：版本→镜像推导（抓包对照表）/ 版本过滤 /
//  实例解码（搜索响应样本）/ 创建请求编码（对齐抓包字段）
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("vLLM 模型")
struct AIVllmModelsTests {

    // MARK: 版本 → 镜像

    @Test("版本到镜像推导（对照 logs/vLLM与下载器.md 抓包表）", arguments: [
        ("nvidia-0.27.1", "vllm/vllm-openai:v0.27.1"),
        ("nvidia-0.26.0", "vllm/vllm-openai:v0.26.0"),
        ("nvidia-0.25.1", "vllm/vllm-openai:v0.25.1"),
        ("nvidia-0.25.0", "vllm/vllm-openai:v0.25.0"),
        ("nvidia-0.23.0", "vllm/vllm-openai:v0.23.0"),
        ("nvidia-0.22.1", "vllm/vllm-openai:v0.22.1"),
        ("nvidia-0.20.0-cu130", "vllm/vllm-openai:v0.20.0-cu130"),
        // GB10 双机特化版本：镜像 tag 带 v 前缀
        ("nvidia-gb10-dspark-0.1.1", "vllm/vllm-openai:vgb10-dspark-0.1.1"),
        ("ascend-0.23.0-310p", "quay.io/ascend/vllm-ascend:v0.23.0-310p"),
        ("ascend-0.23.0rc1-310p", "quay.io/ascend/vllm-ascend:v0.23.0rc1-310p"),
        ("ascend-0.23.0rc1-openeuler", "quay.io/ascend/vllm-ascend:v0.23.0rc1-openeuler"),
        ("ascend-0.23.0-openeuler", "quay.io/ascend/vllm-ascend:v0.23.0-openeuler"),
        ("ascend-0.21.0rc1-310p", "quay.io/ascend/vllm-ascend:v0.21.0rc1-310p"),
        ("intel-0.14.0-b8.3.1", "intel/llm-scaler-vllm:0.14.0-b8.3.1"),
    ])
    func imageMapping(appVersion: String, expected: String) {
        #expect(VllmImageMapper.defaultImage(appVersion: appVersion) == expected)
    }

    @Test("未知前缀 / 空版本无法推导")
    func imageMappingUnknown() {
        #expect(VllmImageMapper.defaultImage(appVersion: "rocm-1.0") == nil)
        #expect(VllmImageMapper.defaultImage(appVersion: "nvidia-") == nil)
        #expect(VllmImageMapper.defaultImage(appVersion: "") == nil)
    }

    @Test("按类型过滤版本列表（保持服务端排序）")
    func versionFiltering() {
        let all = [
            "nvidia-gb10-dspark-0.1.1", "nvidia-0.27.1", "nvidia-0.26.0",
            "ascend-0.23.0-310p", "nvidia-0.23.0", "intel-0.14.0-b8.3.1",
        ]
        #expect(VllmImageMapper.versions(of: .nvidia, in: all)
                == ["nvidia-gb10-dspark-0.1.1", "nvidia-0.27.1", "nvidia-0.26.0", "nvidia-0.23.0"])
        #expect(VllmImageMapper.versions(of: .ascend, in: all) == ["ascend-0.23.0-310p"])
        #expect(VllmImageMapper.versions(of: .intel, in: all) == ["intel-0.14.0-b8.3.1"])
        #expect(VllmImageMapper.versions(of: .nvidia, in: []) == [])
    }

    // MARK: 实例解码

    @Test("搜索响应实例解码（抓包样本，Installing 状态）")
    func decodeInstance() throws {
        let json = """
        {"id":1,"appInstallId":83,"agentAccountId":1,"name":"vLLM",
         "appVersion":"intel-0.14.0-b8.3.1","imageType":"intel",
         "image":"intel/llm-scaler-vllm:0.14.0-b8.3.1","commandTemplateID":3,
         "port":8000,"modelDir":"/nvme_data/test","command":"--model /models/Qwen3.6-27B",
         "containerName":"1Panel-vllm-aOKC","status":"Installing","message":"",
         "path":"/opt/1panel/apps/vllm/vLLM","restartPolicy":"unless-stopped",
         "allowPort":true,"specifyIP":"","cpuQuota":0,"memoryLimit":0,"memoryUnit":"M",
         "syncModelAccount":true,"modelAccountBaseURLType":"systemIP",
         "modelAccountBaseURL":"http://192.168.50.12:8000/v1",
         "pullImage":true,"editCompose":false,"dockerCompose":"services:\\n  vllm:",
         "upgradable":false,"createdAt":"2026-09-12T09:07:56+08:00"}
        """
        let item = try JSONDecoder().decode(VllmInstance.self, from: Data(json.utf8))
        #expect(item.id == 1)
        #expect(item.displayName == "vLLM")
        #expect(item.imageType == "intel")
        #expect(item.typeDisplay == "Intel")
        #expect(item.port == 8000)
        #expect(item.status == "Installing")
        #expect(item.isTransitioning)
        #expect(!item.isRunning)
        #expect(item.modelAccountBaseURLType == "systemIP")
        #expect(item.cpuQuota == 0)
    }

    @Test("缺失可选字段与状态辅助判断")
    func decodeInstanceMinimal() throws {
        let json = #"{"id":9,"name":"a","status":"Running"}"#
        let item = try JSONDecoder().decode(VllmInstance.self, from: Data(json.utf8))
        #expect(item.isRunning)
        #expect(!item.isTransitioning)
        #expect(item.port == nil)
        #expect(item.path == nil)
    }

    // MARK: 创建请求编码

    @Test("创建请求字段名对齐抓包（commandTemplateID 驼峰 / taskID）")
    func encodeCreateRequest() throws {
        let req = VllmCreateRequest(
            name: "vLLM",
            appVersion: "intel-0.14.0-b8.3.1",
            imageType: "intel",
            image: "intel/llm-scaler-vllm:0.14.0-b8.3.1",
            commandTemplateID: 3,
            port: 8000,
            modelDir: "/nvme_data/test",
            command: "--model /models/Qwen3.6-27B",
            advanced: true,
            containerName: "",
            allowPort: true,
            specifyIP: "",
            restartPolicy: "unless-stopped",
            cpuQuota: 0,
            memoryLimit: 0,
            memoryUnit: "M",
            syncModelAccount: true,
            modelAccountBaseURLType: "systemIP",
            modelAccountBaseURL: "http://192.168.50.12:8000/v1",
            pullImage: true,
            editCompose: false,
            dockerCompose: "",
            syncAgents: false,
            taskID: "f6abd4db-bc6a-481a-a4a8-503c71b89929")
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
        #expect(obj["commandTemplateID"] as? Int == 3)
        #expect(obj["taskID"] as? String == "f6abd4db-bc6a-481a-a4a8-503c71b89929")
        #expect(obj["modelAccountBaseURLType"] as? String == "systemIP")
        #expect(obj["restartPolicy"] as? String == "unless-stopped")
        #expect(obj["imageType"] as? String == "intel")
        // 编辑模式才带 id；创建请求不携带
        #expect(obj["id"] == nil)

        var edit = req
        edit.id = 7
        let editObj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(edit)) as? [String: Any])
        #expect(editObj["id"] as? Int == 7)
    }

    // MARK: 操作请求编码

    @Test("操作请求编码（start 不带 forceDelete，delete 携带）")
    func encodeOperateRequest() throws {
        let start = VllmOperateRequest(id: 2, operate: "start", taskID: "a4b764f3-dce8-4c25-a893-a05616f5568c")
        let startObj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(start)) as? [String: Any])
        #expect(startObj["id"] as? Int == 2)
        #expect(startObj["operate"] as? String == "start")
        #expect(startObj["taskID"] as? String == "a4b764f3-dce8-4c25-a893-a05616f5568c")
        // start/stop/restart 无 forceDelete 字段
        #expect(startObj["forceDelete"] == nil)

        let del = VllmOperateRequest(id: 1, operate: "delete", taskID: "ed58b00b-5654-4148-bb4f-a3d2230d892f", forceDelete: false)
        let delObj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(del)) as? [String: Any])
        #expect(delObj["operate"] as? String == "delete")
        #expect(delObj["forceDelete"] as? Bool == false)
    }

    // MARK: Base URL 推导

    @Test("访问地址四选一的 Base URL 推导")
    func baseURLDerivation() {
        #expect(VllmBaseURLType.systemIP.baseURL(port: 8000, containerName: "", panelHost: "192.168.50.12")
                == "http://192.168.50.12:8000/v1")
        #expect(VllmBaseURLType.localhost.baseURL(port: 8001, containerName: "", panelHost: "")
                == "http://127.0.0.1:8001/v1")
        #expect(VllmBaseURLType.container.baseURL(port: 8000, containerName: "1Panel-vllm-aOKC", panelHost: "")
                == "http://1Panel-vllm-aOKC:8000/v1")
        // 容器名为空时回退服务默认容器名，用户可在高级设置填写后自动刷新
        #expect(VllmBaseURLType.container.baseURL(port: 8000, containerName: "", panelHost: "")
                == "http://vllm:8000/v1")
        // 自定义地址由用户手动填写，不推导
        #expect(VllmBaseURLType.custom.baseURL(port: 8000, containerName: "", panelHost: "") == nil)
    }
}
