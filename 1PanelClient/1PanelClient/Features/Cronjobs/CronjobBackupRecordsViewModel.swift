//
//  CronjobBackupRecordsViewModel.swift
//  1PanelClient
//
//  计划任务备份记录 ViewModel（@Observable 样板）：
//  bycronjob 分页拉全 + 描述修改；导航/弹窗呈现态留在视图。
//

import Foundation
import Observation

@Observable
@MainActor
final class CronjobBackupRecordsViewModel {
    private(set) var records: [BackupRecord] = []
    private(set) var isLoading = true
    var loadError: String?
    var toastMessage: String?

    private let jobID: Int
    private let client: APIClient

    init(job: Cronjob, client: APIClient) {
        self.jobID = job.id
        self.client = client
    }

    func load() async {
        do {
            let pageSize = 100
            var all: [BackupRecord] = []
            var page = 1
            var total = Int.max
            while all.count < total && page <= 20 {
                let resp: BackupRecordListResponse = try await client.send(
                    path: APIEndpoint.backupsRecordSearchByCronjob.path,
                    body: BackupRecordByCronjobRequest(page: page, pageSize: pageSize, cronjobID: jobID),
                    as: BackupRecordListResponse.self
                )
                let items = resp.items ?? []
                all.append(contentsOf: items)
                total = resp.total
                if items.count < pageSize { break }
                page += 1
            }
            records = all
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    /// 提交描述修改；返回 nil 表示成功，非 nil 为错误文案（Sheet 内展示）
    func submitDescription(_ record: BackupRecord, _ newText: String) async -> String? {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.backupsRecordDescriptionUpdate.path,
                body: DescriptionUpdateRequest(id: record.id, description: newText),
                as: EmptyResponse.self
            )
            if let idx = records.firstIndex(where: { $0.id == record.id }) {
                records[idx] = record.withDescription(newText)
            }
            toastMessage = L10n.t("描述已更新")
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
