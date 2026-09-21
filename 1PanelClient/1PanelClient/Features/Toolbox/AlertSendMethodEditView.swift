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

    // Webhook（type == "custom"）
    @State private var webhook = AlertWebhookConfig()

    @State private var enabled = true
    /// 邮箱/Webhook 测试是否已通过（创建时必须测试通过才能保存；Webhook 编辑同样要求）
    @State private var tested = false
    /// Webhook 测试通过时的 config 快照：配置再改动即与快照不等，须重新测试才能保存
    @State private var testedConfig: AlertWebhookConfig?
    /// Webhook 测试通过时的摘要（HTTP 状态码 · 耗时）
    @State private var webhookTestSummary = ""
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var didFill = false

    private var isEditing: Bool { editing != nil }
    private var isEmail: Bool { sendType == .email }
    private var isWebhook: Bool { sendType == .custom }

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

    /// Webhook 必填项：名称 + 地址
    private var webhookFormValid: Bool {
        let name = (webhook.displayName ?? "").trimmingCharacters(in: .whitespaces)
        let url = (webhook.url?.value ?? "").trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && !url.isEmpty
    }

    /// 创建邮箱必须先测试通过；Webhook 创建/编辑均要求测试通过且配置未被再改动；
    /// 编辑邮箱与 Bark 可直接保存
    private var canSave: Bool {
        guard !isSaving else { return false }
        switch sendType {
        case .email:
            guard emailFormValid else { return false }
            if !isEditing && !tested { return false }
            return true
        case .bark:
            return barkFormValid
        case .custom:
            return webhookFormValid && tested && testedConfig == webhook
        }
    }

    /// Webhook 测试通过后配置是否又被改动（提示重新测试）
    private var webhookTestStale: Bool {
        tested && testedConfig != webhook
    }

    var body: some View {
        Form {
            typeSection
            switch sendType {
            case .email:
                emailSection
                testSection
            case .bark:
                barkSection
            case .custom:
                webhookSection
                webhookTestSection
            }
            if isEditing { statusSection }
        }
        .navigationTitle(isEditing ? L10n.t("编辑发送方式") : L10n.t("添加发送方式"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("保存")) {
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
        Section(L10n.t("类型")) {
            if isEditing {
                // 类型不可改：描边只读框 + 锁标识
                OutlinedShape(label: L10n.t("类型"), isFocused: false,
                              hasValue: true,
                              trailing: {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }) {
                    Text(AlertSendType(rawValue: editing?.type ?? "")?.displayName
                         ?? (editing?.type ?? L10n.t("未知")))
                        .lineLimit(1)
                }
            } else {
                OutlinedPicker(label: L10n.t("类型"),
                               options: AlertSendType.allCases,
                               selection: $sendType) { $0.displayName }
                    .onChange(of: sendType) { _, _ in
                        tested = false
                        testedConfig = nil
                    }
            }
        }
    }

    // MARK: - 邮箱配置

    private var emailSection: some View {
        Section {
            OutlinedTextField(label: L10n.t("显示名称"), text: $displayName)
            OutlinedTextField(label: L10n.t("发信地址"), text: $sender)
                .keyboardType(.emailAddress)
            OutlinedTextField(label: L10n.t("用户名"), text: $userName)
            OutlinedTextField(label: L10n.t("密码"), text: $password, isSecure: true)
            OutlinedTextField(label: L10n.t("SMTP 服务器"), text: $host, keyboardType: .URL)
            OutlinedTextField(label: L10n.t("端口号"), text: $portText, keyboardType: .numberPad)
            OutlinedPicker(label: L10n.t("加密方式"),
                           options: ["", "SSL", "TLS"], selection: $encryption,
                           optionLabels: ["": L10n.t("无")])
            OutlinedTextField(label: L10n.t("收件人"), text: $recipient)
                .keyboardType(.emailAddress)
        } header: {
            SectionLabel(title: L10n.t("邮箱通知"), systemImage: "envelope")
        } footer: {
            Text(L10n.t("保存前请先发送测试邮件确认配置可用"))
        }
    }

    private var testSection: some View {
        Section {
            Button {
                Task { await sendTest() }
            } label: {
                HStack {
                    Label(L10n.t("发送测试邮件"), systemImage: "paperplane")
                    if isTesting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isTesting || !emailFormValid)

            if tested {
                Label(L10n.t("测试已通过"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } footer: {
            Text(L10n.t("测试邮件将发送至收件人地址，请确认收到后再保存"))
        }
    }

    // MARK: - Bark 配置

    private var barkSection: some View {
        Section {
            OutlinedTextField(label: L10n.t("机器人名称"), text: $displayName)
            OutlinedTextField(label: L10n.t("Webhook 地址"), text: $barkURL, keyboardType: .URL)
        } header: {
            SectionLabel(title: "Bark", systemImage: "bell")
        } footer: {
            Text(L10n.t("Bark 的推送 Webhook 地址，形如 https://api.day.app/xxxxxx"))
        }
    }

    // MARK: - Webhook 配置

    /// Webhook 名称绑定（config.displayName 为可选字符串）
    private var webhookNameText: Binding<String> {
        Binding(get: { webhook.displayName ?? "" },
                set: { webhook.displayName = $0 })
    }

    /// Webhook 地址绑定（config.url 为对象，此处取/写 value）
    private var webhookURLText: Binding<String> {
        Binding(get: { webhook.url?.value ?? "" },
                set: { webhook.url = AlertWebhookURLValue(value: $0) })
    }

    private var webhookSection: some View {
        Section {
            OutlinedTextField(label: L10n.t("名称"), text: webhookNameText)
            OutlinedTextField(label: L10n.t("Webhook 地址"), text: webhookURLText,
                              keyboardType: .URL)

            NavigationLink {
                AlertWebhookBodyView(config: $webhook)
            } label: {
                HStack {
                    Text("Body")
                    Spacer()
                    Text("\(webhook.presetEnum.displayName) · \(webhook.bodyTypeEnum.displayName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            NavigationLink {
                AlertWebhookHeadersView(config: $webhook)
            } label: {
                HStack {
                    Text("Headers")
                    Spacer()
                    let count = webhook.headers?.count ?? 0
                    Text(count == 0 ? L10n.t("未设置") : L10n.f("%ld 条", count))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            SectionLabel(title: "Webhook", systemImage: "arrow.triangle.branch")
        } footer: {
            Text(L10n.t("必须测试通过后才能保存"))
        }
    }

    private var webhookTestSection: some View {
        Section {
            Button {
                Task { await sendWebhookTest() }
            } label: {
                HStack {
                    Label(L10n.t("发送测试请求"), systemImage: "paperplane")
                    if isTesting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isTesting || !webhookFormValid)

            if tested && !webhookTestStale {
                Label(
                    webhookTestSummary.isEmpty
                        ? L10n.t("测试已通过")
                        : L10n.f("测试已通过 · %@", webhookTestSummary),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            } else if tested {
                Label(L10n.t("配置已修改，请重新测试"), systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
        } footer: {
            Text(L10n.t("将向该地址发送一条测试告警，请求成功后才可保存"))
        }
    }

    /// 发送 Webhook 测试请求（POST /alert/config/test），通过后解锁保存；
    /// 通过时记录 config 快照，之后任何改动都会使保存重新失效
    private func sendWebhookTest() async {
        guard let configJSON = encodedWebhookConfig() else { return }
        isTesting = true
        let result = await vm.testWebhook(configJSON)
        isTesting = false
        guard let result else { return }
        tested = result.isPassed
        webhookTestSummary = result.isPassed ? result.summary : ""
        testedConfig = result.isPassed ? webhook : nil
    }

    /// 规范化并编码 Webhook config（提交与测试共用）
    private func encodedWebhookConfig() -> String? {
        guard let data = try? JSONEncoder().encode(webhook.sanitizedForSubmit),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    // MARK: - 状态（仅编辑）

    private var statusSection: some View {
        Section {
            Toggle(L10n.t("启用"), isOn: $enabled)
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
        } else if sendType == .bark {
            barkURL = cfg.url ?? ""
        } else if isWebhook, let parsed = item.webhookConfig {
            webhook = parsed
            if webhook.body == nil { webhook.body = AlertWebhookBody() }
            if webhook.headers == nil { webhook.headers = [] }
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
        let configJSON: String
        switch sendType {
        case .email:
            guard let port, emailFormValid else { return nil }
            let config = AlertSendConfig(
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
            guard let data = try? JSONEncoder().encode(config),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            configJSON = json
        case .bark:
            guard barkFormValid else { return nil }
            let config = AlertSendConfig(
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
            guard let data = try? JSONEncoder().encode(config),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            configJSON = json
        case .custom:
            guard webhookFormValid, let json = encodedWebhookConfig() else { return nil }
            configJSON = json
        }
        return AlertConfigUpdateRequest(
            id: editing?.id,
            type: sendType.rawValue,
            title: sendType.apiTitle,
            status: enabled ? "Enable" : "Disable",
            config: configJSON,
            displayName: sendType == .custom
                ? (webhook.displayName ?? "") : displayName
        )
    }
}
