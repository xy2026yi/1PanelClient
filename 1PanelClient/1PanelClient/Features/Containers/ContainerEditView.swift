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
    /// 升级前的重建确认（升级会重建容器，确认后才提交并进入任务进度）
    @State private var pendingUpgrade = false
    /// 升级任务进度（logs/tasks/read 轮询，复用 TaskProgressView）
    @State private var progressTaskID: String?
    @State private var progressFinished = false

    init(container: Container, vm: ContainersViewModel) {
        self.container = container
        self.vm = vm
        _image = State(initialValue: container.imageName ?? "")
    }

    var body: some View {
        Form {
            // 当前镜像仅展示不可改（升级 = 换目标镜像重建）
            Section(L10n.t("当前镜像")) {
                Text(container.imageName ?? "—")
                    .font(.dataMonospacedBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

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
                    pendingUpgrade = true
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
        // 升级任务进度页：任务完成（或转后台）后进度页自行收起，随后收起升级页
        .navigationDestination(isPresented: Binding(
            get: { progressTaskID != nil },
            set: { if !$0 { progressTaskID = nil } }
        )) {
            if let taskID = progressTaskID {
                TaskProgressView(taskID: taskID,
                                 title: L10n.f("升级容器 %@", container.name)) { _ in
                    progressFinished = true
                    // 返回 false：进度页自行 dismiss；onDisappear 再收起升级页
                    return false
                }
                .onDisappear {
                    if progressFinished { dismiss() }
                }
            }
        }
        // 升级需重建容器，提交前确认（对齐 Web 端 confirm 的弹出时机与文案）
        .alert(L10n.t("升级"), isPresented: $pendingUpgrade) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("确认")) { Task { await submit() } }
        } message: {
            Text(L10n.t("升级操作需要重建容器，任何未持久化的数据将会丢失，是否继续？"))
        }
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
    }

    private func submit() async {
        if let taskID = await vm.upgradeContainer(
            name: container.name,
            image: image.trimmingCharacters(in: .whitespaces),
            forcePull: forcePull
        ) {
            progressTaskID = taskID
        }
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

    /// 更新任务进度（logs/tasks/read 轮询，复用 TaskProgressView）
    @State private var progressTaskID: String?
    @State private var progressFinished = false
    /// 保存前的重建确认（保存会重建容器，确认后才提交并进入任务进度）
    @State private var pendingSave = false

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
                    onPrimary: { pendingSave = true })
            }
        }
        .navigationTitle(L10n.t("编辑容器"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        // 更新任务进度页：任务完成（或转后台）后进度页自行收起，随后收起整个编辑页
        .navigationDestination(isPresented: Binding(
            get: { progressTaskID != nil },
            set: { if !$0 { progressTaskID = nil } }
        )) {
            if let taskID = progressTaskID {
                TaskProgressView(taskID: taskID,
                                 title: L10n.f("更新容器 %@", info?.name ?? container.name)) { _ in
                    progressFinished = true
                    // 返回 false：进度页自行 dismiss；onDisappear 再收起编辑页
                    return false
                }
                .onDisappear {
                    if progressFinished { dismiss() }
                }
            }
        }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        // 保存需重建容器，提交前确认（对齐 Web 端 operate/confirm 的弹出时机）
        .alert(L10n.t("编辑"), isPresented: $pendingSave) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("确认")) { Task { await submit() } }
        } message: {
            Text(L10n.t("编辑容器需要重建，任何未持久化的数据将丢失，是否继续操作？"))
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
    /// env/labels 数组拼回换行原文；info.memory 单位为 MB（服务端已由字节换算）
    /// 直接取值（整 GiB 且 ≥1G 取 G，否则 M，小数截断——提交侧未改动时原样回传防丢精度）
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
        d.cmdStr = ContainerCreateDraft.quoteArgs(i.cmd ?? [])
        d.entrypointStr = ContainerCreateDraft.quoteArgs(i.entrypoint ?? [])
        d.workingDir = i.workingDir ?? ""
        d.user = i.user ?? ""
        d.restartPolicy = i.restartPolicy ?? "always"
        d.cpuShares = i.cpuShares ?? 1024
        d.cpuCores = (i.nanoCPUs ?? 0) / 1_000_000_000
        let memMB = i.memory ?? 0
        if memMB >= 1024, memMB.truncatingRemainder(dividingBy: 1024) == 0 {
            d.memoryUnit = "G"
            d.memoryValue = Int(memMB / 1024)
        } else {
            d.memoryUnit = "M"
            d.memoryValue = Int(memMB.rounded(.towardZero))
        }
        d.privileged = i.privileged ?? false
        d.autoRemove = i.autoRemove ?? false
        d.tty = i.tty ?? false
        d.openStdin = i.openStdin ?? false
        return d
    }

    private func submit() async {
        guard let info else { return }
        if let taskID = await vm.updateContainer(info: info, draft: draft) {
            progressTaskID = taskID
        }
    }
}

