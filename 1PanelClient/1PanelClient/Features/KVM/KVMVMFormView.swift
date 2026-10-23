//
//  KVMVMFormView.swift
//  1PanelClient
//
//  虚拟机创建 / 编辑表单（logs/高级功能-KVM.md 抓包 2026-10-23）：
//  创建：名称 / 从模版启动（开 → 模版下拉并回填总线·网络·存储池·CPU·内存·磁盘，
//  隐藏镜像与系统类型；关 → 镜像 + 操作系统类型）/ 磁盘总线 / 网络 / 存储池 /
//  CPU / 内存 / 磁盘容量 / 创建后启动 / 开机自启 / 描述。
//  请求形状按抓包：普通创建 bootOrder="hd,cdrom"、模版创建携 templateID 且 bootOrder="hd"、isoPaths 为空数组。
//  编辑（仅关机态）：名称只读 / 镜像 / 网络 / 启动项（磁盘优先·镜像优先）/ CPU / 内存 / 开机自启 / 描述。
//  提交返回 taskID → 表单内 push 任务进度（operateNode=local），完成后刷新列表并分步收栈。
//

import SwiftUI

struct KVMVMFormView: View {
    @ObservedObject var vm: KVMViewModel
    /// 编辑对象；nil 为创建
    let machine: KVMVirtualMachine?

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var fromTemplate = false
    @State private var templateID = ""
    @State private var isoPath = ""
    @State private var osType: KVMOSType = .linux
    @State private var diskBus: KVMDiskBus = .virtio
    @State private var network = ""
    @State private var storagePool = ""
    @State private var cpuText = "1"
    @State private var memoryText = "1024"
    @State private var diskSizeText = "20"
    @State private var bootOrder: KVMBootOrder = .hdFirst
    @State private var startAfterCreate = true
    @State private var autoStart = false
    @State private var description = ""

    @State private var isSubmitting = false
    @State private var showProgress = false
    @State private var activeTaskID = ""
    @State private var didPrefill = false

    init(vm: KVMViewModel, machine: KVMVirtualMachine? = nil) {
        self.vm = vm
        self.machine = machine
    }

    private var isEdit: Bool { machine != nil }

    var body: some View {
        Form {
            basicSection
            if !isEdit { sourceSection }
            hardwareSection
            optionSection
        }
        .navigationTitle(isEdit ? L10n.t("编辑虚拟机") : L10n.t("创建虚拟机"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text(isEdit ? L10n.t("保存") : L10n.t("创建")).bold()
                    }
                }
                .disabled(!isValid || isSubmitting)
            }
        }
        // 进度由表单内 push（与 vLLM 创建同模式）：完成后刷新列表并分步收栈
        .navigationDestination(isPresented: $showProgress) {
            TaskProgressView(taskID: activeTaskID,
                             title: isEdit ? L10n.t("编辑虚拟机") : L10n.t("创建虚拟机"),
                             node: "local") { _ in
                Task { await vm.loadVMs() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    dismiss()
                }
                return false
            }
        }
        .task {
            await vm.loadReferenceData()
            prefillIfNeeded()
        }
        .onChange(of: fromTemplate) { _, on in
            if on { applyTemplate(templateID) }
        }
        .onChange(of: templateID) { _, id in
            if fromTemplate { applyTemplate(id) }
        }
    }

    // MARK: 分区

    private var basicSection: some View {
        Section {
            if let machine {
                // 名称不可修改（服务端以名称定位域）
                OutlinedShape(label: L10n.t("名称"), isFocused: false, hasValue: true,
                              trailing: { EmptyView() }) {
                    Text(machine.displayName)
                        .font(.dataMonospacedBody)
                        .lineLimit(1)
                }
            } else {
                OutlinedTextField(label: L10n.t("名称"), text: $name)
            }
            if !isEdit {
                Toggle(L10n.t("从模版启动"), isOn: $fromTemplate)
            }
        } header: {
            SectionLabel(title: L10n.t("基本信息"), systemImage: "desktopcomputer")
        } footer: {
            if !isEdit {
                Text(L10n.t("从模版启动会以模版磁盘为基础创建，无需镜像安装；模版的总线 / 网络 / 存储池 / 规格会自动回填。"))
            }
        }
    }

    /// 创建来源：模版（从模版启动）或 镜像 + 系统类型
    private var sourceSection: some View {
        Section {
            if fromTemplate {
                OutlinedPicker(label: L10n.t("模版"), options: templateOptions,
                               selection: $templateID, optionLabels: templateLabels)
            } else {
                OutlinedPicker(label: L10n.t("镜像"), options: isoOptions,
                               selection: $isoPath, optionLabels: isoLabels)
                OutlinedPicker(label: L10n.t("操作系统类型"), options: KVMOSType.allCases,
                               selection: $osType) { $0.displayName }
            }
        } header: {
            SectionLabel(title: fromTemplate ? L10n.t("模版") : L10n.t("安装来源"),
                         systemImage: fromTemplate ? "doc.on.doc" : "opticaldisc")
        } footer: {
            if fromTemplate, vm.templates.isEmpty {
                Text(L10n.t("暂无模版：可在「模版」段查看，或先将一台关机的虚拟机「转为模版」。"))
            } else if !fromTemplate, vm.isos.isEmpty {
                Text(L10n.t("暂无可用镜像：请先在「镜像」段添加 ISO。"))
            }
        }
    }

    private var hardwareSection: some View {
        Section {
            if !isEdit {
                OutlinedPicker(label: L10n.t("磁盘总线"), options: KVMDiskBus.allCases,
                               selection: $diskBus) { $0.displayName }
            }
            OutlinedPicker(label: L10n.t("网络"), options: networkOptions, selection: $network)
            if !isEdit {
                OutlinedPicker(label: L10n.t("存储池"), options: storageOptions, selection: $storagePool)
            }
            if isEdit {
                OutlinedPicker(label: L10n.t("启动项"), options: KVMBootOrder.allCases,
                               selection: $bootOrder) { $0.displayName }
                OutlinedPicker(label: L10n.t("镜像"), options: isoOptions,
                               selection: $isoPath, optionLabels: isoLabels)
            }
            OutlinedUnitField(label: "CPU", unit: L10n.t("核"), text: $cpuText, range: 1...512)
            OutlinedUnitField(label: L10n.t("内存"), unit: "MB", text: $memoryText, range: 128...1_048_576)
            if !isEdit {
                OutlinedUnitField(label: L10n.t("磁盘容量"), unit: "GB", text: $diskSizeText, range: 1...65_536)
            }
        } header: {
            SectionLabel(title: L10n.t("硬件配置"), systemImage: "cpu")
        } footer: {
            if isEdit {
                Text(L10n.t("磁盘容量与总线创建后不可修改"))
            }
        }
    }

    private var optionSection: some View {
        Section {
            if !isEdit {
                Toggle(L10n.t("创建后启动"), isOn: $startAfterCreate)
            }
            Toggle(L10n.t("开机自启"), isOn: $autoStart)
            OutlinedMultiLineField(label: L10n.t("描述"), lines: 3, text: $description)
        } header: {
            SectionLabel(title: L10n.t("选项"), systemImage: "slider.horizontal.3")
        }
    }

    // MARK: 选项数据

    private var templateOptions: [String] {
        let ids = vm.templates.map { String($0.id) }
        return ids.isEmpty ? [""] : ids
    }

    private var templateLabels: [String: String] {
        var labels: [String: String] = ["": L10n.t("请选择")]
        for template in vm.templates {
            labels[String(template.id)] = template.displayName
        }
        return labels
    }

    /// 镜像选项：空值 = 不挂载；仅列已就绪的镜像
    private var isoOptions: [String] {
        [""] + vm.isos.filter { $0.isReady }.compactMap(\.path)
    }

    private var isoLabels: [String: String] {
        var labels: [String: String] = ["": L10n.t("不挂载镜像")]
        for iso in vm.isos where iso.path != nil {
            labels[iso.path!] = iso.displayName
        }
        return labels
    }

    private var networkOptions: [String] {
        let names = vm.networks.compactMap(\.name)
        if names.isEmpty { return network.isEmpty ? ["default"] : [network] }
        return names.contains(network) || network.isEmpty ? names : [network] + names
    }

    private var storageOptions: [String] {
        let names = vm.storages.compactMap(\.name)
        if names.isEmpty { return storagePool.isEmpty ? ["default"] : [storagePool] }
        return names.contains(storagePool) || storagePool.isEmpty ? names : [storagePool] + names
    }

    // MARK: 回填

    /// 引用数据到达后一次性回填默认值 / 编辑态字段
    private func prefillIfNeeded() {
        guard !didPrefill else { return }
        didPrefill = true
        if let machine {
            name = machine.displayName
            isoPath = machine.isoPaths?.first ?? ""
            network = machine.network ?? ""
            storagePool = machine.storagePool ?? ""
            cpuText = String(machine.cpu ?? 1)
            memoryText = String(machine.memory ?? 1024)
            diskSizeText = String(machine.diskSize ?? 20)
            // "hd"（模版创建）归到磁盘优先
            bootOrder = KVMBootOrder(rawValue: machine.bootOrder ?? "") ?? .hdFirst
            autoStart = machine.autoStart ?? false
            description = machine.description ?? ""
            diskBus = KVMDiskBus(rawValue: machine.diskBus ?? "") ?? .virtio
        } else {
            let networkNames = vm.networks.compactMap(\.name)
            network = networkNames.contains("default") ? "default" : (networkNames.first ?? "default")
            let poolNames = vm.storages.compactMap(\.name)
            storagePool = poolNames.contains("default") ? "default" : (poolNames.first ?? "default")
            templateID = vm.templates.first.map { String($0.id) } ?? ""
        }
    }

    /// 选中模版 → 回填总线 / 网络 / 存储池 / CPU / 内存 / 磁盘容量（仍可手改）
    private func applyTemplate(_ id: String) {
        guard let template = vm.templates.first(where: { String($0.id) == id }) else {
            if templateID.isEmpty, let first = vm.templates.first { templateID = String(first.id) }
            return
        }
        if let bus = KVMDiskBus(rawValue: template.diskBus ?? "") { diskBus = bus }
        if let n = template.network, !n.isEmpty { network = n }
        if let p = template.storagePool, !p.isEmpty { storagePool = p }
        if let cpu = template.cpu { cpuText = String(cpu) }
        if let memory = template.memory { memoryText = String(memory) }
        if let disk = template.diskSize { diskSizeText = String(disk) }
    }

    // MARK: 校验与提交

    private var isValid: Bool {
        guard let cpu = Int(cpuText), cpu >= 1,
              let memory = Int(memoryText), memory >= 128,
              !network.isEmpty else { return false }
        if isEdit { return true }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !storagePool.isEmpty,
              let disk = Int(diskSizeText), disk >= 1 else { return false }
        if fromTemplate { return Int(templateID) != nil }
        return true
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let cpu = Int(cpuText) ?? 1
        let memory = Int(memoryText) ?? 1024

        if let machine {
            let request = KVMUpdateRequest(
                taskID: UUID().uuidString,
                name: machine.displayName,
                cpu: cpu,
                memory: memory,
                isoPaths: isoPath.isEmpty ? [] : [isoPath],
                network: network,
                bootOrder: bootOrder.rawValue,
                autoStart: autoStart,
                description: description)
            if let taskID = await vm.update(request) {
                presentProgress(taskID)
            }
            return
        }

        let request = KVMCreateRequest(
            name: name.trimmingCharacters(in: .whitespaces),
            cpu: cpu,
            memory: memory,
            diskSize: Int(diskSizeText) ?? 20,
            osType: osType.rawValue,
            diskBus: diskBus.rawValue,
            templateID: fromTemplate ? Int(templateID) : nil,
            storagePool: storagePool,
            isoPaths: fromTemplate || isoPath.isEmpty ? [] : [isoPath],
            network: network,
            bootOrder: fromTemplate ? "hd" : "hd,cdrom",
            startAfterCreate: startAfterCreate,
            autoStart: autoStart,
            description: description,
            taskID: UUID().uuidString)
        if let taskID = await vm.create(request) {
            presentProgress(taskID)
        }
    }

    /// 服务端未回 taskID（VM 已重拉并提示）时直接收栏
    private func presentProgress(_ taskID: String) {
        if taskID.isEmpty {
            dismiss()
        } else {
            activeTaskID = taskID
            showProgress = true
        }
    }
}
