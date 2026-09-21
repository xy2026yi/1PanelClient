//
//  AlertWebhookModelsTests.swift
//  1PanelClientTests
//
//  Webhook 发送方式模型测试（样本取自 logs 需求文档 2026-09-21 抓包）：
//  config 编码形状（url 对象化 / headers uid+action）/ 列表返回字符串 url 解码 /
//  测试响应两种形状（对象与裸 bool）
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("Webhook 发送方式模型")
struct AlertWebhookModelsTests {

    @Test("默认 config：genericJson 预设 + 对应模版")
    func defaultConfig() throws {
        let config = AlertWebhookConfig()
        #expect(config.presetEnum == .genericJson)
        #expect(config.bodyTypeEnum == .json)
        let template = try #require(config.body?.template)
        #expect(template.contains("\"schema_version\": \"1\""))
        #expect(template.contains("{{title}}"))
        #expect(template.contains("{{nodeName}}"))
    }

    @Test("提交编码：url 对象化 + headers 带 uid/action（与抓包一致）")
    func encodeForSubmit() throws {
        var config = AlertWebhookConfig()
        config.displayName = "测试"
        config.presetEnum = .genericJson
        config.url = AlertWebhookURLValue(value: "https://127.0.0.1:8088/api")
        config.body?.template = AlertWebhookPreset.genericJson.defaultTemplate ?? ""
        config.headers = [
            AlertWebhookHeader(key: "1", value: "1", secret: false),
            AlertWebhookHeader(key: "2", value: "2", secret: true)
        ]

        let sanitized = config.sanitizedForSubmit
        let data = try JSONEncoder().encode(sanitized)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let root = try #require(obj)

        #expect(root["schemaVersion"] as? Int == 1)
        #expect(root["method"] as? String == "POST")
        #expect(root["preset"] as? String == "genericJson")
        let url = try #require(root["url"] as? [String: Any])
        #expect(url["action"] as? String == "replace")
        #expect(url["value"] as? String == "https://127.0.0.1:8088/api")
        let body = try #require(root["body"] as? [String: Any])
        #expect(body["type"] as? String == "json")
        #expect((body["fields"] as? [Any])?.isEmpty == true)
        let headers = try #require(root["headers"] as? [[String: Any]])
        #expect(headers.count == 2)
        #expect(headers[0]["key"] as? String == "1")
        #expect(headers[0]["secret"] as? Bool == false)
        #expect(headers[0]["action"] as? String == "replace")
        #expect(headers[0]["value"] as? String == "1")
        #expect(headers[1]["secret"] as? Bool == true)
        // uid 为小写 UUID
        let uid = try #require(headers[0]["uid"] as? String)
        #expect(uid == uid.lowercased())
        #expect(UUID(uuidString: uid) != nil)
    }

    @Test("列表返回解码：url 为纯字符串、headers/body 缺省字段")
    func decodeListShape() throws {
        let json = """
        {"schemaVersion":1,"displayName":"server","preset":"genericJson",
         "url":"https://bin.webhookrelay.com/v1/webhooks/4bf09544",
         "body":{"type":"json","template":"{\\"title\\": \\"{{title}}\\"}"},"headers":[]}
        """
        let config = try JSONDecoder().decode(AlertWebhookConfig.self, from: Data(json.utf8))
        #expect(config.displayName == "server")
        #expect(config.url?.value == "https://bin.webhookrelay.com/v1/webhooks/4bf09544")
        #expect(config.presetEnum == .genericJson)
        #expect(config.headers?.isEmpty == true)
        // 解码后再次编码：url 恒为对象（action=replace）
        let data = try JSONEncoder().encode(config)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let url = try #require(root["url"] as? [String: Any])
        #expect(url["action"] as? String == "replace")
    }

    @Test("空 Header 行提交时过滤")
    func sanitizeDropsEmptyHeaders() {
        var config = AlertWebhookConfig()
        config.headers = [
            AlertWebhookHeader(key: "", value: "", secret: false),
            AlertWebhookHeader(key: "X-Token", value: "abc", secret: true)
        ]
        #expect(config.sanitizedForSubmit.headers?.count == 1)
        #expect(config.sanitizedForSubmit.headers?.first?.key == "X-Token")
    }

    @Test("测试结果解码：对象形状与裸 bool 形状")
    func decodeTestResult() throws {
        let objectShape = try JSONDecoder().decode(
            AlertWebhookTestResult.self,
            from: Data("{\"success\": true, \"statusCode\": 200, \"duration\": 1209}".utf8))
        #expect(objectShape.isPassed)
        #expect(objectShape.statusCode == 200)
        #expect(objectShape.summary.contains("200"))

        let boolShape = try JSONDecoder().decode(
            AlertWebhookTestResult.self, from: Data("true".utf8))
        #expect(boolShape.isPassed)

        let failed = try JSONDecoder().decode(
            AlertWebhookTestResult.self,
            from: Data("{\"success\": false, \"statusCode\": 404, \"duration\": 88}".utf8))
        #expect(!failed.isPassed)
    }
}

@Suite("计划任务新增类型模型")
struct CronjobNewTypeModelsTests {

    @Test("新增类型枚举解析与备份账号/压缩密码能力")
    func typeCapabilities() {
        #expect(CronjobType(rawValue: "directory") == .directory)
        #expect(CronjobType(rawValue: "log") == .log)
        #expect(CronjobType(rawValue: "curl") == .curl)
        #expect(CronjobType(rawValue: "cutWebsiteLog") == .cutWebsiteLog)
        #expect(CronjobType(rawValue: "cleanLog") == .cleanLog)

        #expect(CronjobType.directory.needsBackupAccount)
        #expect(CronjobType.log.needsBackupAccount)
        #expect(!CronjobType.curl.needsBackupAccount)
        #expect(!CronjobType.cutWebsiteLog.needsBackupAccount)
        #expect(!CronjobType.cleanLog.needsBackupAccount)

        // 压缩密码仅备份压缩产物类型（数据库备份不含）
        #expect(CronjobType.app.supportsCompressionSecret)
        #expect(CronjobType.website.supportsCompressionSecret)
        #expect(CronjobType.directory.supportsCompressionSecret)
        #expect(CronjobType.log.supportsCompressionSecret)
        #expect(CronjobType.snapshot.supportsCompressionSecret)
        #expect(!CronjobType.database.supportsCompressionSecret)
    }

    @Test("详情解码：文件列表 / urlItems / 告警字段")
    func decodeInfoFields() throws {
        let json = """
        {"id":1,"name":"文件","type":"directory","isDir":false,
         "files":[{"val":"/opt/a.png"},{"val":"/etc/b.sock"}],
         "sourceDir":"/opt/a.png,/etc/b.sock",
         "url":"https://baidu.com,https://bing.com","urlItems":["https://baidu.com","https://bing.com"],
         "scopes":["website"],"hasAlert":true,"alertCount":3,
         "alertTitle":"计划任务-清理日志「 清理日志 」任务失败告警",
         "alertMethod":"5,6","alertMethodItems":["5","6"],"secret":"111111"}
        """
        let info = try JSONDecoder().decode(CronjobInfo.self, from: Data(json.utf8))
        #expect(info.jobType == .directory)
        #expect(info.isDir == false)
        #expect(info.filePathList == ["/opt/a.png", "/etc/b.sock"])
        #expect(info.alertMethodIDSet == [5, 6])
        #expect(info.hasAlert == true)
        #expect(info.alertCount == 3)
        #expect(info.secret == "111111")
    }

    @Test("创建请求编码：文件列表为 {val} 形状 + 告警字段")
    func encodeCreateRequest() throws {
        var req = CronjobCreateRequest()
        req.type = "directory"
        req.isDir = false
        req.files = [CronjobFileItem(val: "/opt/1panel/a.png")]
        req.sourceDir = "/opt/1panel/a.png"
        req.secret = "111111"
        req.hasAlert = true
        req.alertCount = 3
        req.alertTitle = "计划任务-备份目录或文件「 文件 」任务失败告警"
        req.alertMethod = "5,6"
        req.alertMethodItems = ["5", "6"]

        let data = try JSONEncoder().encode(req)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let files = try #require(root["files"] as? [[String: Any]])
        #expect(files.first?["val"] as? String == "/opt/1panel/a.png")
        #expect(root["secret"] as? String == "111111")
        #expect(root["hasAlert"] as? Bool == true)
        #expect(root["alertMethod"] as? String == "5,6")
        #expect(root["alertMethodItems"] as? [String] == ["5", "6"])
    }
}
