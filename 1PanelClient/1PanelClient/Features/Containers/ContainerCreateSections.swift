//
//  ContainerCreateSections.swift
//  1PanelClient
//
//  创建/编辑容器共用的向导表单与子页面（依据用户 0919 需求 + 抓包）：
//  ContainerWizardForm（三页：基础 / 端口存储 / 高级，draft 为唯一数据源）、
//  镜像选择页（点击回填）、端口编辑页、挂载编辑页（卷下拉 + 传播模式提示）。
//
//  创建：ContainerCreateView 从空草稿开始；
//  编辑：ContainerEditView 由 /containers/info 回填同结构草稿，两表单永续一致。
//

import SwiftUI

// MARK: - 创建/编辑共用向导表单

/// 三页向导：基础（名称/镜像/网络）→ 端口存储（端口/挂载/环境变量/标签）→ 高级（默认收起）。
/// 高级页字段顺序：策略 → 命令 → 端点 → 资源限制分组 → 用户 → 工作目录 → 高级分组。
/// nameEditable=false（编辑流）时名称行为只读展示：接口按原名称重建容器，不可改名
struct ContainerWizardForm: View {
    @Binding var draft: ContainerCreateDraft
    @ObservedObject var vm: ContainersViewModel
    @Binding var wizardPage: Int
    @Binding var advancedEnabled: Bool
    var nameEditable = true
    /// 最后页主操作文案（创建 / 保存）
    let primaryTitle: String
    var isBusy = false
    /// 最后页主操作禁用（创建：名称或镜像为空；编辑：镜像为空）
    var primaryDisabled = false
    let onPrimary: () -> Void

    @State private var showImagePicker = false

    private let wizardPageNames = [L10n.t("基础"), L10n.t("端口存储"), L10n.t("高级")]
    private let restartPolicies = ["no", "always", "unless-stopped", "on-failure"]

    var body: some View {
        VStack(spacing: 0) {
            WizardStepsBar(pageNames: wizardPageNames, current: wizardPage)
            Form {
                Group {
                    switch wizardPage {
                    case 0:
                        basicsSection
                        networkSection
                    case 1:
                        portsSection
                        volumesSection
                        envSection
                        labelsSection
                    default:
                        advancedToggleSection
                        if advancedEnabled {
                            restartSection
                            commandSection
                            resourceSection
                            runtimeSection
                            advancedSection
                        }
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        // 镜像选择页目标必须挂在 Form（懒加载容器）外，否则导航栈看不到、未来版本将被忽略
        .navigationDestination(isPresented: $showImagePicker) {
            ContainerImagePickerView(options: vm.imageOptions) { opt in
                draft.image = opt
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WizardBottomBar(
                page: wizardPage,
                totalPages: wizardPageNames.count,
                primaryTitle: primaryTitle,
                isBusy: isBusy,
                primaryDisabled: primaryDisabled,
                onBack: { withAnimation { wizardPage -= 1 } },
                onNext: { withAnimation { wizardPage += 1 } },
                onPrimary: onPrimary)
        }
        .animation(.easeInOut(duration: 0.22), value: wizardPage)
    }

    // MARK: 基础

    private var basicsSection: some View {
        Section(L10n.t("基础信息")) {
            if nameEditable {
                OutlinedTextField(label: L10n.t("名称"), prompt: "nginx-test", text: $draft.name)
            } else {
                // 编辑流名称不可改（接口按原名称重建容器）：描边框 + 右侧锁标识只读展示
                OutlinedShape(label: L10n.t("名称"), isFocused: false,
                              hasValue: !draft.name.isEmpty,
                              trailing: {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }) {
                    Text(draft.name)
                        .lineLimit(1)
                }
            }
            // 镜像输入框右侧图标：进入已有镜像选择页，选中回填
            OutlinedShape(label: L10n.t("镜像"), isFocused: false,
                          hasValue: !draft.image.isEmpty,
                          trailing: {
                Button {
                    showImagePicker = true
                } label: {
                    Image(systemName: "square.stack.3d.up")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityLabel(L10n.t("选择已有镜像"))
            }) {
                // 不用 prompt：OutlinedShape 空态已在框内画「镜像」标签，
                // TextField prompt 会与之常显叠加（重影）；示例改框下 hint
                TextField("", text: $draft.image)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Toggle(L10n.t("总是拉取最新镜像"), isOn: $draft.forcePull)
        }
    }

    // MARK: 网络

    private var networkSection: some View {
        Section(L10n.t("网络")) {
            Picker(L10n.t("网络"), selection: $draft.network) {
                ForEach(vm.networkOptions.isEmpty ? ["bridge"] : vm.networkOptions, id: \.self) { (n: String) in
                    Text(n).tag(n)
                }
            }
            OutlinedTextField(label: L10n.t("主机名"), prompt: "hostname", text: $draft.hostname)
            if draft.network == "1panel-network" {
                OutlinedTextField(label: "IPv4", prompt: "192.168.1.10",
                                  text: $draft.networkIPv4, keyboardType: .decimalPad)
                OutlinedTextField(label: "IPv6", prompt: "fd00::10",
                                  text: $draft.networkIPv6)
            }
        }
        .onAppear {
            if !vm.networkOptions.isEmpty && !vm.networkOptions.contains(draft.network) {
                draft.network = vm.networkOptions.first ?? "bridge"
            }
        }
    }

    // MARK: 端口（入口行 → 端口编辑页）

    private var portsSection: some View {
        Section {
            Toggle(L10n.t("暴露所有端口"), isOn: $draft.publishAllPorts)
            NavigationLink {
                ContainerPortsEditorView(ports: $draft.ports)
            } label: {
                HStack {
                    Text(L10n.t("端口"))
                    Spacer()
                    if draft.ports.isEmpty {
                        Text(L10n.t("未设置")).foregroundStyle(.secondary)
                    } else {
                        Text(L10n.f("%ld 条", draft.ports.count)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: 挂载（入口行 → 挂载编辑页）

    private var volumesSection: some View {
        Section {
            NavigationLink {
                ContainerVolumesEditorView(volumes: $draft.volumes, vm: vm)
            } label: {
                HStack {
                    Text(L10n.t("挂载"))
                    Spacer()
                    if draft.volumes.isEmpty {
                        Text(L10n.t("未设置")).foregroundStyle(.secondary)
                    } else {
                        Text(L10n.f("%ld 条", draft.volumes.count)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: 环境变量 / 标签（多行描边框，每行一条 KEY=VALUE）

    private var envSection: some View {
        Section {
            // 形态 7.1 标准：默认 5 行、内容超出自动增高（labels/cmd 等按需求保持 1 行）
            OutlinedMultiLineField(label: L10n.t("环境变量"), prompt: "KEY=VALUE",
                                   text: $draft.envText)
        }
    }

    private var labelsSection: some View {
        Section {
            OutlinedMultiLineField(label: L10n.t("标签"), prompt: "app=web",
                                   lines: 1, text: $draft.labelsText)
        }
    }

    // MARK: 高级页

    private var advancedToggleSection: some View {
        Section {
            Toggle(L10n.t("高级设置"), isOn: $advancedEnabled)
        } footer: {
            Text(L10n.t("重启策略、资源限制等进阶项"))
        }
    }

    // 重启策略
    private var restartSection: some View {
        Section(L10n.t("重启策略")) {
            Picker(L10n.t("策略"), selection: $draft.restartPolicy) {
                ForEach(restartPolicies, id: \.self) { Text($0).tag($0) }
            }
        }
    }

    // 命令 / 端点（提交拆为 cmd / entrypoint 数组）
    private var commandSection: some View {
        Section {
            OutlinedMultiLineField(label: L10n.t("命令"), prompt: "echo .",
                                   lines: 1, text: $draft.cmdStr)
            OutlinedMultiLineField(label: L10n.t("端点"), prompt: "docker.sh",
                                   lines: 1, text: $draft.entrypointStr)
        }
    }

    // 资源限制
    private var resourceSection: some View {
        Section {
            OutlinedUnitField(label: L10n.t("CPU 份额"), unit: "",
                              prompt: L10n.t("可选"),
                              text: cpuSharesText, range: 2...262144)
            OutlinedUnitField(label: L10n.t("CPU核心数"), unit: L10n.t("核"),
                              text: cpuCoresText,
                              hint: L10n.t("如果设置为 0，则表示没有限制"))
            OutlinedUnitField(label: L10n.t("内存"), unit: "", prompt: "0",
                              text: memoryText,
                              hint: L10n.t("如果设置为 0，则表示没有限制"))
            OutlinedPicker(label: L10n.t("内存单位"), options: ["K", "M", "G"],
                           selection: $draft.memoryUnit,
                           optionLabels: ["K": "KB", "M": "MB", "G": "GB"])
        } header: {
            Text(L10n.t("资源限制"))
        }
    }

    // 用户 / 工作目录
    private var runtimeSection: some View {
        Section {
            OutlinedTextField(label: L10n.t("用户"), prompt: "nginx", text: $draft.user)
            OutlinedTextField(label: L10n.t("工作目录"), prompt: "/root",
                              text: $draft.workingDir, keyboardType: .URL)
        }
    }

    // 特权模式等开关
    private var advancedSection: some View {
        Section(L10n.t("高级")) {
            Toggle(L10n.t("特权模式"), isOn: $draft.privileged)
            Toggle(L10n.t("自动删除"), isOn: $draft.autoRemove)
            Toggle("TTY", isOn: $draft.tty)
            Toggle(L10n.t("标准输入"), isOn: $draft.openStdin)
        }
    }

    // 数值绑定（String ↔ 数值，非法输入保持原值）

    private var cpuSharesText: Binding<String> {
        Binding<String>(get: { String(draft.cpuShares) },
                        set: { draft.cpuShares = Int($0) ?? draft.cpuShares })
    }

    private var cpuCoresText: Binding<String> {
        Binding<String>(get: { draft.cpuCores == 0 ? "0" : String(format: "%.1f", draft.cpuCores) },
                        set: { draft.cpuCores = Double($0) ?? 0 })
    }

    private var memoryText: Binding<String> {
        Binding<String>(get: { String(draft.memoryValue) },
                        set: { draft.memoryValue = Int($0) ?? 0 })
    }
}

// MARK: - 镜像选择页

/// 已有镜像列表：点击行回填草稿镜像并返回
struct ContainerImagePickerView: View {
    let options: [String]
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if options.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无可用镜像"),
                    systemImage: "shippingbox",
                    description: Text(L10n.t("请先拉取镜像或在应用商店安装应用"))
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(options, id: \.self) { opt in
                        Button {
                            onSelect(opt)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "shippingbox")
                                    .foregroundStyle(.blue)
                                Text(opt)
                                    .font(.dataMonospacedBody)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.t("选择镜像"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 端口编辑页

/// 端口映射列表：每条 = 主机IP/主机端口/容器端口/协议，右侧删除、底部添加
struct ContainerPortsEditorView: View {
    @Binding var ports: [CreatePortRow]

    private let protocols = ["tcp", "udp"]

    var body: some View {
        Form {
            ForEach($ports) { $port in
                portSection($port)
            }
            Section {
                Button {
                    ports.append(CreatePortRow())
                } label: {
                    Label(L10n.t("添加"), systemImage: "plus.circle")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .navigationTitle(L10n.t("端口"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func portSection(_ port: Binding<CreatePortRow>) -> some View {
        Section {
            OutlinedTextField(label: L10n.t("主机端口"), text: port.host,
                              keyboardType: .numberPad)
            OutlinedTextField(label: L10n.t("容器端口"), text: port.containerPort,
                              keyboardType: .numberPad)
            OutlinedTextField(label: L10n.t("主机 IP"), prompt: L10n.t("可选"),
                              text: port.hostIP)
            OutlinedPicker(label: L10n.t("协议"), options: protocols,
                           selection: port.protocolField)
        } header: {
            // 样式 A（与负载均衡节点一致）：节头序号 + 节头删除（仅一条不可删）
            HStack {
                Text(L10n.f("端口-%ld", (ports.firstIndex(where: { $0.id == port.id }) ?? 0) + 1))
                Spacer()
                if ports.count > 1 {
                    Button {
                        ports.removeAll { $0.id == port.id }
                    } label: {
                        Label(L10n.t("删除端口"), systemImage: "trash")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }
}

// MARK: - 挂载编辑页

/// 挂载列表：类型 bind/volume；bind=主机目录输入框，volume=挂载卷下拉（截前 30 位）；
/// 传播模式仅 bind 有，六种选项各自带提示
struct ContainerVolumesEditorView: View {
    @Binding var volumes: [CreateVolumeRow]
    @ObservedObject var vm: ContainersViewModel

    @State private var volumeOptions: [String] = []
    private let client = APIClient.shared(for: ServerManager.shared.current
                                            ?? ServerConfig(name: "", baseURL: "", apiKey: ""))

    private let typeOptions = ["bind", "volume"]
    private let modeOptions: [(String, String)] = [("rw", L10n.t("读写")), ("ro", L10n.t("只读"))]
    /// 传播模式（shared 字段）：值 → (名称, 提示)
    private let shareOptions: [(String, String, String)] = [
        ("private",  L10n.t("私有"),     L10n.t("容器里的挂载变化和主机互不干扰")),
        ("rprivate", L10n.t("递归私有"), L10n.t("容器里所有挂载和主机完全隔离")),
        ("shared",   L10n.t("共享"),     L10n.t("主机和容器里的挂载变化互相可见")),
        ("rshared",  L10n.t("递归共享"), L10n.t("主机和容器里所有挂载变化互相可见")),
        ("slave",    L10n.t("从属"),     L10n.t("容器能看见主机的挂载变化，但自己的变化不影响主机")),
        ("rslave",   L10n.t("递归从属"), L10n.t("容器里所有挂载都能看见主机变化，但不影响主机")),
    ]

    var body: some View {
        Form {
            ForEach($volumes) { $vol in
                volumeSection($vol)
            }
            Section {
                Button {
                    volumes.append(CreateVolumeRow())
                } label: {
                    Label(L10n.t("添加"), systemImage: "plus.circle")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .navigationTitle(L10n.t("挂载"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadVolumeOptions() }
    }

    private func volumeSection(_ vol: Binding<CreateVolumeRow>) -> some View {
        Section {
            OutlinedPicker(label: L10n.t("类型"), options: typeOptions,
                           selection: vol.type,
                           optionLabels: ["bind": "bind", "volume": "volume"])

            if vol.type.wrappedValue == "bind" {
                OutlinedTextField(label: L10n.t("主机目录"), prompt: "/data/1",
                                  text: vol.sourceDir, keyboardType: .URL)
            } else {
                OutlinedPicker(label: L10n.t("挂载卷"),
                               options: volumeOptions,
                               selection: vol.sourceDir,
                               optionLabels: Dictionary(uniqueKeysWithValues:
                                   volumeOptions.map { ($0, $0.volumeShortDisplay) }))
            }

            OutlinedTextField(label: L10n.t("容器目录"), prompt: "/data1",
                              text: vol.containerDir)
            OutlinedPicker(label: L10n.t("模式"),
                           options: modeOptions.map(\.0),
                           selection: vol.mode,
                           optionLabels: Dictionary(uniqueKeysWithValues: modeOptions))
            // 挂载卷没有传播模式
            if vol.type.wrappedValue == "bind" {
                OutlinedPicker(label: L10n.t("传播模式"),
                               options: shareOptions.map(\.0),
                               selection: vol.shared,
                               optionLabels: Dictionary(uniqueKeysWithValues:
                                   shareOptions.map { ($0.0, $0.1) }))
                if let hint = shareOptions.first(where: { $0.0 == vol.shared.wrappedValue })?.2 {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            // 样式 A（与负载均衡节点一致）：节头序号 + 节头删除（仅一条不可删）
            HStack {
                Text(L10n.f("挂载-%ld", (volumes.firstIndex(where: { $0.id == vol.id }) ?? 0) + 1))
                Spacer()
                if volumes.count > 1 {
                    Button {
                        volumes.removeAll { $0.id == vol.id }
                    } label: {
                        Label(L10n.t("删除挂载"), systemImage: "trash")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    /// GET /containers/volume：挂载卷选项（长哈希只显示前 30 位，提交传完整值）
    private func loadVolumeOptions() async {
        struct VolumeOption: Decodable { let option: String? }
        guard volumeOptions.isEmpty else { return }
        if let list: [VolumeOption] = try? await client.send(
            path: APIEndpoint.containersVolume.path, method: "GET",
            as: [VolumeOption].self) {
            volumeOptions = list.compactMap { $0.option ?? "" }.filter { !$0.isEmpty }
        }
    }
}

// MARK: - 卷选项短显示

extension String {
    /// 挂载卷下拉短显示（前 30 位），提交仍用完整值
    var volumeShortDisplay: String {
        count > 30 ? String(prefix(30)) + "…" : self
    }
}
