//
//  AIDownloaderModelsTests.swift
//  1PanelClientTests
//
//  模型下载器模型测试：任务/本地模型/仓库条目解码（抓包样本）、
//  状态辅助判断与大小展示回退
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("模型下载器模型")
struct AIDownloaderModelsTests {

    @Test("下载任务解码（抓包样本：Downloading，canCancel=true）")
    func decodeTask() throws {
        let json = """
        {"id":1,"source":"huggingface","repoID":"Qwen/Qwen3-0.6B","revision":"main",
         "modelName":"Qwen3-0.6B","targetDir":"/opt/1panel/ai/models/Qwen3-0.6B",
         "status":"Downloading","progress":0,"totalSize":0,"downloadedSize":0,
         "errorMessage":"","createdAt":"2026-09-12 09:49:10",
         "startedAt":"2026-09-12 09:49:10","completedAt":"",
         "canCancel":true,"canRetry":false,"canRemoveRecord":false}
        """
        let task = try JSONDecoder().decode(ModelDownloadTask.self, from: Data(json.utf8))
        #expect(task.id == 1)
        #expect(task.displayName == "Qwen3-0.6B")
        #expect(task.sourceDisplay == "HuggingFace")
        #expect(task.isActive)
        #expect(!task.isFailed)
        #expect(task.canCancel == true)
        #expect(task.progress == 0)
    }

    @Test("完成任务解码与进度详情（Success，canRemoveRecord=true）")
    func decodeTaskSuccess() throws {
        let json = """
        {"id":1,"source":"huggingface","repoID":"Qwen/Qwen3-0.6B","revision":"main",
         "modelName":"Qwen3-0.6B","targetDir":"/opt/1panel/ai/models/Qwen3-0.6B",
         "status":"Success","progress":100,"totalSize":1519209243,
         "downloadedSize":1519209243,"errorMessage":"",
         "createdAt":"2026-09-12 09:49:10","startedAt":"2026-09-12 09:49:10",
         "completedAt":"2026-09-12 09:52:13",
         "canCancel":false,"canRetry":false,"canRemoveRecord":true}
        """
        let task = try JSONDecoder().decode(ModelDownloadTask.self, from: Data(json.utf8))
        #expect(!task.isActive)
        #expect(task.canRemoveRecord == true)
        // 进度详情包含 "已下载 / 总量" 的分隔展示
        #expect(task.progressDetail.contains("/"))
    }

    @Test("modelscope 来源展示与失败状态")
    func sourceAndFailedState() throws {
        let json = #"{"id":2,"source":"modelscope","repoID":"Qwen/Qwen2.5-0.5B-Instruct","status":"Failed","errorMessage":"network timeout"}"#
        let task = try JSONDecoder().decode(ModelDownloadTask.self, from: Data(json.utf8))
        #expect(task.sourceDisplay == "ModelScope")
        #expect(task.isFailed)
        #expect(task.errorMessage == "network timeout")
        // modelName 缺失时回退 repoID
        #expect(task.displayName == "Qwen/Qwen2.5-0.5B-Instruct")
    }

    @Test("本地模型解码与大小展示回退")
    func decodeLocalItem() throws {
        let withText = #"{"name":"Qwen3-0.6B","path":"/opt/1panel/ai/models/Qwen3-0.6B","size":1519239168,"sizeFormatted":"1.4 GB","createdAt":"2026-09-12 09:51:53"}"#
        let item = try JSONDecoder().decode(ModelLocalItem.self, from: Data(withText.utf8))
        #expect(item.displaySize == "1.4 GB")
        #expect(item.id == "Qwen3-0.6B")

        let noText = #"{"name":"m","size":999632896,"sizeFormatted":""}"#
        let fallback = try JSONDecoder().decode(ModelLocalItem.self, from: Data(noText.utf8))
        #expect(!fallback.displaySize.isEmpty)
        #expect(fallback.displaySize != "-")

        let zero = #"{"name":"m","size":0,"sizeFormatted":""}"#
        let empty = try JSONDecoder().decode(ModelLocalItem.self, from: Data(zero.utf8))
        #expect(empty.displaySize == "-")
    }

    @Test("仓库搜索条目与详情解码")
    func decodeRepoItems() throws {
        let search = """
        {"repoID":"Qwen/Qwen3-0.6B","name":"Qwen3-0.6B","downloads":20685071,
         "likes":1597,"size":0,"sizeFormatted":""}
        """
        let item = try JSONDecoder().decode(ModelRepoItem.self, from: Data(search.utf8))
        #expect(item.id == "Qwen/Qwen3-0.6B")
        // HF 搜索 size=0 且无格式化文本 → 不展示
        #expect(item.displaySize.isEmpty)
        #expect(item.downloads == 20685071)

        let detail = """
        {"repoID":"Qwen/Qwen3-0.6B","name":"Qwen3-0.6B","downloads":20685071,"likes":1597,
         "size":1503264768,"sizeFormatted":"1.4 GB","modelCard":"# Qwen3-0.6B",
         "files":[{"name":"model.safetensors","size":1503300328,"sizeFormatted":"1.4 GB"},
                  {"name":"config.json","size":726,"sizeFormatted":"0.7 KB"}]}
        """
        let d = try JSONDecoder().decode(ModelRepoDetail.self, from: Data(detail.utf8))
        #expect(d.modelCard == "# Qwen3-0.6B")
        #expect(d.files?.count == 2)
        #expect(d.files?.first?.displaySize == "1.4 GB")
    }

    @Test("搜索请求编码（sort 默认 downloads，pageSize 50）")
    func encodeSearchRequest() throws {
        let req = ModelRepoSearchRequest(query: "Qwen")
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
        #expect(obj["query"] as? String == "Qwen")
        #expect(obj["sort"] as? String == "downloads")
        #expect(obj["page"] as? Int == 1)
        #expect(obj["pageSize"] as? Int == 50)
    }

    @Test("排序选项覆盖抓包枚举")
    func sortOptions() {
        #expect(ModelRepoSort.allCases.map(\.rawValue)
                == ["downloads", "trending", "likes", "created", "updated"])
        #expect(ModelRepoSource.allCases.map(\.rawValue) == ["huggingface", "modelscope"])
    }
}
