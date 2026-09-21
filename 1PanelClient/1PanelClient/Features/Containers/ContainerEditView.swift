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
            Section(L10n.t("目标镜像")) {
                TextField(L10n.t("如 nginx:latest"), text: $image)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.dataMonospacedBody)
                if image.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(L10n.t("镜像不能为空"))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Toggle(L10n.t("总是拉取镜像（force pull）"), isOn: $forcePull)
            } footer: {
                Text(L10n.t("开启后将强制重新拉取镜像，忽略本地缓存。"))
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
                        Text(L10n.t("升级"))
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(image.trimmingCharacters(in: .whitespaces).isEmpty || vm.containerOperating)
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle(L10n.f("升级 %@", container.name))
        .navigationBarTitleDisplayMode(.inline)
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
    }

    private func submit() async {
        let ok = await vm.upgradeContainer(
            name: container.name,
            image: image.trimmingCharacters(in: .whitespaces),
            forcePull: forcePull
        )
        if ok { dismiss() }
    }
}

// MARK: - 容器编辑页

/// 与创建一致的向导表单（ContainerWizardForm 共用三页），加载 /containers/info
/// 回填草稿后即可编辑全部字段；名称不可改（接口按原名称重建容器）
struct ContainerEditView: View {
    let container: Container
    @ObservedObject var vm: ContainersViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var info: ContainerInfo?
    @State private var isLoading = false
    @State private var loadError: String?

    @State private var draft = ContainerCreateDraft()
    @State private var wizardPage = 0
    @State private var advancedEnabled = false

    var body: some View {
        Group {
            if isLoading {
                loadingForm
            } else if loadError != nil {
                loadErrorForm
            } else {
                ContainerWizardForm(
                    draft: $draft,
                    vm: vm,
                    wizardPage: $wizardPage,
                    advancedEnabled: $advancedEnabled,
                    nameEditable: false,
                    primaryTitle: L10n.t("保存"),
                    isBusy: vm.containerOperating,
                    primaryDisabled: draft.image.isEmpty,
                    onPrimary: { Task { await submit() } })
            }
        }
        .navigationTitle(L10n.t("编辑容器"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .toastOverlay(message: $vm.toastMessage)
        .task {
            await load()
        }
    }

    private var loadingForm: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(L10n.t("加载容器配置…"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
    }

    private var loadErrorForm: some View {
        Form {
            Section {
                Text(loadError ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                Button(L10n.t("重试")) {
                    Task { await load() }
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        // 向导表单依赖的选项：网络/挂载卷/镜像下拉
        await vm.loadCreateOptions()
        guard let i = await vm.loadContainerInfo(name: container.name) else {
            loadError = vm.alertMessage.isEmpty ? L10n.t("获取容器配置失败") : vm.alertMessage
            return
        }
        info = i
        draft = Self.draft(from: i)
    }

    /// ContainerInfo → 编辑草稿：cmd/entrypoint 数组拼回空格分隔原文，
    /// env/labels 数组拼回换行原文，内存字节换算数值+单位（整 GiB 取 G，否则 M）
    private static func draft(from i: ContainerInfo) -> ContainerCreateDraft {
        var d = ContainerCreateDraft()
        d.name = i.name
        d.image = i.image
        d.forcePull = i.forcePull ?? false
        let net = i.networks?.first
        d.network = net?.network ?? "bridge"
        d.networkIPv4 = net?.ipv4 ?? ""
        d.networkIPv6 = net?.ipv6 ?? ""
        d.hostname = i.hostname ?? ""
        d.publishAllPorts = i.publishAllPorts ?? false
        d.ports = (i.exposedPorts ?? []).map {
            CreatePortRow(hostIP: $0.hostIP, host: $0.hostPort,
                          containerPort: $0.containerPort, protocolField: $0.protocolField)
        }
        d.volumes = (i.volumes ?? []).map {
            CreateVolumeRow(type: $0.type, sourceDir: $0.sourceDir,
                            containerDir: $0.containerDir, mode: $0.mode, shared: $0.shared)
        }
        d.envText = (i.env ?? []).joined(separator: "\n")
        d.labelsText = (i.labels ?? []).joined(separator: "\n")
        d.cmdStr = (i.cmd ?? []).joined(separator: " ")
        d.entrypointStr = (i.entrypoint ?? []).joined(separator: " ")
        d.workingDir = i.workingDir ?? ""
        d.user = i.user ?? ""
        d.restartPolicy = i.restartPolicy ?? "always"
        d.cpuShares = i.cpuShares ?? 1024
        d.cpuCores = (i.nanoCPUs ?? 0) / 1_000_000_000
        // 字节 → 数值+单位（整除且 ≥1GB 取 GB，否则 MB；与创建表单单位菜单一致）
        let memBytes = i.memory ?? 0
        if memBytes % (1024 * 1024 * 1024) == 0, memBytes >= 1024 * 1024 * 1024 {
            d.memoryUnit = "G"
            d.memoryValue = Int(memBytes / 1024 / 1024 / 1024)
        } else {
            d.memoryUnit = "M"
            d.memoryValue = Int(memBytes / 1024 / 1024)
        }
        d.privileged = i.privileged ?? false
        d.autoRemove = i.autoRemove ?? false
        d.tty = i.tty ?? false
        d.openStdin = i.openStdin ?? false
        return d
    }

    private func submit() async {
        guard let info else { return }
        if await vm.updateContainer(info: info, draft: draft) {
            dismiss()
        }
    }
}

