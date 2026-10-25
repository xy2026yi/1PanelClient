//
//  RuntimesViewModel.swift
//  1PanelClient
//
//  运行环境列表 VM：分类型查询/分页/启停重启/删除（含关联检查）/备注/同步。
//  创建与编辑由表单提交（返回 taskID 自行推进度页），其余任务式操作在此推入。
//

import SwiftUI
import Combine

/// 任务进度目标（任务式操作 → TaskProgressView）
struct RuntimeTaskTarget: Identifiable, Hashable {
    let taskID: String
    let title: String
    var id: String { taskID }
}

@MainActor
final class RuntimesViewModel: ObservableObject {

    // MARK: - 分段（全部 + 四类型）

    enum Segment: String, CaseIterable, Identifiable {
        case all, php, node, python, go

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return L10n.t("全部")
            case .php: return "PHP"
            case .node: return "Node.js"
            case .python: return "Python"
            case .go: return "Go"
            }
        }

        /// search 请求的 type 值（全部传空串）
        var searchType: String {
            switch self {
            case .all: return ""
            case .php: return RuntimeType.php.searchKey
            case .node: return RuntimeType.node.searchKey
            case .python: return RuntimeType.python.searchKey
            case .go: return RuntimeType.go.searchKey
            }
        }
    }

    // MARK: - 状态

    @Published var segment: Segment = .all {
        didSet { if oldValue != segment { Task { await load() } }
        }
    }
    @Published private(set) var runtimes: [RuntimeEntry] = []
    @Published private(set) var total = 0
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    @Published var toastMessage: String?
    @Published var showAlert = false
    @Published var alertMessage = "" {
        didSet { if !alertMessage.isEmpty { showAlert = true } }
    }

    /// 任务式操作进度（创建/编辑由表单返回 taskID 后写入，列表侧删除亦走此）
    @Published var activeTask: RuntimeTaskTarget?

    /// 行级操作中（启停/重启转圈）
    @Published private(set) var operatingIDs: Set<Int> = []

    // 删除流程：先查关联（有关联直接提示解绑），无关联再弹输入名称确认
    @Published var deleteTarget: RuntimeEntry?
    @Published private(set) var deleteBlockers: [AppDeleteCheckItem] = []

    let client: APIClient

    private let server: ServerConfig
    private var page = 1
    private let pageSize = 20
    private var loadGeneration = 0

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient.shared(for: server)
    }

    // MARK: - 查询

    func load() async {
        loadGeneration += 1
        let gen = loadGeneration
        page = 1
        isLoading = runtimes.isEmpty
        errorMessage = nil
        do {
            let req = RuntimeListSearchRequest(page: 1, pageSize: pageSize, type: segment.searchType)
            let resp: RuntimeListResponse = try await client.send(
                path: APIEndpoint.runtimesSearch.path, body: req, as: RuntimeListResponse.self
            )
            guard gen == loadGeneration else { return }
            runtimes = resp.items ?? []
            total = resp.total
        } catch {
            guard gen == loadGeneration, !APIError.isCancellation(error) else { return }
            // 已有数据时降级为 toast（轮询期间网络抖动不打断列表展示）
            if runtimes.isEmpty {
                errorMessage = error.localizedDescription
            } else {
                toastMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    func loadMore() async {
        guard runtimes.count < total, !isLoading else { return }
        loadGeneration += 1
        let gen = loadGeneration
        isLoading = true
        page += 1
        do {
            let req = RuntimeListSearchRequest(page: page, pageSize: pageSize, type: segment.searchType)
            let resp: RuntimeListResponse = try await client.send(
                path: APIEndpoint.runtimesSearch.path, body: req, as: RuntimeListResponse.self
            )
            guard gen == loadGeneration else { return }
            let known = Set(runtimes.map(\.id))
            runtimes.append(contentsOf: (resp.items ?? []).filter { !known.contains($0.id) })
            total = resp.total
        } catch {
            guard gen == loadGeneration, !APIError.isCancellation(error) else { return }
            page -= 1
            toastMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - 同步 / 备注

    /// 进页同步容器状态（面板进入列表页时自动调用）
    func syncStatus() async {
        struct Empty: Encodable {}
        _ = try? await client.send(path: APIEndpoint.runtimesSync.path, body: Empty(), as: EmptyResponse.self)
    }

    func updateRemark(_ entry: RuntimeEntry, remark: String) async {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.runtimesRemark.path,
                body: RuntimeRemarkRequest(id: entry.id, remark: remark),
                as: EmptyResponse.self
            )
            if let idx = runtimes.firstIndex(where: { $0.id == entry.id }) {
                runtimes[idx].remark = remark
            }
        } catch {
            toastMessage = L10n.f("备注保存失败：%@", error.localizedDescription)
        }
    }

    // MARK: - 启动 / 停止 / 重启

    func operate(_ entry: RuntimeEntry, operate: String) async {
        guard operatingIDs.isEmpty else { return }
        operatingIDs.insert(entry.id)
        defer { operatingIDs.remove(entry.id) }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.runtimesOperate.path,
                body: RuntimeOperateRequest(operate: operate, ID: entry.id),
                as: EmptyResponse.self
            )
            toastMessage = L10n.t("操作已提交")
            // 过渡态立即拉一次；面板靠任务/轮询收敛，这里轻量刷新即可
            try? await Task.sleep(for: .seconds(1))
            await load()
        } catch {
            toastMessage = L10n.f("操作失败：%@", error.localizedDescription)
        }
    }

    // MARK: - 删除（先查关联 → 输入名称确认 → 任务式）

    func requestDelete(_ entry: RuntimeEntry) async {
        deleteTarget = nil
        deleteBlockers = []
        do {
            let path = APIEndpoint.runtimesDeleteCheck.path
                .replacingOccurrences(of: ":id", with: String(entry.id))
            let linked: [AppDeleteCheckItem] = try await client.send(
                path: path, method: APIEndpoint.runtimesDeleteCheck.method,
                queryItems: client.operateNodeQuery, as: [AppDeleteCheckItem].self
            )
            deleteBlockers = linked
        } catch {
            // 检查失败不阻断删除，按无关联继续（服务端仍会校验）
            deleteBlockers = []
        }
        guard deleteBlockers.isEmpty else {
            // 有关联网站时服务端无条件拒绝（forceDelete 也不放行），
            // 不进名称确认，提示先解绑（面板同口径）
            let names = deleteBlockers
                .map { $0.name ?? $0.type ?? "" }
                .filter { !$0.isEmpty }
                .joined(separator: "、")
            alertMessage = L10n.f(
                "该运行环境被以下网站使用：%@。请先在「网站」中解绑或删除对应网站，再删除运行环境。",
                names
            )
            return
        }
        deleteTarget = entry
    }

    func confirmDelete(_ entry: RuntimeEntry, force: Bool, deleteImage: Bool) async {
        let taskID = UUID().uuidString.lowercased()
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.runtimesDel.path,
                body: RuntimeDeleteRequest(
                    id: entry.id, forceDelete: force, deleteImage: deleteImage, taskID: taskID
                ),
                as: EmptyResponse.self
            )
            deleteTarget = nil
            activeTask = RuntimeTaskTarget(
                taskID: taskID, title: L10n.f("删除运行环境 %@", entry.displayName)
            )
        } catch {
            alertMessage = L10n.f("删除失败：%@", error.localizedDescription)
        }
    }

    // MARK: - 清理构建缓存（PHP 构建镜像产生的缓存；复用容器清理端点，任务式）

    @discardableResult
    func cleanBuildCache() async -> String? {
        let taskID = UUID().uuidString.lowercased()
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersPrune.path,
                body: ContainerPruneRequest(taskID: taskID, pruneType: "buildcache",
                                            withTagAll: false),
                as: EmptyResponse.self
            )
            activeTask = RuntimeTaskTarget(taskID: taskID, title: L10n.t("清理构建缓存"))
            return taskID
        } catch {
            alertMessage = L10n.f("清理失败：%@", error.localizedDescription)
            return nil
        }
    }

    // MARK: - 创建 / 编辑提交（表单调用，返回 taskID 由表单推进度页）

    func submitCreate(_ request: RuntimeCreateRequest) async -> String? {
        do {
            // 创建响应是详情条目的另一形态（params 为空串、无 appID/appParams），
            // 不能按 RuntimeEntry 解码——只关心提交成功，进度经 request.taskID 推进
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.runtimesCreate.path, body: request, as: EmptyResponse.self
            )
            return request.taskID
        } catch {
            alertMessage = L10n.f("创建失败：%@", error.localizedDescription)
            return nil
        }
    }

    func submitUpdate(_ request: RuntimeUpdateRequest, name: String) async -> String? {
        // update 接口同步返回（无 taskID 回执）；编辑保存以提交即视为进入重建，
        // 用请求内无任务可轮询 —— 抓包口径 rebuild 重建走构建日志而非任务日志，
        // 进度改为详情页「日志」查看，这里返回 nil 表示无进度页可推
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.runtimesUpdate.path, body: request, as: EmptyResponse.self
            )
            toastMessage = L10n.f("已保存，正在重建 %@", name)
            return nil
        } catch {
            alertMessage = L10n.f("保存失败：%@", error.localizedDescription)
            return nil
        }
    }
}
