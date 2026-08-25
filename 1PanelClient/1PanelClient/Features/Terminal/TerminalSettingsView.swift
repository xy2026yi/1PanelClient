//
//  TerminalSettingsView.swift
//  1PanelClient
//
//  终端设置：默认连接开关（含重置连接信息确认）+ 连接信息编辑（测试 / 保存）
//  基于 doc/终端-1.md 抓包（settings/ssh*）
//

import SwiftUI
import Combine

struct TerminalSettingsView: View {
    @StateObject private var vm: TerminalSettingsViewModel

    init(server: ServerConfig) {
        _vm = StateObject(wrappedValue: TerminalSettingsViewModel(server: server))
    }

    /// 待确认的默认连接变更（nil=无待确认）
    @State private var pendingDefaultChange: Bool?

    var body: some View {
        Group {
            if vm.isLoading && vm.conn == nil {
                LoadingStateView()
            } else if let err = vm.errorMessage, vm.conn == nil {
                LoadErrorStateView(message: err) {
                    Task { await vm.load() }
                }
            } else {
                settingsList
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("设置"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .sheet(item: $vm.pendingConnEdit) { conn in
            TerminalSSHConnEditView(vm: vm, existing: conn)
        }
        // 默认连接确认（自定义 sheet：关闭场景带「重置连接信息」勾选）
        .sheet(isPresented: Binding(
            get: { pendingDefaultChange != nil },
            set: { if !$0 { pendingDefaultChange = nil } }
        )) {
            if let target = pendingDefaultChange {
                DefaultConnConfirmSheet(target: target) { reset in
                    pendingDefaultChange = nil
                    Task { await vm.updateDefaultConn(enabled: target, withReset: reset) }
                }
            }
        }
        .task { await vm.load() }
        .refreshable { await vm.load() }
    }

    private var settingsList: some View {
        List {
            defaultConnSection
            connInfoSection
        }
    }

    // MARK: - 默认连接

    private var defaultConnSection: some View {
        Section {
            Toggle(L10n.t("默认连接"), isOn: Binding(
                get: { vm.conn?.isDefaultConnEnabled ?? false },
                set: { newValue in
                    // 拨动先弹确认，确认后才真正提交；取消则由 Toggle 状态回弹
                    pendingDefaultChange = newValue
                }
            ))
            .disabled(vm.conn == nil)
        } header: {
            Text(L10n.t("默认连接"))
        } footer: {
            Text(L10n.t("开启后进入终端页将自动连接所在节点终端"))
        }
    }

    // MARK: - 连接信息

    private var connInfoSection: some View {
        Section {
            Button {
                if let conn = vm.conn {
                    vm.pendingConnEdit = conn
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.t("连接信息"))
                            .foregroundStyle(.primary)
                        Text("\(vm.conn?.user ?? "—")@\(vm.conn?.addr ?? "—")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(L10n.t("设置"))
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
            .buttonStyle(.plain)
            .disabled(vm.conn == nil)
        } header: {
            Text(L10n.t("连接信息"))
        } footer: {
            Text(L10n.t("本机终端自动连接使用的 SSH 地址与认证方式"))
        }
    }
}

// MARK: - 默认连接确认弹窗

/// 默认连接开关确认：开启/关闭文案不同，关闭时可勾选「重置连接信息」
struct DefaultConnConfirmSheet: View {
    /// 目标状态：true=即将开启，false=即将关闭
    let target: Bool
    let onConfirm: (_ reset: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var resetConn = false

    var body: some View {
        VStack(spacing: 16) {
            Text(L10n.t("默认连接"))
                .font(.headline)
                .padding(.top, 20)

            Text(target
                 ? L10n.t("该操作将【允许】打开终端后自动连接所在节点终端，是否继续？")
                 : L10n.t("该操作将【禁止】打开终端后自动连接所在节点终端，是否继续？"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            if !target {
                Toggle(L10n.t("重置连接信息"), isOn: $resetConn)
                    .padding(.horizontal, 20)
            }

            VStack(spacing: 0) {
                Button {
                    onConfirm(resetConn)
                } label: {
                    Text(L10n.t("确认"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                Button(L10n.t("取消")) { dismiss() }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .bottomSheetDetents([.medium])
        .presentationDragIndicator(.hidden)
    }
}

// MARK: - 连接信息编辑表单

struct TerminalSSHConnEditView: View {
    @ObservedObject var vm: TerminalSettingsViewModel
    let existing: TerminalSSHConn
    @Environment(\.dismiss) private var dismiss

    @State private var addr = ""
    @State private var portText = "22"
    @State private var user = ""
    @State private var authMode = "password"
    @State private var password = ""
    @State private var privateKey = ""
    @State private var passPhrase = ""
    @State private var tested = false
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var didFill = false

    private var isKeyAuth: Bool { authMode == "key" }
    private var port: Int? { Int(portText) }

    private var formValid: Bool {
        guard !addr.isEmpty, !user.isEmpty, let port, port > 0 else { return false }
        if isKeyAuth {
            return !privateKey.isEmpty
        }
        // 密码不回显：已有服务端凭据（base64 非空）即视为有效，
        // buildRequest 会把原值回传，改地址/端口无需重输密码
        return !password.isEmpty || (existing.password?.isEmpty == false)
    }

    private var canSave: Bool { formValid && tested && !isSaving }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.t("主机地址"), text: $addr)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L10n.t("端口"), text: $portText)
                        .keyboardType(.numberPad)
                    TextField(L10n.t("用户名"), text: $user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(L10n.t("基本信息"))
                }

                Section {
                    Picker(L10n.t("认证方式"), selection: $authMode) {
                        Text(L10n.t("密码认证")).tag("password")
                        Text(L10n.t("私钥认证")).tag("key")
                    }
                    .pickerStyle(.segmented)

                    if isKeyAuth {
                        TextEditor(text: $privateKey)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 100)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .overlay(alignment: .topLeading) {
                                if privateKey.isEmpty {
                                    Text(L10n.t("私钥（粘贴 OPENSSH PRIVATE KEY）"))
                                        .font(.footnote)
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 8)
                                        .padding(.leading, 4)
                                        .allowsHitTesting(false)
                                }
                            }
                        SecureField(L10n.t("私钥密码（可选）"), text: $passPhrase)
                    } else {
                        SecureField(L10n.t("密码"), text: $password)
                    }
                } header: {
                    Text(L10n.t("认证"))
                }

                testSection
            }
            .navigationTitle(L10n.t("连接信息"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("确认")) {
                        Task {
                            guard let req = buildRequest() else { return }
                            isSaving = true
                            if await vm.saveConn(req) {
                                dismiss()
                            }
                            isSaving = false
                        }
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear { fillIfEditing() }
            // 测试结果只对测试时的表单内容有效：任一字段改动后需重新测试才能保存
            .onChange(of: authMode) { _, _ in tested = false }
            .onChange(of: addr) { _, _ in tested = false }
            .onChange(of: portText) { _, _ in tested = false }
            .onChange(of: user) { _, _ in tested = false }
            .onChange(of: password) { _, _ in tested = false }
            .onChange(of: privateKey) { _, _ in tested = false }
            .onChange(of: passPhrase) { _, _ in tested = false }
        }
        .bottomSheetDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - 连接测试

    private var testSection: some View {
        Section {
            Button {
                Task {
                    guard let req = buildRequest() else { return }
                    isTesting = true
                    tested = await vm.testConn(req)
                    isTesting = false
                }
            } label: {
                HStack {
                    Label(L10n.t("连接测试"), systemImage: "dot.radiowaves.left.and.right")
                    if isTesting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isTesting || !formValid)

            if tested {
                Label(L10n.t("测试已通过"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } footer: {
            Text(L10n.t("保存前需连接测试通过"))
        }
    }

    // MARK: - 预填 / 请求

    private func fillIfEditing() {
        guard !didFill else { return }
        didFill = true
        addr = existing.addr ?? ""
        portText = existing.port.map { String($0) } ?? "22"
        user = existing.user ?? ""
        authMode = existing.authMode ?? "password"
        // 私钥回显服务端 base64 解码后的明文；密码不回显（服务端也不下发）
        if let key = existing.privateKey,
           let data = Data(base64Encoded: key),
           let decoded = String(data: data, encoding: .utf8) {
            privateKey = decoded
        }
    }

    /// 凭据字段：新输入为明文 base64；未修改时回传服务端原 base64 值
    private func buildRequest() -> TerminalSSHConnUpdateRequest? {
        guard let port, formValid else { return nil }
        return TerminalSSHConnUpdateRequest(
            user: user,
            addr: addr,
            port: port,
            authMode: authMode,
            password: password.isEmpty
                ? (existing.password ?? "")
                : Data(password.utf8).base64EncodedString(),
            privateKey: privateKey.isEmpty
                ? (existing.privateKey ?? "")
                : Data(privateKey.utf8).base64EncodedString(),
            passPhrase: passPhrase.isEmpty
                ? (existing.passPhrase ?? "")
                : Data(passPhrase.utf8).base64EncodedString()
        )
    }
}

// MARK: - ViewModel

@MainActor
final class TerminalSettingsViewModel: ObservableObject {
    @Published var conn: TerminalSSHConn?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var toastMessage: String?
    /// 打开连接信息编辑表单
    @Published var pendingConnEdit: TerminalSSHConn?

    private let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            conn = try await client.send(
                path: APIEndpoint.settingsSSHConn.path,
                method: APIEndpoint.settingsSSHConn.method,
                as: TerminalSSHConn.self
            )
            errorMessage = nil
        } catch let err as APIError {
            errorMessage = err.errorDescription ?? L10n.t("未知错误")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 默认连接开关：POST /settings/ssh/default
    func updateDefaultConn(enabled: Bool, withReset: Bool) async {
        let req = TerminalSSHDefaultRequest(
            withReset: withReset,
            defaultConn: enabled ? "Enable" : "Disable"
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.settingsSSHDefault.path,
                body: req,
                as: EmptyResponse.self
            )
            showToast(enabled ? L10n.t("已开启默认连接") : L10n.t("已关闭默认连接"))
            await load()
        } catch let err as APIError {
            showAlert(message: L10n.f("操作失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            await load()  // 失败回弹开关状态
        } catch {
            showAlert(message: L10n.f("操作失败：%@", error.localizedDescription))
            await load()
        }
    }

    /// 连接信息测试：POST /settings/ssh/check/info（data=true/false）
    @discardableResult
    func testConn(_ req: TerminalSSHConnUpdateRequest) async -> Bool {
        do {
            let ok: Bool = try await client.send(
                path: APIEndpoint.settingsSSHCheckInfo.path,
                body: req,
                as: Bool.self
            )
            if !ok {
                showAlert(message: L10n.t("连接测试未通过，请检查地址、端口与认证信息"))
            } else {
                showToast(L10n.t("连接测试通过"))
            }
            return ok
        } catch let err as APIError {
            showAlert(message: L10n.f("测试失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("测试失败：%@", error.localizedDescription))
            return false
        }
    }

    /// 保存连接信息：POST /settings/ssh
    @discardableResult
    func saveConn(_ req: TerminalSSHConnUpdateRequest) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.settingsSSHSave.path,
                body: req,
                as: EmptyResponse.self
            )
            showToast(L10n.t("连接信息已保存"))
            await load()
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("保存失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("保存失败：%@", error.localizedDescription))
            return false
        }
    }

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { self?.toastMessage = nil }
        }
    }
}
