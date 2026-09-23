//
//  BackupAccountsViewModel.swift
//  1PanelClient
//
//  备份账号 ViewModel + 连接测试状态（自 BackupAccountsView.swift 拆出，内容未改动）
//

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class BackupAccountsViewModel: ObservableObject {
    /// 列表数据放 VM（PageVMStore 常驻）：重访页面直接渲染上次数据
    @Published var accounts: [BackupAccount] = []
    @Published var isLoading = false
    /// 首屏加载失败（空态展示重试按钮）；已有数据时刷新失败仅弹提示、保留旧列表
    @Published var loadFailed = false
    @Published var showAlert = false
    @Published var alertMessage = ""

    private let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient.shared(for: server)
    }

    /// 列表加载（进页 / 下拉 / 增删后）：失败保留旧数据。
    /// 首屏尚无内容时不短路：秒退秒进场景下在途刷新被取消、页面为空，
    /// 短路不仅让快照卡空态，还会让 autoRefresh 误记 5 秒节流窗口
    func refresh() async {
        guard !isLoading || accounts.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        if let list = await loadAccounts() {
            accounts = list
            loadFailed = false
        } else if Task.isCancelled {
            // 页面退出取消不是失败：不标加载失败
            return
        } else if accounts.isEmpty {
            loadFailed = true
        }
    }

    /// 加载全部账号（按 total 分页拉全）；失败返回 nil（调用方保留旧数据）
    func loadAccounts() async -> [BackupAccount]? {
        let pageSize = 100
        var all: [BackupAccount] = []
        do {
            var page = 1
            var total = Int.max
            while all.count < total && page <= 20 {
                let req = BackupAccountSearchRequest(page: page, pageSize: pageSize, type: "", name: "")
                let resp: BackupAccountListResponse = try await client.send(
                    path: APIEndpoint.backupAccountsSearch.path, body: req,
                    as: BackupAccountListResponse.self
                )
                let items = resp.items ?? []
                all.append(contentsOf: items)
                total = resp.total
                if items.count < pageSize { break }
                page += 1
            }
            return all
        } catch {
            // 页面退出取消不是失败：不弹窗
            guard !APIError.isCancellation(error) else { return nil }
            showAlert(message: L10n.f("加载备份账号失败：%@", error.localizedDescription))
            return nil
        }
    }

    /// 获取存储桶列表（MINIO / 阿里云OSS）；MINIO 仅含 endpoint，OSS 另带 scType
    /// alertOnError=false 时失败不弹 VM 级 alert（桶选择页自行提示）
    /// 拉取桶列表；出错返回 nil（与「成功且为空列表」区分，调用方按需弹窗/空态）
    func fetchBuckets(type: String, vars: BackupVarsJSON, accessKey: String, credential: String,
                      alertOnError: Bool = true) async -> [String]? {
        let req = BackupBucketsRequest(
            isPublic: false, type: type, vars: vars.jsonString,
            accessKey: accessKey, credential: credential
        )
        do {
            let buckets: [String] = try await client.send(
                path: APIEndpoint.backupAccountsBuckets.path, body: req, as: [String].self
            )
            return buckets
        } catch {
            if alertOnError {
                showAlert(message: L10n.f("获取桶失败：%@", error.localizedDescription))
            }
            return nil
        }
    }

    /// 凭据 Base64（表单提交与桶拉取共用）
    static func encodeBase64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    /// 连接测试；返回失败原因（成功返回 nil）
    /// 连接测试；成功时 OAuth 类型（OneDrive/GoogleDrive）响应携带 token
    ///（Base64 的 refresh_token，由调用方解码存入 vars）
    func checkConnection(_ op: BackupAccountOperate) async -> (reason: String?, token: String?) {
        do {
            let res: BackupCheckResult = try await client.send(
                path: APIEndpoint.backupAccountsCheck.path, body: op, as: BackupCheckResult.self
            )
            if res.isOk { return (nil, res.token) }
            let msg = res.msg ?? ""
            return (msg.isEmpty ? L10n.t("连接失败") : msg, nil)
        } catch {
            return (error.localizedDescription, nil)
        }
    }

    /// OAuth 默认客户端信息（GET /backups/client/:type，OneDrive/GoogleDrive 创建时预填）
    func loadOAuthClientInfo(type: String) async -> BackupClientInfo? {
        do {
            return try await client.send(
                path: APIEndpoint.backupAccountsClientInfo.path
                    .replacingOccurrences(of: ":type", with: type),
                method: "GET", as: BackupClientInfo.self)
        } catch {
            return nil
        }
    }

    /// 创建 / 更新
    func submitAccount(_ op: BackupAccountOperate, isCreate: Bool) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: isCreate ? APIEndpoint.backupAccountsCreate.path : APIEndpoint.backupAccountsUpdate.path,
                body: op,
                as: EmptyResponse.self
            )
            return true
        } catch {
            showAlert(message: L10n.f("%@失败：%@", isCreate ? L10n.t("创建") : L10n.t("保存"), error.localizedDescription))
            return false
        }
    }

    func deleteAccount(id: Int) async -> Bool {
        let req = BackupAccountDeleteRequest(id: id)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.backupAccountsDelete.path, body: req, as: EmptyResponse.self
            )
            return true
        } catch {
            showAlert(message: L10n.f("删除失败：%@", error.localizedDescription))
            return false
        }
    }

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }
}

// MARK: - 连接测试状态

enum ConnectionCheckState: Equatable {
    case none
    case ok
    case failed(String)
}

