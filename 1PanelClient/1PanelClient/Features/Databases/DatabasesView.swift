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

    func loadSystems() async {
        isLoading = true
        defer { isLoading = false }

        async let mysql: [DatabaseSystem]? = fetchList(types: "mysql,mariadb,mysql-cluster")
        async let pg: [DatabaseSystem]? = fetchList(types: "postgresql,postgresql-cluster")
        async let redis: [DatabaseSystem]? = fetchList(types: "redis,redis-cluster")

        var all: [DatabaseSystem] = []
        all.append(contentsOf: await mysql ?? [])
        all.append(contentsOf: await pg ?? [])
        all.append(contentsOf: await redis ?? [])
        self.systems = all
        self.errorMessage = nil
    }

    private func fetchList(types: String) async -> [DatabaseSystem]? {
        let path = "/api/v2/databases/db/list/\(types)"
        do {
            return try await client.send(path: path, method: "GET", as: [DatabaseSystem].self)
        } catch {
            return nil
        }
    }
}

// MARK: - 数据库首页（DB 系统列表）

struct DatabasesView: View {
    @StateObject private var vm: DatabasesViewModel

    init(server: ServerConfig) {
        _vm = StateObject(wrappedValue: DatabasesViewModel(server: server))
    }

    var body: some View {
        List {
            if vm.systems.isEmpty && !vm.isLoading {
                emptySection
            } else {
                if !vm.mysqlSystems.isEmpty { systemGroup("MySQL / MariaDB", vm.mysqlSystems) }
                if !vm.pgSystems.isEmpty { systemGroup("PostgreSQL", vm.pgSystems) }
                if !vm.redisSystems.isEmpty { systemGroup("Redis", vm.redisSystems) }
            }
        }
        .navigationTitle("数据库")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.loadSystems() }
        .task {
            if vm.systems.isEmpty { await vm.loadSystems() }
        }
        .overlay {
            if vm.isLoading && vm.systems.isEmpty {
                ProgressView()
            }
        }
    }

    private var emptySection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "cylinder")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("未检测到数据库")
                    .font(.headline)
                Text("请先在应用商店安装 MySQL / PostgreSQL / Redis。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
    }

    @ViewBuilder
    private func systemGroup(_ title: String, _ items: [DatabaseSystem]) -> some View {
        Section(title) {
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

struct DatabaseSystemRow: View {
    let system: DatabaseSystem

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(
                systemName: system.systemIcon,
                color: Color.fromDBString(system.systemColor),
                size: 42
            )
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

    var isPostgreSQL: Bool {
        system.type.lowercased().contains("postgresql")
    }

    var isRedis: Bool {
        let t = system.type.lowercased()
        return t == "redis" || t == "redis-cluster"
    }

    var searchPath: String {
        let t = system.type.lowercased()
        if t.contains("postgresql") { return APIEndpoint.databasesPgSearch.path }
        return APIEndpoint.databasesSearch.path
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
        let path = isPostgreSQL ? APIEndpoint.databasesPgPassword.path : APIEndpoint.databasesChangePassword.path
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
        let checkPath = isPostgreSQL ? APIEndpoint.databasesPgDelCheck.path : APIEndpoint.databasesDelCheck.path
        let delPath = isPostgreSQL ? APIEndpoint.databasesPgDel.path : APIEndpoint.databasesDel.path
        do {
            let _: EmptyResponse = try await client.send(path: checkPath, body: checkReq, as: EmptyResponse.self)
            let _: EmptyResponse = try await client.send(path: delPath, body: delReq, as: EmptyResponse.self)
            await loadDatabases()
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
    @State private var pendingAction: String?
    @State private var pendingDeleteDb: DatabaseItem?
    @State private var isStatusExpanded = false

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
        }
        .navigationTitle(vm.system.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.refresh() }
        .task { await vm.refresh() }
        .overlay(alignment: .bottomTrailing) {
            if vm.supportsDatabaseList {
                Button { showCreate = true } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Color.accentColor, in: Circle())
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                }
                .padding(.trailing, 20)
                .padding(.bottom, 20)
            }
        }
        .sheet(isPresented: $showCreate) {
            CreateDatabaseView(system: vm.system) { await vm.loadDatabases() }
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
        .alert(
            "删除数据库",
            isPresented: Binding(
                get: { pendingDeleteDb != nil },
                set: { if !$0 { pendingDeleteDb = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingDeleteDb = nil }
            Button("删除", role: .destructive) {
                let db = pendingDeleteDb
                pendingDeleteDb = nil
                if let db { Task { await vm.deleteDatabase(db) } }
            }
        } message: {
            if let db = pendingDeleteDb {
                Text("确定删除数据库「\(db.name)」吗？删除后不可恢复。")
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

    private var statusSection: some View {
        Section {
            if let check = vm.check {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isStatusExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        IconBadge(systemName: check.isRunning ? "play.circle.fill" : "stop.circle.fill",
                                  color: check.isRunning ? .green : .red, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.app ?? vm.system.displayName).font(.headline)
                            HStack(spacing: 6) {
                                StatusBadge(
                                    text: check.isRunning ? "运行中" : "已停止",
                                    color: check.isRunning ? .green : .red,
                                    icon: check.isRunning ? "checkmark.circle" : "exclamationmark.triangle"
                                )
                                if let v = check.version, !v.isEmpty {
                                    Text("v\(v)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                        Image(systemName: isStatusExpanded ? "chevron.up" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isStatusExpanded {
                    HStack(spacing: 12) {
                        if !check.isRunning {
                            Button { pendingAction = "start" } label: {
                                Label("启动", systemImage: "play.fill")
                            }
                            .disabled(vm.isOperating)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        } else {
                            Button { pendingAction = "stop" } label: {
                                Label("停止", systemImage: "stop.fill")
                            }
                            .disabled(vm.isOperating)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.red)
                        }

                        Button { pendingAction = "restart" } label: {
                            Label("重启", systemImage: "arrow.clockwise")
                        }
                        .disabled(vm.isOperating)
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button { showDatabaseTerminal = true } label: {
                            Label("终端", systemImage: "terminal")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } else {
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
                    HStack {
                        Text("密码").foregroundStyle(.secondary)
                        Spacer()
                        Text(String(repeating: "•", count: min(pwd.count, 12)))
                            .font(.system(.subheadline, design: .monospaced))
                        Button {
                            UIPasteboard.general.string = pwd
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .foregroundStyle(.secondary)
                        }
                    }
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

                if !vm.supportsDatabaseList {
                    Button {
                        showRedisTerminal = true
                    } label: {
                        Label("Redis 终端", systemImage: "terminal")
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
            if vm.databases.isEmpty {
                Text("暂无数据库")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(vm.databases) { db in
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
            }
        } header: {
            SectionLabel(title: "数据库（\(vm.databases.count)）", systemImage: "cylinder")
        }
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
                if let perm = db.permission, perm == "%" || perm.isEmpty {
                    StatusBadge(text: "远程", color: .blue, icon: "network")
                } else {
                    StatusBadge(text: "本机", color: .orange, icon: "lock.shield")
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
