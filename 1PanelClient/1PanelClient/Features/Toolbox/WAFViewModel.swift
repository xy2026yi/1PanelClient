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

    private let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    func loadAll() async {
        isLoading = true
        defer { isLoading = false }
        async let s = client.send(path: APIEndpoint.wafStatus.path, method: "GET", as: WAFStatus.self)
        async let c = client.send(path: APIEndpoint.wafConfigGlobal.path, method: "GET", as: WAFConfig.self)
        do {
            let (s, c) = try await (s, c)
            status = s
            config = c
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
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

