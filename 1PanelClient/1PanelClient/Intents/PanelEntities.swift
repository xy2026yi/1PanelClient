//
//  PanelEntities.swift
//  1PanelClient
//
//  App Intents 实体：服务器 / 容器 / 网站 / 计划任务。
//  实体仅携带展示与定位字段 + serverID（apiKey 留在 Keychain，绝不进实体序列化）。
//

import AppIntents

// MARK: - 服务器

struct PanelServerEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "1Panel Server"

    let id: UUID
    let name: String
    let baseURL: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(baseURL)")
    }

    static var defaultQuery = PanelServerQuery()
}

struct PanelServerQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [PanelServerEntity] {
        @MainActor func lookup() -> [PanelServerEntity] {
            identifiers.compactMap { id in
                ServerManager.shared.servers
                    .first(where: { $0.id == id })
                    .map { PanelServerEntity(id: $0.id, name: $0.name, baseURL: $0.baseURL) }
            }
        }
        return await MainActor.run(body: lookup)
    }

    func suggestedEntities() async throws -> [PanelServerEntity] {
        @MainActor func list() -> [PanelServerEntity] {
            ServerManager.shared.servers.map {
                PanelServerEntity(id: $0.id, name: $0.name, baseURL: $0.baseURL)
            }
        }
        return await MainActor.run(body: list)
    }

    func defaultEntity() async -> PanelServerEntity? {
        (try? await suggestedEntities())?.first
    }
}

// MARK: - 容器

struct ContainerEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Container"

    let name: String
    let state: String
    let imageName: String?
    /// 操作时按 serverID 从 Keychain 取凭据
    let serverID: UUID

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(imageName ?? state)")
    }

    static var defaultQuery = ContainerEntityQuery()

    /// 容器名在同一服务器内唯一，作为实体标识
    var id: String { name }

    init(name: String, state: String, imageName: String?, serverID: UUID) {
        self.name = name
        self.state = state
        self.imageName = imageName
        self.serverID = serverID
    }

    init(container: Container, serverID: UUID) {
        self.init(name: container.displayName, state: container.state,
                  imageName: container.imageName, serverID: serverID)
    }
}

struct ContainerEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ContainerEntity] {
        // 名称即标识（1Panel 容器操作按 name 提交）；跨服务器场景由 serverID 区分
        guard let server = await resolvedServer() else { return [] }
        let all = try await IntentService.listContainers(server)
        return identifiers.compactMap { id in all.first(where: { $0.displayName == id }) }
            .map { ContainerEntity(container: $0, serverID: server.id) }
    }

    func suggestedEntities() async throws -> [ContainerEntity] {
        guard let server = await resolvedServer() else { return [] }
        return try await IntentService.listContainers(server)
            .map { ContainerEntity(container: $0, serverID: server.id) }
    }

    private func resolvedServer() async -> ServerConfig? {
        await MainActor.run { IntentService.currentServer() }
    }
}

// MARK: - 网站

struct WebsiteEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Website"

    let id: Int
    let domain: String
    let status: String
    let serverID: UUID

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(domain)", subtitle: "\(status)")
    }

    static var defaultQuery = WebsiteEntityQuery()

    init(id: Int, domain: String, status: String, serverID: UUID) {
        self.id = id
        self.domain = domain
        self.status = status
        self.serverID = serverID
    }

    init(website: Website, serverID: UUID) {
        self.init(id: website.id, domain: website.displayName,
                  status: website.status ?? "", serverID: serverID)
    }
}

struct WebsiteEntityQuery: EntityQuery {
    func entities(for identifiers: [Int]) async throws -> [WebsiteEntity] {
        guard let server = await resolvedServer() else { return [] }
        let all = try await IntentService.listWebsites(server)
        return identifiers.compactMap { id in all.first(where: { $0.id == id }) }
            .map { WebsiteEntity(website: $0, serverID: server.id) }
    }

    func suggestedEntities() async throws -> [WebsiteEntity] {
        guard let server = await resolvedServer() else { return [] }
        return try await IntentService.listWebsites(server)
            .map { WebsiteEntity(website: $0, serverID: server.id) }
    }

    private func resolvedServer() async -> ServerConfig? {
        await MainActor.run { IntentService.currentServer() }
    }
}

// MARK: - 计划任务

struct CronjobEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Scheduled Task"

    let id: Int
    let name: String
    let spec: String
    let serverID: UUID

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(spec)")
    }

    static var defaultQuery = CronjobEntityQuery()

    init(id: Int, name: String, spec: String, serverID: UUID) {
        self.id = id
        self.name = name
        self.spec = spec
        self.serverID = serverID
    }

    init(job: Cronjob, serverID: UUID) {
        self.init(id: job.id, name: job.name ?? "#\(job.id)",
                  spec: job.spec ?? "", serverID: serverID)
    }
}

struct CronjobEntityQuery: EntityQuery {
    func entities(for identifiers: [Int]) async throws -> [CronjobEntity] {
        guard let server = await resolvedServer() else { return [] }
        let all = try await IntentService.listCronjobs(server)
        return identifiers.compactMap { id in all.first(where: { $0.id == id }) }
            .map { CronjobEntity(job: $0, serverID: server.id) }
    }

    func suggestedEntities() async throws -> [CronjobEntity] {
        guard let server = await resolvedServer() else { return [] }
        return try await IntentService.listCronjobs(server)
            .map { CronjobEntity(job: $0, serverID: server.id) }
    }

    private func resolvedServer() async -> ServerConfig? {
        await MainActor.run { IntentService.currentServer() }
    }
}
