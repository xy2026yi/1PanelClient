//
//  ContainerCreateView.swift
//  1PanelClient
//

import SwiftUI

// MARK: - 创建容器

struct ContainerCreateView: View {
    @ObservedObject var vm: ContainersViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ContainerCreateDraft()
    @State private var newEnvText = ""

    private let restartPolicies = ["no", "always", "unless-stopped", "on-failure"]
    private let protocols = ["tcp", "udp"]
    private let volumeTypes = ["bind", "volume"]
    private let volumeModes = ["rw", "ro"]
    private let shareModes = ["private", "shared"]

    /// 向导分页：0 基础（名称/镜像/网络） 1 端口与存储 2 高级（默认收起）
    @State private var wizardPage = 0
    @State private var advancedEnabled = false
    private let wizardPageNames = [L10n.t("基础"), L10n.t("端口存储"), L10n.t("高级")]

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
                    default:
                        Section {
                            Toggle(L10n.t("高级设置"), isOn: $advancedEnabled)
                        } footer: {
                            Text(L10n.t("重启策略、资源限制等进阶项"))
                        }
                        if advancedEnabled {
                            restartSection
                            resourceSection
                            advancedSection
                        }
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
                primaryTitle: L10n.t("创建"),
                isBusy: vm.containerOperating,
                primaryDisabled: draft.name.isEmpty || draft.image.isEmpty,
                onBack: { withAnimation { wizardPage -= 1 } },
                onNext: { withAnimation { wizardPage += 1 } },
                onPrimary: {
                    Task {
                        if await vm.createContainer(draft: draft) {
                            dismiss()
                        }
                    }
                }
            )
        }
        .animation(.easeInOut(duration: 0.22), value: wizardPage)
        .navigationTitle(L10n.t("创建容器"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .task { await vm.loadCreateOptions() }
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: { Text(vm.alertMessage) }
    }

    // MARK: 基础

    private var basicsSection: some View {
        Section(L10n.t("基础信息")) {
            HStack {
                Text(L10n.t("名称")).foregroundStyle(.secondary)
                Spacer()
                TextField(L10n.t("如 nginx-test"), text: $draft.name)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L10n.t("镜像")).foregroundStyle(.secondary)
                    Spacer()
                    TextField(L10n.t("如 nginx:latest"), text: $draft.image)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if !vm.imageOptions.isEmpty {
                    Menu {
                        ForEach(vm.imageOptions, id: \.self) { (opt: String) in
                            Button(opt) { draft.image = opt }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "square.stack.3d.up")
                            Text(draft.image.isEmpty ? L10n.t("选择已有镜像") : draft.image)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.caption)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
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
            HStack {
                Text(L10n.t("主机名")).foregroundStyle(.secondary)
                Spacer()
                TextField("hostname", text: $draft.hostname)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .onAppear {
            if !vm.networkOptions.isEmpty && !vm.networkOptions.contains(draft.network) {
                draft.network = vm.networkOptions.first ?? "bridge"
            }
        }
    }

    // MARK: 端口

    private var portsSection: some View {
        Section {
            Toggle(L10n.t("暴露所有端口"), isOn: $draft.publishAllPorts)
            ForEach($draft.ports) { $port in
                portRow($port)
            }
            .onDelete { draft.ports.remove(atOffsets: $0) }
            addRowButton(L10n.t("添加端口映射")) { draft.ports.append(CreatePortRow()) }
        } header: {
            Text(L10n.t("端口映射"))
        } footer: {
            Text(L10n.t("容器端口 → 主机端口，如 80 → 8080"))
        }
    }

    private func portRow(_ port: Binding<CreatePortRow>) -> some View {
        VStack(spacing: 6) {
            HStack {
                TextField(L10n.t("容器端口"), text: port.containerPort)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(L10n.t("主机端口"), text: port.host)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
            }
            Picker(L10n.t("协议"), selection: port.protocolField) {
                ForEach(protocols, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: 挂载卷

    private var volumesSection: some View {
        Section {
            ForEach($draft.volumes) { $vol in
                volumeRow($vol)
            }
            .onDelete { draft.volumes.remove(atOffsets: $0) }
            addRowButton(L10n.t("添加挂载卷")) { draft.volumes.append(CreateVolumeRow()) }
        } header: {
            Text(L10n.t("挂载卷"))
        } footer: {
            Text(L10n.t("主机目录 → 容器目录"))
        }
    }

    private func volumeRow(_ vol: Binding<CreateVolumeRow>) -> some View {
        VStack(spacing: 6) {
            HStack {
                FormTextField(label: L10n.t("主机目录"), text: vol.sourceDir, style: .stacked)
                    .font(.dataMonospacedCaption)
                Image(systemName: "arrow.left").font(.caption).foregroundStyle(.secondary)
                FormTextField(label: L10n.t("容器目录"), text: vol.containerDir, style: .stacked)
                    .font(.dataMonospacedCaption)
            }
            HStack {
                Picker(L10n.t("模式"), selection: vol.mode) {
                    ForEach(volumeModes, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker(L10n.t("共享"), selection: vol.shared) {
                    ForEach(shareModes, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    // MARK: 环境变量

    private var envSection: some View {
        Section(L10n.t("环境变量")) {
            ForEach(draft.env.indices, id: \.self) { idx in
                HStack {
                    Text(draft.env[idx])
                        .font(.dataMonospacedCaption)
                        .lineLimit(1)
                    Spacer()
                }
            }
            .onDelete { draft.env.remove(atOffsets: $0) }
            HStack {
                TextField("KEY=VALUE", text: $newEnvText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.dataMonospacedCaption)
                Button {
                    let t = newEnvText.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    draft.env.append(t)
                    newEnvText = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
        }
    }

    // MARK: 重启策略

    private var restartSection: some View {
        Section(L10n.t("重启策略")) {
            Picker(L10n.t("策略"), selection: $draft.restartPolicy) {
                ForEach(restartPolicies, id: \.self) { Text($0).tag($0) }
            }
        }
    }

    // MARK: 资源限制

    private var resourceSection: some View {
        Section {
            HStack {
                Text(L10n.t("CPU 权重"))
                Spacer()
                Stepper("\(draft.cpuShares)", value: $draft.cpuShares, in: 2...262144, step: 64)
                    .monospacedDigit()
            }
            HStack {
                Text(L10n.t("内存上限"))
                Spacer()
                TextField("0", value: $draft.memoryMB, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text("MB").foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.t("资源限制"))
        } footer: {
            if let lim = vm.containerLimit {
                Text(L10n.f("宿主机可用：CPU %ld 核", lim.cpu ?? 0) + (lim.memory.map { L10n.f("，内存 %@", formatBytes($0)) } ?? ""))
            }
        }
    }

    // MARK: 高级

    private var advancedSection: some View {
        Section(L10n.t("高级")) {
            Toggle(L10n.t("特权模式"), isOn: $draft.privileged)
            Toggle(L10n.t("自动删除"), isOn: $draft.autoRemove)
            Toggle("TTY", isOn: $draft.tty)
            Toggle(L10n.t("标准输入"), isOn: $draft.openStdin)
        }
    }

    // MARK: 辅助

    private func addRowButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus.circle")
                .foregroundStyle(Color.accentColor)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let f = Double(bytes)
        if f > 1_073_741_824 { return String(format: "%.1f GB", f / 1_073_741_824) }
        if f > 1_048_576 { return String(format: "%.0f MB", f / 1_048_576) }
        return "\(bytes) B"
    }
}
