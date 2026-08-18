//
//  ContainerEditView.swift
//  1PanelClient
//

import SwiftUI

// MARK: - 容器升级页

struct ContainerUpgradeView: View {
    let container: Container
    @ObservedObject var vm: ContainersViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var image: String
    @State private var forcePull = false

    init(container: Container, vm: ContainersViewModel) {
        self.container = container
        self.vm = vm
        _image = State(initialValue: container.imageName ?? "")
    }

    var body: some View {
        Form {
            Section("目标镜像") {
                TextField("镜像名:标签", text: $image)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                if image.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("镜像不能为空")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Toggle("总是拉取镜像（force pull）", isOn: $forcePull)
            } footer: {
                Text("开启后将强制重新拉取镜像，忽略本地缓存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        if vm.containerOperating {
                            ProgressView()
                                .tint(.white)
                        }
                        Text("升级")
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(image.trimmingCharacters(in: .whitespaces).isEmpty || vm.containerOperating)
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle("升级 \(container.name)")
        .navigationBarTitleDisplayMode(.inline)
        .alert("提示", isPresented: $vm.showAlert) {
            Button("好的", role: .cancel) {
                if vm.lastAlertIsSuccess {
                    dismiss()
                }
            }
        } message: {
            Text(vm.alertMessage)
        }
    }

    private func submit() async {
        await vm.upgradeContainer(
            name: container.name,
            image: image.trimmingCharacters(in: .whitespaces),
            forcePull: forcePull
        )
    }
}

// MARK: - 容器编辑页

struct ContainerEditView: View {
    let container: Container
    @ObservedObject var vm: ContainersViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var info: ContainerInfo?
    @State private var image: String = ""
    @State private var forcePull = false
    @State private var publishAllPorts = false
    @State private var envs: [String] = []
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        Form {
            if isLoading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("加载容器配置…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
            } else if let loadError {
                Section {
                    Text(loadError)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            } else if let info {
                Section("基础") {
                    HStack {
                        Text("名称")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(info.name)
                            .font(.system(.body, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section {
                    TextField("镜像名:标签", text: $image, axis: .horizontal)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !vm.imageOptions.isEmpty {
                        Menu {
                            ForEach(vm.imageOptions, id: \.self) { opt in
                                Button(opt) { image = opt }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "square.stack.3d.up")
                                Text(image.isEmpty ? "选择镜像" : "选择镜像")
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("镜像")
                } footer: {
                    if image.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("镜像不能为空")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Toggle("强制拉取镜像", isOn: $forcePull)
                    Toggle("暴露所有端口", isOn: $publishAllPorts)
                }

                Section("环境变量") {
                    ForEach(envs.indices, id: \.self) { i in
                        TextField("KEY=VALUE", text: Binding(
                            get: { envs[i] },
                            set: { envs[i] = $0 }
                        ), axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...4)
                    }
                    .onDelete { envs.remove(atOffsets: $0) }

                    Button {
                        envs.append("")
                    } label: {
                        Label("添加环境变量", systemImage: "plus")
                    }
                }
            }
        }
        .navigationTitle("编辑容器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if let info { Task { await submit(info: info) } }
                } label: {
                    if vm.containerOperating {
                        ProgressView()
                    } else {
                        Text("保存").fontWeight(.medium)
                    }
                }
                .disabled(info == nil || image.trimmingCharacters(in: .whitespaces).isEmpty || vm.containerOperating)
            }
        }
        .alert("提示", isPresented: $vm.showAlert) {
            Button("好的", role: .cancel) {
                if vm.lastAlertIsSuccess {
                    dismiss()
                }
            }
        } message: {
            Text(vm.alertMessage)
        }
        .task {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        if vm.imageOptions.isEmpty { await vm.loadImageOptions() }
        guard let i = await vm.loadContainerInfo(name: container.name) else {
            loadError = vm.alertMessage.isEmpty ? "获取容器配置失败" : vm.alertMessage
            return
        }
        info = i
        image = i.image
        forcePull = i.forcePull ?? false
        publishAllPorts = i.publishAllPorts ?? false
        envs = i.env ?? []
    }

    private func submit(info: ContainerInfo) async {
        await vm.updateContainer(
            info: info,
            image: image.trimmingCharacters(in: .whitespaces),
            forcePull: forcePull,
            publishAllPorts: publishAllPorts,
            env: envs.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        )
    }
}

