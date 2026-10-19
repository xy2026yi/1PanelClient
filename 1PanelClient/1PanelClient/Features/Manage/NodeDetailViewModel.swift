//
//  NodeDetailViewModel.swift
//  1PanelClient
//
//  节点详情数据层：从 NodeDetailView 迁出的数据态与加载逻辑（纯搬迁，
//  零行为变化；操作方法与 PageVMStore 接入随后续批次）。
//  load() 的三个契约保持原语义：
//    ① item 为 nil 才置 isLoading——重访/回填有快照时静默刷新不转圈
//    ② hasLoaded 门控 onAppear 的静默刷新，防 .task/.onAppear 双首发
//    ③ 代际只在结果替换点校验，并发 load 只让最后一次生效
//

import Foundation
import Combine

@MainActor
final class NodeDetailViewModel: ObservableObject {
    @Published private(set) var item: NodeDetailItem?
    @Published private(set) var current: NodeCurrentItem?
    @Published private(set) var counts: NodeCounts?
    /// 当前操作节点名（NodeScope 镜像：进页/回页/节点切换通知三处同步）
    @Published private(set) var currentNode = "local"
    @Published private(set) var isLoading = true
    @Published private(set) var hasLoaded = false
    @Published private(set) var errorMessage: String?

    /// 加载代际：并发 load 时只让最后一次的结果生效，
    /// 避免先发出的慢请求晚到，把新数据覆盖回旧值
    private var loadGeneration = 0

    let nodeID: Int
    let client: APIClient
    private let serverID: UUID

    init(nodeID: Int, server: ServerConfig) {
        self.nodeID = nodeID
        self.client = APIClient.shared(for: server)
        self.serverID = server.id
    }

    // MARK: - 派生

    var nodeName: String { item?.name ?? "" }
    var isCurrentNode: Bool { nodeName == currentNode && !nodeName.isEmpty }
    /// local 为主控节点，删除后当前面板连接即失效
    var isLocalNode: Bool { (item?.name ?? "local") == "local" }

    /// 响应过程中连接被服务端断开（主控自身重启的预期表现），按 URLError 精确识别
    static func isConnectionDropped(_ error: Error) -> Bool {
        guard case .networkError(let err) = error as? APIError,
              let urlErr = err as? URLError else { return false }
        return urlErr.code == .networkConnectionLost || urlErr.code == .timedOut
    }

    /// 从 NodeScope 同步当前操作节点名
    func syncCurrentNode() {
        currentNode = NodeScope.current(for: serverID) ?? "local"
    }

    // MARK: - 加载

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        if item == nil { isLoading = true }
        do {
            let resp: PageResponse<NodeDetailItem> = try await client.send(
                path: APIEndpoint.nodesSearch.path,
                body: NodeSearchRequest(page: 1, pageSize: 100),
                as: PageResponse<NodeDetailItem>.self
            )
            guard generation == loadGeneration else { return }
            errorMessage = nil
            item = (resp.items ?? []).first(where: { $0.id == nodeID })
            if item == nil {
                errorMessage = L10n.t("节点不存在或已被移除")
            }
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
        // 实时状态与数量（失败不阻塞页面）
        if let currents = try? await client.send(
            path: APIEndpoint.nodesCurrent.path,
            method: APIEndpoint.nodesCurrent.method,
            as: [NodeCurrentItem].self
        ) {
            guard generation == loadGeneration else { return }
            current = currents.first(where: { $0.nodeName == nodeName })
        }
        if !nodeName.isEmpty {
            let loaded = await NodeCountsLoader.load(for: nodeName, client: client)
            guard generation == loadGeneration else { return }
            counts = loaded
        }
        hasLoaded = true
    }

    // MARK: - 操作（请求与业务判定归 VM；呈现/导航由 View 按结果处理）

    enum NodeOpOutcome {
        /// 成功（含主控重启预期断连按成功处理）；关联值为导航载荷（同步的 taskID）
        case ok(String?)
        case failed(String)
    }

    @Published private(set) var isSyncing = false

    /// 同步节点：提交成功返回 taskID（View 据此进任务进度页）
    func syncNode() async -> NodeOpOutcome {
        guard !isSyncing else { return .ok(nil) }
        isSyncing = true
        defer { isSyncing = false }
        let taskID = UUID().uuidString
        do {
            _ = try await client.send(
                path: APIEndpoint.nodesSync.path,
                body: NodeSyncRequest(id: nodeID, taskID: taskID),
                as: EmptyResponse.self
            )
            return .ok(taskID)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 重启面板/服务器（service 为 RestartTarget.rawValue）；
    /// 仅重启本机（主控）时服务端收到指令后会主动断开连接，这类网络错误
    /// 按成功处理——远程节点重启经主控转发、主控不重启，错误如实上报
    func restartNode(service: String) async -> NodeOpOutcome {
        do {
            _ = try await client.send(
                path: APIEndpoint.nodesRestart.path,
                body: NodeRestartRequest(id: nodeID, restartService: service),
                as: EmptyResponse.self
            )
            return .ok(nil)
        } catch {
            if isLocalNode, Self.isConnectionDropped(error) {
                return .ok(nil)
            }
            return .failed(error.localizedDescription)
        }
    }

    /// 删除节点；删除的是当前切换节点时回退本机，
    /// 避免后续请求路由到不存在的节点
    func deleteNode(force: Bool, withUninstall: Bool) async -> NodeOpOutcome {
        do {
            _ = try await client.send(
                path: APIEndpoint.nodesDelete.path,
                body: NodeDeleteRequest(ids: [nodeID], force: force, withUninstall: withUninstall),
                as: EmptyResponse.self
            )
            if nodeName == (NodeScope.current(for: serverID) ?? "local") {
                NodeScope.setCurrent(nil, for: serverID)
            }
            return .ok(nil)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
