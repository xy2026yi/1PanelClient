//
//  AlertSendMethodEditView.swift
//  1PanelClient
//
//  告警发送方式创建 / 编辑（邮箱通知：需测试通过后才能保存；Bark：名称 + Webhook）
//

import SwiftUI

struct AlertSendMethodEditView: View {
    @ObservedObject var vm: AlertViewModel
    /// 编辑模式时传入已有配置；创建模式传 nil
    let editing: AlertConfigItem?
    @Environment(\.dismiss) private var dismiss

    @State private var sendType: AlertSendType = .email

    // 邮箱
    @State private var displayName = ""
    @State private var sender = ""
    @State private var userName = ""
    @State private var password = ""
    @State private var host = ""
    @State private var portText = ""
    @State private var encryption = "SSL"
    @State private var recipient = ""

    // Bark
    @State private var barkURL = ""

    @State private var enabled = true
    /// 邮箱测试是否已通过（创建时必须测试通过才能保存）
    @State private var tested = false
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var didFill = false

    private var isEditing: Bool { editing != nil }
    private var isEmail: Bool { sendType == .email }

    /// 端口号（非法输入返回 nil）
    private var port: Int? { Int(portText) }

    /// 邮箱必填项是否齐全
    private var emailFormValid: Bool {
        !displayName.isEmpty && !sender.isEmpty && !host.isEmpty
            && port != nil && port! > 0 && !recipient.isEmpty
    }

    private var barkFormValid: Bool {
        !displayName.isEmpty && !barkURL.isEmpty
    }

    /// 创建邮箱必须先测试通过；编辑与 Bark 可直接保存
    private var canSave: Bool {
        guard !isSaving else { return false }
        if isEmail {
            guard emailFormValid else { return false }
            if !isEditing && !tested { return false }
            return true
        }
        return barkFormValid
    }

    var body: some View {
        Form {
            typeSection
            if isEmail {
                emailSection
                testSection
            } else {
                barkSection
            }
            if isEditing { statusSection }
        }
        .navigationTitle(isEditing ? "编辑发送方式" : "添加发送方式")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") {
                    if let req = buildRequest() {
                        Task {
                            isSaving = true
                            // 成功后自动返回列表，Toast 在列表页展示
                            if await vm.saveConfig(req) { dismiss() }
                            isSaving = false
                        }
                    }
                }
                .disabled(!canSave)
            }
        }
        .onAppear { fillIfEditing() }
    }

    // MARK: - 类型选择（仅创建时可改）

    private var typeSection: some View {
        Section("类型") {
            if isEditing {
                LabeledContent("类型", value: AlertSendType(rawValue: editing?.type ?? "")?.displayName ?? (editing?.type ?? "未知"))
            } else {
                Picker("类型", selection: $sendType) {
                    ForEach(AlertSendType.allCases) { t in
                        Label(t.displayName, systemImage: t.icon).tag(t)
                    }
                }
                .pickerStyle(.inline)
                .onChange(of: sendType) { _, _ in tested = false }
            }
        }
    }

    // MARK: - 邮箱配置

    private var emailSection: some View {
        Section {
            TextField("显示名称", text: $displayName)
            TextField("发信地址", text: $sender)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("用户名（可选）", text: $userName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("密码（可选）", text: $password)
            TextField("SMTP 服务器", text: $host)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("端口号", text: $portText)
                .keyboardType(.numberPad)
            Picker("加密方式", selection: $encryption) {
                Text("无").tag("")
                Text("SSL").tag("SSL")
                Text("TLS").tag("TLS")
            }
            TextField("收件人", text: $recipient)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            SectionLabel(title: "邮箱通知", systemImage: "envelope")
        } footer: {
            Text("保存前请先发送测试邮件确认配置可用")
        }
    }

    private var testSection: some View {
        Section {
            Button {
                Task { await sendTest() }
            } label: {
                HStack {
                    Label("发送测试邮件", systemImage: "paperplane")
                    if isTesting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isTesting || !emailFormValid)

            if tested {
                Label("测试已通过", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } footer: {
            Text("测试邮件将发送至收件人地址，请确认收到后再保存")
        }
    }

    // MARK: - Bark 配置

    private var barkSection: some View {
        Section {
            TextField("机器人名称", text: $displayName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Webhook 地址", text: $barkURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            SectionLabel(title: "Bark", systemImage: "bell")
        } footer: {
            Text("Bark 的推送 Webhook 地址，形如 https://api.day.app/xxxxxx")
        }
    }

    // MARK: - 状态（仅编辑）

    private var statusSection: some View {
        Section {
            Toggle("启用", isOn: $enabled)
        }
    }

    // MARK: - 编辑预填

    private func fillIfEditing() {
        guard let item = editing, !didFill else { return }
        didFill = true
        if let t = AlertSendType(rawValue: item.type ?? "") {
            sendType = t
        }
        let cfg = item.sendConfig
        displayName = cfg.displayName ?? ""
        userName = cfg.userName ?? ""
        password = cfg.password ?? ""
        host = cfg.host ?? ""
        portText = cfg.port.map { String($0) } ?? ""
        encryption = cfg.encryption ?? ""
        if isEmail {
            sender = cfg.sender ?? ""
            recipient = cfg.recipient ?? ""
        } else {
            barkURL = cfg.url ?? ""
        }
        enabled = item.isEnabled
    }

    // MARK: - 请求构造

    private func sendTest() async {
        guard let port else { return }
        isTesting = true
        let req = AlertEmailTestRequest(
            displayName: displayName,
            sender: sender,
            userName: userName,
            password: password,
            host: host,
            port: port,
            encryption: encryption,
            status: enabled ? "Enable" : "Disable",
            recipient: recipient
        )
        tested = await vm.testEmail(req)
        isTesting = false
    }

    private func buildRequest() -> AlertConfigUpdateRequest? {
        let config: AlertSendConfig
        switch sendType {
        case .email:
            guard let port, emailFormValid else { return nil }
            config = AlertSendConfig(
                displayName: displayName,
                sender: sender,
                userName: userName,
                password: password,
                host: host,
                port: port,
                encryption: encryption,
                status: enabled ? "Enable" : "Disable",
                recipient: recipient,
                url: nil
            )
        case .bark:
            guard barkFormValid else { return nil }
            config = AlertSendConfig(
                displayName: displayName,
                sender: nil,
                userName: nil,
                password: nil,
                host: nil,
                port: nil,
                encryption: nil,
                status: enabled ? "Enable" : "Disable",
                recipient: nil,
                url: barkURL
            )
        }
        guard let data = try? JSONEncoder().encode(config),
              let configJSON = String(data: data, encoding: .utf8) else { return nil }
        return AlertConfigUpdateRequest(
            id: editing?.id,
            type: sendType.rawValue,
            title: sendType.apiTitle,
            status: enabled ? "Enable" : "Disable",
            config: configJSON,
            displayName: displayName
        )
    }
}
