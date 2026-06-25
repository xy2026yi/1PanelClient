//
//  DatabaseDetailView.swift
//  1PanelClient
//
//  单个数据库详情：连接信息 / 改密码 / 改权限 / 删除
//

import SwiftUI

@MainActor
final class DatabaseDetailViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var isOperating = false
    @Published var errorMessage: String?

    let database: DatabaseItem
    let system: DatabaseSystem
    private let client: APIClient

    init(database: DatabaseItem, system: DatabaseSystem, server: ServerConfig) {
        self.database = database
        self.system = system
        self.client = APIClient(server: server)
    }

    func changePassword(_ password: String) async {
        isOperating = true
        defer { isOperating = false }
        let value = Data(password.utf8).base64EncodedString()
        let req = ChangePasswordRequest(
            id: database.id, from: database.from ?? "local",
            type: system.type, database: system.database, value: value
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.databasesChangePassword.path, body: req, as: EmptyResponse.self
            )
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
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(forceDelete: Bool, deleteBackup: Bool) async -> Bool {
        let req = DelDBRequest(
            id: database.id, type: system.type,
            database: system.database, deleteBackup: deleteBackup, forceDelete: forceDelete
        )
        do {
            let _: EmptyResponse? = try await client.send(
                path: APIEndpoint.databasesDelCheck.path, body: req, as: EmptyResponse?.self
            )
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.databasesDel.path, body: req, as: EmptyResponse.self
            )
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
    @State private var showDeleteAlert = false
    @State private var deleteNameConfirm = ""
    @State private var forceDelete = false
    @State private var deleteBackup = false

    let onDeleted: () async -> Void

    init(database: DatabaseItem, system: DatabaseSystem, onDeleted: @escaping () async -> Void) {
        let server = ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: DatabaseDetailViewModel(database: database, system: system, server: server))
        self.onDeleted = onDeleted
    }

    var body: some View {
        List {
            infoSection
            accessSection
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
                    await onDeleted()
                }
            }
        }
        .sheet(isPresented: $showAccessSheet) {
            ChangeAccessSheet(database: vm.database) { value in
                Task {
                    await vm.changeAccess(value: value)
                    await onDeleted()
                }
            }
        }
        .alert("删除数据库", isPresented: $showDeleteAlert) {
            TextField("请输入数据库名称", text: $deleteNameConfirm)
                .textInputAutocapitalization(.never)
            Toggle("强制删除", isOn: $forceDelete)
            Toggle("删除备份", isOn: $deleteBackup)
            Button("取消", role: .cancel) {}
            Button("确认删除", role: .destructive) {
                Task {
                    let ok = await vm.delete(forceDelete: forceDelete, deleteBackup: deleteBackup)
                    if ok {
                        await onDeleted()
                        dismiss()
                    }
                }
            }
            .disabled(deleteNameConfirm != (vm.database.name ?? ""))
        } message: {
            Text("此操作不可恢复，请输入「\(vm.database.name ?? "")」确认删除。")
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

    // MARK: 访问权限

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

    // MARK: 删除

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                deleteNameConfirm = ""
                forceDelete = false
                deleteBackup = false
                showDeleteAlert = true
            } label: {
                Label("删除数据库", systemImage: "trash")
            }
        }
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
