//
//  SSHView.swift
//  1PanelClient
//
//  SSH 管理：服务操作 / 基础配置 / 完整配置编辑
//

import SwiftUI
import Combine

// MARK: - 数据模型

struct SSHConfig: Decodable {
    let autoStart: Bool
    let isExist: Bool
    let isActive: Bool
    let port: String
    let listenAddress: String
    let passwordAuthentication: String
    let pubkeyAuthentication: String
    let permitRootLogin: String
    let useDNS: String
}

struct SSHOperateRequest: Encodable {
    let operation: String
}

struct SSHUpdateRequest: Encodable {
    let key: String
    let oldValue: String
    let newValue: String
}

struct SSHFileRequest: Encodable {
    let name: String
}

struct SSHFileUpdateRequest: Encodable {
    let key: String
    let value: String
}

// MARK: - ViewModel

@MainActor
final class SSHViewModel: ObservableObject {
    @Published var config: SSHConfig?
    @Published var isLoading = true
    @Published var isOperating = false
    @Published var errorMessage: String?
    @Published var successMessage: String?

    private let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    func loadConfig() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let resp: SSHConfig = try await client.send(path: APIEndpoint.sshSearch.path, body: EmptyBody(), as: SSHConfig.self)
            config = resp
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func operate(_ operation: String) async {
        isOperating = true
        defer { isOperating = false }
        let req = SSHOperateRequest(operation: operation)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.sshOperate.path, body: req, as: EmptyResponse.self)
            successMessage = "操作成功"
            await loadConfig()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func update(key: String, oldValue: String, newValue: String) async {
        isOperating = true
        defer { isOperating = false }
        let req = SSHUpdateRequest(key: key, oldValue: oldValue, newValue: newValue)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.sshUpdate.path, body: req, as: EmptyResponse.self)
            successMessage = "配置已更新"
            await loadConfig()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct EmptyBody: Encodable {}

// MARK: - SSH 主视图

struct SSHView: View {
    @StateObject private var vm: SSHViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isServiceExpanded = false
    @State private var editingField: SSHField?
    @State private var pendingAction: String?

    enum SSHField: Identifiable {
        case port, listenAddress
        var id: Self { self }
    }

    init(server: ServerConfig) {
        _vm = StateObject(wrappedValue: SSHViewModel(server: server))
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.config == nil {
                ProgressView("加载中…")
            } else if let config = vm.config {
                content(config: config)
            } else if let err = vm.errorMessage {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button("重试") { Task { await vm.loadConfig() } }
                }
            }
        }
        .navigationTitle("SSH")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.loadConfig() }
        .task { await vm.loadConfig() }
        .alert("提示", isPresented: Binding(
            get: { vm.successMessage != nil || vm.errorMessage != nil },
            set: { _ in vm.successMessage = nil; vm.errorMessage = nil }
        )) {
            Button("好的") { vm.successMessage = nil; vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? vm.successMessage ?? "")
        }
        .alert(
            pendingAction.map { sshActionDisplayName($0) } ?? "",
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
                Text("将对 SSH 进行 \(sshActionDisplayName(action)) 操作，是否继续？")
            }
        }
        .sheet(item: $editingField) { field in
            switch field {
            case .port:
                SSHFieldSheet(title: "连接端口", value: vm.config?.port ?? "22", placeholder: "22") { newVal in
                    Task { await vm.update(key: "Port", oldValue: vm.config?.port ?? "", newValue: newVal) }
                }
            case .listenAddress:
                SSHFieldSheet(title: "监听地址", value: vm.config?.listenAddress ?? "", placeholder: "0.0.0.0,::") { newVal in
                    Task { await vm.update(key: "ListenAddress", oldValue: vm.config?.listenAddress ?? "", newValue: newVal) }
                }
            }
        }
    }

    private func sshActionDisplayName(_ action: String) -> String {
        switch action {
        case "stop":    return "停止"
        case "start":   return "启动"
        case "restart": return "重启"
        case "enable":  return "开启自启"
        case "disable": return "关闭自启"
        default:        return action
        }
    }

    @ViewBuilder
    private func content(config: SSHConfig) -> some View {
        List {
            // 服务管理
            ServiceStatusCard(
                title: "SSH",
                statusText: config.isActive ? "运行中" : "已停止",
                statusColor: config.isActive ? .green : .red,
                isOperating: vm.isOperating,
                isExpanded: $isServiceExpanded,
                actions: [
                    ServiceAction(
                        title: config.isActive ? "停止" : "启动",
                        icon: config.isActive ? "stop.fill" : "play.fill",
                        color: config.isActive ? .orange : .green
                    ) { pendingAction = config.isActive ? "stop" : "start" },
                    ServiceAction(title: "重启", icon: "arrow.triangle.2.circlepath", color: .blue) {
                        pendingAction = "restart"
                    }
                ]
            ) {
                IconBadge(systemName: "terminal", color: .blue, size: 44)
            } extra: {
                Toggle("开机自启", isOn: Binding(
                    get: { config.autoStart },
                    set: { newVal in
                        pendingAction = newVal ? "enable" : "disable"
                    }
                ))
                .disabled(vm.isOperating)
            }

            // 基础配置
            Section {
                Button { editingField = .port } label: {
                    HStack {
                        Text("连接端口")
                        Spacer()
                        Text(config.port)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { editingField = .listenAddress } label: {
                    HStack {
                        Text("监听地址")
                        Spacer()
                        Text(config.listenAddress.isEmpty ? "默认" : config.listenAddress)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Picker("root 用户", selection: Binding(
                    get: { config.permitRootLogin },
                    set: { newVal in
                        Task { await vm.update(key: "PermitRootLogin", oldValue: config.permitRootLogin, newValue: newVal) }
                    }
                )) {
                    Text("允许 SSH 登陆").tag("yes")
                    Text("禁止 SSH 登陆").tag("no")
                    Text("仅允许密钥登陆").tag("without-password")
                    Text("仅允许预定义命令").tag("forced-commands-only")
                }
                .disabled(vm.isOperating)

                Toggle("密码认证", isOn: Binding(
                    get: { config.passwordAuthentication == "yes" },
                    set: { newVal in
                        Task { await vm.update(key: "PasswordAuthentication", oldValue: config.passwordAuthentication, newValue: newVal ? "yes" : "no") }
                    }
                ))
                .disabled(vm.isOperating)

                Toggle("密钥认证", isOn: Binding(
                    get: { config.pubkeyAuthentication == "yes" },
                    set: { newVal in
                        Task { await vm.update(key: "PubkeyAuthentication", oldValue: config.pubkeyAuthentication, newValue: newVal ? "yes" : "no") }
                    }
                ))
                .disabled(vm.isOperating)

                Toggle("反向解析", isOn: Binding(
                    get: { config.useDNS == "yes" },
                    set: { newVal in
                        Task { await vm.update(key: "UseDNS", oldValue: config.useDNS, newValue: newVal ? "yes" : "no") }
                    }
                ))
                .disabled(vm.isOperating)
            } header: {
                SectionLabel(title: "基础配置", systemImage: "slider.horizontal.3")
            }

            // 全部配置
            Section {
                NavigationLink {
                    SSHFullConfigView(server: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
                } label: {
                    Label("全部配置", systemImage: "doc.text")
                }
            }
        }
    }
}

// MARK: - 字段编辑 Sheet

struct SSHFieldSheet: View {
    let title: String
    let value: String
    let placeholder: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var input = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(title) {
                    TextField(placeholder, text: $input)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(title == "连接端口" ? .numberPad : .default)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { input = value }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(input)
                        dismiss()
                    }
                    .disabled(input == value)
                }
            }
        }
        .presentationDetents([.height(200)])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - SSH 完整配置编辑

struct SSHFullConfigView: View {
    let server: ServerConfig

    @State private var configText = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var successMessage: String?
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient(server: server)
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("加载中…")
            } else {
                TextEditor(text: $configText)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }
        .navigationTitle("sshd_config")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") {
                    Task { await save() }
                }
                .disabled(isSaving || isLoading)
            }
        }
        .task { await loadConfig() }
        .alert("提示", isPresented: Binding(
            get: { successMessage != nil || errorMessage != nil },
            set: { _ in successMessage = nil; errorMessage = nil }
        )) {
            Button("好的") { successMessage = nil; errorMessage = nil }
        } message: {
            Text(errorMessage ?? successMessage ?? "")
        }
    }

    private func loadConfig() async {
        isLoading = true
        let req = SSHFileRequest(name: "sshdConf")
        do {
            let resp: String = try await client.send(path: APIEndpoint.sshFile.path, body: req, as: String.self)
            configText = resp
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        isSaving = true
        let req = SSHFileUpdateRequest(key: "sshdConf", value: configText)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.sshFileUpdate.path, body: req, as: EmptyResponse.self)
            successMessage = "已保存"
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}
