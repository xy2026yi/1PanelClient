//
//  AIMcpFormView.swift
//  1PanelClient
//
//  MCP Server 创建/编辑：类型（npx/uvx）/ 启动命令（多行）/ 外部访问地址（协议+地址）/
//  输出类型联动（SSE 路径 / 流式传输路径+协议版本）/ 环境变量 / 挂载；
//  编辑为全字段回传（含服务端生成的 compose 与时间戳）
//

import SwiftUI

struct AIMcpFormView: View {
    let server: ServerConfig
    let editing: McpServer?
    @ObservedObject var vm: AIMcpViewModel
    @Environment(\.dismiss) private var dismiss

    // MARK: 表单状态

    @State private var name = ""
    @State private var type = "npx"
    @State private var command = ""

    /// 外部访问地址：协议 + 主机地址（host[:port]，不含协议）
    @State private var protocolScheme = "http://"
    @State private var urlHost = ""

    @State private var outputTransport = "streamableHttp"
    @State private var pathField = ""
    @State private var protocolVersion = "2025-06-18"
    @State private var gatewayArgs = ""
    @State private var gatewayImage = "supercorp/supergateway:3.4.3"

    @State private var containerName = ""
    @State private var portField = "8000"
    @State private var allowPort = false

    @State private var environments: [AIKeyValueItem] = []
    @State private var newEnvKey = ""
    @State private var newEnvValue = ""

    @State private var volumes: [String] = []
    @State private var newVolumeHost = ""
    @State private var newVolumeContainer = ""

    @State private var isSaving = false
    @State private var showProgress = false
    @State private var activeTaskID = ""
    @State private var didFill = false

    private let transports = ["sse", "streamableHttp"]
    private let types = ["npx", "uvx"]

    private var isEditing: Bool { editing != nil }

    private var portValue: Int { Int(portField) ?? 0 }

    private var canSubmit: Bool {
        !name.isEmpty && !command.isEmpty && !urlHost.isEmpty
            && !pathField.isEmpty && !gatewayImage.isEmpty && portValue > 0 && !isSaving
    }

    var body: some View {
        Form {
            baseSection
            transportSection
            containerSection
            envSection
            volumeSection
        }
        .navigationTitle(isEditing ? L10n.t("编辑 MCP") : L10n.t("创建 MCP"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                }
                .disabled(!canSubmit)
            }
        }
        .task { fillIfEditing() }
        .onChange(of: name) { _, newValue in
            if !isEditing {
                containerName = newValue
                pathField = "/" + newValue
            }
        }
        .navigationDestination(isPresented: $showProgress) {
            TaskProgressView(taskID: activeTaskID, title: L10n.f("创建 %@", name)) { isDone in
                if isDone {
                    Task { await vm.load() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        dismiss()
                    }
                }
                return false
            }
        }
    }

    // MARK: - Sections

    private var baseSection: some View {
        Section {
            TextField(L10n.t("名称"), text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(isEditing)

            Picker(L10n.t("类型"), selection: $type) {
                ForEach(types, id: \.self) { Text($0).tag($0) }
            }

            TextEditor(text: $command)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 88)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            SectionLabel(title: L10n.t("基本信息"), systemImage: "puzzlepiece")
        } footer: {
            Text(L10n.t("启动命令为 stdio 命令行，多个命令换行分隔"))
        }
    }

    private var transportSection: some View {
        Section {
            // 协议前缀与地址同行，点击前缀切换 http/https
            HStack(spacing: 8) {
                Button {
                    protocolScheme = protocolScheme == "http://" ? "https://" : "http://"
                } label: {
                    Text(protocolScheme)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.t("切换协议"))

                TextField(L10n.t("外部访问地址"), text: $urlHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(.caption, design: .monospaced))
            }

            Picker(L10n.t("输出类型"), selection: $outputTransport) {
                ForEach(transports, id: \.self) { Text($0).tag($0) }
            }

            if outputTransport == "sse" {
                TextField(L10n.t("SSE 路径"), text: $pathField)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.caption, design: .monospaced))
            } else {
                TextField(L10n.t("流式传输路径"), text: $pathField)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.caption, design: .monospaced))
                TextField(L10n.t("协议版本"), text: $protocolVersion)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            TextField(L10n.t("参数"), text: $gatewayArgs)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            TextField(L10n.t("镜像"), text: $gatewayImage)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.caption, design: .monospaced))
        } header: {
            SectionLabel(title: L10n.t("网关配置"), systemImage: "arrow.left.arrow.right.circle")
        } footer: {
            Text(L10n.t("访问地址与端口供客户端接入 MCP Server 使用"))
        }
    }

    private var containerSection: some View {
        Section {
            TextField(L10n.t("容器名称"), text: $containerName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Text(L10n.t("端口")).foregroundStyle(.secondary)
                Spacer()
                TextField("8000", text: $portField)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
            }
            Toggle(L10n.t("端口外部访问"), isOn: $allowPort)
        } header: {
            SectionLabel(title: L10n.t("容器"), systemImage: "shippingbox")
        } footer: {
            Text(L10n.t("开启后 MCP 端口将对外开放（0.0.0.0）"))
        }
    }

    /// 环境变量：KEY/VALUE 成对添加（对齐 ContainerCreateView envSection 模式）
    private var envSection: some View {
        Section {
            ForEach(environments) { env in
                HStack {
                    Text(env.key)
                        .font(.system(.caption, design: .monospaced))
                    Spacer()
                    Text(env.value)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .onDelete { environments.remove(atOffsets: $0) }

            HStack(spacing: 8) {
                TextField("KEY", text: $newEnvKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.caption, design: .monospaced))
                Image(systemName: "arrow.left")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                TextField("VALUE", text: $newEnvValue)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.caption, design: .monospaced))
                Button {
                    addEnv()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(newEnvKey.isEmpty ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.borderless)
                .disabled(newEnvKey.isEmpty)
                .accessibilityLabel(L10n.t("添加"))
            }
        } header: {
            SectionLabel(title: L10n.t("环境变量"), systemImage: "gearshape.2")
        }
    }

    /// 挂载：宿主目录 → 容器目录（"host:container" 串提交）
    private var volumeSection: some View {
        Section {
            ForEach(volumes, id: \.self) { volume in
                Text(volume)
                    .font(.system(.caption, design: .monospaced))
            }
            .onDelete { volumes.remove(atOffsets: $0) }

            HStack(spacing: 8) {
                TextField(L10n.t("宿主机目录"), text: $newVolumeHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.caption, design: .monospaced))
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                TextField(L10n.t("容器目录"), text: $newVolumeContainer)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.caption, design: .monospaced))
                Button {
                    addVolume()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(newVolumeHost.isEmpty ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.borderless)
                .disabled(newVolumeHost.isEmpty)
                .accessibilityLabel(L10n.t("添加"))
            }
        } header: {
            SectionLabel(title: L10n.t("挂载"), systemImage: "externaldrive")
        }
    }

    // MARK: - 编辑回填

    private func fillIfEditing() {
        guard !didFill else { return }
        didFill = true
        guard let e = editing else { return }
        name = e.name
        type = e.type ?? "npx"
        command = e.command ?? ""
        outputTransport = e.outputTransport ?? "streamableHttp"
        pathField = (e.outputTransport == "sse") ? (e.ssePath ?? "") : (e.streamableHttpPath ?? "")
        protocolVersion = e.protocolVersion ?? "2025-06-18"
        gatewayArgs = e.gatewayArgs ?? ""
        gatewayImage = e.gatewayImage ?? "supercorp/supergateway:3.4.3"
        containerName = e.containerName ?? e.name
        portField = String(e.port ?? 8000)
        environments = e.environments ?? []
        volumes = e.volumes ?? []
        allowPort = !(e.hostIP ?? "").isEmpty

        // baseUrl 拆回协议 + 地址
        let base = e.baseUrl ?? ""
        if base.hasPrefix("https://") {
            protocolScheme = "https://"
            urlHost = String(base.dropFirst("https://".count))
        } else {
            protocolScheme = "http://"
            urlHost = base.hasPrefix("http://") ? String(base.dropFirst("http://".count)) : base
        }
    }

    private func addEnv() {
        let key = newEnvKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        environments.removeAll { $0.key == key }
        environments.append(AIKeyValueItem(key: key, value: newEnvValue))
        newEnvKey = ""
        newEnvValue = ""
    }

    private func addVolume() {
        let host = newVolumeHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        let container = newVolumeContainer.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = container.isEmpty ? host : "\(host):\(container)"
        guard !volumes.contains(entry) else { return }
        volumes.append(entry)
        newVolumeHost = ""
        newVolumeContainer = ""
    }

    // MARK: - 保存

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let taskID = UUID().uuidString
        let activePath = pathField.hasPrefix("/") ? pathField : "/" + pathField
        let req = McpServerUpsertRequest(
            id: editing?.id ?? 0,
            createdAt: editing?.createdAt ?? "",
            updatedAt: editing?.updatedAt ?? "",
            name: name,
            dockerCompose: editing?.dockerCompose ?? "",
            command: command,
            containerName: containerName.isEmpty ? name : containerName,
            message: editing?.message ?? "",
            port: portValue,
            status: editing?.status ?? "",
            env: editing?.env ?? "",
            baseUrl: protocolScheme + urlHost,
            ssePath: activePath,
            websiteID: editing?.websiteID ?? 0,
            dir: editing?.dir ?? "",
            hostIP: allowPort ? "0.0.0.0" : "",
            streamableHttpPath: activePath,
            outputTransport: outputTransport,
            type: type,
            gatewayImage: gatewayImage,
            protocolVersion: protocolVersion,
            gatewayArgs: gatewayArgs,
            environments: environments,
            volumes: volumes,
            protocolScheme: protocolScheme,
            urlHost: urlHost,
            taskID: taskID
        )

        do {
            let _: EmptyResponse = try await vm.client.send(
                path: isEditing ? APIEndpoint.aiMcpServerUpdate.path : APIEndpoint.aiMcpServerCreate.path,
                body: req,
                as: EmptyResponse.self)
            if isEditing {
                vm.toastMessage = L10n.t("已保存")
                await vm.load()
                dismiss()
            } else {
                activeTaskID = taskID
                showProgress = true
            }
        } catch {
            guard !APIError.isCancellation(error) else { return }
            vm.alertMessage = L10n.f("保存失败：%@", error.localizedDescription)
            vm.showAlert = true
        }
    }
}
