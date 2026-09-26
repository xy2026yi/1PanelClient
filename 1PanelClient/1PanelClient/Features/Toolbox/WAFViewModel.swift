//
//  WAFViewModel.swift
//  1PanelClient
//

import SwiftUI
import Combine

// MARK: - WAF ViewModel

@MainActor
final class WAFViewModel: ObservableObject {
    @Published var status: WAFStatus?
    @Published var config: WAFConfig?
    /// CDN 类型角标回显：config/global 的 cdn 块不随 cdn/update 更新（抓包
    /// 2026-09-26），列表行以 POST /cdn {websiteID:0} 读到的为准
    @Published var cdnType: String?
    @Published var isLoading = true
    @Published var isOperating = false
    @Published var errorMessage: String?
    @Published var successMessage: String?
    /// OpenResty 安装状态（WAF 依赖 OpenResty，未装时展示安装引导而不是接口错误）
    @Published var openRestyCheck: AppInstallCheck?

    private let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient.shared(for: server)
    }

    /// OpenResty 明确未安装（check 判定 isExist=false）
    var openRestyNotInstalled: Bool {
        openRestyCheck?.isExist == false
    }

    func loadAll() async {
        isLoading = true
        defer { isLoading = false }
        async let checkTask = checkOpenResty()
        async let s = client.send(path: APIEndpoint.wafStatus.path, method: "GET", as: WAFStatus.self)
        async let c = client.send(path: APIEndpoint.wafConfigGlobal.path, method: "GET", as: WAFConfig.self)
        do {
            let (s, c) = try await (s, c)
            status = s
            config = c
            errorMessage = nil
            _ = await checkTask
        } catch {
            // 页面退出取消不是失败：保留原状态
            guard !APIError.isCancellation(error) else { return }
            // OpenResty 未安装时 WAF 接口必然报「global.json 不存在」类错误，属预期：
            // 等安装状态出结论再决定是否当错误展示，避免未装场景弹「服务错误」提示
            if await checkTask {
                errorMessage = error.localizedDescription
            } else {
                errorMessage = nil
            }
        }
    }

    /// 轻量刷新全局配置（单 GET）：全局配置列表页进入/从子页返回时回显用——
    /// 子页（恶意 IP 组 / 蜘蛛 IP 池等）改开关不经 vm，快照会停在进入前。
    /// 静默失败保持旧快照，不设 isLoading（不打扰、无加载态）
    func loadConfig() async {
        guard let cfg: WAFConfig = try? await client.send(
            path: APIEndpoint.wafConfigGlobal.path, method: "GET", as: WAFConfig.self
        ) else { return }
        config = cfg
        // cdn 块在 config/global 里不随 cdn/update 变化，角标另经 /cdn 读取
        if let cdn: WAFCdnConfig = try? await client.send(
            path: APIEndpoint.wafCdn.path,
            body: WAFCdnRequest(websiteID: 0),
            as: WAFCdnConfig.self
        ) {
            cdnType = cdn.type
        }
    }

    /// 检测 OpenResty 安装状态；返回是否已安装（检测失败视为已安装，走正常错误展示兜底）
    @discardableResult
    private func checkOpenResty() async -> Bool {
        let req = AppCheckRequest(key: "openresty", name: "")
        do {
            openRestyCheck = try await client.send(
                path: APIEndpoint.appsInstalledCheck.path, body: req, as: AppInstallCheck.self
            )
        } catch {
            // 页面退出取消不是失败：保留上次检查结果
            if !APIError.isCancellation(error) { openRestyCheck = nil }
        }
        return openRestyCheck?.isExist != false
    }

    func toggleRule(scope: String, state: String) async {
        isOperating = true
        defer { isOperating = false }
        let req = WAFGlobalStateRequest(scope: scope, state: state)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafConfigGlobalState.path, body: req, as: EmptyResponse.self)
            successMessage = state == "on" ? L10n.t("已启用") : L10n.t("已禁用")
            await loadAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

