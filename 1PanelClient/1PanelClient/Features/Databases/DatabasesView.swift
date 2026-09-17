//
//  DatabasesView.swift
//  1PanelClient
//
//  数据库模块：MySQL / PostgreSQL / Redis
//

import SwiftUI
import Combine

// MARK: - 数据库首页 ViewModel

@MainActor
final class DatabasesViewModel: ObservableObject {
    @Published var systems: [DatabaseSystem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient.shared(for: server)
    }

    var mysqlSystems: [DatabaseSystem] { systems.filter { ["mysql","mariadb","mysql-cluster"].contains($0.type.lowercased()) } }
    var pgSystems: [DatabaseSystem] { systems.filter { ["postgresql","postgresql-cluster"].contains($0.type.lowercased()) } }
    var redisSystems: [DatabaseSystem] { systems.filter { ["redis","redis-cluster"].contains($0.type.lowercased()) } }
    var mongoSystems: [DatabaseSystem] { systems.filter { ["mongodb","mongodb-cluster"].contains($0.type.lowercased()) } }

    /// 最近一次请求失败的错误信息（仅用于全部请求失败时展示）
    private var lastError: String?

    func loadSystems() async {
        isLoading = true
        defer { isLoading = false }

        async let mysql: [DatabaseSystem]? = fetchList(types: "mysql,mariadb,mysql-cluster")
        async let pg: [DatabaseSystem]? = fetchList(types: "postgresql,postgresql-cluster")
        async let redis: [DatabaseSystem]? = fetchList(types: "redis,redis-cluster")
        async let mongo: [DatabaseSystem]? = fetchList(types: "mongodb,mongodb-cluster")

        // nil = 请求失败（与「已安装但列表为空」区分开），全部失败才算加载失败
        let results = [await mysql, await pg, await redis, await mongo]
        // 页面退出取消不是失败：不写空列表/错误态，保留原快照
        if Task.isCancelled { return }
        var all: [DatabaseSystem] = []
        var loaded = 0
        for list in results {
            if let list {
                all.append(contentsOf: list)
                loaded += 1
            }
        }
        self.systems = all
        self.errorMessage = (loaded == 0 && all.isEmpty)
            ? (lastError ?? L10n.t("数据库列表加载失败，请检查服务器连接"))
            : nil
        lastError = nil
    }

    private func fetchList(types: String) async -> [DatabaseSystem]? {
        let path = APIEndpoint.databasesDbList.path.replacingOccurrences(of: ":types", with: types)
        do {
            return try await client.send(path: path, method: "GET", as: [DatabaseSystem].self)
        } catch {
            // 页面退出取消不记为失败原因（上层按取消整体跳过写状态）
            guard !APIError.isCancellation(error) else { return nil }
            lastError = L10n.f("加载失败：%@", error.localizedDescription)
            return nil
        }
    }
}

// MARK: - 数据库首页（DB 系统列表）

/// 数据库类型分类（始终展示的 4 类，未安装时显示占位行 + 安装入口）
enum DBCategory: String, CaseIterable, Identifiable {
    case mysql, postgresql, redis, mongodb

    var id: String { rawValue }

    /// 分组标题
    var title: String {
        switch self {
        case .mysql:       return "MySQL / MariaDB"
        case .postgresql:  return "PostgreSQL"
        case .redis:       return "Redis"
        case .mongodb:     return "MongoDB"
        }
    }

    /// 安装跳转用的应用 key（对应应用商店中的应用标识）
    var appKey: String {
        switch self {
        case .mysql:       return "mysql"
        case .postgresql:  return "postgresql"
        case .redis:       return "redis"
        case .mongodb:     return "mongodb"
        }
    }

    /// db/list 请求的 types 参数（与 DatabasesViewModel.fetchList 同口径）
    var listTypes: String {
        switch self {
        case .mysql:       return "mysql,mariadb,mysql-cluster"
        case .postgresql:  return "postgresql,postgresql-cluster"
        case .redis:       return "redis,redis-cluster"
        case .mongodb:     return "mongodb,mongodb-cluster"
        }
    }

    /// 品牌图标
    var brand: Brand {
        switch self {
        case .mysql:       return .mysql
        case .postgresql:  return .postgresql
        case .redis:       return .redis
        case .mongodb:     return .mongodb
        }
    }
}

struct DatabasesView: View {
    @StateObject private var vm: DatabasesViewModel
    /// 未安装引导页目标分类（nil = 未推入）。
    /// 用 item binding 而非静态 NavigationLink：安装完成后由父页置 nil 收回，
    /// 不依赖子页 dismiss()（多层 push 收栈时 env dismiss 不可靠，会停留在引导页）
    @State private var notInstalledCategory: DBCategory?

    init(server: ServerConfig) {
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(key: ManageItem.database.storeKey(server: server)) {
            DatabasesViewModel(server: server)
        })
    }

    var body: some View {
        List {
            // 全部请求失败：显示错误态 + 重试（而不是误显示为「未安装」）
            if vm.systems.isEmpty, let msg = vm.errorMessage, !vm.isLoading {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(msg)
                } actions: {
                    Button(L10n.t("重试")) {
                        Task { await vm.loadSystems() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(DBCategory.allCases, id: \.rawValue) { category in
                    systemGroup(for: category)
                }
            }
        }
        .navigationTitle(L10n.t("数据库"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.loadSystems() }
        .task {
            // 重访（已有快照）时门控不转圈，这里静默刷新拿最新列表（5 秒内重访节流）
            await PageVMStore.shared.autoRefresh(vm: vm) {
                await vm.loadSystems()
            }
        }
        // 应用安装完成时刷新（如从「安装 XX」流程返回后，新装的数据库需重新拉取）
        .onReceive(NotificationCenter.default.publisher(for: .installCompleted)) { _ in
            Task { await vm.loadSystems() }
        }
        // 未安装引导页：binding 收回（含安装完成后由子页回调触发）
        .navigationDestination(item: $notInstalledCategory) { category in
            NotInstalledDatabaseView(category: category) {
                withAnimation { notInstalledCategory = nil }
            }
        }
        .overlay {
            if vm.isLoading && vm.systems.isEmpty {
                LoadingStateView()
            }
        }
    }

    /// 单个分类分组：有实例则列出，无实例则显示未安装占位行
    @ViewBuilder
    private func systemGroup(for category: DBCategory) -> some View {
        let items = systems(for: category)
        if items.isEmpty {
            // 未安装：占位行（推入方式见 notInstalledCategory 注释）
            Section(category.title) {
                Button {
                    notInstalledCategory = category
                } label: {
                    NotInstalledDatabaseRow(category: category)
                }
            }
        } else {
            // 已安装：列出实例
            Section(category.title) {
                ForEach(items) { sys in
                    NavigationLink {
                        DatabaseSystemView(system: sys)
                    } label: {
                        DatabaseSystemRow(system: sys)
                    }
                }
            }
        }
    }

    /// 取某分类下已安装的数据库实例
    private func systems(for category: DBCategory) -> [DatabaseSystem] {
        switch category {
        case .mysql:       return vm.mysqlSystems
        case .postgresql:  return vm.pgSystems
        case .redis:       return vm.redisSystems
        case .mongodb:     return vm.mongoSystems
        }
    }
}

// MARK: - 未安装占位行

/// 未安装数据库的占位行：灰色品牌图标 + 名称 + 「未安装」标签
/// （行已改为 Button 推入，补 chevron 保持 NavigationLink 的可点视觉提示）
struct NotInstalledDatabaseRow: View {
    let category: DBCategory

    var body: some View {
        HStack(spacing: 14) {
            BrandIcon(brand: category.brand, size: 44)
                .opacity(0.4)   // 未安装：图标变淡
            VStack(alignment: .leading, spacing: 3) {
                Text(category.title).font(.headline).foregroundStyle(.secondary)
                Text(L10n.t("未安装"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - 未安装数据库详情页（提示 + 安装按钮）

/// 未安装数据库的详情页：提示未安装并提供跳转应用商店安装的入口
struct NotInstalledDatabaseView: View {
    let category: DBCategory
    /// 安装完成/检测到已安装时收回本页（父页置 nil binding，比 env dismiss 可靠）
    var onInstallCompleted: () -> Void = {}

    /// 应用商店 ViewModel（详情页 + 安装表单共用）
    @StateObject private var storeVM: AppStoreViewModel = {
        let server = ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        return AppStoreViewModel(server: server)
    }()
    /// 是否已进入安装表单（用于区分「自己的安装完成」与无关的全局 installCompleted 通知）
    @State private var didEnterInstall = false

    private let client: APIClient

    init(category: DBCategory, onInstallCompleted: @escaping () -> Void = {}) {
        self.category = category
        self.onInstallCompleted = onInstallCompleted
        self.client = APIClient.shared(for: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            BrandIcon(brand: category.brand, size: 72)
                .opacity(0.5)

            VStack(spacing: 8) {
                Text(L10n.f("%@未安装", category.title))
                    .font(.headline)
                Text(L10n.f("请先安装 %@ 后再使用此功能", category.title))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // 用 NavigationLink 直接 push 应用详情页（避免 isPresented 时序问题）
            NavigationLink {
                AppStoreDetailView(appKey: category.appKey, vm: storeVM)
            } label: {
                Label(L10n.f("安装 %@", category.title), systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)

            Spacer()
        }
        .padding()
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        // 安装表单的 push 由 AppStoreDetailView 上的同名 destination 统一处理
        //（点「安装」时的栈顶页，注册页=触发页）。此前本页也挂了一份注册，
        // 数据库入口的栈内出现两层同名 isPresented 注册竞争同一次 push，
        // 偶发表现为点了安装被弹回/无反应，多试几次才进
        // 跟踪是否进入过安装表单（showInstall true→false 表示用户开始了安装流程）
        .onChange(of: storeVM.showInstall) { _, isShown in
            if isShown { didEnterInstall = true }
        }
        // 安装完成通知：仅当确实进入了本页发起的安装流程时才收回本页，
        // 避免无关的全局 installCompleted 通知误触发（表现为点击安装变返回）；
        // 收回走父页 binding（onInstallCompleted），不依赖 env dismiss()。
        // 安装表单由 AppInstallView 自行收栈（0.35s 延迟 + pop 转场），
        // 本页须等其彻底结束再收，否则两级 pop 动画竞争、后者被丢弃，
        // 表现为安装完成后停在应用详情页少返回一层
        .onReceive(NotificationCenter.default.publisher(for: .installCompleted)) { _ in
            guard didEnterInstall else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                onInstallCompleted()
            }
        }
        // 兜底：回到本页时重查安装状态，已安装则收回本页（列表页已按通知刷新）。
        // 覆盖「后台运行」等通知链路未覆盖的返回路径
        .onAppear {
            Task { await dismissIfInstalled() }
        }
    }

    /// 重查该分类是否已有实例：有则收回本页（列表数据由 installCompleted 通知刷新）
    private func dismissIfInstalled() async {
        // 安装表单仍在展示时不查（后台运行中途返回的场景查了也是未完成态）
        guard !storeVM.showInstall else { return }
        guard let list: [DatabaseSystem] = try? await client.send(
            path: APIEndpoint.databasesDbList.path.replacingOccurrences(of: ":types", with: category.listTypes),
            method: "GET",
            as: [DatabaseSystem].self) else { return }
        if !list.isEmpty {
            onInstallCompleted()
        }
    }
}

struct DatabaseSystemRow: View {
    let system: DatabaseSystem

    var body: some View {
        HStack(spacing: 14) {
            // 优先显示内置品牌图标，未知类型回退到 SF Symbol
            if let brand = Brand.from(dbType: system.type) {
                BrandIcon(brand: brand, size: 44)
            } else {
                IconBadge(
                    systemName: system.systemIcon,
                    color: Color.fromDBString(system.systemColor)
                )
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(system.displayName).font(.headline)
                if let v = system.version, !v.isEmpty {
                    Text("v\(v)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 单个数据库系统详情 ViewModel

@MainActor
final class DatabaseSystemViewModel: ObservableObject {
    @Published var check: AppInstallCheck?
    @Published var connInfo: ConnInfo?
    @Published var remoteAccess: Bool = false
    @Published var databases: [DatabaseItem] = []
    @Published var users: [DatabaseUser] = []
    @Published var grants: [DatabaseGrant] = []
    @Published var isLoading = false
    @Published var isOperating = false
    @Published var errorMessage: String?
    /// 数据库列表分页（C5）：首屏 200/页 + 滚动到底自动追加
    @Published private(set) var dbTotal = 0
    @Published private(set) var isLoadingMore = false
    private var dbPage = 1
    /// 列表代数：loadDatabases() 替换列表时递增，追加页响应到达时与捕获值
    /// 比对，期间发生过任何重载即丢弃过期追加。用代数而非页码比对：页码
    /// 归 1 后 next==2==page+1 恒成立，首次翻页恰是页码判定的盲区
    private var dbGeneration = 0
    private static let pageSize = 200

    let system: DatabaseSystem
    private let client: APIClient

    /// 是否为支持数据库列表的类型（MySQL/PostgreSQL）
    var supportsDatabaseList: Bool {
        let t = system.type.lowercased()
        return t != "redis" && t != "redis-cluster"
    }

    /// 是否支持远程访问开关（仅 MySQL/MariaDB）
    var supportsRemoteAccess: Bool {
        let t = system.type.lowercased()
        return t == "mysql" || t == "mariadb" || t == "mysql-cluster"
    }

    /// 是否支持用户管理（仅 MySQL/MariaDB）
    var supportsUserManagement: Bool {
        let t = system.type.lowercased()
        return t == "mysql" || t == "mariadb" || t == "mysql-cluster"
    }

    var isPostgreSQL: Bool {
        system.type.lowercased().contains("postgresql")
    }

    var isMongoDB: Bool {
        system.type.lowercased().contains("mongodb")
    }

    var isRedis: Bool {
        let t = system.type.lowercased()
        return t == "redis" || t == "redis-cluster"
    }

    var searchPath: String {
        let t = system.type.lowercased()
        if t.contains("postgresql") { return APIEndpoint.databasesPgSearch.path }
        if t.contains("mongodb") { return APIEndpoint.databasesMongoSearch.path }
        return APIEndpoint.databasesSearch.path
    }

    /// MongoDB 终端初始命令：进入容器后自动执行 mongosh 连接数据库
    /// （容器内 shell 不连库；连接参数取自应用连接信息）
    var mongoInitialCommand: String? {
        guard isMongoDB,
              let ci = connInfo,
              let user = ci.username, !user.isEmpty,
              let pwd = ci.password, !pwd.isEmpty
        else { return nil }
        let port = ci.port ?? 27017
        return "mongosh \"mongodb://127.0.0.1:\(port)/admin?authSource=admin\" --username '\(user)' --password '\(pwd)'\r\n"
    }

    init(system: DatabaseSystem, server: ServerConfig) {
        self.system = system
        self.client = APIClient.shared(for: server)
    }

    /// 容器是否运行中：check 未就绪（加载中/查询失败）时按运行处理，
    /// 避免进页闪空态；确认停止后据此跳过容器内请求并收敛页面
    var isContainerRunning: Bool {
        check?.isRunning ?? true
    }

    func refresh() async {
        // 与 FirewallViewModel 一致：进页 .task 与下拉并发时只跑一轮
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        // check 走应用安装层、不依赖容器运行，先行判定状态；容器已停止时
        // 连接信息/远程开关/库表/用户这些容器内接口必然 500
        //（daemon: container not running），跳过待启动成功后由 operate 补拉
        await loadCheck()
        guard check?.isRunning == true else { return }
        // 全并行、各一次：此前 async let 与直接 await 混用，每个请求都实际发出两遍。
        // remote 仅 MySQL 系需要（远程访问开关）；其余类型服务端在其容器内
        // exec 对应可执行文件（MongoDB 镜像无 mongodb 命令）会 500，不发
        async let connInfo: () = loadConnInfo()
        async let remote: () = supportsRemoteAccess ? loadRemote() : ()
        async let dbs: () = supportsDatabaseList ? loadDatabases() : ()
        async let users: () = supportsUserManagement ? loadUsers() : ()
        _ = await (connInfo, remote, dbs, users)
    }

    func loadCheck() async {
        let req = AppCheckRequest(key: system.database, name: system.database)
        do {
            check = try await client.send(path: APIEndpoint.appsInstalledCheck.path, body: req, as: AppInstallCheck.self)
        } catch {
            // 页面退出取消不是失败：不写错误态（与常驻 VM 同一纪律）
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadConnInfo() async {
        let req = ConnInfoRequest(type: system.type, name: system.database)
        do {
            connInfo = try await client.send(path: APIEndpoint.appsInstalledConnInfo.path, body: req, as: ConnInfo.self)
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadRemote() async {
        let req = ConnInfoRequest(type: system.type, name: system.database)
        do {
            let resp: Bool = try await client.send(path: APIEndpoint.databasesRemote.path, body: req, as: Bool.self)
            remoteAccess = resp
        } catch {
            // 辅助数据静默降级：仅影响开关回显，不阻塞页面、不打错误提示
            guard !APIError.isCancellation(error) else { return }
        }
    }

    func loadDatabases() async {
        let req = DBSearchRequest(page: 1, pageSize: Self.pageSize, database: system.database, orderBy: "createdAt", order: "null")
        do {
            let resp: PageResponse<DatabaseItem> = try await client.send(path: searchPath, body: req, as: PageResponse<DatabaseItem>.self)
            databases = resp.items ?? []
            dbTotal = resp.total ?? resp.items?.count ?? 0
            dbPage = 1
            dbGeneration += 1
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// 追加下一页数据库（滚动到底触发；按 id 去重防跨页重复）
    func loadMoreDatabases() async {
        guard databases.count < dbTotal, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let next = dbPage + 1
        let gen = dbGeneration
        let req = DBSearchRequest(page: next, pageSize: Self.pageSize, database: system.database, orderBy: "createdAt", order: "null")
        do {
            let resp: PageResponse<DatabaseItem> = try await client.send(path: searchPath, body: req, as: PageResponse<DatabaseItem>.self)
            // 期间列表已被重载（下拉/建库删库触发新代数）：丢弃过期追加
            guard gen == dbGeneration else { return }
            let existing = Set(databases.map(\.id))
            let newItems = (resp.items ?? []).filter { !existing.contains($0.id) }
            if newItems.isEmpty {
                // 翻页间隙服务器侧数据变动，去重后零新增：total 收敛为已加载量
                dbTotal = databases.count
                return
            }
            databases += newItems
            dbTotal = resp.total ?? dbTotal
            dbPage = next
        } catch {
            // 追加失败不打断列表，下拉刷新可重试
        }
    }

    func operate(_ op: String) async {
        guard let installId = check?.appInstallId else { return }
        isOperating = true
        defer { isOperating = false }
        let req = AppOpRequest(installId: installId, operate: op)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.appsInstalledOperate.path, body: req, as: EmptyResponse.self)
            // 启动/重启后补拉容器内数据（refresh 内部会先重查运行状态）；
            // 停止后 refresh 只重查状态、不再请求容器内接口
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func toggleRemote(_ on: Bool) async {
        let value = on ? "%" : "localhost"
        let req = ChangeAccessRequest(id: 0, from: "local", type: system.type, database: system.database, value: value)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.databasesChangeAccess.path, body: req, as: EmptyResponse.self)
            await loadRemote()
        } catch {
            errorMessage = error.localizedDescription
            await loadRemote()
        }
    }

    func changeServicePassword(_ password: String) async {
        let value = Data(password.utf8).base64EncodedString()
        let req = ChangePasswordRequest(id: 0, from: "local", type: system.type, database: system.database, value: value)
        let path: String
        if isPostgreSQL {
            path = APIEndpoint.databasesPgPassword.path
        } else if isMongoDB {
            // MongoDB root 密码：POST /databases/mongodb/root/password
            path = APIEndpoint.databasesMongoRootPassword.path
        } else {
            path = APIEndpoint.databasesChangePassword.path
        }
        do {
            let _: EmptyResponse = try await client.send(path: path, body: req, as: EmptyResponse.self)
            await loadConnInfo()
        } catch { errorMessage = error.localizedDescription }
    }

    func changeRedisPassword(_ password: String) async -> Bool {
        let value = Data(password.utf8).base64EncodedString()
        let req = RedisPasswordRequest(database: system.database, value: value)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.databasesRedisPassword.path, body: req, as: EmptyResponse.self)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteDatabase(_ db: DatabaseItem) async {
        let dbType = db.type ?? system.type
        let checkReq = DelCheckRequest(id: db.id, type: dbType, database: system.database)
        let delReq = DelDBRequest(id: db.id, type: dbType, database: system.database, deleteBackup: false, forceDelete: false)
        let checkPath: String
        let delPath: String
        if isPostgreSQL {
            checkPath = APIEndpoint.databasesPgDelCheck.path
            delPath = APIEndpoint.databasesPgDel.path
        } else if isMongoDB {
            checkPath = APIEndpoint.databasesMongoDelCheck.path
            delPath = APIEndpoint.databasesMongoDel.path
        } else {
            checkPath = APIEndpoint.databasesDelCheck.path
            delPath = APIEndpoint.databasesDel.path
        }
        do {
            let _: EmptyResponse = try await client.send(path: checkPath, body: checkReq, as: EmptyResponse.self)
            let _: EmptyResponse = try await client.send(path: delPath, body: delReq, as: EmptyResponse.self)
            databases.removeAll { $0.id == db.id }
            await loadDatabases()
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - MySQL 用户管理

    func loadUsers() async {
        let req = DBUsersRequest(database: system.database)
        do {
            let resp: [DatabaseUser] = try await client.send(
                path: APIEndpoint.databasesUsersSearch.path, body: req, as: [DatabaseUser].self
            )
            users = resp.filter { !($0.isDelete ?? false) }
            await loadGrants()
        } catch {
            // 页面退出取消不是失败：不写错误态
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func loadGrants() async {
        let req = DBUsersRequest(database: system.database)
        do {
            grants = try await client.send(
                path: APIEndpoint.databasesGrantsSearch.path, body: req, as: [DatabaseGrant].self
            )
        } catch { grants = [] }
    }

    func databasesForUser(_ user: DatabaseUser) -> [String] {
        grants
            .filter { $0.username == user.username && $0.host == user.host }
            .compactMap { $0.database }
    }

    func createUser(
        username: String, host: String, password: String,
        description: String, databases: [String]
    ) async -> Bool {
        isOperating = true
        defer { isOperating = false }
        let pwdBase64 = Data(password.utf8).base64EncodedString()
        let req = CreateDBUserRequest(
            database: system.database, username: username,
            host: host, password: pwdBase64,
            description: description, dbs: databases
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.databasesUsersCreate.path, body: req, as: EmptyResponse.self
            )
            await loadUsers()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteUser(_ user: DatabaseUser) async {
        guard let username = user.username, let host = user.host else { return }
        isOperating = true
        defer { isOperating = false }
        let req = DeleteDBUserRequest(database: system.database, username: username, host: host)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.databasesUsersDelete.path, body: req, as: EmptyResponse.self
            )
            users.removeAll { $0.id == user.id }
            grants.removeAll { $0.username == username && $0.host == host }
            await loadUsers()
        } catch { errorMessage = error.localizedDescription }
    }
}

// MARK: - 单个数据库系统详情视图

struct DatabaseSystemView: View {
    @StateObject private var vm: DatabaseSystemViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showCreate = false
    @State private var showConnInfo = false
    @State private var showRedisTerminal = false
    @State private var showDatabaseTerminal = false
    /// MySQL/MariaDB 状态（databases/status）
    @State private var showMySQLStatus = false
    /// MySQL/MariaDB 参数（databases/variables）
    @State private var showMySQLVariables = false
    /// MySQL/MariaDB 性能调整（优化方案预设）
    @State private var showMySQLPerformance = false
    /// MySQL/MariaDB 配置修改（my.cnf）
    @State private var showMySQLConf = false
    /// Redis 状态（databases/redis/status）
    @State private var showRedisStatus = false
    /// Redis 性能调整（timeout/maxclients/maxmemory）
    @State private var showRedisPerformance = false
    @State private var showContainerTerminal = false
    @State private var pendingAction: String?
    @State private var pendingDeleteDb: DatabaseItem?
    @State private var isStatusExpanded = false
    @State private var showCreateUser = false
    @State private var pendingDeleteUser: DatabaseUser?
    @State private var searchText = ""
    @State private var isSearching = false

    /// 库/用户列表按名称过滤（搜索态）
    private var filteredDatabases: [DatabaseItem] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return vm.databases }
        return vm.databases.filter { ($0.name ?? "").localizedCaseInsensitiveContains(q) }
    }

    private var filteredUsers: [DatabaseUser] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return vm.users }
        return vm.users.filter { ($0.username ?? "").localizedCaseInsensitiveContains(q) }
    }

    init(system: DatabaseSystem) {
        _vm = StateObject(wrappedValue: DatabaseSystemViewModel(system: system, server: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")))
    }

    var body: some View {
        List {
            statusSection
            // 容器已停止：库表/用户等容器内数据不可用（也不再请求），
            // 仅保留状态卡与启动入口，避免空态误导
            if vm.isContainerRunning {
                if vm.supportsDatabaseList {
                    databaseListSection
                }
                if vm.supportsUserManagement {
                    userListSection
                }
            }
        }
        .searchIconMode(text: $searchText, isSearching: $isSearching, title: vm.system.displayName, prompt: L10n.t("搜索数据库 / 用户"))
        // 右上角加号（菜单）：与其他列表页 toolbar 创建范式一致，按系统能力显示可用项；
        // 无可创建项（Redis 两类均不支持）或容器停止时不显示空 + 号
        .toolbar {
            if !isSearching && vm.isContainerRunning
                && (vm.supportsDatabaseList || vm.supportsUserManagement) {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if vm.supportsDatabaseList {
                            Button {
                                showCreate = true
                            } label: {
                                Label(L10n.t("创建数据库"), systemImage: "cylinder")
                            }
                        }
                        if vm.supportsUserManagement {
                            Button {
                                showCreateUser = true
                            } label: {
                                Label(L10n.t("创建用户"), systemImage: "person.badge.plus")
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L10n.t("创建"))
                }
            }
        }
        .refreshable { await vm.refresh() }
        .task { await vm.refresh() }
        .navigationDestination(isPresented: $showCreate) {
            CreateDatabaseView(system: vm.system) { await vm.loadDatabases() }
        }
        .navigationDestination(isPresented: $showCreateUser) {
            CreateDatabaseUserView(system: vm.system, availableDatabases: vm.databases.map { $0.name ?? "" }.filter { !$0.isEmpty }) {
                await vm.loadUsers()
            }
        }
        .navigationDestination(isPresented: $showConnInfo) {
            DatabaseConnInfoView(vm: vm)
        }
        .navigationDestination(isPresented: $showMySQLStatus) {
            DatabaseMySQLStatusView(system: vm.system)
        }
        .navigationDestination(isPresented: $showMySQLVariables) {
            DatabaseMySQLVariablesView(system: vm.system)
        }
        .navigationDestination(isPresented: $showMySQLPerformance) {
            DatabaseMySQLPerformanceView(system: vm.system)
        }
        .navigationDestination(isPresented: $showMySQLConf) {
            DatabaseMySQLConfView(system: vm.system)
        }
        .navigationDestination(isPresented: $showRedisStatus) {
            DatabaseRedisStatusView(system: vm.system)
        }
        .navigationDestination(isPresented: $showRedisPerformance) {
            DatabaseRedisPerformanceView(system: vm.system)
        }
        .navigationDestination(isPresented: $showRedisTerminal) {
            TerminalScreen(
                server: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""),
                target: .redis(name: vm.system.database, cols: 80, rows: 24)
            )
        }
        .navigationDestination(isPresented: $showDatabaseTerminal) {
            TerminalScreen(
                server: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""),
                target: .database(
                    databaseType: vm.system.type,
                    database: vm.system.database,
                    cols: 80, rows: 24
                )
            )
        }
        // MongoDB 无数据库专用终端，进入其容器执行 /bin/sh，
        // 连接就绪后自动下发 mongosh（与网页端行为一致）
        .navigationDestination(isPresented: $showContainerTerminal) {
            if let container = vm.check?.containerName {
                TerminalScreen(
                    server: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""),
                    target: .container(containerID: container, user: "", command: "/bin/sh", cols: 80, rows: 24),
                    initialCommand: vm.mongoInitialCommand
                )
            }
        }
        .alert(
            pendingAction.map { dbActionDisplayName($0) } ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            )
        ) {
            Button(L10n.t("取消"), role: .cancel) { pendingAction = nil }
            Button(L10n.t("确认"), role: .destructive) {
                Haptic.warning()
                let op = pendingAction
                pendingAction = nil
                if let op { Task { await vm.operate(op) } }
            }
        } message: {
            if let action = pendingAction {
                Text(L10n.f("将对 %@ 进行 %@ 操作，是否继续？", vm.system.displayName, dbActionDisplayName(action)))
            }
        }
        .sheet(item: $pendingDeleteDb) { db in
            TextInputConfirmSheet(
                title: L10n.t("删除数据库"),
                message: L10n.f("此操作不可恢复。请输入数据库名称「%@」以确认删除。", db.name ?? ""),
                expectedText: db.name ?? "",
                fieldLabel: L10n.t("确认名称"),
                fieldPlaceholder: L10n.t("数据库名称")
            ) {
                Task { await vm.deleteDatabase(db) }
            }
        }
        .sheet(item: $pendingDeleteUser) { user in
            TextInputConfirmSheet(
                title: L10n.t("删除用户"),
                message: L10n.f("此操作不可恢复。请输入用户名「%@」以确认删除。", user.username ?? ""),
                expectedText: user.username ?? "",
                fieldLabel: L10n.t("确认用户名"),
                fieldPlaceholder: L10n.t("用户名")
            ) {
                Task { await vm.deleteUser(user) }
            }
        }
    }

    private func dbActionDisplayName(_ action: String) -> String {
        switch action {
        case "stop":    return L10n.t("停止")
        case "start":   return L10n.t("启动")
        case "restart": return L10n.t("重启")
        default:        return action
        }
    }

    // MARK: 状态卡片（可折叠面板）

    @ViewBuilder
    private var statusSection: some View {
        if let check = vm.check {
            ServiceStatusCard(
                title: check.app ?? vm.system.displayName,
                subtitle: check.version.flatMap { $0.isEmpty ? nil : "v\($0)" },
                statusText: check.isRunning ? L10n.t("运行中") : L10n.t("已停止"),
                statusColor: check.isRunning ? .statusRunning : .statusStopped,
                isOperating: vm.isOperating,
                isExpanded: $isStatusExpanded,
                actions: drawerActions(check)
            ) {
                EmptyView()
            }
        } else {
            Section {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
    }

    /// 抽屉操作：启停/重启/终端 + 连接信息（创建数据库/用户入口在右上角加号菜单）；
    /// MySQL/MariaDB 追加「状态 / 参数 / 性能调整 / 配置修改」四入口
    private func drawerActions(_ check: AppInstallCheck) -> [ServiceAction] {
        var actions: [ServiceAction] = [
            ServiceAction(
                title: check.isRunning ? L10n.t("停止") : L10n.t("启动"),
                icon: check.isRunning ? "stop.fill" : "play.fill",
                color: check.isRunning ? .orange : .green
            ) { pendingAction = check.isRunning ? "stop" : "start" },
            ServiceAction(title: L10n.t("重启"), icon: "arrow.triangle.2.circlepath", color: .blue) {
                pendingAction = "restart"
            },
            ServiceAction(
                title: L10n.t("终端"),
                icon: "terminal",
                color: .teal,
                isDisabled: vm.isMongoDB && (check.containerName?.isEmpty ?? true)
            ) {
                if vm.isRedis {
                    showRedisTerminal = true
                } else if vm.isMongoDB {
                    showContainerTerminal = true
                } else {
                    showDatabaseTerminal = true
                }
            },
            ServiceAction(title: L10n.t("连接信息"), icon: "link", color: .cyan) {
                showConnInfo = true
            },
        ]
        if ["mysql", "mariadb"].contains(vm.system.type.lowercased()) {
            actions.append(ServiceAction(title: L10n.t("状态"), icon: "speedometer", color: .purple) {
                showMySQLStatus = true
            })
            actions.append(ServiceAction(title: L10n.t("参数"), icon: "slider.horizontal.3", color: .indigo) {
                showMySQLVariables = true
            })
            actions.append(ServiceAction(title: L10n.t("性能调整"), icon: "wand.and.stars", color: .mint) {
                showMySQLPerformance = true
            })
            actions.append(ServiceAction(title: L10n.t("配置修改"), icon: "doc.plaintext", color: .brown) {
                showMySQLConf = true
            })
        }
        if vm.system.type.lowercased() == "redis" {
            actions.append(ServiceAction(title: L10n.t("状态"), icon: "speedometer", color: .purple) {
                showRedisStatus = true
            })
            actions.append(ServiceAction(title: L10n.t("性能调整"), icon: "wand.and.stars", color: .mint) {
                showRedisPerformance = true
            })
        }
        return actions
    }

    // MARK: 数据库列表

    private var databaseListSection: some View {
        Section {
            ForEach(filteredDatabases, id: \.id) { db in
                NavigationLink {
                    DatabaseDetailView(database: db, system: vm.system) { await vm.loadDatabases() }
                } label: {
                    DatabaseItemRow(db: db)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDeleteDb = db
                    } label: { Label(L10n.t("删除"), systemImage: "trash") }
                }
                .onAppear {
                    // 触底判定用未过滤列表的末行：过滤后末行可能不可见，
                    // 挂底部的加载行兜底触发；过滤空时若还有未加载页，
                    // 加载行仍渲染、翻页不会被空态卡停
                    if db.id == vm.databases.last?.id {
                        Task { await vm.loadMoreDatabases() }
                    }
                }
            }
            if filteredDatabases.isEmpty {
                ContentUnavailableView {
                    Label(
                        searchText.trimmingCharacters(in: .whitespaces).isEmpty
                            ? L10n.t("暂无数据库") : L10n.t("无匹配的数据库"),
                        systemImage: "tray"
                    )
                }
                .frame(maxWidth: .infinity)
            }
            if vm.databases.count < vm.dbTotal || vm.isLoadingMore {
                LoadingStateView(compact: true)
                .onAppear { Task { await vm.loadMoreDatabases() } }
            }
        } header: {
            // 与防火墙段头同口径：显示总数（max 兜底翻页间隙的瞬时不一致）
            SectionLabel(
                title: L10n.f("数据库（%ld）", max(vm.dbTotal, vm.databases.count)),
                systemImage: "cylinder"
            )
        }
    }

    // MARK: 用户列表（MySQL）

    private var userListSection: some View {
        Section {
            ForEach(filteredUsers, id: \.id) { user in
                NavigationLink {
                    DatabaseUserDetailView(user: user, system: vm.system, availableDatabases: vm.databases.map { $0.name ?? "" }.filter { !$0.isEmpty }) {
                        await vm.loadUsers()
                    }
                } label: {
                    DatabaseUserRow(user: user, grants: vm.databasesForUser(user))
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDeleteUser = user
                    } label: { Label(L10n.t("删除"), systemImage: "trash") }
                }
            }
            if filteredUsers.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("暂无用户"), systemImage: "tray")
                }
                .frame(maxWidth: .infinity)
            }
        } header: {
            SectionLabel(title: L10n.f("用户（%ld）", filteredUsers.count), systemImage: "person.2")
        }
    }
}

// MARK: - 连接信息页（由详情页抽屉「连接信息」进入）

struct DatabaseConnInfoView: View {
    @ObservedObject var vm: DatabaseSystemViewModel
    @State private var showServicePasswordSheet = false
    @State private var showRedisPasswordSheet = false

    var body: some View {
        List {
            Section {
                if let ci = vm.connInfo {
                    CopyableInfoRow(key: L10n.t("容器地址"), value: ci.containerName ?? vm.system.address ?? "-", monospaced: true)
                    if let port = ci.port { CopyableInfoRow(key: L10n.t("端口"), value: "\(port)", monospaced: true) }
                    CopyableInfoRow(key: L10n.t("外部地址"), value: "127.0.0.1", monospaced: true)
                    if let user = ci.username, !user.isEmpty {
                        InfoRow(key: L10n.t("用户名"), value: user)
                    }

                    if vm.supportsRemoteAccess {
                        Toggle(isOn: Binding(
                            get: { vm.remoteAccess },
                            set: { on in Task { await vm.toggleRemote(on) } }
                        )) {
                            Label(L10n.t("远程访问"), systemImage: "network")
                        }
                        .disabled(vm.isOperating)
                    }

                    if let pwd = ci.password, !pwd.isEmpty {
                        PasswordRow(password: pwd)
                        Button {
                            if vm.isRedis {
                                showRedisPasswordSheet = true
                            } else {
                                showServicePasswordSheet = true
                            }
                        } label: {
                            Label(L10n.t("修改密码"), systemImage: "key")
                        }
                    }
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            } header: {
                SectionLabel(title: L10n.t("连接信息"), systemImage: "link")
            }
        }
        .navigationTitle(L10n.t("连接信息"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            async let conn: () = vm.loadConnInfo()
            async let remote: () = vm.loadRemote()
            _ = await (conn, remote)
        }
        .sheet(isPresented: $showServicePasswordSheet) {
            ChangePasswordSheet(
                title: L10n.f("修改 %@ 密码", vm.system.displayName),
                currentPassword: vm.connInfo?.password
            ) { newPassword in
                Task { await vm.changeServicePassword(newPassword) }
            }
        }
        .sheet(isPresented: $showRedisPasswordSheet) {
            RedisPasswordSheet(
                currentPassword: vm.connInfo?.password
            ) { newPassword in
                Task {
                    let ok = await vm.changeRedisPassword(newPassword)
                    if ok {
                        await vm.operate("restart")
                        await vm.loadConnInfo()
                    }
                }
            }
        }
    }
}

// MARK: - 数据库用户行

struct DatabaseUserRow: View {
    let user: DatabaseUser
    let grants: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(user.displayName)
                    .font(.dataMonospacedBody.bold())
                if let host = user.host, host == "%" {
                    StatusBadge(text: L10n.t("远程"), color: .blue, icon: "network")
                } else {
                    StatusBadge(text: L10n.t("本机"), color: .orange, icon: "lock.shield")
                }
            }

            if let pwd = user.password, !pwd.isEmpty {
                PasswordRow(password: pwd, compact: true)
            }

            if !grants.isEmpty {
                HStack(spacing: 4) {
                    Text(L10n.t("数据库:")).font(.caption).foregroundStyle(.secondary)
                    Text(grants.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if let desc = user.description, !desc.isEmpty {
                Text(desc).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 数据库行

struct DatabaseItemRow: View {
    let db: DatabaseItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(db.name ?? "-")
                    .font(.dataMonospacedBody.bold())
                // MongoDB 无 permission 字段，不显示本机/远程徽标
                if !db.isMongoDB {
                    if let perm = db.permission, perm == "%" || perm.isEmpty {
                        StatusBadge(text: L10n.t("远程"), color: .blue, icon: "network")
                    } else {
                        StatusBadge(text: L10n.t("本机"), color: .orange, icon: "lock.shield")
                    }
                }
            }
            if let desc = db.description, !desc.isEmpty {
                Text(desc).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 8) {
                if let u = db.username, !u.isEmpty {
                    Text(L10n.f("用户: %@", u)).font(.caption).foregroundStyle(.secondary)
                }
                if let f = db.format, !f.isEmpty {
                    Text(f).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 修改密码 Sheet

struct ChangePasswordSheet: View {
    let title: String
    let currentPassword: String?
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newPassword = ""
    @State private var showCurrent = false
    @State private var showNew = false

    var body: some View {
        NavigationStack {
            Form {
                if let cur = currentPassword, !cur.isEmpty {
                    Section(L10n.t("当前密码")) {
                        HStack {
                            Text(showCurrent ? cur : String(repeating: "•", count: min(cur.count, 12)))
                                .font(.dataMonospacedBody)
                            Spacer()
                            Button { showCurrent.toggle() } label: {
                                Image(systemName: showCurrent ? "eye.slash" : "eye")
                            }.accessibilityLabel(showCurrent ? L10n.t("隐藏密码") : L10n.t("显示密码"))
                            Button { UIPasteboard.general.string = cur } label: {
                                Image(systemName: "doc.on.doc")
                            }.accessibilityLabel(L10n.t("复制密码"))
                        }
                    }
                }
                Section(L10n.t("新密码")) {
                    HStack {
                        Group {
                            if showNew {
                                TextField(L10n.t("输入或生成新密码"), text: $newPassword)
                            } else {
                                SecureField(L10n.t("输入或生成新密码"), text: $newPassword)
                            }
                        }
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.dataMonospacedBody)

                        Button { showNew.toggle() } label: {
                            Image(systemName: showNew ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }.accessibilityLabel(showNew ? L10n.t("隐藏密码") : L10n.t("显示密码"))
                    }
                    Button {
                        newPassword = randomPassword()
                        showNew = true
                    } label: {
                        Label(L10n.t("生成随机密码"), systemImage: "shuffle")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("保存")) {
                        onConfirm(newPassword)
                        dismiss()
                    }
                    .disabled(newPassword.isEmpty)
                }
            }
        }
    }

    private func randomPassword() -> String {
        let chars = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<16).map { _ in chars.randomElement()! })
    }
}

// MARK: - Redis 密码修改 Sheet（两步：输入密码 → 确认重启）

struct RedisPasswordSheet: View {
    let currentPassword: String?
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newPassword = ""
    @State private var showCurrent = false
    @State private var step: Step = .input
    @State private var restartConfirm = ""

    enum Step { case input, confirm }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .input: inputStep
                case .confirm: confirmStep
                }
            }
            .navigationTitle(L10n.t("修改 Redis 密码"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if step == .input {
                        Button(L10n.t("下一步")) {
                            step = .confirm
                        }
                        .disabled(newPassword.isEmpty)
                    } else {
                        Button(L10n.t("立即重启"), role: .destructive) {
                            Haptic.warning()
                            onConfirm(newPassword)
                            dismiss()
                        }
                        .disabled(restartConfirm != L10n.t("立即重启"))
                    }
                }
            }
        }
    }

    private var inputStep: some View {
        Form {
            if let cur = currentPassword, !cur.isEmpty {
                Section(L10n.t("当前密码")) {
                    HStack {
                        Text(showCurrent ? cur : String(repeating: "•", count: min(cur.count, 12)))
                            .font(.dataMonospacedBody)
                        Spacer()
                        Button { showCurrent.toggle() } label: {
                            Image(systemName: showCurrent ? "eye.slash" : "eye")
                        }.accessibilityLabel(showCurrent ? L10n.t("隐藏密码") : L10n.t("显示密码"))
                        Button { UIPasteboard.general.string = cur } label: {
                            Image(systemName: "doc.on.doc")
                        }.accessibilityLabel(L10n.t("复制密码"))
                    }
                }
            }
            Section(L10n.t("新密码")) {
                TextField(L10n.t("输入或生成新密码"), text: $newPassword)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.dataMonospacedBody)
                Button {
                    newPassword = randomPassword()
                } label: {
                    Label(L10n.t("生成随机密码"), systemImage: "shuffle")
                }
            }
        }
    }

    private var confirmStep: some View {
        Form {
            Section {
                Label(L10n.t("修改密码后需要重启 Redis 才能生效"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(L10n.t("请输入「立即重启」以确认操作。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section(L10n.t("确认重启")) {
                FormTextField(label: L10n.t("请输入「立即重启」"), text: $restartConfirm)
            }
        }
    }

    private func randomPassword() -> String {
        let chars = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<16).map { _ in chars.randomElement()! })
    }
}

// MARK: - 半屏确认删除 Sheet（数据库 / 用户）

