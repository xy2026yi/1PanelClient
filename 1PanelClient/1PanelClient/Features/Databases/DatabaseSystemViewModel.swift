//
//  DatabaseSystemViewModel.swift
//  1PanelClient
//
//  单个数据库系统详情 ViewModel（自 DatabasesView.swift 拆出，内容未改动）
//

import SwiftUI
import Combine

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
            if postStartGrace { graceError = error.localizedDescription; return }
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
            if postStartGrace { graceError = error.localizedDescription; return }
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

    /// 启动/重启后的就绪宽限：应用层状态先行、容器内服务（mysqld 等）
    /// socket 可能尚未就绪，此期间容器内接口 500 不弹错、按间隔重试
    private var postStartGrace = false
    private var graceError: String?

    func operate(_ op: String) async {
        guard let installId = check?.appInstallId else { return }
        isOperating = true
        defer { isOperating = false }
        let req = AppOpRequest(installId: installId, operate: op)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.appsInstalledOperate.path, body: req, as: EmptyResponse.self)
            if op == "start" || op == "restart" {
                // 宽限重试补拉容器内数据（refresh 每轮全量重拉，含远程开关回显）；
                // MySQL 冷启动 socket 就绪可达 20s+：间隔 2s 最多 12 轮（约 24s），
                // 全部失败才提示
                for attempt in 0..<12 {
                    graceError = nil
                    postStartGrace = true
                    await refresh()
                    postStartGrace = false
                    if graceError == nil { break }
                    if attempt < 11 { try? await Task.sleep(for: .seconds(2)) }
                }
                if let err = graceError { errorMessage = err }
            } else {
                // 停止后 refresh 只重查状态、不再请求容器内接口
                await refresh()
            }
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
            users = resp.filter { !($0.isDelete ?? false) && $0.id != justDeletedUserID }
            await loadGrants()
        } catch {
            // 页面退出取消不是失败：不写错误态
            guard !APIError.isCancellation(error) else { return }
            if postStartGrace { graceError = error.localizedDescription; return }
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

    /// 刚删除用户的 id：reload 结果中过滤（服务端删除最终一致期间列表可能仍返回
    /// 该用户，数量不减会触发 List diff invalid update 崩溃）
    private var justDeletedUserID: String?

    func deleteUser(_ user: DatabaseUser) async {
        guard let username = user.username, let host = user.host else { return }
        // 等 TextInputConfirmSheet 收起动画完成再改列表：确认弹窗关闭与列表
        // 变更同一事务并发是已知崩溃窗口
        try? await Task.sleep(for: .milliseconds(500))
        isOperating = true
        defer { isOperating = false }
        let req = DeleteDBUserRequest(database: system.database, username: username, host: host)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.databasesUsersDelete.path, body: req, as: EmptyResponse.self
            )
            grants.removeAll { $0.username == username && $0.host == host }
            justDeletedUserID = user.id
            await loadUsers()
            justDeletedUserID = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

