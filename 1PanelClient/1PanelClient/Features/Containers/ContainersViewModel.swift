//
//  ContainersViewModel.swift
//  1PanelClient
//

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class ContainersViewModel: ObservableObject {
    @Published var containers: [Container] = []
    @Published var dockerStatus: DockerStatus?
    @Published var images: [ContainerImage] = []
    @Published var imageOptions: [String] = []

    /// 创建容器选项
    @Published var networkOptions: [String] = []
    @Published var volumeOptions: [String] = []
    @Published var containerLimit: ContainerLimit?

    @Published var isLoading = false
    @Published var isLoadingDocker = false
    @Published var isLoadingImages = false
    @Published var dockerOperating = false
    @Published var containerOperating = false
    @Published var imageOperating = false
    @Published var errorMessage: String?
    @Published var dockerErrorMessage: String?

    @Published var showAlert = false
    @Published var alertMessage = ""
    /// 最近一次 alert 是否为操作成功（任务已提交）——提交页据此判断是否返回，
    /// 避免依赖 alert 文案字符串匹配
    @Published var lastAlertIsSuccess = false

    /// 标记 docker 状态是否已加载，避免 List 重绘反复请求
    private var dockerLoaded = false

    private var client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    func refresh() async {
        if dockerStatus == nil { isLoadingDocker = true }
        // 并行加载容器列表和 Docker 状态，避免串行等待
        async let listTask = load(query: "")
        async let dockerTask = loadDockerStatus(force: false)
        _ = await (listTask, dockerTask)
    }

    func search(query: String) async {
        await load(query: query)
    }

    // MARK: - 容器列表 + 运行时指标

    private func load(query: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let req = ContainerSearchRequest(
            page: 1, pageSize: 100, name: query, state: "all",
            orderBy: "createdAt", order: "null"
        )
        do {
            let resp: ContainerListResponse = try await client.send(
                path: APIEndpoint.containersSearch.path,
                body: req, as: ContainerListResponse.self
            )
            // 先显示列表，避免等待 stats 接口导致长时间 loading
            self.containers = resp.items ?? []
            // 后台合并运行时指标（CPU/内存），完成后刷新界面
            await mergeStats()
        } catch let err as APIError {
            self.errorMessage = err.errorDescription
            self.containers = []
        } catch {
            self.errorMessage = error.localizedDescription
            self.containers = []
        }
    }

    private func mergeStats() async {
        guard let stats: [ContainerStats] = try? await client.send(
            path: APIEndpoint.containersListStats.path,
            method: "GET", as: [ContainerStats].self
        ) else { return }
        let pairs: [(String, ContainerStats)] = stats.compactMap {
            guard let id = $0.containerID else { return nil }
            return (id, $0)
        }
        let map = Dictionary(uniqueKeysWithValues: pairs)
        for i in containers.indices {
            if let s = map[containers[i].containerID] {
                containers[i].cpuPercent = s.cpuPercent
                containers[i].memoryUsage = s.memoryUsage
                containers[i].memoryLimit = s.memoryLimit
                containers[i].memoryPercent = s.memoryPercent
            }
        }
    }

    // MARK: - Docker 服务状态

    func loadDockerStatus(force: Bool) async {
        if !force && dockerLoaded { return }
        dockerLoaded = true
        isLoadingDocker = true
        defer { isLoadingDocker = false }
        do {
            self.dockerStatus = try await client.send(
                path: APIEndpoint.containersDockerStatus.path,
                method: "GET", as: DockerStatus.self
            )
        } catch {
            // 解码/网络失败时记录原因，便于排查；不阻断容器列表展示
            self.dockerStatus = nil
            self.dockerErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Docker 操作（start/stop/restart）

    func operateDocker(operation: String) async {
        dockerOperating = true
        defer { dockerOperating = false }
        let opName = operation == "start" ? "启动" : (operation == "stop" ? "停止" : "重启")
        let req = DockerOperateRequest(operation: operation)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersDockerOperate.path,
                body: req, as: EmptyResponse.self
            )
            try? await Task.sleep(for: .seconds(1))
            await loadDockerStatus(force: true)
            await load(query: "")
        } catch {
            showAlert(message: "\(opName) Docker 失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 清理容器

    func pruneContainers() async {
        dockerOperating = true
        defer { dockerOperating = false }
        let req = ContainerPruneRequest(
            taskID: UUID().uuidString, pruneType: "container", withTagAll: false
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersPrune.path,
                body: req, as: EmptyResponse.self
            )
            try? await Task.sleep(for: .seconds(1))
            await load(query: "")
            showAlert(message: "清理容器任务已提交")
        } catch {
            showAlert(message: "清理容器失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 单个容器操作（stop/start/restart/kill）

    @discardableResult
    func operateContainer(name: String, operation: String) async -> Bool {
        containerOperating = true
        defer { containerOperating = false }
        let opName: String
        switch operation {
        case "stop": opName = "停止"
        case "start": opName = "启动"
        case "restart": opName = "重启"
        case "kill": opName = "关闭"
        case "pause": opName = "暂停"
        case "unpause": opName = "恢复"
        case "remove": opName = "删除"
        default: opName = operation
        }
        let req = ContainerOperateRequest(names: [name], operation: operation, taskID: UUID().uuidString)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersOperate.path,
                body: req, as: EmptyResponse.self
            )
            try? await Task.sleep(for: .seconds(1))
            await load(query: "")
            showAlert(message: "\(opName)容器「\(name)」任务已提交")
            return true
        } catch {
            showAlert(message: "\(opName)容器失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 提交容器操作并返回 taskID（供 TaskProgressView 轮询进度）；失败返回 nil
    func operateContainerTask(name: String, operation: String) async -> String? {
        containerOperating = true
        defer { containerOperating = false }
        let taskID = UUID().uuidString
        let req = ContainerOperateRequest(names: [name], operation: operation, taskID: taskID)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersOperate.path,
                body: req, as: EmptyResponse.self
            )
            return taskID
        } catch let err as APIError {
            showAlert(message: "操作失败：\(err.errorDescription ?? "未知错误")")
            return nil
        } catch {
            showAlert(message: "操作失败：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 容器升级

    func upgradeContainer(name: String, image: String, forcePull: Bool) async {
        containerOperating = true
        defer { containerOperating = false }
        let req = ContainerUpgradeRequest(
            taskID: UUID().uuidString, names: [name], image: image, forcePull: forcePull
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersUpgrade.path,
                body: req, as: EmptyResponse.self
            )
            try? await Task.sleep(for: .seconds(1))
            await load(query: "")
            showAlert(message: "升级容器「\(name)」任务已提交", isSuccess: true)
        } catch {
            showAlert(message: "升级容器失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 容器日志（SSE 流式）

    /// 返回容器日志的 SSE 流（已剥离 `data: ` 前缀）
    func streamLogs(container name: String) -> AsyncThrowingStream<String, Error> {
        client.streamSSELines(
            path: APIEndpoint.containersSearchLog.path,
            queryItems: [
                URLQueryItem(name: "container", value: name),
                URLQueryItem(name: "since", value: "all"),
                URLQueryItem(name: "tail", value: "100"),
                URLQueryItem(name: "follow", value: "true"),
                URLQueryItem(name: "operateNode", value: "local")
            ]
        )
    }

    // MARK: - 容器编辑（info / image 选项 / update）

    private struct ContainerInfoRequest: Encodable { let name: String }

    /// 获取容器详情配置（POST /containers/info）
    /// 失败时弹出 alert，返回 nil
    func loadContainerInfo(name: String) async -> ContainerInfo? {
        do {
            return try await client.send(
                path: APIEndpoint.containersInfo.path,
                body: ContainerInfoRequest(name: name),
                as: ContainerInfo.self
            )
        } catch {
            showAlert(message: "获取容器配置失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 加载镜像选项（GET /containers/image），用于编辑/升级时下拉选择
    func loadImageOptions() async {
        do {
            let opts = try await client.send(
                path: APIEndpoint.containersImageOptions.path,
                method: "GET", as: [ContainerOption].self
            )
            self.imageOptions = opts.map { $0.option }
        } catch {
            self.imageOptions = []
        }
    }

    // MARK: - 创建容器

    /// 加载创建容器所需选项：网络 / 存储卷 / 镜像 / CPU·内存上限
    func loadCreateOptions() async {
        async let nets: [ContainerOption]? = try? await client.send(
            path: APIEndpoint.containersNetwork.path, method: "GET", as: [ContainerOption].self
        )
        async let vols: [ContainerOption]? = try? await client.send(
            path: APIEndpoint.containersVolume.path, method: "GET", as: [ContainerOption].self
        )
        async let imgs: [ContainerOption]? = try? await client.send(
            path: APIEndpoint.containersImageOptions.path, method: "GET", as: [ContainerOption].self
        )
        async let lim: ContainerLimit? = try? await client.send(
            path: APIEndpoint.containersLimit.path, method: "GET", as: ContainerLimit.self
        )
        let (n, v, i, l) = await (nets, vols, imgs, lim)
        self.networkOptions = (n ?? []).map { $0.option }
        self.volumeOptions = (v ?? []).map { $0.option }
        self.imageOptions = (i ?? []).map { $0.option }
        self.containerLimit = l
    }

    /// 创建容器（POST /containers），字段对齐 doc/手动创建容器.log
    func createContainer(draft: ContainerCreateDraft) async {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty,
              !draft.image.trimmingCharacters(in: .whitespaces).isEmpty else {
            showAlert(message: "容器名称和镜像不能为空")
            return
        }
        containerOperating = true
        defer { containerOperating = false }

        let ports = draft.ports.map {
            ContainerUpdatePort(
                hostIP: "", hostPort: $0.host,
                containerPort: $0.containerPort, protocolField: $0.protocolField,
                host: $0.host
            )
        }
        let volumes = draft.volumes.map {
            ContainerVolumeInfo(
                type: $0.type, sourceDir: $0.sourceDir, containerDir: $0.containerDir,
                mode: $0.mode, shared: $0.shared
            )
        }
        let networks = [ContainerNetworkInfo(
            network: draft.network, ipv4: "", ipv6: "", macAddr: ""
        )]
        let req = ContainerUpdateRequest(
            taskID: UUID().uuidString,
            name: draft.name.trimmingCharacters(in: .whitespaces),
            image: draft.image.trimmingCharacters(in: .whitespaces),
            imageInput: true,
            forcePull: draft.forcePull,
            networks: networks,
            hostname: draft.hostname,
            domainName: "",
            dns: [],
            cmdStr: "",
            entrypointStr: "",
            memoryItem: 0,
            cmd: [],
            workingDir: "",
            user: "",
            openStdin: draft.openStdin,
            tty: draft.tty,
            entrypoint: [],
            publishAllPorts: draft.publishAllPorts,
            exposedPorts: ports,
            nanoCPUs: 0,
            cpuShares: draft.cpuShares,
            memory: Int64(draft.memoryMB) * 1024 * 1024,
            volumes: volumes,
            privileged: draft.privileged,
            autoRemove: draft.autoRemove,
            labels: [],
            env: draft.env,
            restartPolicy: draft.restartPolicy
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersCreate.path, body: req, as: EmptyResponse.self
            )
            try? await Task.sleep(for: .seconds(1))
            await load(query: "")
            showAlert(message: "创建容器「\(draft.name)」任务已提交", isSuccess: true)
        } catch {
            showAlert(message: "创建容器失败：\(error.localizedDescription)")
        }
    }

    /// 更新容器配置（POST /containers/update）
    /// info 来自 /containers/info；image / forcePull / publishAllPorts / env 为用户编辑后的值
    func updateContainer(
        info: ContainerInfo,
        image: String,
        forcePull: Bool,
        publishAllPorts: Bool,
        env: [String]
    ) async {
        containerOperating = true
        defer { containerOperating = false }

        let ports = (info.exposedPorts ?? []).map { p in
            ContainerUpdatePort(
                hostIP: p.hostIP,
                hostPort: p.hostPort,
                containerPort: p.containerPort,
                protocolField: p.protocolField,
                host: "\(p.hostIP):\(p.hostPort)"
            )
        }
        let req = ContainerUpdateRequest(
            taskID: UUID().uuidString,
            name: info.name,
            image: image,
            imageInput: false,
            forcePull: forcePull,
            networks: info.networks ?? [],
            hostname: info.hostname ?? "",
            domainName: info.domainName ?? "",
            dns: info.dns ?? [],
            cmdStr: "",
            entrypointStr: (info.entrypoint ?? []).joined(separator: " "),
            memoryItem: 0,
            cmd: info.cmd ?? [],
            workingDir: info.workingDir ?? "",
            user: info.user ?? "",
            openStdin: info.openStdin ?? false,
            tty: info.tty ?? false,
            entrypoint: info.entrypoint ?? [],
            publishAllPorts: publishAllPorts,
            exposedPorts: ports,
            nanoCPUs: info.nanoCPUs ?? 0,
            cpuShares: info.cpuShares ?? 0,
            memory: info.memory ?? 0,
            volumes: info.volumes ?? [],
            privileged: info.privileged ?? false,
            autoRemove: info.autoRemove ?? false,
            labels: info.labels ?? [],
            env: env,
            restartPolicy: info.restartPolicy ?? "always"
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersUpdate.path,
                body: req, as: EmptyResponse.self
            )
            try? await Task.sleep(for: .seconds(1))
            await load(query: "")
            showAlert(message: "更新容器「\(info.name)」任务已提交", isSuccess: true)
        } catch {
            showAlert(message: "更新容器失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 镜像列表

    func loadImages() async {
        isLoadingImages = true
        defer { isLoadingImages = false }
        do {
            self.images = try await client.send(
                path: APIEndpoint.containersImageAll.path,
                method: "GET", as: [ContainerImage].self
            )
        } catch {
            self.images = []
        }
    }

    // MARK: - 清理镜像（withTagAll: false=未标签, true=未使用）

    func pruneImages(withTagAll: Bool) async {
        imageOperating = true
        defer { imageOperating = false }
        let type = withTagAll ? "未使用" : "未标签"
        let req = ContainerPruneRequest(
            taskID: UUID().uuidString, pruneType: "image", withTagAll: withTagAll
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersPrune.path,
                body: req, as: EmptyResponse.self
            )
            try? await Task.sleep(for: .seconds(1))
            await loadImages()
            showAlert(message: "清理\(type)镜像任务已提交")
        } catch {
            showAlert(message: "清理\(type)镜像失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 拉取镜像

    func pullImage(fromRepo: Bool, repoID: Int, imageNames: [String]) async -> String? {
        imageOperating = true
        defer { imageOperating = false }
        let req = ImagePullRequest(
            taskID: UUID().uuidString,
            fromRepo: fromRepo,
            repoID: repoID,
            imageName: imageNames
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersImagePull.path,
                body: req, as: EmptyResponse.self
            )
            return req.taskID
        } catch {
            showAlert(message: "拉取镜像失败：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 查询仓库

    private struct RepoSearchRequest: Encodable {
        let page: Int
        let pageSize: Int
    }

    func loadRepos() async -> [ContainerRepo] {
        let req = RepoSearchRequest(page: 1, pageSize: 100)
        do {
            let resp: PageResponse<ContainerRepo> = try await client.send(
                path: APIEndpoint.containersRepoSearch.path,
                body: req, as: PageResponse<ContainerRepo>.self
            )
            return resp.items ?? []
        } catch {
            return []
        }
    }

    // MARK: - 仓库管理（添加/编辑/删除/同步）

    func createRepo(_ req: RepoCreateRequest) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersRepoCreate.path, body: req, as: EmptyResponse.self
            )
            return true
        } catch {
            showAlert(message: "添加仓库失败：\(error.localizedDescription)")
            return false
        }
    }

    func updateRepo(_ req: RepoUpdateRequest) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersRepoUpdate.path, body: req, as: EmptyResponse.self
            )
            return true
        } catch {
            showAlert(message: "更新仓库失败：\(error.localizedDescription)")
            return false
        }
    }

    func deleteRepo(id: Int) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersRepoDelete.path,
                body: RepoIDRequest(id: id), as: EmptyResponse.self
            )
            return true
        } catch {
            showAlert(message: "删除仓库失败：\(error.localizedDescription)")
            return false
        }
    }

    func syncRepo(id: Int) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersRepoSync.path,
                body: RepoIDRequest(id: id), as: EmptyResponse.self
            )
            showAlert(message: "仓库同步任务已提交")
            return true
        } catch {
            showAlert(message: "同步仓库失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 删除镜像

    func deleteImages(names: [String]) async -> Bool {
        imageOperating = true
        defer { imageOperating = false }
        let req = ImageDeleteRequest(names: names)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersImageDelete.path,
                body: req, as: EmptyResponse.self
            )
            await loadImages()
            return true
        } catch {
            showAlert(message: "删除镜像失败：\(error.localizedDescription)")
            return false
        }
    }

    private func showAlert(message: String, isSuccess: Bool = false) {
        alertMessage = message
        lastAlertIsSuccess = isSuccess
        showAlert = true
    }
}

