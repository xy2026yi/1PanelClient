//
//  BackupRecordModelsTests.swift
//  1PanelClientTests
//
//  备份记录模型测试：bycronjob 分页请求 / 描述修改请求 / withDescription 回写
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("备份记录模型（bycronjob + 描述修改）")
struct BackupRecordModelsTests {

    private func encode(_ req: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
    }

    @Test("按计划任务过滤请求编码（上游 dto.RecordSearchByCronjob：PageInfo + cronjobID）")
    func encodeByCronjobRequest() throws {
        let req = try encode(BackupRecordByCronjobRequest(page: 1, pageSize: 100, cronjobID: 7))
        #expect(req["page"] as? Int == 1)
        #expect(req["pageSize"] as? Int == 100)
        #expect(req["cronjobID"] as? Int == 7)
    }

    @Test("bycronjob 响应解码（items 与 record/search 同构）")
    func decodeByCronjobResponse() throws {
        let json = """
        {"total":1,"items":[{"id":512,"createdAt":"2026-09-22T03:00:00+08:00",
         "accountType":"LOCAL","accountName":"localhost","downloadAccountID":1,
         "fileDir":"/opt/1panel/backup/system_snapshot","fileName":"snapshot-xxx.tar.gz",
         "taskID":"a1b2","status":"Success","message":"","description":"每日备份"}]}
        """
        let resp = try JSONDecoder().decode(BackupRecordListResponse.self, from: Data(json.utf8))
        #expect(resp.total == 1)
        let record = try #require(resp.items?.first)
        #expect(record.id == 512)
        #expect(record.fullPath == "/opt/1panel/backup/system_snapshot/snapshot-xxx.tar.gz")
        #expect(record.description == "每日备份")
    }

    @Test("描述回写副本仅变更描述字段")
    func withDescriptionKeepsOtherFields() {
        let record = BackupRecord(
            id: 512, createdAt: "2026-09-22T03:00:00+08:00", accountType: "LOCAL",
            accountName: "localhost", downloadAccountID: 1,
            fileDir: "/opt/1panel/backup", fileName: "snapshot-xxx.tar.gz",
            taskID: "a1b2", status: "Success", message: "", description: nil)
        let rewritten = record.withDescription("改名")
        #expect(rewritten.description == "改名")
        #expect(rewritten.id == record.id)
        #expect(rewritten.fileName == record.fileName)
        #expect(rewritten.status == record.status)
    }

    @Test("备份任务类型判定（备份类才有「备份记录」入口）")
    func cronjobTypeProducesRecords() {
        #expect(CronjobType.app.producesBackupRecords)
        #expect(CronjobType.website.producesBackupRecords)
        #expect(CronjobType.database.producesBackupRecords)
        #expect(CronjobType.directory.producesBackupRecords)
        #expect(CronjobType.log.producesBackupRecords)
        #expect(CronjobType.snapshot.producesBackupRecords)
        #expect(!CronjobType.shell.producesBackupRecords)
        #expect(!CronjobType.curl.producesBackupRecords)
        #expect(!CronjobType.cleanLog.producesBackupRecords)
    }
}
