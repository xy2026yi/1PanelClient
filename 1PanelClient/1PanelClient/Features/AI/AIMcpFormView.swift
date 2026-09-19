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

    /// 环境变量多行原文（每行一条 KEY=VALUE，形态 7.1；提交拆为 environments）
    @State private var envText = ""

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

    /// 向导分页：0 基础（名称/网关） 1 容器（容器/环境变量/挂载）
    @State private var wizardPage = 0
    private let wizardPageNames = [L10n.t("基础"), L10n.t("容器")]

    var body: some View {
        VStack(spacing: 0) {
            WizardStepsBar(pageNames: wizardPageNames, current: wizardPage)
            Form {
                Group {
                    switch wizardPage {
                    case 0:
                        baseSection
                        transportSection
                    default:
                        containerSection
                        envSection
                        volumeSection
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WizardBottomBar(
                page: wizardPage,
                totalPages: wizardPageNames.count,
                primaryTitle: isEditing ? L10n.t("保存") : L10n.t("创建"),
                isBusy: isSaving,
                primaryDisabled: !canSubmit,
                onBack: { withAnimation { wizardPage -= 1 } },
                onNext: { withAnimation { wizardPage += 1 } },
                onPrimary: { Task { await save() } }
            )
        }
        .animation(.easeInOut(duration: 0.22), value: wizardPage)
        .navigationTitle(isEditing ? L10n.t("编辑 MCP") : L10n.t("创建 MCP"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
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
            OutlinedTextField(label: L10n.t("名称"), text: $name)
                .disabled(isEditing)

            OutlinedPicker(label: L10n.t("类型"), options: types, selection: $type)

            OutlinedMultiLineField(label: L10n.t("启动命令"), prompt: "npx -y …",
                                   text: $command)
        } header: {
            SectionLabel(title: L10n.t("基本信息"), systemImage: "puzzlepiece")
        } footer: {
            Text(L10n.t("启动命令为 stdio 命令行，多个命令换行分隔"))
        }
    }

    private var transportSection: some View {
        Section {
            // 外部访问地址 = 协议 + 地址（两个描边字段，与反向代理一致）
            OutlinedPicker(label: L10n.t("协议"), options: ["http://", "https://"],
                           selection: $protocolScheme)
            OutlinedTextField(label: L10n.t("外部访问地址"), prompt: "host:port",
                              text: $urlHost, keyboardType: .URL)

            OutlinedPicker(label: L10n.t("输出类型"), options: transports,
                           selection: $outputTransport)

            if outputTransport == "sse" {
                OutlinedTextField(label: L10n.t("SSE 路径"), text: $pathField)
                    .font(.dataMonospacedCaption)
            } else {
                OutlinedTextField(label: L10n.t("流式传输路径"), text: $pathField)
                    .font(.dataMonospacedCaption)
                OutlinedTextField(label: L10n.t("协议版本"), text: $protocolVersion)
            }

            OutlinedTextField(label: L10n.t("参数"), text: $gatewayArgs)

            OutlinedTextField(label: L10n.t("镜像"), text: $gatewayImage)
                .font(.dataMonospacedCaption)
        } header: {
            SectionLabel(title: L10n.t("网关配置"), systemImage: "arrow.left.arrow.right.circle")
        } footer: {
            Text(L10n.t("访问地址与端口供客户端接入 MCP Server 使用"))
        }
    }

    private var containerSection: some View {
        Section {
            OutlinedTextField(label: L10n.t("容器名称"), text: $containerName)
            OutlinedTextField(label: L10n.t("端口"), text: $portField,
                              keyboardType: .numberPad)
            Toggle(L10n.t("端口外部访问"), isOn: $allowPort)
        } header: {
            SectionLabel(title: L10n.t("容器"), systemImage: "shippingbox")
        } footer: {
            Text(L10n.t("开启后 MCP 端口将对外开放（0.0.0.0）"))
        }
    }

    /// 环境变量（形态 7.1：每行一条 KEY=VALUE，默认 5 行自动增高）
    private var envSection: some View {
        Section {
            OutlinedMultiLineField(label: L10n.t("环境变量"), prompt: "KEY=VALUE",
                                   text: $envText)
        } header: {
            SectionLabel(title: L10n.t("环境变量"), systemImage: "gearshape.2")
        }
    }

    /// 挂载：宿主目录 → 容器目录（"host:container" 串提交）
    private var volumeSection: some View {
        Section {
            ForEach(volumes, id: \.self) { volume in
                Text(volume)
                    .font(.dataMonospacedCaption)
            }
            .onDelete { volumes.remove(atOffsets: $0) }

            HStack(spacing: 8) {
                OutlinedTextField(label: L10n.t("宿主机目录"), text: $newVolumeHost)
                    .font(.dataMonospacedCaption)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                OutlinedTextField(label: L10n.t("容器目录"), text: $newVolumeContainer)
                    .font(.dataMonospacedCaption)
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
        envText = (e.environments ?? []).map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
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

    /// 环境变量多行原文 → KEY=VALUE 数组（首个 = 分隔；无 = 视为仅有键）
    private var envItems: [AIKeyValueItem] {
        envText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                if let eq = line.firstIndex(of: "=") {
                    return AIKeyValueItem(
                        key: String(line[..<eq]),
                        value: String(line[line.index(after: eq)...]))
                }
                return AIKeyValueItem(key: line, value: "")
            }
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
            environments: envItems,
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
