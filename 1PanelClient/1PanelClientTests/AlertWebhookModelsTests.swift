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

    @Test("详情解码：文件列表 / urlItems / 告警字段 + 通知条件（v2.4.0 alertTriggerMode）")
    func decodeInfoFields() throws {
        let json = """
        {"id":1,"name":"文件","type":"directory","isDir":false,
         "files":[{"val":"/opt/a.png"},{"val":"/etc/b.sock"}],
         "sourceDir":"/opt/a.png,/etc/b.sock",
         "url":"https://baidu.com,https://bing.com","urlItems":["https://baidu.com","https://bing.com"],
         "scopes":["website"],"hasAlert":true,"alertCount":3,
         "alertTitle":"计划任务-清理日志「 清理日志 」任务失败告警",
         "alertMethod":"5,6","alertMethodItems":["5","6"],
         "alertTriggerMode":"both","secret":"111111"}
        """
        let info = try JSONDecoder().decode(CronjobInfo.self, from: Data(json.utf8))
        #expect(info.jobType == .directory)
        #expect(info.isDir == false)
        #expect(info.filePathList == ["/opt/a.png", "/etc/b.sock"])
        #expect(info.alertMethodIDSet == [5, 6])
        #expect(info.hasAlert == true)
        #expect(info.alertCount == 3)
        #expect(info.secret == "111111")
        // 通知条件（抓包 2026-10-21：列表项含 alertTriggerMode）
        #expect(info.alertTriggerModeValue == "both")
        // 旧面板无该字段 → 回落「仅失败」
        let legacy = try JSONDecoder().decode(CronjobInfo.self,
            from: Data(#"{"id":2,"name":"旧","type":"shell","hasAlert":true,"alertCount":3}"#.utf8))
        #expect(legacy.alertTriggerMode == nil && legacy.alertTriggerModeValue == "failed")
    }

    /// 抓包 2026-10-22（列表 search）：列表项带 alertCount + alertTriggerMode
    /// 且无 hasAlert——告警关闭时 Web 端提交 alertCount=0，>0 即已设置
    @Test("列表解码：alertCount/alertTriggerMode（已设置判定与归一；抓包 2026-10-22）")
    func decodeListAlertFields() throws {
        let json = """
        {"total":2,"items":[
         {"id":53,"name":"5654658","type":"shell","scriptMode":"input","script":"#!/bin/bash",
          "status":"Enable","alertCount":3,"alertTriggerMode":"failed"},
         {"id":50,"name":"234","type":"shell","scriptMode":"input",
          "status":"Enable","alertCount":3,"alertTriggerMode":"both"}]}
        """
        struct Resp: Decodable { let items: [Cronjob] }
        let resp = try JSONDecoder().decode(Resp.self, from: Data(json.utf8))
        let alerted = try #require(resp.items.first)
        #expect(alerted.alertCount == 3)
        #expect(alerted.hasAlertConfigured == true)
        #expect(alerted.alertTriggerModeValue == "failed")
        let both = try #require(resp.items.last)
        #expect(both.alertTriggerModeValue == "both")

        // 未设置告警 / 旧面板缺字段：不判为已设置，条件归一回落 failed
        let off = try JSONDecoder().decode(Cronjob.self,
            from: Data(#"{"id":9,"name":"无告警","type":"shell","alertCount":0}"#.utf8))
        #expect(off.hasAlertConfigured == false)
        let legacy = try JSONDecoder().decode(Cronjob.self,
            from: Data(#"{"id":8,"name":"旧","type":"shell"}"#.utf8))
        #expect(legacy.hasAlertConfigured == false && legacy.alertTriggerModeValue == "failed")
    }

    @Test("创建请求编码：文件列表为 {val} 形状 + 告警字段 + 通知条件")
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
        req.alertTriggerMode = "success"

        let data = try JSONEncoder().encode(req)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let files = try #require(root["files"] as? [[String: Any]])
        #expect(files.first?["val"] as? String == "/opt/1panel/a.png")
        #expect(root["secret"] as? String == "111111")
        #expect(root["hasAlert"] as? Bool == true)
        #expect(root["alertMethod"] as? String == "5,6")
        #expect(root["alertMethodItems"] as? [String] == ["5", "6"])
        // 通知条件随请求提交；缺省值为 failed（与 Web 表单默认一致）
        #expect(root["alertTriggerMode"] as? String == "success")
        let defaulted = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CronjobCreateRequest())) as? [String: Any]
        #expect(defaulted?["alertTriggerMode"] as? String == "failed")
    }

    /// 抓包 2026-10-22：Shell 脚本来源三模式提交形状——library 只携 scriptID
    /// （script 置空串）；select（路径选择）携路径于 script、scriptID 置空
    @Test("Shell 脚本来源提交形状（library 只携 scriptID / select 携路径；抓包 2026-10-22）")
    func encodeShellScriptModes() throws {
        var library = CronjobCreateRequest()
        library.type = "shell"
        library.scriptMode = "library"
        library.script = ""
        library.scriptID = 12
        let lroot = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(library)) as? [String: Any])
        #expect(lroot["scriptMode"] as? String == "library")
        #expect(lroot["scriptID"] as? Int == 12)
        #expect((lroot["script"] as? String)?.isEmpty == true)

        var select = CronjobCreateRequest()
        select.type = "shell"
        select.scriptMode = "select"
        select.script = "/root/1.sh"
        let sroot = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(select)) as? [String: Any])
        #expect(sroot["scriptMode"] as? String == "select")
        #expect(sroot["script"] as? String == "/root/1.sh")
        #expect(sroot["scriptID"] == nil)
    }
}

// MARK: - 告警规则类型（v2.4.0 计划任务告警）

@Suite("告警规则类型归并")
struct AlertRuleTypeTests {

    /// 抓包 2026-10-22（告警列表）：计划任务创建的告警 type 为任务类型
    /// （shell/…，随 taskName/project），统一识别为「计划任务执行异常」；
    /// 触发条件解析 advancedParams 的通知条件
    @Test("计划任务告警类型归并 + advancedParams 通知条件（抓包 2026-10-22）")
    func cronjobAlertRuleMapping() throws {
        func rule(_ json: String) throws -> AlertRule {
            try JSONDecoder().decode(AlertRule.self, from: Data(json.utf8))
        }
        let failed = try rule("""
        {"id":10,"type":"shell","cycle":0,"count":0,"method":"5",
         "title":"计划任务-Shell 脚本「 5654658 」任务失败告警",
         "project":"53","taskName":"5654658","status":"Enable","sendCount":3,
         "advancedParams":"{\\"alertTriggerMode\\":\\"failed\\"}"}
        """)
        #expect(failed.alertType == .cronjob)
        #expect(failed.alertType.displayName == L10n.t("计划任务执行异常"))
        #expect(failed.conditionDisplay == L10n.t("仅失败"))

        let both = try rule("""
        {"id":9,"type":"app","cycle":0,"count":0,"method":"5",
         "title":"计划任务-备份应用「 234 」任务失败告警",
         "project":"50","status":"Enable","sendCount":3,
         "advancedParams":"{\\"alertTriggerMode\\":\\"both\\"}"}
        """)
        #expect(both.alertType == .cronjob)
        #expect(both.conditionDisplay == L10n.t("成功或失败"))

        // 面板类告警不受影响；缺 advancedParams 的任务告警回落「仅失败」
        let panel = try rule(#"{"id":5,"type":"panelPwdEndTime","cycle":15,"method":"5","status":"Enable","advancedParams":""}"#)
        #expect(panel.alertType == .panelPwdEndTime)
        let noParams = try rule(#"{"id":8,"type":"database","method":"5","status":"Enable"}"#)
        #expect(noParams.alertType == .cronjob)
        #expect(noParams.conditionDisplay == L10n.t("仅失败"))
    }

    /// 抓包 2026-10-22（创建计划任务告警）：type/subType 为任务类型、project 为
    /// 任务 id、通知条件顶层与 advancedParams JSON 双写
    @Test("计划任务告警创建请求编码（type=任务类型 + 通知条件双写；抓包 2026-10-22）")
    func cronjobAlertUpsertEncode() throws {
        var req = AlertUpsertRequest(
            type: "shell", cycle: 0, count: 0, sendCount: 3,
            method: "5", project: "49", status: "Enable",
            title: "计划任务-Shell 脚本「123」执行告警",
            sendMethod: ["__all__"])
        req.alertTriggerMode = "success"
        req.advancedParams = #"{"alertTriggerMode":"success"}"#
        req.subType = "shell"
        let root = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(req)) as? [String: Any])
        #expect(root["type"] as? String == "shell")
        #expect(root["subType"] as? String == "shell")
        #expect(root["project"] as? String == "49")
        #expect(root["sendCount"] as? Int == 3)
        #expect(root["alertTriggerMode"] as? String == "success")
        #expect(root["advancedParams"] as? String == #"{"alertTriggerMode":"success"}"#)
    }

    /// 抓包 2026-10-22（alert/cronjob/list）：按任务类型查询可告警任务
    @Test("可告警计划任务列表解码（id/name/status/type；抓包 2026-10-22）")
    func alertCronjobOptionsDecode() throws {
        let json = """
        [{"id":49,"name":"123","status":"Enable","type":"shell"},
         {"id":50,"name":"234","status":"Enable","type":"shell"},
         {"id":53,"name":"5654658","status":"Enable","type":"shell"}]
        """
        let items = try JSONDecoder().decode([AlertCronjobOption].self, from: Data(json.utf8))
        #expect(items.count == 3)
        #expect(items.first?.id == 49 && items.first?.name == "123")
        #expect(items.last?.name == "5654658")
    }
}
