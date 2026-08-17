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
        self.client = APIClient(server: server)
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
            ? (lastError ?? "数据库列表加载失败，请检查服务器连接")
            : nil
        lastError = nil
    }

    private func fetchList(types: String) async -> [DatabaseSystem]? {
        let path = "/api/v2/databases/db/list/\(types)"
        do {
            return try await client.send(path: path, method: "GET", as: [DatabaseSystem].self)
        } catch {
            lastError = "加载失败：\(error.localizedDescription)"
            return nil
        }
    }
}

// MARK: - 数据库首页（DB 系统列表）

/// 数据库类型分类（始终展示的 4 类，未安装时显示占位行 + 安装入口）
enum DBCategory: String, CaseIterable {
    case mysql, postgresql, redis, mongodb

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

    init(server: ServerConfig) {
        _vm = StateObject(wrappedValue: DatabasesViewModel(server: server))
    }

    var body: some View {
        List {
            // 全部请求失败：显示错误态 + 重试（而不是误显示为「未安装」）
            if vm.systems.isEmpty, let msg = vm.errorMessage, !vm.isLoading {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(msg)
                } actions: {
                    Button("重试") {
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
        .navigationTitle("数据库")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.loadSystems() }
        .task {
            if vm.systems.isEmpty { await vm.loadSystems() }
        }
        // 应用安装完成时刷新（如从「安装 XX」流程返回后，新装的数据库需重新拉取）
        .onReceive(NotificationCenter.default.publisher(for: .installCompleted)) { _ in
            Task { await vm.loadSystems() }
        }
        .overlay {
            if vm.isLoading && vm.systems.isEmpty {
                ProgressView()
            }
        }
    }

    /// 单个分类分组：有实例则列出，无实例则显示未安装占位行
    @ViewBuilder
    private func systemGroup(for category: DBCategory) -> some View {
        let items = systems(for: category)
        if items.isEmpty {
            // 未安装：占位行
            Section(category.title) {
                NavigationLink {
                    NotInstalledDatabaseView(category: category)
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
struct NotInstalledDatabaseRow: View {
    let category: DBCategory

    var body: some View {
        HStack(spacing: 14) {
            BrandIcon(brand: category.brand, size: 44)
                .opacity(0.4)   // 未安装：图标变淡
            VStack(alignment: .leading, spacing: 3) {
                Text(category.title).font(.headline).foregroundStyle(.secondary)
                Text("未安装")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 未安装数据库详情页（提示 + 安装按钮）

/// 未安装数据库的详情页：提示未安装并提供跳转应用商店安装的入口
struct NotInstalledDatabaseView: View {
    let category: DBCategory
    @Environment(\.dismiss) private var dismiss

    /// 应用商店 ViewModel（详情页 + 安装表单共用）
    @StateObject private var storeVM: AppStoreViewModel = {
        let server = ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        return AppStoreViewModel(server: server)
    }()
    /// 是否已进入安装表单（用于区分「自己的安装完成」与无关的全局 installCompleted 通知）
    @State private var didEnterInstall = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            BrandIcon(brand: category.brand, size: 72)
                .opacity(0.5)

            VStack(spacing: 8) {
                Text("\(category.title)未安装")
                    .font(.headline)
                Text("请先安装 \(category.title) 后再使用此功能")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // 用 NavigationLink 直接 push 应用详情页（避免 isPresented 时序问题）
            NavigationLink {
                AppStoreDetailView(appKey: category.appKey, vm: storeVM)
            } label: {
                Label("安装 \(category.title)", systemImage: "arrow.down.circle.fill")
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
        // 安装表单：详情页点「安装」后 push 安装表单
        .navigationDestination(isPresented: $storeVM.showInstall) {
            if let installDetail = storeVM.installDetail {
                AppInstallView(detail: installDetail, vm: storeVM)
            }
        }
        // 跟踪是否进入过安装表单（showInstall true→false 表示用户开始了安装流程）
        .onChange(of: storeVM.showInstall) { _, isShown in
            if isShown { didEnterInstall = true }
        }
        // 安装完成通知：仅当确实进入了本页发起的安装流程时才返回，
        // 避免无关的全局 installCompleted 通知误触发 dismiss（表现为点击安装变返回）
        .onReceive(NotificationCenter.default.publisher(for: .installCompleted)) { _ in
            guard didEnterInstall else { return }
            storeVM.showInstall = false
            // 等导航栈稳定后再 dismiss，避免动画冲突
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                dismiss()
            }
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
        self.client = APIClient(server: server)
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        async let _: () = loadCheck()
        async let _: () = loadConnInfo()
        async let _: () = loadRemote()
        if supportsDatabaseList {
            async let _: () = loadDatabases()
            _ = await loadDatabases()
        }
        if supportsUserManagement {
            async let _: () = loadUsers()
            _ = await loadUsers()
        }
        _ = await (loadCheck(), loadConnInfo(), loadRemote())
    }

    func loadCheck() async {
        let req = AppCheckRequest(key: system.database, name: system.database)
        do {
            check = try await client.send(path: APIEndpoint.appsInstalledCheck.path, body: req, as: AppInstallCheck.self)
        } catch { errorMessage = error.localizedDescription }
    }

    func loadConnInfo() async {
        let req = ConnInfoRequest(type: system.type, name: system.database)
        do {
            connInfo = try await client.send(path: APIEndpoint.appsInstalledConnInfo.path, body: req, as: ConnInfo.self)
        } catch { errorMessage = error.localizedDescription }
    }

    func loadRemote() async {
        let req = ConnInfoRequest(type: system.type, name: system.database)
        do {
            let resp: Bool = try await client.send(path: APIEndpoint.databasesRemote.path, body: req, as: Bool.self)
            remoteAccess = resp
        } catch { errorMessage = error.localizedDescription }
    }

    func loadDatabases() async {
        let req = DBSearchRequest(page: 1, pageSize: 200, database: system.database, orderBy: "createdAt", order: "null")
        do {
            let resp: PageResponse<DatabaseItem> = try await client.send(path: searchPath, body: req, as: PageResponse<DatabaseItem>.self)
            databases = resp.items ?? []
        } catch { errorMessage = error.localizedDescription }
    }

    func operate(_ op: String) async {
        guard let installId = check?.appInstallId else { return }
        isOperating = true
        defer { isOperating = false }
        let req = AppOpRequest(installId: installId, operate: op)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.appsInstalledOperate.path, body: req, as: EmptyResponse.self)
            await loadCheck()
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
        } catch { errorMessage = error.localizedDescription }
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
    @State private var showServicePasswordSheet = false
    @State private var showRedisTerminal = false
    @State private var showRedisPasswordSheet = false
    @State private var showDatabaseTerminal = false
    @State private var showContainerTerminal = false
    @State private var pendingAction: String?
    @State private var pendingDeleteDb: DatabaseItem?
    @State private var isStatusExpanded = false
    @State private var showCreateUser = false
    @State private var pendingDeleteUser: DatabaseUser?

    init(system: DatabaseSystem) {
        _vm = StateObject(wrappedValue: DatabaseSystemViewModel(system: system, server: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")))
    }

    var body: some View {
        List {
            statusSection
            connInfoSection
            if vm.supportsDatabaseList {
                databaseListSection
            }
            if vm.supportsUserManagement {
                userListSection
            }
        }
        .navigationTitle(vm.system.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.refresh() }
        .task { await vm.refresh() }
        .overlay(alignment: .bottomTrailing) {
            if vm.supportsDatabaseList {
                MenuFloatingActionButton {
                    Button { showCreate = true } label: {
                        Label("创建数据库", systemImage: "cylinder.badge.plus")
                    }
                    if vm.supportsUserManagement {
                        Button { showCreateUser = true } label: {
                            Label("创建用户", systemImage: "person.badge.plus")
                        }
                    }
                }
                .accessibilityLabel("创建数据库或用户")
            }
        }
        .navigationDestination(isPresented: $showCreate) {
            CreateDatabaseView(system: vm.system) { await vm.loadDatabases() }
        }
        .navigationDestination(isPresented: $showCreateUser) {
            CreateDatabaseUserView(system: vm.system, availableDatabases: vm.databases.map { $0.name ?? "" }.filter { !$0.isEmpty }) {
                await vm.loadUsers()
            }
        }
        .sheet(isPresented: $showServicePasswordSheet) {
            ChangePasswordSheet(
                title: "修改 \(vm.system.displayName) 密码",
                currentPassword: vm.connInfo?.password
            ) { newPassword in
                Task { await vm.changeServicePassword(newPassword) }
            }
        }
        .navigationDestination(isPresented: $showRedisTerminal) {
            TerminalView(
                server: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""),
                target: .redis(name: vm.system.database, cols: 80, rows: 24)
            )
        }
        .navigationDestination(isPresented: $showDatabaseTerminal) {
            TerminalView(
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
                TerminalView(
                    server: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""),
                    target: .container(containerID: container, user: "", command: "/bin/sh", cols: 80, rows: 24),
                    initialCommand: vm.mongoInitialCommand
                )
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
        .alert(
            pendingAction.map { dbActionDisplayName($0) } ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingAction = nil }
            Button("确认", role: .destructive) {
                let op = pendingAction
                pendingAction = nil
                if let op { Task { await vm.operate(op) } }
            }
        } message: {
            if let action = pendingAction {
                Text("将对 \(vm.system.displayName) 进行 \(dbActionDisplayName(action)) 操作，是否继续？")
            }
        }
        .sheet(item: $pendingDeleteDb) { db in
            TextInputConfirmSheet(
                title: "删除数据库",
                message: "此操作不可恢复。请输入数据库名称「\(db.name ?? "")」以确认删除。",
                expectedText: db.name ?? "",
                fieldLabel: "确认名称",
                fieldPlaceholder: "数据库名称"
            ) {
                Task { await vm.deleteDatabase(db) }
            }
        }
        .sheet(item: $pendingDeleteUser) { user in
            TextInputConfirmSheet(
                title: "删除用户",
                message: "此操作不可恢复。请输入用户名「\(user.username ?? "")」以确认删除。",
                expectedText: user.username ?? "",
                fieldLabel: "确认用户名",
                fieldPlaceholder: "用户名"
            ) {
                Task { await vm.deleteUser(user) }
            }
        }
    }

    private func dbActionDisplayName(_ action: String) -> String {
        switch action {
        case "stop":    return "停止"
        case "start":   return "启动"
        case "restart": return "重启"
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
                statusText: check.isRunning ? "运行中" : "已停止",
                statusColor: check.isRunning ? .green : .red,
                isOperating: vm.isOperating,
                isExpanded: $isStatusExpanded,
                actions: [
                    ServiceAction(
                        title: check.isRunning ? "停止" : "启动",
                        icon: check.isRunning ? "stop.fill" : "play.fill",
                        color: check.isRunning ? .orange : .green
                    ) { pendingAction = check.isRunning ? "stop" : "start" },
                    ServiceAction(title: "重启", icon: "arrow.triangle.2.circlepath", color: .blue) {
                        pendingAction = "restart"
                    },
                    ServiceAction(
                        title: "终端",
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
                    }
                ]
            ) {
                IconBadge(systemName: "cylinder.split.1x2", color: .purple, size: 44)
            }
        } else {
            Section {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
    }

    // MARK: 连接信息

    private var connInfoSection: some View {
        Section {
            if let ci = vm.connInfo {
                InfoRow(key: "容器地址", value: ci.containerName ?? vm.system.address ?? "-")
                if let port = ci.port { InfoRow(key: "端口", value: "\(port)") }
                InfoRow(key: "外部地址", value: "127.0.0.1")
                if let user = ci.username, !user.isEmpty {
                    InfoRow(key: "用户名", value: user)
                }

                if vm.supportsRemoteAccess {
                    Toggle(isOn: Binding(
                        get: { vm.remoteAccess },
                        set: { on in Task { await vm.toggleRemote(on) } }
                    )) {
                        Label("远程访问", systemImage: "network")
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
                        Label("修改密码", systemImage: "key")
                    }
                }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        } header: {
            SectionLabel(title: "连接信息", systemImage: "link")
        }
    }

    // MARK: 数据库列表

    private var databaseListSection: some View {
        Section {
            ForEach(vm.databases, id: \.id) { db in
                NavigationLink {
                    DatabaseDetailView(database: db, system: vm.system) { await vm.loadDatabases() }
                } label: {
                    DatabaseItemRow(db: db)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDeleteDb = db
                    } label: { Label("删除", systemImage: "trash") }
                }
            }
            if vm.databases.isEmpty {
                Text("暂无数据库")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        } header: {
            SectionLabel(title: "数据库（\(vm.databases.count)）", systemImage: "cylinder")
        }
    }

    // MARK: 用户列表（MySQL）

    private var userListSection: some View {
        Section {
            ForEach(vm.users, id: \.id) { user in
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
                    } label: { Label("删除", systemImage: "trash") }
                }
            }
            if vm.users.isEmpty {
                Text("暂无用户")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        } header: {
            SectionLabel(title: "用户（\(vm.users.count)）", systemImage: "person.2")
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
                    .font(.system(.body, design: .monospaced).bold())
                if let host = user.host, host == "%" {
                    StatusBadge(text: "远程", color: .blue, icon: "network")
                } else {
                    StatusBadge(text: "本机", color: .orange, icon: "lock.shield")
                }
            }

            if let pwd = user.password, !pwd.isEmpty {
                PasswordRow(password: pwd, compact: true)
            }

            if !grants.isEmpty {
                HStack(spacing: 4) {
                    Text("数据库:").font(.caption).foregroundStyle(.secondary)
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
                    .font(.system(.body, design: .monospaced).bold())
                // MongoDB 无 permission 字段，不显示本机/远程徽标
                if !db.isMongoDB {
                    if let perm = db.permission, perm == "%" || perm.isEmpty {
                        StatusBadge(text: "远程", color: .blue, icon: "network")
                    } else {
                        StatusBadge(text: "本机", color: .orange, icon: "lock.shield")
                    }
                }
            }
            if let desc = db.description, !desc.isEmpty {
                Text(desc).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 8) {
                if let u = db.username, !u.isEmpty {
                    Text("用户: \(u)").font(.caption).foregroundStyle(.secondary)
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
                    Section("当前密码") {
                        HStack {
                            Text(showCurrent ? cur : String(repeating: "•", count: min(cur.count, 12)))
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Button { showCurrent.toggle() } label: {
                                Image(systemName: showCurrent ? "eye.slash" : "eye")
                            }
                            Button { UIPasteboard.general.string = cur } label: {
                                Image(systemName: "doc.on.doc")
                            }
                        }
                    }
                }
                Section("新密码") {
                    HStack {
                        Group {
                            if showNew {
                                TextField("输入或生成新密码", text: $newPassword)
                            } else {
                                SecureField("输入或生成新密码", text: $newPassword)
                            }
                        }
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))

                        Button { showNew.toggle() } label: {
                            Image(systemName: showNew ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        newPassword = randomPassword()
                        showNew = true
                    } label: {
                        Label("生成随机密码", systemImage: "shuffle")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认") {
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
            .navigationTitle("修改 Redis 密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if step == .input {
                        Button("下一步") {
                            step = .confirm
                        }
                        .disabled(newPassword.isEmpty)
                    } else {
                        Button("立即重启", role: .destructive) {
                            onConfirm(newPassword)
                            dismiss()
                        }
                        .disabled(restartConfirm != "立即重启")
                    }
                }
            }
        }
    }

    private var inputStep: some View {
        Form {
            if let cur = currentPassword, !cur.isEmpty {
                Section("当前密码") {
                    HStack {
                        Text(showCurrent ? cur : String(repeating: "•", count: min(cur.count, 12)))
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Button { showCurrent.toggle() } label: {
                            Image(systemName: showCurrent ? "eye.slash" : "eye")
                        }
                        Button { UIPasteboard.general.string = cur } label: {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                }
            }
            Section("新密码") {
                TextField("输入或生成新密码", text: $newPassword)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))
                Button {
                    newPassword = randomPassword()
                } label: {
                    Label("生成随机密码", systemImage: "shuffle")
                }
            }
        }
    }

    private var confirmStep: some View {
        Form {
            Section {
                Label("修改密码后需要重启 Redis 才能生效", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("请输入「立即重启」以确认操作。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("确认重启") {
                TextField("请输入「立即重启」", text: $restartConfirm)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }
    }

    private func randomPassword() -> String {
        let chars = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<16).map { _ in chars.randomElement()! })
    }
}

// MARK: - 半屏确认删除 Sheet（数据库 / 用户）

// MARK: - Color 扩展

extension Color {
    static func fromDBString(_ name: String) -> Color {
        switch name {
        case "blue":   return .blue
        case "indigo": return .indigo
        case "red":    return .red
        case "purple": return .purple
        case "green":  return .green
        case "orange": return .orange
        default:       return .purple
        }
    }
}
