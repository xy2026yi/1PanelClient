//
//  LogsModelsTests.swift
//  1PanelClientTests
//
//  登陆日志清空/导出请求体（POST /hosts/ssh/log/clean|export 抓包 2026-10-26）
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("日志模型")
struct LogsModelsTests {

    private func encode(_ req: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
    }

    @Test("清空登陆日志请求体为空对象")
    func encodeClean() throws {
        let body = try encode(SSHLogCleanRequest())
        #expect(body.isEmpty)
    }

    @Test("导出登陆日志：状态/条数组合（All→-1 不限，Success/Failed→正数）")
    func encodeExport() throws {
        // 所有 + 所有
        let all = try encode(SSHLogExportRequest())
        #expect(all["info"] as? String == "")
        #expect(all["status"] as? String == "All")
        #expect(all["page"] as? Int == 1)
        #expect(all["pageSize"] as? Int == -1)

        // 成功 + 100
        let success = try encode(SSHLogExportRequest(status: "Success", pageSize: 100))
        #expect(success["status"] as? String == "Success")
        #expect(success["pageSize"] as? Int == 100)

        // 失败 + 1000
        let failed = try encode(SSHLogExportRequest(status: "Failed", pageSize: 1000))
        #expect(failed["status"] as? String == "Failed")
        #expect(failed["pageSize"] as? Int == 1000)
    }

    @Test("清空面板日志：logType 区分操作/登录（抓包 2026-10-26）")
    func encodeCoreClean() throws {
        let operation = try encode(CoreLogCleanRequest(logType: "operation"))
        #expect(operation["logType"] as? String == "operation")

        let login = try encode(CoreLogCleanRequest(logType: "login"))
        #expect(login["logType"] as? String == "login")
    }

    @Test("网站日志操作：delete 携带 id 与 logType（access/error；抓包 2026-10-26）")
    func encodeWebsiteLogOperate() throws {
        let access = try encode(WebsiteLogOperateRequest(id: 4, operate: "delete", logType: "access.log"))
        #expect(access["id"] as? Int == 4)
        #expect(access["operate"] as? String == "delete")
        #expect(access["logType"] as? String == "access.log")

        let error = try encode(WebsiteLogOperateRequest(id: 4, operate: "delete", logType: "error.log"))
        #expect(error["logType"] as? String == "error.log")
    }
}
