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

    var body: some View {
        Form {
            basicsSection
            networkSection
            portsSection
            volumesSection
            envSection
            restartSection
            resourceSection
            advancedSection
        }
        .navigationTitle("创建容器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await vm.createContainer(draft: draft) }
                } label: {
                    if vm.containerOperating {
                        ProgressView()
                    } else {
                        Text("创建").bold()
                    }
                }
                .disabled(vm.containerOperating || draft.name.isEmpty || draft.image.isEmpty)
            }
        }
        .task { await vm.loadCreateOptions() }
        .alert("提示", isPresented: $vm.showAlert) {
            Button("好的", role: .cancel) {
                if vm.lastAlertIsSuccess { dismiss() }
            }
        } message: { Text(vm.alertMessage) }
    }

    // MARK: 基础

    private var basicsSection: some View {
        Section("基础信息") {
            HStack {
                Text("名称").foregroundStyle(.secondary)
                TextField("如 nginx-test", text: $draft.name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("镜像").foregroundStyle(.secondary)
                    TextField("如 nginx:latest", text: $draft.image)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                }
                if !vm.imageOptions.isEmpty {
                    Menu {
                        ForEach(vm.imageOptions, id: \.self) { (opt: String) in
                            Button(opt) { draft.image = opt }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "square.stack.3d.up")
                            Text(draft.image.isEmpty ? "选择已有镜像" : draft.image)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.caption)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            Toggle("总是拉取最新镜像", isOn: $draft.forcePull)
        }
    }

    // MARK: 网络

    private var networkSection: some View {
        Section("网络") {
            Picker("网络", selection: $draft.network) {
                ForEach(vm.networkOptions.isEmpty ? ["bridge"] : vm.networkOptions, id: \.self) { (n: String) in
                    Text(n).tag(n)
                }
            }
            HStack {
                Text("主机名").foregroundStyle(.secondary)
                TextField("hostname", text: $draft.hostname)
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
            Toggle("暴露所有端口", isOn: $draft.publishAllPorts)
            ForEach($draft.ports) { $port in
                portRow($port)
            }
            .onDelete { draft.ports.remove(atOffsets: $0) }
            addRowButton("添加端口映射") { draft.ports.append(CreatePortRow()) }
        } header: {
            Text("端口映射")
        } footer: {
            Text("容器端口 → 主机端口，如 80 → 8080")
        }
    }

    private func portRow(_ port: Binding<CreatePortRow>) -> some View {
        VStack(spacing: 6) {
            HStack {
                TextField("容器端口", text: port.containerPort)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("主机端口", text: port.host)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
            }
            Picker("协议", selection: port.protocolField) {
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
            addRowButton("添加挂载卷") { draft.volumes.append(CreateVolumeRow()) }
        } header: {
            Text("挂载卷")
        } footer: {
            Text("主机目录 → 容器目录")
        }
    }

    private func volumeRow(_ vol: Binding<CreateVolumeRow>) -> some View {
        VStack(spacing: 6) {
            HStack {
                TextField("主机目录", text: vol.sourceDir)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.caption, design: .monospaced))
                Image(systemName: "arrow.left").font(.caption).foregroundStyle(.secondary)
                TextField("容器目录", text: vol.containerDir)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.caption, design: .monospaced))
            }
            HStack {
                Picker("模式", selection: vol.mode) {
                    ForEach(volumeModes, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("共享", selection: vol.shared) {
                    ForEach(shareModes, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    // MARK: 环境变量

    private var envSection: some View {
        Section("环境变量") {
            ForEach(draft.env.indices, id: \.self) { idx in
                HStack {
                    Text(draft.env[idx])
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                }
            }
            .onDelete { draft.env.remove(atOffsets: $0) }
            HStack {
                TextField("KEY=VALUE", text: $newEnvText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.caption, design: .monospaced))
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
        Section("重启策略") {
            Picker("策略", selection: $draft.restartPolicy) {
                ForEach(restartPolicies, id: \.self) { Text($0).tag($0) }
            }
        }
    }

    // MARK: 资源限制

    private var resourceSection: some View {
        Section {
            HStack {
                Text("CPU 权重")
                Spacer()
                Stepper("\(draft.cpuShares)", value: $draft.cpuShares, in: 2...262144, step: 64)
                    .monospacedDigit()
            }
            HStack {
                Text("内存上限")
                Spacer()
                TextField("0", value: $draft.memoryMB, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text("MB").foregroundStyle(.secondary)
            }
        } header: {
            Text("资源限制")
        } footer: {
            if let lim = vm.containerLimit {
                Text("宿主机可用：CPU \(lim.cpu ?? 0) 核" + (lim.memory.map { "，内存 \(formatBytes($0))" } ?? ""))
            }
        }
    }

    // MARK: 高级

    private var advancedSection: some View {
        Section("高级") {
            Toggle("特权模式", isOn: $draft.privileged)
            Toggle("自动删除", isOn: $draft.autoRemove)
            Toggle("TTY", isOn: $draft.tty)
            Toggle("标准输入", isOn: $draft.openStdin)
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
