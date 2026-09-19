//
//  CreateDatabaseView.swift
//  1PanelClient
//
//  创建数据库：名称 / 用户名 / 密码 / 字符集 / 排序规则 / 权限 / 备注
//  PostgreSQL: 名称 / 用户名(自动同步) / 密码 / 字符集 / 超级用户 / 备注
//  MongoDB: 名称 / 用户名(默认同名) / 密码 / 权限角色(dbOwner/read/readWrite/userAdmin) / 备注
//

import SwiftUI
import Combine

@MainActor
final class CreateDatabaseViewModel: ObservableObject {
    @Published var formats: [FormatOption] = []
    @Published var users: [DatabaseUser] = []
    @Published var isLoading = false
    @Published var isCreating = false
    @Published var errorMessage: String?

    let system: DatabaseSystem
    private let client: APIClient

    var isPostgreSQL: Bool {
        system.type.lowercased().contains("postgresql")
    }

    var isMySQL: Bool {
        let t = system.type.lowercased()
        return t == "mysql" || t == "mariadb" || t == "mysql-cluster"
    }

    var isMongoDB: Bool {
        system.type.lowercased().contains("mongodb")
    }

    init(system: DatabaseSystem, server: ServerConfig) {
        self.system = system
        self.client = APIClient.shared(for: server)
    }

    func loadFormats() async {
        isLoading = true
        defer { isLoading = false }
        let req = FormatOptionsRequest(name: system.database)
        do {
            formats = try await client.send(
                path: APIEndpoint.databasesFormatOptions.path, body: req, as: [FormatOption].self
            )
        } catch { errorMessage = error.localizedDescription }
    }

    func loadUsers() async {
        let req = DBUsersRequest(database: system.database)
        do {
            let resp: [DatabaseUser] = try await client.send(
                path: APIEndpoint.databasesUsersSearch.path, body: req, as: [DatabaseUser].self
            )
            users = resp.filter { !($0.isDelete ?? false) }
        } catch { errorMessage = error.localizedDescription }
    }

    func systemUserCreate(
        username: String, host: String, password: String,
        description: String, databases: [String]
    ) async -> Bool {
        isCreating = true
        defer { isCreating = false }
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
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func createMySQL(
        name: String, username: String, password: String,
        format: String, collation: String,
        permission: String, permissionIPs: String,
        description: String
    ) async -> Bool {
        isCreating = true
        defer { isCreating = false }
        let pwdBase64 = Data(password.utf8).base64EncodedString()
        let req = CreateDBRequest(
            name: name, from: "local", type: system.type,
            database: system.database, format: format, collation: collation,
            username: username, password: pwdBase64,
            permission: permission, permissionIPs: permissionIPs,
            description: description
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.databasesCreate.path, body: req, as: EmptyResponse.self
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func createPG(
        name: String, username: String, password: String,
        format: String, superUser: Bool, description: String
    ) async -> Bool {
        isCreating = true
        defer { isCreating = false }
        let pwdBase64 = Data(password.utf8).base64EncodedString()
        let req = CreatePGDBRequest(
            name: name, from: "local", type: system.type,
            database: system.database, format: format,
            username: username, password: pwdBase64,
            superUser: superUser, description: description
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.databasesPgCreate.path, body: req, as: EmptyResponse.self
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func createMongo(
        name: String, username: String, password: String,
        permission: MongoPermission, description: String
    ) async -> Bool {
        isCreating = true
        defer { isCreating = false }
        let pwdBase64 = Data(password.utf8).base64EncodedString()
        let req = CreateMongoDBRequest(
            name: name, from: "local", database: system.database,
            username: username, password: pwdBase64,
            permission: permission.rawValue, description: description
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.databasesMongoCreate.path, body: req, as: EmptyResponse.self
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

// MARK: - 创建视图

struct CreateDatabaseView: View {
    @StateObject private var vm: CreateDatabaseViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var selectedFormat = "utf8mb4"
    @State private var selectedCollation = ""
    @State private var userGrantMode: UserGrantMode = .none
    @State private var selectedExistingUser = ""
    @State private var permissionMode: PermissionMode = .all
    @State private var permissionIPs = ""
    @State private var superUser = true
    @State private var mongoPermission: MongoPermission = .dbOwner
    @State private var description = ""

    let onCreated: () async -> Void

    init(system: DatabaseSystem, onCreated: @escaping () async -> Void) {
        let server = ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: CreateDatabaseViewModel(system: system, server: server))
        self.onCreated = onCreated
    }

    enum PermissionMode: String, CaseIterable, Identifiable {
        case all = "所有人(%)"
        case ip = "指定IP"
        var id: String { rawValue }
    }

    /// 权限枚举 ↔ 字符串（OutlinedPicker 用 String；rawValue 即显示名）
    private var permissionModeBinding: Binding<String> {
        Binding<String>(
            get: { permissionMode.rawValue },
            set: { permissionMode = PermissionMode(rawValue: $0) ?? .all }
        )
    }

    enum UserGrantMode: String, CaseIterable, Identifiable {
        case none = "不授权"
        case select = "选择"
        case create = "创建"
        var id: String { rawValue }
    }

    private var availableCollations: [String] {
        vm.formats.first { $0.format == selectedFormat }?.collations ?? []
    }

    private var canCreate: Bool {
        let nameOk = !name.trimmingCharacters(in: .whitespaces).isEmpty
        if vm.isPostgreSQL || vm.isMongoDB {
            let userOk = !username.trimmingCharacters(in: .whitespaces).isEmpty
            let pwdOk = !password.isEmpty
            return nameOk && userOk && pwdOk
        }
        guard nameOk else { return false }
        switch userGrantMode {
        case .none:
            return true
        case .select:
            return !selectedExistingUser.isEmpty
        case .create:
            let userOk = !username.trimmingCharacters(in: .whitespaces).isEmpty
            let pwdOk = !password.isEmpty
            let permOk = permissionMode == .all || !permissionIPs.trimmingCharacters(in: .whitespaces).isEmpty
            return userOk && pwdOk && permOk
        }
    }

    var body: some View {
        Form {
            Section(L10n.t("基本信息")) {
                OutlinedTextField(label: L10n.t("数据库名称"), text: $name)
            }

            if vm.isPostgreSQL {
                pgUserSection
                Section(L10n.t("权限")) {
                    Toggle(L10n.t("超级用户"), isOn: $superUser)
                }
            } else if vm.isMongoDB {
                mongoUserSection
                Section(L10n.t("权限")) {
                    OutlinedPicker(label: L10n.t("角色"), options: MongoPermission.allCases,
                                   selection: $mongoPermission) { $0.displayName }
                }
            } else if vm.isMySQL {
                mysqlCharsetSection
                mysqlUserGrantSection
            }

            Section(L10n.t("描述")) {
                OutlinedMultiLineField(label: L10n.t("描述"), prompt: L10n.t("可选"),
                                       text: $description)
            }

            if let msg = vm.errorMessage {
                Section {
                    Text(msg).foregroundStyle(.red).font(.caption)
                }
            }
        }
        .navigationTitle(L10n.t("创建数据库"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("创建")) {
                    Task { await submit() }
                }
                .disabled(!canCreate || vm.isCreating)
            }
        }
        .task {
            if !vm.isMongoDB && vm.formats.isEmpty { await vm.loadFormats() }
            if vm.isMySQL {
                await vm.loadUsers()
                if password.isEmpty {
                    password = PasswordInputRow.randomPassword()
                    showPassword = true
                }
            }
            if (vm.isPostgreSQL || vm.isMongoDB) && password.isEmpty {
                password = PasswordInputRow.randomPassword()
                showPassword = true
            }
        }
        .onChange(of: name) { _, newValue in
            if vm.isMySQL && userGrantMode == .create {
                username = newValue
            }
            if vm.isMongoDB {
                username = newValue
            }
        }
        .onChange(of: userGrantMode) { _, newMode in
            if newMode == .create {
                username = name
                if password.isEmpty {
                    password = PasswordInputRow.randomPassword()
                    showPassword = true
                }
            }
        }
    }

    // MARK: PostgreSQL 用户（保持原有行为：名称同步）

    private var pgUserSection: some View {
        Section(L10n.t("用户")) {
            OutlinedTextField(label: L10n.t("用户名"), text: $username)
                .onChange(of: name) { _, newValue in
                    username = newValue
                }
            passwordRow
        }
    }

    // MARK: MongoDB 用户（名称自动带入同名，可修改）

    private var mongoUserSection: some View {
        Section(L10n.t("用户")) {
            OutlinedTextField(label: L10n.t("用户名"), prompt: L10n.t("默认同名称"), text: $username)
            passwordRow
        }
    }

    // MARK: MySQL 字符集 / 排序规则

    private var mysqlCharsetSection: some View {
        Section(L10n.t("字符集与排序规则")) {
            OutlinedPicker(label: L10n.t("字符集"), options: vm.formats.map(\.format),
                           selection: $selectedFormat)
            .onChange(of: selectedFormat) { _, _ in
                selectedCollation = ""
            }

            OutlinedPicker(label: L10n.t("排序规则"),
                           options: [""] + availableCollations,
                           selection: $selectedCollation,
                           optionLabels: ["": L10n.t("默认")])
        }
    }

    // MARK: MySQL 用户授权

    /// 授权用户选项（空串=请选择；id 去重防重复键）
    private var existingUserKeys: [String] {
        var keys = [""]
        var seen: Set<String> = [""]
        for u in vm.users where seen.insert(u.id).inserted { keys.append(u.id) }
        return keys
    }

    private var existingUserOptions: [String: String] {
        var labels = ["": L10n.t("请选择...")]
        for u in vm.users { labels[u.id] = u.displayName }
        return labels
    }

    private var mysqlUserGrantSection: some View {
        Group {
            Section(L10n.t("用户授权")) {
                OutlinedPicker(label: L10n.t("授权方式"), options: UserGrantMode.allCases,
                               selection: $userGrantMode) { L10n.t($0.rawValue) }
            }

            switch userGrantMode {
            case .none:
                EmptyView()
            case .select:
                Section(L10n.t("选择用户")) {
                    if vm.users.isEmpty {
                        Text(L10n.t("暂无可用用户，请先创建用户或切换为「创建」模式"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        OutlinedPicker(label: L10n.t("授权用户"),
                                       options: existingUserKeys,
                                       selection: $selectedExistingUser,
                                       optionLabels: existingUserOptions)
                    }
                }
            case .create:
                Section(L10n.t("新用户")) {
                    OutlinedTextField(label: L10n.t("用户名"), text: $username)
                    passwordRow
                }
                Section {
                    OutlinedPicker(label: L10n.t("权限"),
                                   options: PermissionMode.allCases.map(\.rawValue),
                                   selection: permissionModeBinding)
                    if permissionMode == .ip {
                        OutlinedMultiLineField(label: L10n.t("IP"),
                                               prompt: "172.16.10.111,172.16.10.112",
                                               text: $permissionIPs)
                    }
                } header: {
                    Text(L10n.t("权限"))
                } footer: {
                    if permissionMode == .ip {
                        Text(L10n.t("多个IP以逗号分隔，例: 172.16.10.111,172.16.10.112"))
                    }
                }
            }
        }
    }

    private var passwordRow: some View {
        PasswordInputRow(password: $password, showPassword: $showPassword)
    }

    private func submit() async {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)

        let ok: Bool
        if vm.isMongoDB {
            let trimmedUser = username.trimmingCharacters(in: .whitespaces)
            ok = await vm.createMongo(
                name: trimmedName, username: trimmedUser,
                password: password, permission: mongoPermission,
                description: description
            )
        } else if vm.isPostgreSQL {
            let trimmedUser = username.trimmingCharacters(in: .whitespaces)
            ok = await vm.createPG(
                name: trimmedName, username: trimmedUser,
                password: password, format: "UTF8",
                superUser: superUser, description: description
            )
        } else {
            let finalUser: String
            let finalPassword: String
            let perm: String
            let ips: String

            switch userGrantMode {
            case .none, .select:
                finalUser = ""
                finalPassword = ""
                perm = "%"
                ips = ""
            case .create:
                finalUser = username.trimmingCharacters(in: .whitespaces)
                finalPassword = password
                if permissionMode == .all {
                    perm = "%"
                    ips = ""
                } else {
                    perm = "%"
                    ips = permissionIPs
                }
            }

            ok = await vm.createMySQL(
                name: trimmedName, username: finalUser,
                password: finalPassword, format: selectedFormat,
                collation: selectedCollation,
                permission: perm, permissionIPs: ips,
                description: description
            )
        }
        if ok {
            await onCreated()
            dismiss()
        }
    }

}

// MARK: - 创建数据库用户视图

struct CreateDatabaseUserView: View {
    @StateObject private var vm: CreateDatabaseViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var permissionMode: UserPermissionMode = .all
    @State private var permissionIPs = ""
    @State private var description = ""
    @State private var selectedDatabases: Set<String> = []

    let availableDatabases: [String]
    let onCreated: () async -> Void

    enum UserPermissionMode: String, CaseIterable, Identifiable {
        case all = "所有人(%)"
        case ip = "指定IP"
        var id: String { rawValue }
    }

    init(system: DatabaseSystem, availableDatabases: [String], onCreated: @escaping () async -> Void) {
        let server = ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: CreateDatabaseViewModel(system: system, server: server))
        self.availableDatabases = availableDatabases
        self.onCreated = onCreated
    }

    private var canCreate: Bool {
        let userOk = !username.trimmingCharacters(in: .whitespaces).isEmpty
        let pwdOk = !password.isEmpty
        let permOk = permissionMode == .all || !permissionIPs.trimmingCharacters(in: .whitespaces).isEmpty
        return userOk && pwdOk && permOk
    }

    var body: some View {
        Form {
            Section(L10n.t("用户信息")) {
                OutlinedTextField(label: L10n.t("用户名"), text: $username)
                passwordRow
                OutlinedMultiLineField(label: L10n.t("描述"), text: $description)
                    .lineLimit(2...4)
            }

            Section(L10n.t("权限")) {
                OutlinedPicker(label: L10n.t("访问权限"), options: UserPermissionMode.allCases,
                               selection: $permissionMode) { L10n.t($0.rawValue) }
                if permissionMode == .ip {
                    OutlinedMultiLineField(label: L10n.t("IP"),
                                           prompt: "172.16.10.111,172.16.10.112",
                                           text: $permissionIPs)
                }
            }

            associatedDatabasesSection

            if let msg = vm.errorMessage {
                Section {
                    Text(msg).foregroundStyle(.red).font(.caption)
                }
            }
        }
        .navigationTitle(L10n.t("创建用户"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("创建")) {
                    Task { await submit() }
                }
                .disabled(!canCreate || vm.isCreating)
            }
        }
        .task {
            if password.isEmpty {
                password = PasswordInputRow.randomPassword()
                showPassword = true
            }
        }
    }

    private var passwordRow: some View {
        PasswordInputRow(password: $password, showPassword: $showPassword)
    }

    @ViewBuilder
    private var associatedDatabasesSection: some View {
        Section(L10n.t("关联数据库")) {
            if availableDatabases.isEmpty {
                Text(L10n.t("暂无可用数据库"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(availableDatabases, id: \.self) { dbName in
                    databaseSelectionRow(dbName)
                }
            }
        }
    }

    private func databaseSelectionRow(_ dbName: String) -> some View {
        CheckRow(title: dbName, isSelected: selectedDatabases.contains(dbName))
            .onTapGesture {
                if selectedDatabases.contains(dbName) {
                    selectedDatabases.remove(dbName)
                } else {
                    selectedDatabases.insert(dbName)
                }
            }
    }

    private func submit() async {
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        let host = permissionMode == .all ? "%" : permissionIPs
        let dbs = Array(selectedDatabases).sorted()
        let ok = await vm.systemUserCreate(
            username: trimmedUser, host: host,
            password: password, description: description,
            databases: dbs
        )
        if ok {
            await onCreated()
            dismiss()
        }
    }

}

// MARK: - 数据库用户详情/编辑视图

@MainActor
final class DatabaseUserDetailViewModel: ObservableObject {
    @Published var user: DatabaseUser
    @Published var grantedDatabases: [String] = []
    @Published var isOperating = false
    @Published var errorMessage: String?

    let system: DatabaseSystem
    let availableDatabases: [String]
    private let client: APIClient

    init(user: DatabaseUser, system: DatabaseSystem, availableDatabases: [String], server: ServerConfig) {
        self.user = user
        self.system = system
        self.availableDatabases = availableDatabases
        self.client = APIClient.shared(for: server)
    }

    func loadGrants() async {
        let req = DBUsersRequest(database: system.database)
        do {
            let allGrants: [DatabaseGrant] = try await client.send(
                path: APIEndpoint.databasesGrantsSearch.path, body: req, as: [DatabaseGrant].self
            )
            grantedDatabases = allGrants
                .filter { $0.username == user.username && $0.host == user.host }
                .compactMap { $0.database }
        } catch { grantedDatabases = [] }
    }

    func changePassword(_ password: String) async -> Bool {
        guard let username = user.username, let host = user.host else { return false }
        isOperating = true
        errorMessage = nil
        defer { isOperating = false }
        let pwdBase64 = Data(password.utf8).base64EncodedString()
        let req = ChangeDBUserPasswordRequest(database: system.database, username: username, host: host, password: pwdBase64)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.databasesUsersPassword.path, body: req, as: EmptyResponse.self
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updatePermission(newHost: String, description: String) async -> Bool {
        guard let username = user.username, let host = user.host else { return false }
        isOperating = true
        errorMessage = nil
        defer { isOperating = false }
        let req = UpdateDBUserRequest(database: system.database, username: username, host: host, newHost: newHost, description: description)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.databasesUsersUpdate.path, body: req, as: EmptyResponse.self
            )
            user = DatabaseUser(username: username, host: newHost, password: user.password, description: description, isDelete: user.isDelete)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func addGrant(db: String) async {
        guard let username = user.username, let host = user.host else { return }
        isOperating = true
        defer { isOperating = false }
        let req = DBGrantRequest(database: system.database, db: db, username: username, host: host)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.databasesGrantsAdd.path, body: req, as: EmptyResponse.self
            )
            await loadGrants()
        } catch { errorMessage = error.localizedDescription }
    }

    func removeGrant(db: String) async {
        guard let username = user.username, let host = user.host else { return }
        isOperating = true
        defer { isOperating = false }
        let req = DBGrantRequest(database: system.database, db: db, username: username, host: host)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.databasesGrantsDelete.path, body: req, as: EmptyResponse.self
            )
            await loadGrants()
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteUser() async -> Bool {
        guard let username = user.username, let host = user.host else { return false }
        isOperating = true
        errorMessage = nil
        defer { isOperating = false }
        let req = DeleteDBUserRequest(database: system.database, username: username, host: host)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.databasesUsersDelete.path, body: req, as: EmptyResponse.self
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

struct DatabaseUserDetailView: View {
    @StateObject private var vm: DatabaseUserDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var activeSheet: UserDetailSheet?

    enum UserDetailSheet: Identifiable {
        case changePassword
        case editPermission
        case addGrant
        case delete
        var id: Self { self }
    }

    let onChanged: () async -> Void

    init(user: DatabaseUser, system: DatabaseSystem, availableDatabases: [String], onChanged: @escaping () async -> Void) {
        let server = ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: DatabaseUserDetailViewModel(user: user, system: system, availableDatabases: availableDatabases, server: server))
        self.onChanged = onChanged
    }

    var body: some View {
        List {
            if let msg = vm.errorMessage {
                Section {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.semanticWarning)
                        .font(.caption)
                }
            }
            infoSection
            permissionSection
            grantedDatabasesSection
            deleteSection
        }
        .navigationTitle(vm.user.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadGrants() }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .changePassword:
                ChangePasswordSheet(
                    title: L10n.t("修改用户密码"),
                    currentPassword: vm.user.password
                ) { newPwd in
                    Task {
                        let ok = await vm.changePassword(newPwd)
                        if ok { await onChanged() }
                    }
                }
            case .editPermission:
                EditUserPermissionSheet(user: vm.user) { newHost, description in
                    Task {
                        let ok = await vm.updatePermission(newHost: newHost, description: description)
                        if ok { await onChanged() }
                    }
                }
            case .addGrant:
                AddGrantSheet(availableDatabases: vm.availableDatabases.filter { !vm.grantedDatabases.contains($0) }) { dbName in
                    Task {
                        await vm.addGrant(db: dbName)
                        await onChanged()
                    }
                }
            case .delete:
                TextInputConfirmSheet(
                    title: L10n.t("删除用户"),
                    message: L10n.f("此操作不可恢复。请输入用户名「%@」以确认删除。", vm.user.username ?? ""),
                    expectedText: vm.user.username ?? "",
                    fieldLabel: L10n.t("确认用户名"),
                    fieldPlaceholder: L10n.t("用户名")
                ) {
                    Task {
                        let ok = await vm.deleteUser()
                        if ok {
                            await onChanged()
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private var infoSection: some View {
        Section {
            if let username = vm.user.username {
                InfoRow(key: L10n.t("用户名"), value: username)
            }
            if let pwd = vm.user.password, !pwd.isEmpty {
                PasswordRow(password: pwd)
            }
            if let desc = vm.user.description, !desc.isEmpty {
                InfoRow(key: L10n.t("描述"), value: desc)
            }

            Button {
                activeSheet = .changePassword
            } label: {
                Label(L10n.t("修改密码"), systemImage: "key")
            }
        } header: {
            SectionLabel(title: L10n.t("用户信息"), systemImage: "person")
        }
    }

    private var permissionSection: some View {
        Section {
            InfoRow(key: L10n.t("当前权限"), value: vm.user.host == "%" ? L10n.t("所有人(%)") : (vm.user.host ?? "-"))
            Button {
                activeSheet = .editPermission
            } label: {
                Label(L10n.t("修改权限"), systemImage: "network")
            }
        } header: {
            SectionLabel(title: L10n.t("权限"), systemImage: "lock.shield")
        }
    }

    private var grantedDatabasesSection: some View {
        Section {
            if vm.grantedDatabases.isEmpty {
                Text(L10n.t("无关联数据库"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vm.grantedDatabases, id: \.self) { dbName in
                    HStack {
                        Text(dbName)
                            .font(.dataMonospacedBody)
                        Spacer()
                        Button {
                            Task { await vm.removeGrant(db: dbName) }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Button {
                activeSheet = .addGrant
            } label: {
                Label(L10n.t("添加关联数据库"), systemImage: "plus.circle")
            }
            .disabled(vm.availableDatabases.filter { !vm.grantedDatabases.contains($0) }.isEmpty)
        } header: {
            SectionLabel(title: L10n.f("关联数据库（%ld）", vm.grantedDatabases.count), systemImage: "cylinder")
        }
    }

    // MARK: 删除

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                activeSheet = .delete
            } label: {
                Label(L10n.t("删除用户"), systemImage: "trash")
            }
        }
    }
}

// MARK: - 修改权限 Sheet

struct EditUserPermissionSheet: View {
    let user: DatabaseUser
    let onConfirm: (_ newHost: String, _ description: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var permissionMode: PermissionMode
    @State private var permissionIPs = ""
    @State private var description = ""

    enum PermissionMode: String, CaseIterable, Identifiable {
        case all = "所有人(%)"
        case ip = "指定IP"
        var id: String { rawValue }
    }

    /// 权限枚举 ↔ 字符串（OutlinedPicker 用 String；rawValue 即显示名）
    private var permissionModeBinding: Binding<String> {
        Binding<String>(
            get: { permissionMode.rawValue },
            set: { permissionMode = PermissionMode(rawValue: $0) ?? .all }
        )
    }

    init(user: DatabaseUser, onConfirm: @escaping (_ newHost: String, _ description: String) -> Void) {
        self.user = user
        self.onConfirm = onConfirm
        let host = user.host ?? "%"
        if host == "%" {
            _permissionMode = State(initialValue: .all)
        } else {
            _permissionMode = State(initialValue: .ip)
            _permissionIPs = State(initialValue: host)
        }
        _description = State(initialValue: user.description ?? "")
    }

    private var finalHost: String {
        permissionMode == .all ? "%" : permissionIPs.trimmingCharacters(in: .whitespaces)
    }

    private var canConfirm: Bool {
        permissionMode == .all || !permissionIPs.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.t("权限")) {
                    OutlinedPicker(label: L10n.t("访问权限"),
                                   options: PermissionMode.allCases.map(\.rawValue),
                                   selection: permissionModeBinding,
                                   optionLabels: PermissionMode.allCases.reduce(into: [:]) {
                                       $0[$1.rawValue] = L10n.t($1.rawValue)
                                   })

                    if permissionMode == .ip {
                        OutlinedMultiLineField(label: L10n.t("IP"),
                                               prompt: "192.168.1.100, 10.0.0.5",
                                               text: $permissionIPs)
                    }
                }
                Section(L10n.t("描述")) {
                    OutlinedMultiLineField(label: L10n.t("描述"), prompt: L10n.t("可选"),
                                           text: $description)
                }
            }
            .navigationTitle(L10n.t("修改权限"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("保存")) {
                        onConfirm(finalHost, description)
                        dismiss()
                    }
                    .disabled(!canConfirm)
                }
            }
        }
    }
}

// MARK: - 添加关联数据库 Sheet

struct AddGrantSheet: View {
    let availableDatabases: [String]
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedDatabase = ""

    var body: some View {
        NavigationStack {
            Form {
                if availableDatabases.isEmpty {
                    Text(L10n.t("暂无可关联的数据库"))
                        .foregroundStyle(.secondary)
                } else {
                    Section(L10n.t("选择数据库")) {
                        ForEach(availableDatabases, id: \.self) { dbName in
                            CheckRow(title: dbName, isSelected: selectedDatabase == dbName)
                                .onTapGesture {
                                    selectedDatabase = dbName
                                }
                        }
                    }
                }
            }
            .navigationTitle(L10n.t("添加关联数据库"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("保存")) {
                        onConfirm(selectedDatabase)
                        dismiss()
                    }
                    .disabled(selectedDatabase.isEmpty)
                }
            }
        }
    }
}

// MARK: - 用户详情页删除确认 Sheet（半屏，输入用户名确认）已由共享 TextInputConfirmSheet 提供
