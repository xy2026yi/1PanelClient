//
//  AppsViewModel.swift
//  1PanelClient
//

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class AppsViewModel: ObservableObject {
    @Published var apps: [AppInstall] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var operatingAppIds: Set<Int> = []

    // 升级相关
    @Published var showUpgradeSheet = false
    @Published var availableVersions: [AppVersion] = []
    @Published var isLoadingVersions = false
    @Published var upgradingVersionId: Int?
    @Published var loadingComposeVersionId: Int?
    /// 当前选中的要升级到的版本（在 ComposeEditorView 里使用）
    @Published var selectedVersion: AppVersion?
    /// 标记升级是否成功完成（用于编辑器返回时的判断）
    @Published var upgradeSuccess = false
    /// 升级进度视图：提交升级成功后展示任务进度
    @Published var showUpgradeProgress = false
    @Published var upgradeTaskID = ""

    // 操作提示
    @Published var showAlert = false
    @Published var alertMessage = ""
    /// alert 确认后自动返回上一层（用于忽略升级成功后）
    @Published var pendingDismissUpgrade = false

    // 卸载相关
    @Published var isUninstalling = false
    @Published var uninstallDone = false

    // 更新参数相关
    @Published var isLoadingParams = false
    @Published var loadedParams: InstalledParamsResponse?
    @Published var isUpdatingParams = false
    @Published var paramsUpdated = false

    /// 标记列表需要刷新（在详情页操作后置 true，返回列表时触发刷新）
    @Published var needsRefresh = false

    /// 应用商店设置（卸载/升级/安装默认选项），供弹窗读取默认勾选
    @Published var appStoreConfig: AppStoreConfig?
    @Published var isLoadingAppStoreConfig = false

    private(set) var client: APIClient

    var updatableCount: Int {
        apps.filter { $0.canUpdate == true }.count
    }

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    func refresh() async {
        await load(query: "")
    }

    func search(query: String) async {
        await load(query: query)
    }

    // MARK: - 应用关联网站

    /// 当前打开应用详情的关联网站（nil=未加载，空=无关联）
    @Published var linkedWebsites: [Website]?

    /// 加载与指定应用关联的网站（website.appInstallId == app.id）；
    /// 加载期间置 nil 隐藏「网站」行，失败按无关联处理，不阻断详情页
    func loadLinkedWebsites(appID: Int) async {
        linkedWebsites = nil
        let req = WebsiteSearchRequest(
            name: "", page: 1, pageSize: 100,
            orderBy: "favorite", order: "descending",
            websiteGroupId: 0, type: ""
        )
        do {
            let resp: WebsiteListResponse = try await client.send(
                path: APIEndpoint.websitesSearch.path,
                body: req,
                as: WebsiteListResponse.self
            )
            linkedWebsites = (resp.items ?? []).filter { $0.appInstallId == appID }
        } catch {
            linkedWebsites = []
        }
    }

    private func load(query: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // update=false 返回全部应用但 canUpdate 始终 false（后端不计算）
        // update=true  只返回可更新的应用，但正确计算 canUpdate
        // 通过 logs/输出20.log 验证：两者 total 不同
        // 解决方案：先拿全部应用，再并发拿可更新列表，用后者标记前者的 canUpdate
        let allReq = AppInstalledSearchRequest(
            page: 1, pageSize: 100, name: query, type: "", tags: [],
            update: false, all: false, unused: false, sync: false
        )
        // 查询可更新列表时不用 name 过滤，因为可能被搜索词过滤掉
        let updatableReq = AppInstalledSearchRequest(
            page: 1, pageSize: 100, name: "", type: "", tags: [],
            update: true, all: false, unused: false, sync: false
        )

        do {
            async let allResp: AppInstalledListResponse = client.send(
                path: APIEndpoint.appsInstalledSearch.path,
                body: allReq,
                as: AppInstalledListResponse.self
            )
            async let updatableResp: AppInstalledListResponse = client.send(
                path: APIEndpoint.appsInstalledSearch.path,
                body: updatableReq,
                as: AppInstalledListResponse.self
            )
            // 并发拉取已忽略列表（GET 接口，失败不阻断主流程）
            async let ignoredResp: [AppIgnoreUpgrade] = client.send(
                path: APIEndpoint.appsIgnoredList.path,
                method: APIEndpoint.appsIgnoredList.method,
                as: [AppIgnoreUpgrade].self
            )

            let (all, updatable) = try await (allResp, updatableResp)
            // ignored 拉取失败则降级为空数组（不阻断应用列表展示）
            let ignored = (try? await ignoredResp) ?? []
            var apps = all.items ?? []
            let updatableMap = Dictionary((updatable.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // 构建 appID → ignoredRecordID 映射
            let ignoredMap = Dictionary(ignored.compactMap { item -> (Int, Int)? in
                guard let appID = item.appID else { return nil }
                return (appID, item.id)
            }, uniquingKeysWith: { a, _ in a })

            // 合并可更新状态、dockerCompose、忽略记录 ID
            for i in apps.indices {
                if let updatableApp = updatableMap[apps[i].id] {
                    apps[i].canUpdate = true
                    apps[i].currentDockerCompose = updatableApp.dockerCompose
                } else {
                    apps[i].canUpdate = false
                }
                if let appID = apps[i].appID {
                    apps[i].ignoredRecordID = ignoredMap[appID]
                }
            }
            self.apps = apps
        } catch let err as APIError {
            self.errorMessage = err.errorDescription
            self.apps = []
        } catch {
            self.errorMessage = error.localizedDescription
            self.apps = []
        }
    }

    // MARK: - 启动/停止/重启

    func operate(app: AppInstall, op: AppOperation) async {
        operatingAppIds.insert(app.id)
        defer { operatingAppIds.remove(app.id) }

        let req = AppInstalledOperateRequest(installId: app.id, operate: op.rawValue)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledOperate.path,
                body: req,
                as: EmptyResponse.self
            )
            // rebuild 是异步操作，状态不会立即变化，需要明确反馈
            if op == .rebuild {
                showAlert(message: "\(app.displayName) 重建请求已提交，容器正在后台重建…")
                needsRefresh = true
            }
            // 所有操作都刷新列表，让详情页 currentApp 能反映最新状态
            try? await Task.sleep(for: .seconds(1))
            await load(query: "")
        } catch let err as APIError {
            showAlert(message: "\(op.displayName)失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "\(op.displayName)失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 升级流程

    func loadVersions(for app: AppInstall) async {
        availableVersions = []
        selectedVersion = nil
        upgradeSuccess = false
        isLoadingVersions = true
        showUpgradeSheet = true

        do {
            // 服务端已按 CompareVersion(仅更高版本)/忽略记录/跨版本规则过滤，
            // 客户端不再按 detailId 二次过滤：应用商店原地升版本号时，
            // 可升级目标与当前安装是同一条 detail 记录，过滤会把唯一版本滤没
            let versions: [AppVersion] = try await client.send(
                path: APIEndpoint.appsUpdateVersions.path,
                body: AppUpdateVersionsRequest(appInstallId: app.id),
                queryItems: [URLQueryItem(name: "operateNode", value: "local")],
                as: [AppVersion].self
            )
            self.availableVersions = versions
        } catch let err as APIError {
            showAlert(message: "查询版本失败：\(err.errorDescription ?? "未知错误")")
            showUpgradeSheet = false
        } catch {
            showAlert(message: "查询版本失败：\(error.localizedDescription)")
            showUpgradeSheet = false
        }
        isLoadingVersions = false
    }

    func prepareComposeEditor(app: AppInstall, version: AppVersion) async -> Bool {
        if let dockerCompose = version.dockerCompose, !dockerCompose.isEmpty {
            selectedVersion = version
            return true
        }

        guard let updateVersion = version.version, !updateVersion.isEmpty else {
            selectedVersion = version
            return true
        }

        loadingComposeVersionId = version.detailId
        defer { loadingComposeVersionId = nil }

        do {
            let versions: [AppVersion] = try await client.send(
                path: APIEndpoint.appsUpdateVersions.path,
                body: AppUpdateVersionsRequest(appInstallId: app.id, updateVersion: updateVersion),
                queryItems: [URLQueryItem(name: "operateNode", value: "local")],
                as: [AppVersion].self
            )
            let preparedVersion = versions.first(where: { $0.detailId == version.detailId })
                ?? versions.first(where: { $0.version == updateVersion })
                ?? version
            selectedVersion = preparedVersion
            if let versionIndex = availableVersions.firstIndex(where: { $0.detailId == preparedVersion.detailId }) {
                availableVersions[versionIndex] = preparedVersion
            }
            return true
        } catch let err as APIError {
            showAlert(message: "加载新版本配置失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "加载新版本配置失败：\(error.localizedDescription)")
            return false
        }
    }

    func confirmUpgrade(
        app: AppInstall,
        to version: AppVersion,
        customCompose: String?,
        deleteOldImage: Bool,
        taskID: String
    ) async {
        upgradingVersionId = version.detailId
        upgradeSuccess = false
        defer { upgradingVersionId = nil }

        let req = AppInstalledOperateRequest(
            installId: app.id,
            operate: AppOperation.upgrade.rawValue,
            detailId: version.detailId,
            backup: appStoreConfig?.isUpgradeBackup ?? true,
            pullImage: true,
            dockerCompose: customCompose,
            deleteImage: deleteOldImage,
            taskID: taskID
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledOperate.path,
                body: req,
                as: EmptyResponse.self
            )
            upgradeSuccess = true
            // 先置位 taskID，再触发进度视图导航（progress 的 navigationDestination 挂在
            // UpgradeSheetView 上，因此不能关闭 UpgradeSheetView，否则会失去锚点导致白屏）。
            // 进度页完成时由 .popAppDetail 通知一次性 pop 回应用列表。
            upgradeTaskID = taskID
            showUpgradeProgress = true
        } catch let err as APIError {
            showAlert(message: "升级失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "升级失败：\(error.localizedDescription)")
        }
    }

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }

    // MARK: - 忽略升级

    /// 忽略指定版本的升级（在版本列表里左滑）
    func ignoreUpgrade(app: AppInstall, version: AppVersion) async {
        let req = AppIgnoreUpgradeRequest(
            appID: app.appID ?? 0,
            scope: "version",
            appDetailID: version.detailId
        )
        await performIgnore(req: req, app: app, successMsg: "已忽略 v\(version.version ?? "") 的升级提示")
    }

    /// 忽略所有版本的升级（在详情页）
    func ignoreUpgrade(app: AppInstall) async {
        let req = AppIgnoreUpgradeRequest(
            appID: app.appID ?? 0,
            scope: "all",
            appDetailID: nil
        )
        await performIgnore(req: req, app: app, successMsg: "已忽略该应用的所有升级提示")
    }

    private func performIgnore(req: AppIgnoreUpgradeRequest, app: AppInstall, successMsg: String) async {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledIgnore.path,
                body: req,
                as: EmptyResponse.self
            )
            // 先弹窗提示，确认后再返回上一层
            pendingDismissUpgrade = true
            showAlert(message: successMsg)
            // 不立即修改 apps 数组（会破坏 NavigationStack），标记返回列表时再刷新
            needsRefresh = true
        } catch let err as APIError {
            showAlert(message: "操作失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "操作失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 取消忽略升级

    /// 取消指定应用的忽略升级（直接用已加载的 ignoredRecordID）
    func cancelIgnoreUpgrade(app: AppInstall) async {
        guard let recordID = app.ignoredRecordID else {
            showAlert(message: "该应用当前未在忽略列表中")
            return
        }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsIgnoredCancel.path,
                body: ReqWithID(id: recordID),
                as: EmptyResponse.self
            )
            showAlert(message: "已取消忽略升级，后续将正常检查更新")
            needsRefresh = true
        } catch let err as APIError {
            showAlert(message: "取消忽略失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "取消忽略失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 更新参数（重建应用）

    /// 加载已安装应用的当前参数（用于「更新参数」表单）
    @MainActor
    func loadParams(for app: AppInstall) async -> InstalledParamsResponse? {
        isLoadingParams = true
        defer { isLoadingParams = false }
        let path = APIEndpoint.appsInstalledParams.path
            .replacingOccurrences(of: ":installId", with: String(app.id))
        do {
            let resp: InstalledParamsResponse = try await client.send(
                path: path,
                method: APIEndpoint.appsInstalledParams.method,
                as: InstalledParamsResponse.self
            )
            self.loadedParams = resp
            return resp
        } catch let err as APIError {
            showAlert(message: "加载参数失败：\(err.errorDescription ?? "未知错误")")
            return nil
        } catch {
            showAlert(message: "加载参数失败：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 应用商店设置（卸载/升级/安装默认选项）

    /// 加载应用商店设置（GET /api/v2/core/settings/apps/store/config）
    func loadAppStoreConfig() async {
        isLoadingAppStoreConfig = true
        defer { isLoadingAppStoreConfig = false }
        do {
            let resp: AppStoreConfig = try await client.send(
                path: APIEndpoint.appStoreSettingConfig.path,
                method: APIEndpoint.appStoreSettingConfig.method,
                as: AppStoreConfig.self
            )
            self.appStoreConfig = resp
        } catch let err as APIError {
            showAlert(message: "加载应用设置失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "加载应用设置失败：\(error.localizedDescription)")
        }
    }

    /// 更新单项应用商店设置（POST /api/v2/core/settings/apps/store/update）。
    /// 成功后同步本地 appStoreConfig 对应字段，避免重复请求。
    func updateAppStoreSetting(scope: AppStoreSettingScope, enabled: Bool) async {
        let status = enabled ? "Enable" : "Disable"
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appStoreSettingUpdate.path,
                body: AppStoreSettingUpdateRequest(scope: scope.rawValue, status: status),
                as: EmptyResponse.self
            )
            // 本地同步，避免重新拉取
            if appStoreConfig == nil { appStoreConfig = AppStoreConfig() }
            switch scope {
            case .uninstallDeleteBackup: appStoreConfig?.uninstallDeleteBackup = status
            case .uninstallDeleteImage:  appStoreConfig?.uninstallDeleteImage = status
            case .upgradeBackup:         appStoreConfig?.upgradeBackup = status
            case .upgradeDeleteImage:    appStoreConfig?.upgradeDeleteImage = status
            case .installAllowPort:      appStoreConfig?.installAllowPort = status
            }
        } catch let err as APIError {
            showAlert(message: "更新应用设置失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "更新应用设置失败：\(error.localizedDescription)")
        }
    }

    /// 提交参数更新（重建应用）
    func updateParams(app: AppInstall, req: AppParamsUpdateRequest) async {
        isUpdatingParams = true
        paramsUpdated = false
        defer { isUpdatingParams = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledParamsUpdate.path,
                body: req,
                as: EmptyResponse.self
            )
            paramsUpdated = true
            showAlert(message: "参数更新请求已提交，应用正在后台重建中…")
            needsRefresh = true
        } catch let err as APIError {
            showAlert(message: "更新失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "更新失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 卸载应用

    /// 卸载应用（先做删除前检查，再调用 delete 操作）
    /// options: deleteDB（删除数据库） / deleteImage（删除镜像） / deleteBackup（删除备份） / forceDelete（强制删除）
    func uninstall(app: AppInstall,
                   deleteDB: Bool,
                   deleteImage: Bool,
                   deleteBackup: Bool,
                   forceDelete: Bool,
                   taskID: String) async {
        isUninstalling = true
        uninstallDone = false
        defer { isUninstalling = false }

        // 0. 联动检查：查询是否存在一键部署类网站引用了该应用
        do {
            let searchReq = WebsiteSearchRequest(
                name: "", page: 1, pageSize: 200,
                orderBy: "created_at", order: "descending",
                websiteGroupId: 0, type: ""
            )
            let resp: WebsiteListResponse = try await client.send(
                path: APIEndpoint.websitesSearch.path,
                body: searchReq,
                as: WebsiteListResponse.self
            )
            let linked = (resp.items ?? []).filter {
                ($0.appType?.lowercased() == "installed" || ($0.type ?? "").lowercased() == "deployment")
                && ($0.appName ?? "").lowercased() == (app.appName ?? app.name ?? "").lowercased()
            }
            if !linked.isEmpty {
                let names = linked.map { $0.displayName }.joined(separator: "、")
                showAlert(message: "该应用被以下网站使用：\(names)。请先在「工具箱 → 网站」中删除对应网站（删除时可勾选删除关联应用），再卸载此应用。")
                return
            }
        } catch {
            // 网站查询失败时不阻塞卸载，继续走原有流程
        }

        // 1. 删除前检查（后端返回关联资源列表，非空则禁止删除）
        let checkPath = APIEndpoint.appsInstalledDeleteCheck.path
            .replacingOccurrences(of: ":installId", with: String(app.id))
        do {
            let linked: [AppDeleteCheckItem] = try await client.send(
                path: checkPath,
                method: "GET",
                as: [AppDeleteCheckItem].self
            )
            if !linked.isEmpty {
                let names = linked.map { "\($0.name ?? "未知")" }.joined(separator: "、")
                showAlert(message: "应用已经关联以下资源，请检查后重试！\n应用 \(names)")
                return
            }
        } catch {
            // data 为 null 或空数组时可能解码失败，继续执行删除
        }
        // 2. 执行删除
        let req = AppInstalledOperateRequest(
            installId: app.id,
            operate: "delete",
            deleteDB: deleteDB,
            deleteImage: deleteImage,
            forceDelete: forceDelete,
            deleteBackup: deleteBackup,
            taskID: taskID
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledOperate.path,
                body: req,
                as: EmptyResponse.self
            )
            uninstallDone = true
            needsRefresh = true
        } catch let err as APIError {
            showAlert(message: "卸载失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "卸载失败：\(error.localizedDescription)")
        }
    }
}

