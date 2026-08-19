//
//  WebsitesViewModel.swift
//  1PanelClient
//

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class WebsitesViewModel: ObservableObject {
    @Published var websites: [Website] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    // 创建网站相关
    @Published var isCreating = false
    @Published var isLoadingCreateData = false
    @Published var availableApps: [AppInstall] = []
    @Published var availableSSLs: [WebsiteSSL] = []

    // 提示
    @Published var showAlert = false
    @Published var alertMessage = ""

    /// 标记列表需要刷新（详情页操作后）
    @Published var needsRefresh = false
    @Published var deletedWebsiteId: Int?

    // OpenResty 应用状态
    @Published var openresty: AppInstall?
    @Published var isLoadingOpenResty = false
    @Published var openRestyOperating = false
    /// 是否已尝试加载过（避免 List 重绘时 .task 反复触发）
    private var openRestyLoaded = false

    private(set) var client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    func refresh() async {
        await load(query: "")
        await loadOpenResty(force: false)
    }

    func search(query: String) async {
        await load(query: query)
    }

    private func load(query: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let req = WebsiteSearchRequest(
            name: query,
            page: 1,
            pageSize: 20,
            orderBy: "favorite",
            order: "descending",
            websiteGroupId: 0,
            type: ""
        )
        do {
            let resp: WebsiteListResponse = try await client.send(
                path: APIEndpoint.websitesSearch.path,
                body: req,
                as: WebsiteListResponse.self
            )
            self.websites = resp.items ?? []
        } catch let err as APIError {
            self.errorMessage = err.errorDescription
            self.websites = []
        } catch {
            self.errorMessage = error.localizedDescription
            self.websites = []
        }
    }

    // MARK: - 创建网站

    /// 加载创建网站所需的公共数据（可用应用 + SSL 证书）
    func loadCreateData(type: WebsiteType) async {
        isLoadingCreateData = true
        defer { isLoadingCreateData = false }

        let appType: String
        switch type {
        case .deployment: appType = "website"
        case .proxy:      appType = "proxy"
        case .staticSite: appType = "static"
        }

        let appReq = WebsiteAppSearchRequest(
            type: appType, unused: true, all: true, page: 1, pageSize: 100
        )
        let sslReq = WebsiteSSLSearchRequest(acmeAccountID: "0")

        do {
            async let appsResp: AppInstalledListResponse = client.send(
                path: APIEndpoint.appsInstalledSearch.path,
                body: appReq,
                as: AppInstalledListResponse.self
            )
            async let sslsResp: [WebsiteSSL] = client.send(
                path: APIEndpoint.websitesSSLSearch.path,
                body: sslReq,
                as: [WebsiteSSL].self
            )
            let (apps, ssls) = try await (appsResp, sslsResp)
            self.availableApps = apps.items ?? []
            self.availableSSLs = ssls
        } catch {
            // 静默失败，让用户至少能填表
            self.availableApps = []
            self.availableSSLs = []
        }
    }

    /// 仅加载 SSL 证书列表（用于 HTTPS 配置页，不依赖应用搜索）
    func loadSSLCerts() async {
        let sslReq = WebsiteSSLSearchRequest(acmeAccountID: "0")
        do {
            let ssls: [WebsiteSSL] = try await client.send(
                path: APIEndpoint.websitesSSLSearch.path,
                body: sslReq,
                as: [WebsiteSSL].self
            )
            self.availableSSLs = ssls
        } catch {
            self.availableSSLs = []
        }
    }

    /// 提交创建网站请求
    @discardableResult
    func createWebsite(req: WebsiteCreateRequest) async -> (success: Bool, message: String) {
        isCreating = true
        defer { isCreating = false }

        // 先做环境检查（后端 data 为 null）
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesCheck.path,
                body: WebsiteCheckRequest(),
                as: EmptyResponse.self
            )
        } catch let err as APIError {
            return (false, L10n.f("环境检查失败：%@", err.errorDescription ?? L10n.t("未知错误")))
        } catch {
            return (false, L10n.f("环境检查失败：%@", error.localizedDescription))
        }

        // 提交创建
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesCreate.path,
                body: req,
                as: EmptyResponse.self
            )
            try? await Task.sleep(for: .seconds(1))
            await load(query: "")
            return (true, L10n.t("网站创建请求已提交，正在后台配置…"))
        } catch let err as APIError {
            return (false, L10n.f("创建失败：%@", err.errorDescription ?? L10n.t("未知错误")))
        } catch {
            return (false, L10n.f("创建失败：%@", error.localizedDescription))
        }
    }

    // MARK: - 删除网站

    func deleteWebsite(id: Int, deleteApp: Bool, deleteBackup: Bool, forceDelete: Bool, deleteDB: Bool) async {
        let req = WebsiteDeleteRequest(
            id: id,
            deleteApp: deleteApp,
            deleteBackup: deleteBackup,
            forceDelete: forceDelete,
            deleteDB: deleteDB
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesDelete.path,
                body: req,
                as: EmptyResponse.self
            )
            deletedWebsiteId = id
            showAlert(message: L10n.t("网站删除成功"))
            try? await Task.sleep(for: .seconds(1))
            await load(query: "")
        } catch let err as APIError {
            showAlert(message: L10n.f("删除失败：%@", err.errorDescription ?? L10n.t("未知错误")))
        } catch {
            showAlert(message: L10n.f("删除失败：%@", error.localizedDescription))
        }
    }

    // MARK: - OpenResty 状态

    /// 加载 OpenResty 应用信息
    /// - Parameter force: true 强制刷新（如操作后）；false 仅首次加载
    func loadOpenResty(force: Bool) async {
        if !force && openRestyLoaded { return }
        openRestyLoaded = true
        isLoadingOpenResty = true
        defer { isLoadingOpenResty = false }

        let req = AppInstalledSearchRequest(
            page: 1, pageSize: 100, name: "", type: "", tags: [],
            update: false, all: true, unused: false, sync: false
        )
        do {
            let resp: AppInstalledListResponse = try await client.send(
                path: APIEndpoint.appsInstalledSearch.path,
                body: req,
                as: AppInstalledListResponse.self
            )
            self.openresty = (resp.items ?? []).first { $0.appKey?.lowercased() == "openresty" }
        } catch {
            self.openresty = nil
        }
    }

    /// 操作 OpenResty（start/stop/restart/reload）
    func operateOpenResty(op: AppOperation) async {
        guard let app = openresty else { return }
        openRestyOperating = true
        defer { openRestyOperating = false }
        let req = AppInstalledOperateRequest(installId: app.id, operate: op.rawValue)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledOperate.path,
                body: req,
                as: EmptyResponse.self
            )
            try? await Task.sleep(for: .seconds(1))
            await loadOpenResty(force: true)
        } catch {
            showAlert(message: L10n.f("%@失败：%@", op.displayName, error.localizedDescription))
        }
    }

    // MARK: - 网站详情

    func loadDetail(id: Int) async -> WebsiteFull? {
        let path = APIEndpoint.websitesDetail.path
            .replacingOccurrences(of: ":id", with: String(id))
        do {
            return try await client.send(
                path: path,
                method: "GET",
                as: WebsiteFull.self
            )
        } catch let err as APIError {
            showAlert(message: L10n.f("加载详情失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return nil
        } catch {
            showAlert(message: L10n.f("加载详情失败：%@", error.localizedDescription))
            return nil
        }
    }

    func operateWebsite(id: Int, operate: String) async -> Bool {
        struct Req: Encodable { let id: Int; let operate: String }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesOperate.path,
                body: Req(id: id, operate: operate),
                as: EmptyResponse.self
            )
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("操作失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("操作失败：%@", error.localizedDescription))
            return false
        }
    }

    // MARK: - 网站基础信息更新

    /// 更新主域名/备注（POST /websites/update），其余字段按当前详情回填避免零值覆盖
    func updateWebsite(_ req: WebsiteUpdateRequest) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesUpdate.path,
                body: req,
                as: EmptyResponse.self
            )
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("保存失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("保存失败：%@", error.localizedDescription))
            return false
        }
    }

    // MARK: - Nginx 配置

    func loadNginxConfig(id: Int) async -> WebsiteNginxConfig? {
        let path = APIEndpoint.websitesNginxConfig.path
            .replacingOccurrences(of: ":id", with: String(id))
        do {
            return try await client.send(
                path: path,
                method: "GET",
                as: WebsiteNginxConfig.self
            )
        } catch let err as APIError {
            showAlert(message: L10n.f("加载配置失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return nil
        } catch {
            showAlert(message: L10n.f("加载配置失败：%@", error.localizedDescription))
            return nil
        }
    }

    func updateNginxConfig(id: Int, content: String) async -> Bool {
        let req = WebsiteNginxUpdateRequest(id: id, content: content)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesNginxUpdate.path,
                body: req,
                as: EmptyResponse.self
            )
            showAlert(message: L10n.t("配置已保存，OpenResty 正在重载…"))
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("保存失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("保存失败：%@", error.localizedDescription))
            return false
        }
    }

    // MARK: - 网站日志

    func loadLog(websiteId: Int, name: String) async -> [String] {
        let req = WebsiteLogReadRequest(
            id: websiteId,
            type: "website",
            name: name,
            page: 1,
            pageSize: 500,
            latest: true
        )
        do {
            let resp: WebsiteLogResponse = try await client.send(
                path: APIEndpoint.websitesLogRead.path,
                body: req,
                as: WebsiteLogResponse.self
            )
            return resp.lines ?? []
        } catch let err as APIError {
            // 404 表示日志文件尚未产生，静默返回空数组
            if case .httpError(let code, _) = err, code == 404 {
                return []
            }
            return []
        } catch {
            return []
        }
    }

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }

    // MARK: - OpenResty 全局配置

    func loadOpenRestyConfig() async -> String? {
        do {
            struct Resp: Decodable { let content: String? }
            let resp: Resp = try await client.send(
                path: APIEndpoint.openrestyConfig.path,
                method: APIEndpoint.openrestyConfig.method,
                as: Resp.self
            )
            return resp.content ?? ""
        } catch let err as APIError {
            showAlert(message: L10n.f("读取配置失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return nil
        } catch {
            showAlert(message: L10n.f("读取配置失败：%@", error.localizedDescription))
            return nil
        }
    }

    func saveOpenRestyConfig(content: String, backup: Bool) async -> Bool {
        struct Req: Encodable { let content: String; let backup: Bool }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.openrestyFile.path,
                body: Req(content: content, backup: backup),
                as: EmptyResponse.self
            )
            showAlert(message: L10n.t("配置保存成功"))
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("保存失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("保存失败：%@", error.localizedDescription))
            return false
        }
    }

    func resetOpenRestyConfig() async -> String? {
        struct Req: Encodable { let type: String; let name: String }
        do {
            let content: String = try await client.send(
                path: APIEndpoint.openrestyReset.path,
                body: Req(type: "openresty", name: ""),
                as: String.self
            )
            return content
        } catch let err as APIError {
            showAlert(message: L10n.f("还原失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return nil
        } catch {
            showAlert(message: L10n.f("还原失败：%@", error.localizedDescription))
            return nil
        }
    }

    // MARK: - HTTPS 配置

    func loadHTTPSConfig(id: Int) async -> WebsiteHTTPS? {
        let path = APIEndpoint.websitesHTTPSRead.path
            .replacingOccurrences(of: ":id", with: String(id))
        do {
            return try await client.send(
                path: path,
                method: "GET",
                as: WebsiteHTTPS.self
            )
        } catch let err as APIError {
            showAlert(message: L10n.f("加载 HTTPS 配置失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return nil
        } catch {
            showAlert(message: L10n.f("加载 HTTPS 配置失败：%@", error.localizedDescription))
            return nil
        }
    }

    func updateHTTPSConfig(websiteId: Int, sslId: Int, req: WebsiteHTTPSUpdateRequest) async -> Bool {
        let path = APIEndpoint.websitesHTTPSUpdate.path
            .replacingOccurrences(of: ":id", with: String(websiteId))
        do {
            let _: EmptyResponse = try await client.send(
                path: path,
                body: req,
                as: EmptyResponse.self
            )
            // 成功时不调用 showAlert：showAlert 绑定在根页 WebsitesTab 上，
            // 会在用户返回主页面时才弹出。改由调用方（WebsiteHTTPSView）显示轻量 toast。
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("保存失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("保存失败：%@", error.localizedDescription))
            return false
        }
    }

    // MARK: - 反向代理路由

    func loadProxies(websiteId: Int) async -> [WebsiteProxy] {
        let req = WebsiteProxiesListRequest(id: websiteId)
        do {
            let resp: WebsiteProxiesResponse = try await client.send(
                path: APIEndpoint.websitesProxiesList.path,
                body: req,
                as: WebsiteProxiesResponse.self
            )
            return resp.proxies ?? []
        } catch let err as APIError {
            // 一键部署类网站的反向代理查询可能返回 data=null（code 200），
            // 此时按"空列表"处理，不弹错误窗，允许用户继续创建代理
            if case .businessError(200, _) = err {
                return []
            }
            // 其他错误静默处理（避免阻塞 UI），返回空列表
            return []
        } catch {
            return []
        }
    }

    func operateProxy(websiteId: Int, operate: WebsiteProxyOperate, req: WebsiteProxyUpdateRequest) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesProxiesUpdate.path,
                body: req,
                as: EmptyResponse.self
            )
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("操作失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("操作失败：%@", error.localizedDescription))
            return false
        }
    }

    /// 启用/停用反向代理
    @discardableResult
    func toggleProxy(websiteId: Int, proxy: WebsiteProxy, enable: Bool) async -> Bool {
        let req = WebsiteProxyStatusRequest(
            id: websiteId,
            name: proxy.name ?? "",
            status: enable ? "enable" : "disable"
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesProxiesStatus.path,
                body: req,
                as: EmptyResponse.self
            )
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("操作失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("操作失败：%@", error.localizedDescription))
            return false
        }
    }

    func saveProxyFile(websiteId: Int, name: String, content: String) async -> Bool {
        let req = WebsiteProxyFileRequest(name: name, websiteID: websiteId, content: content)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesProxiesFile.path,
                body: req,
                as: EmptyResponse.self
            )
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("保存失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("保存失败：%@", error.localizedDescription))
            return false
        }
    }

    // MARK: - 网站配置（默认文档 / 流量限制）

    /// 读取网站配置；失败返回 nil
    func loadWebsiteConfig(websiteId: Int, scope: String, operate: String? = nil, params: WebsiteConfigParams? = nil) async -> WebsiteConfigResponse? {
        let req = WebsiteConfigRequest(operate: operate, scope: scope, websiteId: websiteId, params: params)
        do {
            return try await client.send(
                path: APIEndpoint.websitesConfig.path,
                body: req,
                as: WebsiteConfigResponse.self
            )
        } catch let err as APIError {
            showAlert(message: L10n.f("读取配置失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return nil
        } catch {
            showAlert(message: L10n.f("读取配置失败：%@", error.localizedDescription))
            return nil
        }
    }

    /// 更新网站配置（默认文档 operate=update / 流量限制 启停 add|delete）
    func updateWebsiteConfig(websiteId: Int, operate: String, scope: String, params: WebsiteConfigParams) async -> Bool {
        let req = WebsiteConfigUpdateRequest(operate: operate, scope: scope, websiteId: websiteId, params: params)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesConfigUpdate.path,
                body: req,
                as: EmptyResponse.self
            )
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("保存失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("保存失败：%@", error.localizedDescription))
            return false
        }
    }

    // MARK: - 重定向

    func loadRedirects(websiteId: Int) async -> [WebsiteRedirect] {
        let req = WebsiteRedirectListRequest(websiteID: websiteId)
        do {
            let resp: WebsiteRedirectsResponse = try await client.send(
                path: APIEndpoint.websitesRedirectList.path,
                body: req,
                as: WebsiteRedirectsResponse.self
            )
            return resp.items ?? []
        } catch {
            // 一键部署等类型可能返回 data=null，按空列表处理
            return []
        }
    }

    func operateRedirect(_ req: WebsiteRedirectUpdateRequest) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesRedirectUpdate.path,
                body: req,
                as: EmptyResponse.self
            )
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("操作失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("操作失败：%@", error.localizedDescription))
            return false
        }
    }

    func saveRedirectFile(websiteId: Int, name: String, content: String) async -> Bool {
        let req = WebsiteRedirectFileRequest(name: name, websiteID: websiteId, content: content)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesRedirectFile.path,
                body: req,
                as: EmptyResponse.self
            )
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("保存失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("保存失败：%@", error.localizedDescription))
            return false
        }
    }

    // MARK: - 密码访问

    func loadAuths(websiteId: Int) async -> WebsiteAuthsResponse? {
        let req = WebsiteAuthsListRequest(websiteID: websiteId)
        do {
            return try await client.send(
                path: APIEndpoint.websitesAuths.path,
                body: req,
                as: WebsiteAuthsResponse.self
            )
        } catch let err as APIError {
            showAlert(message: L10n.f("读取密码访问失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return nil
        } catch {
            showAlert(message: L10n.f("读取密码访问失败：%@", error.localizedDescription))
            return nil
        }
    }

    func operateAuth(websiteId: Int, operate: String, username: String = "", password: String = "", remark: String = "") async -> Bool {
        let req = WebsiteAuthsUpdateRequest(
            websiteID: websiteId,
            operate: operate,
            username: username,
            password: password,
            remark: remark
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesAuthsUpdate.path,
                body: req,
                as: EmptyResponse.self
            )
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("操作失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("操作失败：%@", error.localizedDescription))
            return false
        }
    }

    // MARK: - 网站域名列表

    func loadWebsiteDomains(websiteId: Int) async -> [WebsiteDomainItem] {
        let path = APIEndpoint.websitesDomains.path.replacingOccurrences(of: ":id", with: String(websiteId))
        do {
            return try await client.send(path: path, method: "GET", as: [WebsiteDomainItem].self)
        } catch {
            return []
        }
    }
}

/// 重定向列表响应包装（data 可能是 null 或数组）
private struct WebsiteRedirectsResponse: Decodable {
    let items: [WebsiteRedirect]?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let arr = try? container.decode([WebsiteRedirect].self) {
            items = arr
        } else {
            items = nil
        }
    }
}

/// 反向代理列表响应包装（data 可能是 null 或数组）
private struct WebsiteProxiesResponse: Decodable {
    let proxies: [WebsiteProxy]?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let arr = try? container.decode([WebsiteProxy].self) {
            proxies = arr
        } else {
            proxies = nil
        }
    }
}

