//
//  CreateDatabaseView.swift
//  1PanelClient
//
//  创建数据库：名称 / 用户名 / 密码 / 字符集 / 排序规则 / 权限 / 备注
//

import SwiftUI
import Combine

@MainActor
final class CreateDatabaseViewModel: ObservableObject {
    @Published var formats: [FormatOption] = []
    @Published var isLoading = false
    @Published var isCreating = false
    @Published var errorMessage: String?

    let system: DatabaseSystem
    private let client: APIClient

    init(system: DatabaseSystem, server: ServerConfig) {
        self.system = system
        self.client = APIClient(server: server)
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

    func create(
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
    @State private var permissionMode: PermissionMode = .all
    @State private var permissionIPs = ""
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

    private var availableCollations: [String] {
        vm.formats.first { $0.format == selectedFormat }?.collations ?? []
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty &&
        (permissionMode == .all || !permissionIPs.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("数据库名称", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    passwordRow
                }

                Section("字符集") {
                    if vm.formats.isEmpty {
                        if vm.isLoading { HStack { ProgressView(); Text("加载中…") } }
                        else { Text("无法加载字符集选项").foregroundStyle(.secondary) }
                    } else {
                        Picker("字符集", selection: $selectedFormat) {
                            ForEach(vm.formats) { f in
                                Text(f.format).tag(f.format)
                            }
                        }
                        .onChange(of: selectedFormat) { _, _ in
                            selectedCollation = ""
                        }

                        if !availableCollations.isEmpty {
                            Picker("排序规则", selection: $selectedCollation) {
                                Text("默认").tag("")
                                ForEach(availableCollations, id: \.self) { c in
                                    Text(c).tag(c)
                                }
                            }
                        }
                    }
                }

                Section("访问权限") {
                    Picker("权限", selection: $permissionMode) {
                        ForEach(PermissionMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)

                    if permissionMode == .ip {
                        TextField("IP 地址（逗号分隔）", text: $permissionIPs, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...4)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(.body, design: .monospaced))
                    }
                }

                Section("备注") {
                    TextField("可选备注", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }

                if let msg = vm.errorMessage {
                    Section {
                        Text(msg).foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle("创建数据库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        Task { await submit() }
                    }
                    .disabled(!canCreate || vm.isCreating)
                }
            }
            .task {
                if vm.formats.isEmpty { await vm.loadFormats() }
            }
        }
    }

    private var passwordRow: some View {
        HStack {
            if showPassword {
                TextField("密码", text: $password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
            } else {
                SecureField("密码", text: $password)
            }
            Button { showPassword.toggle() } label: {
                Image(systemName: showPassword ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            Button {
                password = randomPassword()
            } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func submit() async {
        let perm: String
        let ips: String
        if permissionMode == .all {
            perm = "%"
            ips = ""
        } else {
            perm = "%"
            ips = permissionIPs
        }
        let ok = await vm.create(
            name: name.trimmingCharacters(in: .whitespaces),
            username: username.trimmingCharacters(in: .whitespaces),
            password: password,
            format: selectedFormat,
            collation: selectedCollation,
            permission: perm,
            permissionIPs: ips,
            description: description
        )
        if ok {
            await onCreated()
            dismiss()
        }
    }

    private func randomPassword() -> String {
        let chars = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<16).map { _ in chars.randomElement()! })
    }
}
