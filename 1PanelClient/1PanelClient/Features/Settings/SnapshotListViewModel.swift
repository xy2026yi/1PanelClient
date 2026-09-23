//
//  SnapshotListViewModel.swift
//  1PanelClient
//
//  快照列表 ViewModel（@Observable 样板，自 SnapshotViews.swift 抽出）：
//  持有数据态与网络动作；导航/弹窗呈现态留在视图。
//

import Foundation
import Observation

@Observable
@MainActor
final class SnapshotListViewModel {
    private(set) var snapshots: [SnapshotItem] = []
    private(set) var isLoading = true
    var loadError: String?
    var toastMessage: String?
    var errorMessage: String?
    var showError = false

    private let client: APIClient

    init(server: ServerConfig) {
        client = APIClient.shared(for: server)
    }

    func load() async {
        do {
            let resp: SnapshotSearchResponse = try await client.send(
                path: APIEndpoint.settingsSnapshotSearch.path,
                body: SnapshotSearchRequest(page: 1, pageSize: 100, orderBy: "createdAt", order: "null"),
                as: SnapshotSearchResponse.self)
            snapshots = resp.items ?? []
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    func delete(_ snapshot: SnapshotItem, deleteWithFile: Bool) async {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.settingsSnapshotDelete.path,
                body: SnapshotDeleteRequest(ids: [snapshot.id], deleteWithFile: deleteWithFile),
                as: EmptyResponse.self)
            toastMessage = L10n.f("已删除「%@」", snapshot.displayName)
            await load()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// 提交恢复任务（isNew=true / reDownload=false，抓包确认）；
    /// 成功返回 taskID（视图跳任务进度页），失败弹错误并返回 nil
    func recover(_ snapshot: SnapshotItem, secret: String, taskID: String) async -> String? {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.settingsSnapshotRecover.path,
                body: SnapshotRecoverRequest(
                    id: snapshot.id, taskID: taskID,
                    isNew: true, reDownload: false, secret: secret),
                as: EmptyResponse.self)
            return taskID
        } catch {
            guard !APIError.isCancellation(error) else { return nil }
            errorMessage = error.localizedDescription
            showError = true
            return nil
        }
    }

    /// 修改快照描述；返回 nil 表示成功（Sheet 自动收起），非 nil 为错误文案
    func submitDescription(_ snapshot: SnapshotItem, _ newText: String) async -> String? {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.settingsSnapshotDescriptionUpdate.path,
                body: DescriptionUpdateRequest(id: snapshot.id, description: newText),
                as: EmptyResponse.self)
            if let idx = snapshots.firstIndex(where: { $0.id == snapshot.id }) {
                snapshots[idx] = snapshot.withDescription(newText)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 重新制作快照（服务端沿用原任务 ID 续跑）；
    /// 有原任务 ID 时返回它（视图跳任务进度页），否则置提示返回 nil
    func recreate(_ snapshot: SnapshotItem) async -> String? {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.settingsSnapshotRecreate.path,
                body: SnapshotRecreateRequest(id: snapshot.id),
                as: EmptyResponse.self)
            if let taskID = snapshot.taskID, !taskID.isEmpty {
                return taskID
            }
            toastMessage = L10n.t("已提交重新制作")
            return nil
        } catch {
            guard !APIError.isCancellation(error) else { return nil }
            errorMessage = error.localizedDescription
            showError = true
            return nil
        }
    }
}
