//
//  CronjobsViewModel.swift
//  1PanelClient
//

import SwiftUI
import Combine

// MARK: - ViewModel

final class CronjobsViewModel: ObservableObject {
    @Published var cronjobs: [Cronjob] = []
    @Published var isLoading = false
    @Published var isCreating = false
    @Published var errorMessage: String?

    @Published var showAlert = false
    @Published var alertMessage = ""

    /// 轻量提示（自动消失，无需确认）
    @Published var toastMessage: String?
    private var toastTask: Task<Void, Never>?

    /// 列表删除确认
    @Published var pendingDeleteJob: Cronjob?
    @Published var deleteCleanData = false

    /// 执行记录
    @Published var records: [CronjobRecord] = []
    @Published var isLoadingRecords = false

    /// 日志
    @Published var logLines: [String] = []
    @Published var isLoadingLog = false
    @Published var logError: String?

    /// 创建表单所需选项
    @Published var systemUsers: [String] = []
    @Published var backupAccounts: [BackupOption] = []
    @Published var installedApps: [InstalledAppOption] = []
    @Published var websiteOptions: [WebsiteOptionSimple] = []
    @Published var dbItems: [DBItemOption] = []
    @Published var isLoadingDBItems = false

    /// 默认分组 ID（创建任务时必须填，否则任务会显示在「-」分组）
    /// 从 POST /api/v2/core/groups/search (type=cronjob) 获取 isDefault=true 的项
    @Published var defaultGroupID: Int = 0

    private(set) var client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let resp: CronjobListResponse = try await client.send(
                path: APIEndpoint.cronjobsSearch.path,
                body: CronjobSearchRequest(),
                as: CronjobListResponse.self
            )
            cronjobs = resp.items ?? []
        } catch let err as APIError {
            errorMessage = err.errorDescription
            showAlert(message: "加载失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            errorMessage = error.localizedDescription
            showAlert(message: "加载失败：\(error.localizedDescription)")
        }
    }

    func handle(job: Cronjob) async {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.cronjobsHandle.path,
                body: CronjobHandleRequest(id: job.id),
                as: EmptyResponse.self
            )
            await refresh()
            showToast("任务「\(job.name ?? "")」已开始执行")
        } catch let err as APIError {
            showAlert(message: "执行失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "执行失败：\(error.localizedDescription)")
        }
    }

    /// 启用/停用计划任务（POST /api/v2/cronjobs/status）
    func updateStatus(job: Cronjob, enabled: Bool) async {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.cronjobsStatus.path,
                body: CronjobUpdateStatusRequest(id: job.id, status: enabled ? "Enable" : "Disable"),
                as: EmptyResponse.self
            )
            await refresh()
            showToast("任务「\(job.name ?? "")」已\(enabled ? "启用" : "停用")")
        } catch let err as APIError {
            showAlert(message: "操作失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "操作失败：\(error.localizedDescription)")
        }
    }

    @discardableResult
    func delete(job: Cronjob) async -> Bool {
        pendingDeleteJob = nil
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.cronjobsDelete.path,
                body: CronjobDeleteRequest(
                    ids: [job.id],
                    cleanData: deleteCleanData,
                    cleanRemoteData: deleteCleanData
                ),
                as: EmptyResponse.self
            )
            deleteCleanData = false
            showToast("任务「\(job.name ?? "")」已删除")
            await refresh()
            return true
        } catch let err as APIError {
            showAlert(message: "删除失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "删除失败：\(error.localizedDescription)")
            return false
        }
    }

    func create(req: CronjobCreateRequest) async -> Bool {
        isCreating = true
        defer { isCreating = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.cronjobsCreate.path,
                body: req,
                as: EmptyResponse.self
            )
            await refresh()
            return true
        } catch let err as APIError {
            showAlert(message: "创建失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "创建失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 更新计划任务（POST /api/v2/cronjobs/update）
    @discardableResult
    func update(req: CronjobCreateRequest) async -> Bool {
        isCreating = true
        defer { isCreating = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.cronjobsUpdate.path,
                body: req,
                as: EmptyResponse.self
            )
            showToast("任务「\(req.name)」已更新")
            await refresh()
            return true
        } catch let err as APIError {
            showAlert(message: "更新失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "更新失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 加载计划任务详情（POST /api/v2/cronjobs/load/info），用于编辑表单预填
    func loadCronjobInfo(id: Int) async -> CronjobInfo? {
        do {
            let info: CronjobInfo = try await client.send(
                path: APIEndpoint.cronjobsLoadInfo.path,
                body: CronjobLoadInfoRequest(id: id),
                as: CronjobInfo.self
            )
            return info
        } catch let err as APIError {
            showAlert(message: "加载详情失败：\(err.errorDescription ?? "未知错误")")
            return nil
        } catch {
            showAlert(message: "加载详情失败：\(error.localizedDescription)")
            return nil
        }
    }

    func loadRecords(jobId: Int) async {
        isLoadingRecords = true
        defer { isLoadingRecords = false }

        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        let start = Calendar.current.date(byAdding: .month, value: -3, to: now) ?? now
        let startStr = df.string(from: start)
        let endStr = df.string(from: now)

        let req = CronjobRecordSearchRequest(
            page: 1, pageSize: 20,
            cronjobID: jobId,
            startTime: startStr, endTime: endStr,
            status: ""
        )
        do {
            let resp: CronjobRecordListResponse = try await client.send(
                path: APIEndpoint.cronjobsRecords.path,
                body: req,
                as: CronjobRecordListResponse.self
            )
            records = resp.items ?? []
        } catch let err as APIError {
            showAlert(message: "记录加载失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "记录加载失败：\(error.localizedDescription)")
        }
    }

    func loadLog(taskID: String) async {
        isLoadingLog = true
        logLines = []
        logError = nil
        defer { isLoadingLog = false }

        let req = CronjobLogRequest(page: 1, pageSize: 500, latest: true, taskID: taskID)
        do {
            let resp: CronjobLogResponse = try await client.send(
                path: APIEndpoint.logsTaskRead.path,
                body: req,
                as: CronjobLogResponse.self
            )
            logLines = resp.lines ?? []
        } catch {
            logError = error.localizedDescription
        }
    }

    func loadCreateOptions() async {
        // 默认分组（创建任务必须指定 groupID，否则任务会显示在「-」分组）
        if defaultGroupID == 0 {
            do {
                let groups: [CronjobGroup] = try await client.send(
                    path: APIEndpoint.cronjobsGroups.path,
                    body: CronjobGroupRequest(type: "cronjob"),
                    as: [CronjobGroup].self
                )
                // 优先取 isDefault=true 的项，否则取第一个
                if let def = groups.first(where: { $0.isDefault == true }) {
                    defaultGroupID = def.id
                } else if let first = groups.first {
                    defaultGroupID = first.id
                }
            } catch {
                // 加载失败保持 0，后端会用其默认值
            }
        }
        // 系统用户
        if systemUsers.isEmpty {
            do {
                systemUsers = try await client.send(
                    path: APIEndpoint.cronjobsUsers.path,
                    method: "GET",
                    as: [String].self
                )
            } catch {
                systemUsers = ["root"]
            }
        }
        // 备份账号
        if backupAccounts.isEmpty {
            do {
                backupAccounts = try await client.send(
                    path: APIEndpoint.cronjobsBackups.path,
                    method: "GET",
                    as: [BackupOption].self
                )
            } catch {
                backupAccounts = []
            }
        }
        // 已安装应用（用于备份应用）
        if installedApps.isEmpty {
            do {
                installedApps = try await client.send(
                    path: "/api/v2/apps/installed/list",
                    method: "GET",
                    as: [InstalledAppOption].self
                )
            } catch {
                installedApps = []
            }
        }
        // 网站列表（用于备份网站）
        if websiteOptions.isEmpty {
            do {
                websiteOptions = try await client.send(
                    path: "/api/v2/websites/options",
                    body: EmptyRequest(),
                    as: [WebsiteOptionSimple].self
                )
            } catch {
                websiteOptions = []
            }
        }
    }

    /// 加载指定类型的数据库实例列表（用于备份数据库任务）
    func loadDBItems(dbType: String) async {
        isLoadingDBItems = true
        dbItems = []
        do {
            dbItems = try await client.send(
                path: "/api/v2/databases/db/item/\(dbType)",
                method: "GET",
                as: [DBItemOption].self
            )
        } catch {
            dbItems = []
        }
        isLoadingDBItems = false
    }

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { self?.toastMessage = nil }
        }
    }
}

// MARK: - 辅助轻量模型（创建表单下拉用）

/// 已安装应用简表（GET /api/v2/apps/installed/list）
struct InstalledAppOption: Decodable, Identifiable, Hashable {
    let id: Int
    let key: String?
    let name: String?
}

/// 网站简表（POST /api/v2/websites/options）
struct WebsiteOptionSimple: Decodable, Identifiable, Hashable {
    let id: Int
    let primaryDomain: String?
    let alias: String?
}

/// 空 POST body
struct EmptyRequest: Encodable {}
