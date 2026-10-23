//
//  AIVllmModelsTests.swift
//  1PanelClientTests
//
//  vLLM 模型测试：版本→镜像推导（抓包对照表）/ 版本过滤 /
//  实例解码（搜索响应样本）/ 创建请求编码（对齐抓包字段）/
//  实例监控（current/search 抓包样本解码、指标分组与分位、请求编码、端点路径）
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

    // MARK: 实例监控（logs/2.4.0新增vllm.md 抓包 2026-10-23）

    /// 抓包样本：无 GPU 机器，status=unavailable、全部指标 null
    private static let unavailablePointJSON = """
    {"createdAt":"2026-10-23T09:51:15.373302089+08:00","appInstallID":1,"status":"unavailable",
     "intervalSeconds":0,"completedRequests":null,"queueTime":null,"averageGenerationTokens":null,
     "prefixCacheHitRate":null,"finishReasons":null,"promptDistribution":null,
     "generationDistribution":null,"running":null,"waiting":null,"cacheUsage":null,
     "promptThroughput":null,"generationThroughput":null,"requestThroughput":null,
     "timeToFirstToken":null,"timePerOutputToken":null,"requestLatency":null,"prefillTime":null,
     "decodeTime":null,"timeToFirstTokenP50":null,"timeToFirstTokenP90":null,
     "timeToFirstTokenP95":null,"timeToFirstTokenP99":null,"timePerOutputTokenP50":null,
     "timePerOutputTokenP90":null,"timePerOutputTokenP95":null,"timePerOutputTokenP99":null,
     "requestLatencyP50":null,"requestLatencyP90":null,"requestLatencyP95":null,
     "requestLatencyP99":null}
    """

    @Test("monitor/current 抓包样本解码：unavailable 全 null，所有指标显示 —")
    func decodeMonitorCurrentUnavailable() throws {
        let point = try JSONDecoder().decode(VllmMonitorPoint.self,
                                             from: Data(Self.unavailablePointJSON.utf8))
        #expect(point.appInstallID == 1)
        #expect(point.status == "unavailable")
        #expect(!point.isAvailable)
        #expect(point.finishReasons == nil)
        for metric in VllmMonitorMetric.allCases {
            #expect(metric.value(in: point) == nil)
            #expect(metric.text(metric.value(in: point)) == "—")
        }
        #expect(MonitorDate.parse(point.createdAt ?? "") != nil)
    }

    @Test("monitor/search 抓包样本解码：sampleCount/bucketSeconds/points")
    func decodeMonitorHistory() throws {
        let json = """
        {"sampleCount":3,"bucketSeconds":0,"points":[\(Self.unavailablePointJSON),
         \(Self.unavailablePointJSON),\(Self.unavailablePointJSON)]}
        """
        let history = try JSONDecoder().decode(VllmMonitorHistory.self, from: Data(json.utf8))
        #expect(history.sampleCount == 3)
        #expect(history.bucketSeconds == 0)
        #expect(history.points?.count == 3)
    }

    @Test("有 GPU 的 ok 采样点：取值、分位数、单位格式化（按服务端口径）")
    func decodeMonitorPointAvailable() throws {
        let json = """
        {"createdAt":"2026-10-23T10:00:00+08:00","appInstallID":1,"status":"ok","intervalSeconds":30,
         "completedRequests":12,"queueTime":0.0123,"averageGenerationTokens":256.5,
         "prefixCacheHitRate":37.5,"finishReasons":{"stop":0.4,"length":0.1},
         "running":3,"waiting":1,"cacheUsage":42.25,"promptThroughput":1234.567,
         "generationThroughput":89.1,"requestThroughput":0.4,
         "timeToFirstToken":0.0456,"timePerOutputToken":0.0123,"requestLatency":2.5,
         "prefillTime":0.03,"decodeTime":2.4,
         "timeToFirstTokenP50":0.04,"timeToFirstTokenP90":0.08,"timeToFirstTokenP95":0.1,
         "timeToFirstTokenP99":0.2}
        """
        let point = try JSONDecoder().decode(VllmMonitorPoint.self, from: Data(json.utf8))
        #expect(point.isAvailable)
        #expect(VllmMonitorMetric.running.text(VllmMonitorMetric.running.value(in: point)) == "3")
        #expect(VllmMonitorMetric.cacheUsage.text(point.cacheUsage) == "42.2%")
        #expect(VllmMonitorMetric.promptThroughput.text(point.promptThroughput) == "1234.57 tokens/s")
        #expect(VllmMonitorMetric.requestThroughput.text(point.requestThroughput) == "0.40 req/s")
        #expect(VllmMonitorMetric.timeToFirstToken.text(point.timeToFirstToken) == "0.046 s")
        #expect(VllmMonitorMetric.averageGenerationTokens.text(point.averageGenerationTokens) == "256.50 tokens")
        #expect(VllmMonitorMetric.prefixCacheHitRate.text(point.prefixCacheHitRate) == "37.5%")
        #expect(point.finishReasons?["stop"] == 0.4)
        // 分位：首 Token 四档齐全；Token 间延迟样本未给分位 → 标签在、值为 nil
        let ttft = VllmMonitorMetric.timeToFirstToken.percentiles(in: point)
        #expect(ttft.map(\.label) == ["P50", "P90", "P95", "P99"])
        #expect(VllmMonitorMetric.timeToFirstToken.percentile("P99", in: point) == 0.2)
        #expect(VllmMonitorMetric.timePerOutputToken.percentile("P50", in: point) == nil)
        #expect(VllmMonitorMetric.running.percentile("P50", in: point) == nil)
    }

    @Test("指标分组与分位归属：概览 6 / 延迟 5 / 请求 4，分位仅延迟三项")
    func monitorMetricGrouping() {
        #expect(VllmMonitorMetric.metrics(in: .overview).count == 6)
        #expect(VllmMonitorMetric.metrics(in: .latency).count == 5)
        #expect(VllmMonitorMetric.metrics(in: .requests).count == 4)
        #expect(VllmMonitorMetric.allCases.filter(\.hasPercentiles).map(\.rawValue)
                == ["timeToFirstToken", "timePerOutputToken", "requestLatency"])
        // 百分比指标曲线固定 0...100，其余动态
        #expect(VllmMonitorMetric.cacheUsage.fixedYDomain == 0...100)
        #expect(VllmMonitorMetric.prefixCacheHitRate.fixedYDomain == 0...100)
        #expect(VllmMonitorMetric.requestLatency.fixedYDomain == nil)
    }

    @Test("monitor 请求编码对齐抓包：search 五字段（默认 avg/overview）、current/clean 仅 appInstallID")
    func encodeMonitorRequests() throws {
        let search = VllmMonitorSearchRequest(
            appInstallID: 1,
            startTime: "2026-10-23T00:51:10.881Z",
            endTime: "2026-10-23T01:52:07.330Z")
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(search)) as? [String: Any])
        #expect(obj["appInstallID"] as? Int == 1)
        #expect(obj["startTime"] as? String == "2026-10-23T00:51:10.881Z")
        #expect(obj["endTime"] as? String == "2026-10-23T01:52:07.330Z")
        #expect(obj["aggregation"] as? String == "avg")
        #expect(obj["group"] as? String == "overview")
        #expect(obj.count == 5)

        let latency = VllmMonitorSearchRequest(appInstallID: 1, startTime: "a", endTime: "b",
                                               aggregation: VllmMonitorAggregation.max.rawValue,
                                               group: VllmMonitorGroup.latency.rawValue)
        let latencyObj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(latency)) as? [String: Any])
        #expect(latencyObj["aggregation"] as? String == "max")
        #expect(latencyObj["group"] as? String == "latency")

        let target = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(VllmMonitorTargetRequest(appInstallID: 7))) as? [String: Any])
        #expect(target["appInstallID"] as? Int == 7)
        #expect(target.count == 1)
    }

    @Test("monitor 端点路径位于 /api/v2/ai/vllm/monitor（非 xpack 前缀）且均为 POST")
    func monitorEndpoints() {
        #expect(APIEndpoint.vllmMonitorCurrent.path == "/api/v2/ai/vllm/monitor/current")
        #expect(APIEndpoint.vllmMonitorSearch.path == "/api/v2/ai/vllm/monitor/search")
        #expect(APIEndpoint.vllmMonitorClean.path == "/api/v2/ai/vllm/monitor/clean")
        #expect(APIEndpoint.vllmMonitorCurrent.method == "POST")
        #expect(APIEndpoint.vllmMonitorSearch.method == "POST")
        #expect(APIEndpoint.vllmMonitorClean.method == "POST")
    }
}
