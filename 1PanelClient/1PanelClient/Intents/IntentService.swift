//
//  IntentService.swift
//  1PanelClient
//
//  App Intents 专用薄服务层：直接基于 APIClient + ServerManager/KeychainStore，
//  不复用 ViewModel（避免 showAlert/showToast 等 UI 副作用）。
//

import Foundation

@MainActor
enum IntentService {
    /// 按 UUID 解析服务器配置（apiKey 从 Keychain 读取，不落入 AppEntity）
    static func server(byID id: UUID) -> ServerConfig? {
        guard let base = ServerManager.shared.servers.first(where: { $0.id == id }) else { return nil }
        guard let key = KeychainStore.read(for: id.uuidString), !key.isEmpty else {
            return base
        }
        return ServerConfig(id: base.id, name: base.name, baseURL: base.baseURL, apiKey: key)
    }

    /// Intent 未指定服务器时用当前服务器
    static func currentServer() -> ServerConfig? {
        guard let base = ServerManager.shared.current else { return nil }
        guard let key = KeychainStore.read(for: base.id.uuidString), !key.isEmpty else {
            return base
        }
        return ServerConfig(id: base.id, name: base.name, baseURL: base.baseURL, apiKey: key)
    }

    // MARK: - 查询

    static func dashboardCurrent(_ server: ServerConfig) async throws -> DashboardCurrent {
        let client = APIClient(server: server)
        return try await client.send(
            path: APIEndpoint.dashboardCurrent.path,
            method: APIEndpoint.dashboardCurrent.method,
            as: DashboardCurrent.self
        )
    }

    static func listContainers(_ server: ServerConfig) async throws -> [Container] {
        let client = APIClient(server: server)
        let resp: ContainerListResponse = try await client.send(
            path: APIEndpoint.containersSearch.path,
            body: ContainerSearchRequest(page: 1, pageSize: 200, name: "", state: "all",
                                         orderBy: "createdAt", order: "null"),
            as: ContainerListResponse.self
        )
        return resp.items ?? []
    }

    static func listWebsites(_ server: ServerConfig) async throws -> [Website] {
        let client = APIClient(server: server)
        let resp: WebsiteListResponse = try await client.send(
            path: APIEndpoint.websitesSearch.path,
            body: WebsiteSearchRequest(name: "", page: 1, pageSize: 200, orderBy: "created_at",
                                       order: "null", websiteGroupId: 0, type: ""),
            as: WebsiteListResponse.self
        )
        return resp.items ?? []
    }

    static func listCronjobs(_ server: ServerConfig) async throws -> [Cronjob] {
        let client = APIClient(server: server)
        let resp: CronjobListResponse = try await client.send(
            path: APIEndpoint.cronjobsSearch.path,
            body: CronjobSearchRequest(),
            as: CronjobListResponse.self
        )
        return resp.items ?? []
    }

    // MARK: - 操作

    static func operateContainer(_ server: ServerConfig, name: String, operation: String) async throws {
        let client = APIClient(server: server)
        let _: EmptyResponse = try await client.send(
            path: APIEndpoint.containersOperate.path,
            body: ContainerOperateRequest(names: [name], operation: operation, taskID: UUID().uuidString),
            as: EmptyResponse.self
        )
    }

    static func operateWebsite(_ server: ServerConfig, id: Int, operate: String) async throws {
        let client = APIClient(server: server)
        struct Req: Encodable { let id: Int; let operate: String }
        let _: EmptyResponse = try await client.send(
            path: APIEndpoint.websitesOperate.path,
            body: Req(id: id, operate: operate),
            as: EmptyResponse.self
        )
    }

    static func runCronjob(_ server: ServerConfig, id: Int) async throws {
        let client = APIClient(server: server)
        let _: EmptyResponse = try await client.send(
            path: APIEndpoint.cronjobsHandle.path,
            body: CronjobHandleRequest(id: id),
            as: EmptyResponse.self
        )
    }
}
