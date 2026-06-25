//
//  DatabaseDetailView.swift
//  1PanelClient
//
//  单个数据库详情：连接信息 / 改密码 / 改权限 / 删除
//

import SwiftUI
import Combine

@MainActor
final class DatabaseDetailViewModel: ObservableObject {
    @Published var database: DatabaseItem
    @Published var isOperating = false
    @Published var errorMessage: String?

    let system: DatabaseSystem
    private let client: APIClient

    init(database: DatabaseItem, system: DatabaseSystem, server: ServerConfig) {
        self.database = database
        self.system = system
        self.client = APIClient(server: server)
    }

    private var searchPath: String {
        let t = system.type.lowercased()
        if t.contains("postgresql") { return APIEndpoint.databasesPgSearch.path }
        return APIEndpoint.databasesSearch.path
    }

    var isPostgreSQL: Bool {
        system.type.lowercased().contains("postgresql")
    }

    /// 修改后重新拉取最新数据
    func reloadDetail() async {
        let req = DBSearchRequest(page: 1, pageSize: 200, database: system.database, orderBy: "createdAt", order: "null")
        do {
            let resp: PageResponse<DatabaseItem> = try await client.send(path: searchPath, body: req, as: PageResponse<DatabaseItem>.self)
            if let updated = resp.items?.first(where: { $0.id == database.id }) {
                database = updated
            }
        } catch { /* 静默 */ }
    }

    func changePassword(_ password: String) async {
        isOperating = true
        defer { isOperating = false }
        let value = Data(password.utf8).base64EncodedString()
        let dbType = system.type
        let dbFrom = database.from ?? "local"
        let dbName = system.database

        do {
            if isPostgreSQL {
                let checkReq = ChangePasswordRequest(id: database.id, from: dbFrom, type: dbType, database: dbName, value: "")
                let _: EmptyResponse = try await client.send(path: APIEndpoint.databasesPgDelCheck.path, body: checkReq, as: EmptyResponse.self)
                let pwdReq = ChangePasswordRequest(id: database.id, from: dbFrom, type: dbType, database: dbName, value: value)
                let _: EmptyResponse = try await client.send(path: APIEndpoint.databasesPgPassword.path, body: pwdReq, as: EmptyResponse.self)
            } else {
                let req = ChangePasswordRequest(id: database.id, from: dbFrom, type: dbType, database: dbName, value: value)
                let _: EmptyResponse = try await client.send(path: APIEndpoint.databasesChangePassword.path, body: req, as: EmptyResponse.self)
            }
            await reloadDetail()
        } catch { errorMessage = error.localizedDescription }
    }

    func changeAccess(value: String) async {
        isOperating = true
        defer { isOperating = false }
        let req = ChangeAccessRequest(
            id: database.id, from: database.from ?? "local",
            type: system.type, database: system.database, value: value
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.databasesChangeAccess.path, body: req, as: EmptyResponse.self
            )
            await reloadDetail()
        } catch { errorMessage = error.localizedDescription }
    }

    func changePrivileges(superUser: Bool) async {
        isOperating = true
        defer { isOperating = false }
        let req = PGPrivilegesRequest(
            name: database.name ?? "",
            database: system.database,
            username: database.username ?? "",
            superUser: superUser
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.databasesPgPrivileges.path, body: req, as: EmptyResponse.self
            )
            await reloadDetail()
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(forceDelete: Bool, deleteBackup: Bool) async -> Bool {
        let checkReq = DelCheckRequest(id: database.id, type: system.type, database: system.database)
        let delReq = DelDBRequest(
            id: database.id, type: system.type,
            database: system.database, deleteBackup: deleteBackup, forceDelete: forceDelete
        )
        let checkPath = isPostgreSQL ? APIEndpoint.databasesPgDelCheck.path : APIEndpoint.databasesDelCheck.path
        let delPath = isPostgreSQL ? APIEndpoint.databasesPgDel.path : APIEndpoint.databasesDel.path
        do {
            let _: EmptyResponse = try await client.send(path: checkPath, body: checkReq, as: EmptyResponse.self)
            let _: EmptyResponse = try await client.send(path: delPath, body: delReq, as: EmptyResponse.self)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

// MARK: - 详情视图

struct DatabaseDetailView: View {
    @StateObject private var vm: DatabaseDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPassword = false
    @State private var showChangePassword = false
    @State private var showAccessSheet = false
    @State private var showPrivilegesSheet = false
    @State private var showDeleteSheet = false

    let onChanged: () async -> Void

    init(database: DatabaseItem, system: DatabaseSystem, onChanged: @escaping () async -> Void) {
        let server = ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: DatabaseDetailViewModel(database: database, system: system, server: server))
        self.onChanged = onChanged
    }

    var body: some View {
        List {
            infoSection
            if vm.isPostgreSQL {
                privilegesSection
            } else {
                accessSection
            }
            deleteSection
        }
        .navigationTitle(vm.database.name ?? "数据库")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showChangePassword) {
            ChangePasswordSheet(
                title: "修改密码",
                currentPassword: vm.database.password
            ) { newPwd in
                Task {
                    await vm.changePassword(newPwd)
                    await onChanged()
                }
            }
        }
        .sheet(isPresented: $showAccessSheet) {
            ChangeAccessSheet(database: vm.database) { value in
                Task {
                    await vm.changeAccess(value: value)
                    await onChanged()
                }
            }
        }
        .sheet(isPresented: $showPrivilegesSheet) {
            PGPrivilegesSheet(database: vm.database) { superUser in
                Task {
                    await vm.changePrivileges(superUser: superUser)
                    await onChanged()
                }
            }
        }
        .sheet(isPresented: $showDeleteSheet) {
            DeleteDatabaseSheet(database: vm.database) { forceDelete, deleteBackup in
                Task {
                    let ok = await vm.delete(forceDelete: forceDelete, deleteBackup: deleteBackup)
                    if ok {
                        await onChanged()
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: 基本信息

    private var infoSection: some View {
        Section {
            InfoRow(key: "名称", value: vm.database.name ?? "-")
            if let u = vm.database.username, !u.isEmpty {
                InfoRow(key: "用户名", value: u)
            }
            if let pwd = vm.database.password, !pwd.isEmpty {
                HStack {
                    Text("密码").foregroundStyle(.secondary)
                    Spacer()
                    Text(showPassword ? pwd : String(repeating: "•", count: min(pwd.count, 12)))
                        .font(.system(.subheadline, design: .monospaced))
                    Button { showPassword.toggle() } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye").foregroundStyle(.secondary)
                    }
                    Button { UIPasteboard.general.string = pwd } label: {
                        Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
                    }
                }
            }
            if let f = vm.database.format, !f.isEmpty {
                InfoRow(key: "字符集", value: f)
            }
            if let c = vm.database.collation, !c.isEmpty {
                InfoRow(key: "排序规则", value: c)
            }
            if let desc = vm.database.description, !desc.isEmpty {
                InfoRow(key: "备注", value: desc)
            }

            Button {
                showChangePassword = true
            } label: {
                Label("修改密码", systemImage: "key")
            }
        } header: {
            SectionLabel(title: "数据库信息", systemImage: "info.circle")
        }
    }

    // MARK: 访问权限 (MySQL)

    private var accessSection: some View {
        Section {
            InfoRow(key: "当前权限", value: vm.database.permissionDisplay)
            Button {
                showAccessSheet = true
            } label: {
                Label("修改访问权限", systemImage: "network")
            }
        } header: {
            SectionLabel(title: "访问权限", systemImage: "lock.shield")
        }
    }

    // MARK: 权限 (PostgreSQL - 超级用户)

    private var privilegesSection: some View {
        Section {
            if let u = vm.database.username, !u.isEmpty {
                InfoRow(key: "绑定用户", value: u)
            }
            InfoRow(key: "当前角色", value: vm.database.permissionDisplay)
            Button {
                showPrivilegesSheet = true
            } label: {
                Label("修改权限", systemImage: "person.badge.shield.checkmark")
            }
        } header: {
            SectionLabel(title: "权限", systemImage: "lock.shield")
        }
    }

    // MARK: 删除

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteSheet = true
            } label: {
                Label("删除数据库", systemImage: "trash")
            }
        }
    }
}

// MARK: - 删除确认 Sheet

struct DeleteDatabaseSheet: View {
    let database: DatabaseItem
    let onConfirm: (_ forceDelete: Bool, _ deleteBackup: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nameConfirm = ""
    @State private var forceDelete = false
    @State private var deleteBackup = false

    private var canDelete: Bool {
        nameConfirm.trimmingCharacters(in: .whitespaces) == (database.name ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("此操作不可恢复。请输入数据库名称「\(database.name ?? "")」以确认删除。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("确认名称") {
                    TextField("数据库名称", text: $nameConfirm)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("选项") {
                    Toggle("强制删除", isOn: $forceDelete)
                    Toggle("删除备份", isOn: $deleteBackup)
                }
            }
            .navigationTitle("删除数据库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("删除", role: .destructive) {
                        onConfirm(forceDelete, deleteBackup)
                        dismiss()
                    }
                    .disabled(!canDelete)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - 修改访问权限 Sheet

struct ChangeAccessSheet: View {
    let database: DatabaseItem
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: AccessMode = .all
    @State private var ipList = ""

    enum AccessMode: String, CaseIterable, Identifiable {
        case all = "所有人(%)"
        case ip = "指定IP"
        var id: String { rawValue }
    }

    init(database: DatabaseItem, onConfirm: @escaping (String) -> Void) {
        self.database = database
        self.onConfirm = onConfirm
        let perm = database.permission ?? ""
        let ips = database.permissionIPs ?? ""
        if perm == "%" || perm.isEmpty {
            if ips.isEmpty {
                _mode = State(initialValue: .all)
            } else {
                _mode = State(initialValue: .ip)
                _ipList = State(initialValue: ips)
            }
        } else {
            _mode = State(initialValue: .ip)
            _ipList = State(initialValue: ips.isEmpty ? perm : ips)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("访问权限") {
                    Picker("权限", selection: $mode) {
                        ForEach(AccessMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)

                    if mode == .ip {
                        TextField("IP 地址（逗号分隔）", text: $ipList, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...4)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(.body, design: .monospaced))
                        Text("多个 IP 用逗号分隔，如 192.168.1.100, 10.0.0.5")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("访问权限")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认") {
                        let value: String
                        if mode == .all {
                            value = "%"
                        } else {
                            value = ipList
                        }
                        onConfirm(value)
                        dismiss()
                    }
                    .disabled(mode == .ip && ipList.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - PostgreSQL 权限修改 Sheet（超级用户开关）

struct PGPrivilegesSheet: View {
    let database: DatabaseItem
    let onConfirm: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var superUser: Bool

    init(database: DatabaseItem, onConfirm: @escaping (Bool) -> Void) {
        self.database = database
        self.onConfirm = onConfirm
        _superUser = State(initialValue: database.isSuperUser)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("为用户「\(database.username ?? "-")」设置数据库权限。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("权限") {
                    Toggle("超级用户", isOn: $superUser)
                }
            }
            .navigationTitle("修改权限")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认") {
                        onConfirm(superUser)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.height(250)])
    }
}
