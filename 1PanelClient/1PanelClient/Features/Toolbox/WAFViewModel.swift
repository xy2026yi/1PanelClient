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
    @Published var isLoading = true
    @Published var isOperating = false
    @Published var errorMessage: String?
    @Published var successMessage: String?
    /// OpenResty 安装状态（WAF 依赖 OpenResty，未装时展示安装引导而不是接口错误）
    @Published var openRestyCheck: AppInstallCheck?

    private let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
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
            // OpenResty 未安装时 WAF 接口必然报「global.json 不存在」类错误，属预期：
            // 等安装状态出结论再决定是否当错误展示，避免未装场景弹「服务错误」提示
            if await checkTask {
                errorMessage = error.localizedDescription
            } else {
                errorMessage = nil
            }
        }
    }

    /// 检测 OpenResty 安装状态；返回是否已安装（检测失败视为已安装，走正常错误展示兜底）
    @discardableResult
    private func checkOpenResty() async -> Bool {
        let req = AppCheckRequest(key: "openresty", name: "")
        openRestyCheck = try? await client.send(
            path: APIEndpoint.appsInstalledCheck.path, body: req, as: AppInstallCheck.self
        )
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

