//
//  KVMViewModel.swift
//  1PanelClient
//
//  虚拟机管理（KVM，/xpack/vms/*，专业版）页面状态：环境检测、五段数据
//  （虚拟机 / 镜像 / 模版 / 网络 / 存储池）加载与全部操作出口。
//  任务式操作（创建·编辑·重命名·转模版·删除·快照·模版删除）成功后置 activeTask，
//  由根页推入 TaskProgressView（operateNode=local，与抓包一致）并在完成时整页刷新；
//  即时操作（电源·同步·网络/存储启停自启·镜像增删改）成功后直接重拉对应段。
//

import SwiftUI
import Combine

/// 任务进度目标（任务式操作 → TaskProgressView）
struct KVMTaskTarget: Identifiable, Hashable {
    let taskID: String
    let title: String
    var id: String { taskID }
}

@MainActor
final class KVMViewModel: ObservableObject {
    enum Segment: String, CaseIterable, Identifiable {
        case vms, iso, templates, networks, storages

        var id: String { rawValue }
        var title: String {
            switch self {
            case .vms: return L10n.t("虚拟机")
            case .iso: return L10n.t("镜像")
            case .templates: return L10n.t("模版")
            case .networks: return L10n.t("网络")
            case .storages: return L10n.t("存储池")
            }
        }
    }

    @Published var segment: Segment = .vms

    // 环境检测
    @Published private(set) var environment: KVMEnvironment?
    @Published private(set) var environmentError: String?
    @Published private(set) var isCheckingEnvironment = true

    // 五段数据
    @Published private(set) var vms: [KVMVirtualMachine] = []
    @Published private(set) var vmTotal = 0
    @Published private(set) var isos: [KVMISOImage] = []
    @Published private(set) var templates: [KVMTemplate] = []
    @Published private(set) var networks: [KVMNetwork] = []
    @Published private(set) var storages: [KVMStoragePool] = []
    /// 创建网络下拉源：可用网桥（Bridge）/ 宿主机网卡（Macvtap），GET 拉取
    @Published private(set) var bridges: [KVMBridge] = []
    @Published private(set) var hostInterfaces: [KVMHostInterface] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var toastMessage: String?
    /// 操作中的虚拟机 id（电源操作期间行内转圈）
    @Published private(set) var operatingIDs: Set<Int> = []
    /// 任务进度目标；根页据此推入进度页
    @Published var activeTask: KVMTaskTarget?

    let server: ServerConfig
    private(set) var client: APIClient
    private var page = 1
    private var loadGeneration = 0
    private static let pageSize = 20

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient.shared(for: server)
    }

    // MARK: 加载

    /// 进页 / 下拉：环境检测 + 当前段数据
    func load() async {
        await checkEnvironment()
        guard environment?.isReady == true else { return }
        await loadSegment()
    }

    func checkEnvironment() async {
        isCheckingEnvironment = true
        defer { isCheckingEnvironment = false }
        do {
            environment = try await client.send(
                path: APIEndpoint.kvmEnvironment.path,
                method: APIEndpoint.kvmEnvironment.method,
                as: KVMEnvironment.self)
            environmentError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            environmentError = error.localizedDescription
        }
    }

    func loadSegment() async {
        isLoading = true
        defer { isLoading = false }
        switch segment {
        case .vms: await loadVMs()
        case .iso: await loadISOs()
        case .templates: await loadTemplates()
        case .networks: await loadNetworks()
        case .storages: await loadStorages()
        }
    }

    /// 表单下拉所需的引用数据（镜像 / 模版 / 网络 / 存储池）并发拉取
    func loadReferenceData() async {
        async let a: () = loadISOs()
        async let b: () = loadTemplates()
        async let c: () = loadNetworks()
        async let d: () = loadStorages()
        _ = await (a, b, c, d)
    }

    func loadVMs() async {
        page = 1
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let resp: PageResponse<KVMVirtualMachine> = try await client.send(
                path: APIEndpoint.kvmSearch.path,
                body: KVMSearchRequest(),
                as: PageResponse<KVMVirtualMachine>.self)
            guard generation == loadGeneration else { return }
            vms = resp.items ?? []
            vmTotal = resp.total ?? 0
            errorMessage = nil
        } catch {
            guard !APIError.isCancellation(error), generation == loadGeneration else { return }
            if vms.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    func loadMoreVMs() async {
        guard vms.count < vmTotal else { return }
        let next = page + 1
        let generation = loadGeneration
        do {
            let resp: PageResponse<KVMVirtualMachine> = try await client.send(
                path: APIEndpoint.kvmSearch.path,
                body: KVMSearchRequest(page: next, pageSize: Self.pageSize),
                as: PageResponse<KVMVirtualMachine>.self)
            guard generation == loadGeneration else { return }
            let existing = Set(vms.map(\.id))
            vms += (resp.items ?? []).filter { !existing.contains($0.id) }
            vmTotal = resp.total ?? vmTotal
            page = next
        } catch {
            // 追加失败静默
        }
    }

    var hasTransitioningVM: Bool { vms.contains { $0.isTransitioning } }

    func loadISOs() async {
        if let list: [KVMISOImage] = await fetchList(.kvmISOList) { isos = list }
    }

    func loadTemplates() async {
        if let list: [KVMTemplate] = await fetchList(.kvmTemplateList) { templates = list }
    }

    func loadNetworks() async {
        if let list: [KVMNetwork] = await fetchList(.kvmNetworkList) { networks = list }
    }

    func loadStorages() async {
        if let list: [KVMStoragePool] = await fetchList(.kvmStorageList) { storages = list }
    }

    /// 无 body 的 POST 列表（镜像 / 模版 / 网络 / 存储池）；失败时保留旧快照。
    /// 不写 errorMessage——那是 VM 列表空态专用，引用数据并发拉取失败
    /// 会把无关错误短暂顶进 VM 分段的「加载失败」占位
    private func fetchList<T: Decodable>(_ endpoint: APIEndpoint) async -> [T]? {
        do {
            return try await client.send(path: endpoint.path, as: [T].self)
        } catch {
            guard !APIError.isCancellation(error) else { return nil }
            return nil
        }
    }

    // MARK: 虚拟机操作

    /// 电源操作（start / shutdown / reboot / suspend / resume / destroy）
    func operate(_ vm: KVMVirtualMachine, _ operate: KVMOperate) async {
        operatingIDs.insert(vm.id)
        defer { operatingIDs.remove(vm.id) }
        let ok: Bool = await sendEmpty(.kvmOperate,
                                       body: KVMOperateRequest(name: vm.displayName, operate: operate.rawValue),
                                       failure: { L10n.f("%@失败：%@", operate.displayName, $0) })
        if ok {
            toastMessage = L10n.f("已执行「%@」", operate.displayName)
            // libvirt 状态切换有延迟：短暂等待后重拉
            try? await Task.sleep(nanoseconds: 800_000_000)
            await loadVMs()
        }
    }

    /// 同步 libvirt 域到面板（无 body）
    func sync() async {
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.kvmSync.path, as: EmptyResponse.self)
            toastMessage = L10n.t("已同步")
            await loadVMs()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            alert(L10n.f("同步失败：%@", detail(error)))
        }
    }

    // MARK: 孤立数据清理（orphans/scan|clean 抓包 2026-10-24）

    @Published private(set) var orphans: [KVMOrphanItem] = []
    @Published private(set) var isScanningOrphans = false
    @Published private(set) var isCleaningOrphans = false
    /// 是否已执行过扫描（区分「未扫描」与「扫描后无孤立数据」空态）
    @Published private(set) var hasScannedOrphans = false

    /// 扫描孤立数据（未被虚拟机 / 快照 / 已登记模版引用的候选文件）
    func scanOrphans() async {
        isScanningOrphans = true
        defer { isScanningOrphans = false }
        do {
            orphans = try await client.send(path: APIEndpoint.kvmOrphansScan.path,
                                            as: [KVMOrphanItem].self)
            hasScannedOrphans = true
        } catch {
            guard !APIError.isCancellation(error) else { return }
            alert(L10n.f("扫描失败：%@", detail(error)))
        }
    }

    /// 清理所选项。响应语义未定（抓包回显已删项，非剩余列表），成功后重扫取权威列表。
    /// 返回是否成功（供视图决定勾选复位策略）
    @discardableResult
    func cleanOrphans(_ items: [KVMOrphanItem]) async -> Bool {
        isCleaningOrphans = true
        defer { isCleaningOrphans = false }
        do {
            _ = try await client.send(path: APIEndpoint.kvmOrphansClean.path,
                                      body: KVMOrphansCleanRequest(items: items),
                                      as: [KVMOrphanItem].self)
            toastMessage = L10n.f("已清理 %ld 项", items.count)
            await scanOrphans()
            return true
        } catch {
            guard !APIError.isCancellation(error) else { return false }
            alert(L10n.f("清理失败：%@", detail(error)))
            return false
        }
    }

    /// 创建 → 返回 taskID（表单自行 push 进度页，完成后分步收栈）；失败 nil
    func create(_ request: KVMCreateRequest) async -> String? {
        await sendTask(.kvmCreate, body: request, present: false,
                       title: L10n.f("创建虚拟机 %@", request.name),
                       failure: { L10n.f("创建失败：%@", $0) })
    }

    func update(_ request: KVMUpdateRequest) async -> String? {
        await sendTask(.kvmUpdate, body: request, present: false,
                       title: L10n.f("编辑虚拟机 %@", request.name),
                       failure: { L10n.f("保存失败：%@", $0) })
    }

    @discardableResult
    func rename(_ vm: KVMVirtualMachine, to newName: String) async -> String? {
        await sendTask(.kvmRename,
                       body: KVMRenameRequest(taskID: UUID().uuidString, name: vm.displayName, newName: newName),
                       title: L10n.f("重命名虚拟机 %@", vm.displayName),
                       failure: { L10n.f("重命名失败：%@", $0) })
    }

    @discardableResult
    func convertToTemplate(_ vm: KVMVirtualMachine, templateName: String,
                           storagePool: String, description: String) async -> String? {
        await sendTask(.kvmTemplateCreate,
                       body: KVMToTemplateRequest(taskID: UUID().uuidString, name: vm.displayName,
                                                  templateName: templateName, storagePool: storagePool,
                                                  description: description),
                       title: L10n.f("转为模版 %@", templateName),
                       failure: { L10n.f("转为模版失败：%@", $0) })
    }

    @discardableResult
    func delete(_ vm: KVMVirtualMachine, force: Bool) async -> String? {
        await sendTask(.kvmDelete,
                       body: KVMDeleteRequest(taskID: UUID().uuidString, id: vm.id, force: force),
                       title: L10n.f("删除虚拟机 %@", vm.displayName),
                       failure: { L10n.f("删除失败：%@", $0) })
    }

    // MARK: 快照

    func listSnapshots(_ vm: KVMVirtualMachine) async throws -> [KVMSnapshot] {
        try await client.send(path: APIEndpoint.kvmSnapshotList.path,
                              body: KVMNameRequest(name: vm.displayName),
                              as: [KVMSnapshot].self)
    }

    @discardableResult
    func createSnapshot(_ vm: KVMVirtualMachine, snapshotName: String, description: String) async -> String? {
        await sendTask(.kvmSnapshotCreate,
                       body: KVMSnapshotCreateRequest(taskID: UUID().uuidString, name: vm.displayName,
                                                      snapshotName: snapshotName, description: description),
                       title: L10n.f("创建快照 %@", snapshotName),
                       failure: { L10n.f("创建快照失败：%@", $0) })
    }

    @discardableResult
    func recoverSnapshot(_ vm: KVMVirtualMachine, snapshotName: String) async -> String? {
        await sendTask(.kvmSnapshotRecover,
                       body: KVMSnapshotRecoverRequest(taskID: UUID().uuidString, name: vm.displayName,
                                                       snapshotName: snapshotName),
                       title: L10n.f("恢复快照 %@", snapshotName),
                       failure: { L10n.f("恢复快照失败：%@", $0) })
    }

    // MARK: 详情 / 磁盘扩容

    /// POST info {name, checkDisks}：checkDisks=true 时磁盘带 resizeBlocked 可扩容判定
    func info(_ vm: KVMVirtualMachine, checkDisks: Bool) async throws -> KVMVirtualMachine {
        try await client.send(path: APIEndpoint.kvmInfo.path,
                              body: KVMInfoRequest(name: vm.displayName, checkDisks: checkDisks),
                              as: KVMVirtualMachine.self)
    }

    /// 磁盘扩容（任务式）→ 进度页；present=true 由根页推入，
    /// 磁盘管理页传 false 自行 push（避免与根页双推）
    @discardableResult
    func resizeDisk(_ vm: KVMVirtualMachine, target: String, sizeGiB: Int, present: Bool = true) async -> String? {
        await sendTask(.kvmDiskResize,
                       body: KVMDiskResizeRequest(name: vm.displayName, target: target,
                                                  sizeGiB: sizeGiB, taskID: UUID().uuidString),
                       present: present,
                       title: L10n.f("扩容磁盘 %@", target),
                       failure: { L10n.f("扩容失败：%@", $0) })
    }

    // MARK: 监控 / 健康检查 / 控制台

    func stats(_ vm: KVMVirtualMachine) async throws -> KVMStats {
        try await client.send(path: APIEndpoint.kvmStats.path,
                              body: KVMNameRequest(name: vm.displayName), as: KVMStats.self)
    }

    func healthCheck(_ vm: KVMVirtualMachine) async throws -> KVMHealthReport {
        try await client.send(path: APIEndpoint.kvmHealthCheck.path,
                              body: KVMNameRequest(name: vm.displayName), as: KVMHealthReport.self)
    }

    func console(_ vm: KVMVirtualMachine) async throws -> KVMGraphics {
        try await client.send(path: APIEndpoint.kvmConsole.path,
                              body: KVMNameRequest(name: vm.displayName), as: KVMGraphics.self)
    }

    // MARK: 镜像

    func createISO(_ request: KVMISOCreateRequest) async -> Bool {
        let ok = await sendEmpty(.kvmISOCreate, body: request, failure: { L10n.f("创建失败：%@", $0) })
        if ok { toastMessage = L10n.t("已添加镜像"); await loadISOs() }
        return ok
    }

    func updateISO(_ request: KVMISOUpdateRequest) async -> Bool {
        let ok = await sendEmpty(.kvmISOUpdate, body: request, failure: { L10n.f("保存失败：%@", $0) })
        if ok { toastMessage = L10n.t("已保存"); await loadISOs() }
        return ok
    }

    func deleteISO(_ iso: KVMISOImage, deleteFile: Bool) async {
        let ok = await sendEmpty(.kvmISODelete, body: KVMISODeleteRequest(id: iso.id, deleteFile: deleteFile),
                                 failure: { L10n.f("删除失败：%@", $0) })
        if ok { toastMessage = L10n.f("已删除「%@」", iso.displayName); await loadISOs() }
    }

    /// 上传 / 下载登记，返回镜像记录 id
    func importStart(_ request: KVMISOImportStartRequest) async -> Int? {
        do {
            let resp: KVMIDResponse = try await client.send(
                path: APIEndpoint.kvmISOImportStart.path, body: request, as: KVMIDResponse.self)
            return resp.id
        } catch {
            guard !APIError.isCancellation(error) else { return nil }
            alert(L10n.f("创建失败：%@", detail(error)))
            return nil
        }
    }

    /// 上传 / 下载状态回写（ready / downloading + tempFileID）
    @discardableResult
    func importUpdate(_ request: KVMISOImportUpdateRequest) async -> Bool {
        await sendEmpty(.kvmISOImportUpdate, body: request, failure: { L10n.f("更新状态失败：%@", $0) })
    }

    // MARK: 模版

    @discardableResult
    func deleteTemplate(_ template: KVMTemplate, deleteDisk: Bool) async -> String? {
        await sendTask(.kvmTemplateDelete,
                       body: KVMTemplateDeleteRequest(taskID: UUID().uuidString, id: template.id, deleteDisk: deleteDisk),
                       title: L10n.f("删除模版 %@", template.displayName),
                       failure: { L10n.f("删除失败：%@", $0) })
    }

    // MARK: 网络

    /// 创建表单下拉源（GET bridges / interfaces；失败静默保留旧值，表单按空列表禁提交）
    func loadNetworkOptions() async {
        do {
            let bridgeList: [KVMBridge] = try await client.send(
                path: APIEndpoint.kvmNetworkBridges.path,
                method: APIEndpoint.kvmNetworkBridges.method, as: [KVMBridge].self)
            bridges = bridgeList
        } catch {
            guard !APIError.isCancellation(error) else { return }
        }
        do {
            let interfaceList: [KVMHostInterface] = try await client.send(
                path: APIEndpoint.kvmNetworkInterfaces.path,
                method: APIEndpoint.kvmNetworkInterfaces.method, as: [KVMHostInterface].self)
            hostInterfaces = interfaceList
        } catch {
            guard !APIError.isCancellation(error) else { return }
        }
    }

    func createNetwork(_ request: KVMNetworkCreateRequest) async -> Bool {
        let ok = await sendEmpty(.kvmNetworkCreate, body: request, failure: { L10n.f("创建失败：%@", $0) })
        if ok { toastMessage = L10n.t("已创建网络"); await loadNetworks() }
        return ok
    }

    func setNetworkActive(_ network: KVMNetwork, active: Bool) async {
        let ok = await sendEmpty(.kvmNetworkUpdate,
                                 body: KVMResourceUpdateRequest(id: network.id, status: active ? "running" : "inactive"),
                                 failure: { L10n.f("操作失败：%@", $0) })
        if ok { toastMessage = active ? L10n.t("已启动") : L10n.t("已停止"); await loadNetworks() }
    }

    func setNetworkAutoStart(_ network: KVMNetwork, on: Bool) async {
        let ok = await sendEmpty(.kvmNetworkUpdate,
                                 body: KVMResourceUpdateRequest(id: network.id, autoStart: on),
                                 failure: { L10n.f("操作失败：%@", $0) })
        if ok { toastMessage = on ? L10n.t("已开启开机自启") : L10n.t("已关闭开机自启"); await loadNetworks() }
    }

    func deleteNetwork(_ network: KVMNetwork, force: Bool) async {
        let ok = await sendEmpty(.kvmNetworkDelete, body: KVMResourceDeleteRequest(id: network.id, force: force),
                                 failure: { L10n.f("删除失败：%@", $0) })
        if ok { toastMessage = L10n.f("已删除「%@」", network.displayName); await loadNetworks() }
    }

    // MARK: 存储池

    func createStorage(_ request: KVMStorageCreateRequest) async -> Bool {
        let ok = await sendEmpty(.kvmStorageCreate, body: request, failure: { L10n.f("创建失败：%@", $0) })
        if ok { toastMessage = L10n.t("已创建存储池"); await loadStorages() }
        return ok
    }

    func setStorageActive(_ pool: KVMStoragePool, active: Bool) async {
        let ok = await sendEmpty(.kvmStorageUpdate,
                                 body: KVMResourceUpdateRequest(id: pool.id, status: active ? "running" : "inactive"),
                                 failure: { L10n.f("操作失败：%@", $0) })
        if ok { toastMessage = active ? L10n.t("已启动") : L10n.t("已停止"); await loadStorages() }
    }

    func setStorageAutoStart(_ pool: KVMStoragePool, on: Bool) async {
        let ok = await sendEmpty(.kvmStorageUpdate,
                                 body: KVMResourceUpdateRequest(id: pool.id, autoStart: on),
                                 failure: { L10n.f("操作失败：%@", $0) })
        if ok { toastMessage = on ? L10n.t("已开启开机自启") : L10n.t("已关闭开机自启"); await loadStorages() }
    }

    func deleteStorage(_ pool: KVMStoragePool, force: Bool) async {
        let ok = await sendEmpty(.kvmStorageDelete, body: KVMResourceDeleteRequest(id: pool.id, force: force),
                                 failure: { L10n.f("删除失败：%@", $0) })
        if ok { toastMessage = L10n.f("已删除「%@」", pool.displayName); await loadStorages() }
    }

    // MARK: 通用发送

    /// 即时操作：成功 true；失败以 failure(错误详情) 组弹窗文案
    private func sendEmpty<B: Encodable>(_ endpoint: APIEndpoint, body: B,
                                         failure: (String) -> String) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(path: endpoint.path, body: body, as: EmptyResponse.self)
            return true
        } catch {
            guard !APIError.isCancellation(error) else { return false }
            alert(failure(detail(error)))
            return false
        }
    }

    /// 任务式操作：成功返回 taskID（服务端未回 taskID 时为空串并直接重拉）；失败弹窗返回 nil。
    /// present=true 时置 activeTask 由根页推入进度页；表单类调用方传 false 自行 push
    private func sendTask<B: Encodable>(_ endpoint: APIEndpoint, body: B, present: Bool = true,
                                        title: String, failure: (String) -> String) async -> String? {
        do {
            let resp: KVMTaskResponse = try await client.send(path: endpoint.path, body: body, as: KVMTaskResponse.self)
            let taskID = resp.taskID ?? ""
            if taskID.isEmpty {
                toastMessage = L10n.t("已提交")
                await loadSegment()
            } else if present {
                activeTask = KVMTaskTarget(taskID: taskID, title: title)
            }
            return taskID
        } catch {
            guard !APIError.isCancellation(error) else { return nil }
            alert(failure(detail(error)))
            return nil
        }
    }

    private func detail(_ error: Error) -> String {
        (error as? APIError)?.errorDescription ?? error.localizedDescription
    }

    private func alert(_ message: String) {
        alertMessage = message
        showAlert = true
    }
}
