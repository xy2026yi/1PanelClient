//
//  KVMResourceViews.swift
//  1PanelClient
//
//  虚拟机资源三段（logs/高级功能-KVM.md 抓包 2026-10-23）：
//  - 模版：列表 / 删除（默认连同删除磁盘文件，任务式；弹窗确认展示磁盘路径）
//    模版由虚拟机「转为模版」产生，无独立创建
//  - 网络：卡片列表（每网络一卡：类型 / CIDR·网关 / DHCP / 桥接或源接口 / 关联数 +
//    启停·自启·删除按钮行）/ 创建（NAT·Bridge·Macvtap；Bridge 桥接名称下拉 GET bridges
//    仅 recommended 可选、Macvtap 宿主机网卡下拉 GET interfaces；地址分配仅 NAT 显示）；
//    删除走半屏弹窗（强制删除开关 + 输入名称确认）
//  - 存储池：卡片列表（路径 + 容量条 + 启停·自启·删除按钮行）/ 创建（本地目录），删除同网络
//  网络与存储池的启停 / 自启走各自 update 端点单字段提交 {id, status} / {id, autoStart}。
//

import SwiftUI

// MARK: - 模版

struct KVMTemplateListView: View {
    @ObservedObject var vm: KVMViewModel

    @State private var actionTemplate: KVMTemplate?
    @State private var pendingDelete: KVMTemplate?

    var body: some View {
        List {
            Section {
                if vm.templates.isEmpty {
                    if vm.isLoading {
                        LoadingStateView(compact: true)
                            .padding(.vertical, 30)
                    } else {
                        ContentUnavailableView(
                            L10n.t("暂无模版"),
                            systemImage: "doc.on.doc",
                            description: Text(L10n.t("将一台关机的虚拟机「转为模版」后，可在创建时「从模版启动」"))
                        )
                        .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(vm.templates) { template in
                        Button {
                            actionTemplate = template
                        } label: {
                            templateRow(template)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } footer: {
                if !vm.templates.isEmpty {
                    Text(L10n.t("点击模版删除；删除模版不影响由其创建的虚拟机"))
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await vm.loadTemplates() }
        .sheet(item: $actionTemplate) { template in
            ActionBottomSheet(
                title: template.displayName,
                items: [
                    ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red, role: .destructive) {
                        pendingDelete = template
                    },
                ],
                onDismiss: { actionTemplate = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: 1))])
            .presentationDragIndicator(.visible)
        }
        // 删除默认连同磁盘文件（deleteDisk=true，与网页端默认一致）
        .alert(
            L10n.t("删除模版"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button(L10n.t("取消"), role: .cancel) { pendingDelete = nil }
            Button(L10n.t("确认"), role: .destructive) {
                Haptic.warning()
                if let template = pendingDelete {
                    Task { await vm.deleteTemplate(template, deleteDisk: true) }
                }
                pendingDelete = nil
            }
        } message: {
            if let template = pendingDelete {
                Text(L10n.f("删除模版 %@（%@），该操作不可回滚，是否继续？",
                            template.displayName, template.diskPath ?? "-"))
            }
        }
    }

    private func templateRow(_ template: KVMTemplate) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "doc.on.doc", color: .purple)
            VStack(alignment: .leading, spacing: 4) {
                Text(template.displayName)
                    .font(.body.bold())
                    .lineLimit(1)
                Text(L10n.f("%ld 核 · %ld MB · %ld GB",
                            template.cpu ?? 0, template.memory ?? 0, template.diskSize ?? 0))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if let source = template.sourceVM, !source.isEmpty {
                        Label(source, systemImage: "desktopcomputer")
                    }
                    if let size = template.size, size > 0 {
                        let parts = MetricFormat.byteParts(size)
                        Text("\(parts.value) \(parts.unit)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer()
            if template.isExist == false {
                StatusBadge(text: L10n.t("文件缺失"), color: .statusError)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - 网络

struct KVMNetworkListView: View {
    @ObservedObject var vm: KVMViewModel

    @State private var showCreate = false
    @State private var deleteNetwork: KVMNetwork?
    @State private var forceDelete = false

    var body: some View {
        List {
            if vm.networks.isEmpty {
                Section {
                    if vm.isLoading {
                        LoadingStateView(compact: true)
                            .padding(.vertical, 30)
                    } else {
                        ContentUnavailableView(
                            L10n.t("暂无网络"),
                            systemImage: "network",
                            description: Text(L10n.t("点击右上角 + 创建虚拟网络"))
                        )
                        .listRowBackground(Color.clear)
                    }
                }
            } else {
                // 每个网络一张卡：信息行 + 启停 / 自启 / 删除按钮行
                ForEach(vm.networks) { network in
                    networkCard(network)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await vm.loadNetworks() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("创建网络"))
            }
        }
        .navigationDestination(isPresented: $showCreate) {
            KVMNetworkFormView(vm: vm)
        }
        .sheet(item: $deleteNetwork) { network in
            TextInputConfirmSheet(
                title: L10n.t("删除网络"),
                message: L10n.f("将删除网络「%@」，该操作不可回滚。如果确认操作，请手动输入 %@。",
                                network.displayName, network.displayName),
                expectedText: network.displayName
            ) {
                await vm.deleteNetwork(network, force: forceDelete)
            } options: {
                Section {
                    Toggle(L10n.t("强制删除"), isOn: $forceDelete)
                } footer: {
                    Text(L10n.t("有关联虚拟机时不可直接删除，需开启强制删除。"))
                }
            }
            .onAppear { forceDelete = false }
        }
    }

    // MARK: 卡片

    /// 单个网络卡：头行（图标 / 名称 / 类型 / 状态）+ 地址信息 + 快捷按钮行
    private func networkCard(_ network: KVMNetwork) -> some View {
        Section {
            HStack(spacing: 12) {
                IconBadge(systemName: "network", color: .teal)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(network.displayName)
                            .font(.body.bold())
                            .lineLimit(1)
                        StatusBadge(text: KVMNetworkType(rawValue: (network.type ?? "").lowercased())?.displayName
                                    ?? (network.type ?? "-"), color: .indigo)
                    }
                    if let cidr = network.cidr, !cidr.isEmpty {
                        Text(L10n.f("%@ · 网关 %@", cidr, network.gateway ?? "-"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let start = network.dhcpStart, let end = network.dhcpEnd, !start.isEmpty {
                        Text("DHCP \(start) – \(end)")
                            .font(.dataMonospacedFootnote)
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 8) {
                        if let bridge = network.bridgeName, !bridge.isEmpty {
                            Text(bridge)
                        } else if let iface = network.sourceInterface, !iface.isEmpty {
                            Text(iface)
                        }
                        Text(L10n.f("%ld 台虚拟机", network.vmCount ?? 0))
                        if network.autoStart == true {
                            Text(L10n.t("开机自启"))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    if let error = network.error, !error.isEmpty {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
                Spacer()
                StatusBadge(text: network.isActive ? L10n.t("运行中") : L10n.t("已停止"),
                            color: network.isActive ? .statusRunning : .secondary)
            }
            .padding(.vertical, 4)
            .listRowSeparator(.hidden)

            networkActionRow(network)
        }
    }

    /// 启停 / 自启 / 删除三枚按钮（启停与自启按当前状态翻转文案、图标与颜色）
    private func networkActionRow(_ network: KVMNetwork) -> some View {
        let autoOn = network.autoStart == true
        return HStack(spacing: 8) {
            if network.isActive {
                CardActionButton(title: L10n.t("停止"), icon: "stop.fill", color: .orange) {
                    Task { await vm.setNetworkActive(network, active: false) }
                }
            } else {
                CardActionButton(title: L10n.t("启动"), icon: "play.fill", color: .green) {
                    Task { await vm.setNetworkActive(network, active: true) }
                }
            }
            CardActionButton(
                title: autoOn ? L10n.t("关闭开机自启") : L10n.t("开启开机自启"),
                icon: autoOn ? "power.circle" : "power.circle.fill", color: .blue
            ) {
                Task { await vm.setNetworkAutoStart(network, on: !autoOn) }
            }
            CardActionButton(title: L10n.t("删除"), icon: "trash", color: .red) {
                forceDelete = false
                deleteNetwork = network
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 4)
    }
}

/// 创建网络：名称 / 类型 / 类型相关字段（Bridge 桥接名称下拉——GET bridges，
/// recommended=false 置灰不可选；Macvtap 宿主机网卡下拉——GET interfaces）/ 
/// 地址分配（仅 NAT 显示）/ 自启 / 描述。
/// Bridge / Macvtap 不显示地址区，但请求体仍带网页端同款默认值
/// （抓包两次提交一致；服务端对非 NAT 类型忽略并清空存储——列表返回 cidr:""）。
struct KVMNetworkFormView: View {
    @ObservedObject var vm: KVMViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type: KVMNetworkType = .nat
    @State private var bridgeName = ""
    @State private var sourceInterface = ""
    @State private var cidr = ""
    @State private var gateway = ""
    @State private var dhcpStart = ""
    @State private var dhcpEnd = ""
    @State private var autoStart = true
    @State private var description = ""
    @State private var isSubmitting = false

    /// Bridge / Macvtap 隐藏地址区的请求体默认值（对齐网页端抓包）
    private static let hiddenCIDR = "192.168.100.0/24"
    private static let hiddenGateway = "192.168.100.1"
    private static let hiddenDHCPStart = "192.168.100.2"
    private static let hiddenDHCPEnd = "192.168.100.254"

    var body: some View {
        Form {
            Section {
                OutlinedTextField(label: L10n.t("名称"), text: $name)
                OutlinedPicker(label: L10n.t("类型"), options: KVMNetworkType.allCases,
                               selection: $type) { $0.displayName }
                if type == .bridge {
                    OutlinedPicker(label: L10n.t("桥接名称"),
                                   options: vm.bridges.compactMap(\.name),
                                   selection: $bridgeName,
                                   optionLabels: bridgeLabels,
                                   disabledOptions: unselectableBridges)
                }
                if type == .macvtap {
                    OutlinedPicker(label: L10n.t("宿主机网卡"),
                                   options: vm.hostInterfaces.compactMap(\.name),
                                   selection: $sourceInterface)
                    if let addresses = selectedInterface?.addresses, !addresses.isEmpty {
                        Text(addresses.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                SectionLabel(title: L10n.t("基本信息"), systemImage: "network")
            } footer: {
                switch type {
                case .nat: Text(L10n.t("NAT：虚拟机经宿主机地址转换访问外网，由 libvirt 分配独立网段。"))
                case .bridge: Text(L10n.t("Bridge：虚拟机桥接到宿主机网桥，与宿主机同网段。仅标记为推荐的网桥可选择。"))
                case .macvtap: Text(L10n.t("Macvtap：虚拟机直接挂到宿主机物理接口，宿主机与虚拟机互不可达。"))
                }
            }

            if type == .nat {
                Section {
                    OutlinedTextField(label: L10n.t("网络 CIDR"), prompt: "192.168.100.0/24", text: $cidr,
                                      keyboardType: .numbersAndPunctuation)
                    OutlinedTextField(label: L10n.t("网关"), prompt: "192.168.100.1", text: $gateway,
                                      keyboardType: .numbersAndPunctuation)
                    OutlinedTextField(label: L10n.t("DHCP 起始地址"), prompt: "192.168.100.2", text: $dhcpStart,
                                      keyboardType: .numbersAndPunctuation)
                    OutlinedTextField(label: L10n.t("DHCP 结束地址"), prompt: "192.168.100.254", text: $dhcpEnd,
                                      keyboardType: .numbersAndPunctuation)
                } header: {
                    SectionLabel(title: L10n.t("地址分配"), systemImage: "number")
                }
            }

            Section {
                Toggle(L10n.t("开机自启"), isOn: $autoStart)
                OutlinedMultiLineField(label: L10n.t("描述"), lines: 3, text: $description)
            }
        }
        .navigationTitle(L10n.t("创建网络"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting { ProgressView() } else { Text(L10n.t("创建")).bold() }
                }
                .disabled(!isValid || isSubmitting)
            }
        }
        .task { await vm.loadNetworkOptions() }
        .onChange(of: type) { _, _ in
            normalizeSelections()
        }
        .onChange(of: vm.bridges) { _, _ in
            normalizeSelections()
        }
        .onChange(of: vm.hostInterfaces) { _, _ in
            normalizeSelections()
        }
    }

    // MARK: 下拉数据

    /// 网桥下拉显示名：name · 来源说明（docker / libvirt）
    private var bridgeLabels: [String: String] {
        Dictionary(uniqueKeysWithValues: vm.bridges.compactMap { bridge in
            bridge.name.map { ($0, bridge.displayLabel) }
        })
    }

    /// recommended=false 的网桥（菜单置灰不可选）
    private var unselectableBridges: Set<String> {
        Set(vm.bridges.filter { !$0.isSelectable }.compactMap(\.name))
    }

    private var selectedInterface: KVMHostInterface? {
        vm.hostInterfaces.first { $0.name == sourceInterface }
    }

    /// 选中值失效（未加载 / 切类型 / 不在可选集）时回填默认：网桥取首个推荐、网卡取首个
    private func normalizeSelections() {
        if type == .bridge {
            let selectable = vm.bridges.filter(\.isSelectable).compactMap(\.name)
            if !selectable.contains(bridgeName) {
                bridgeName = selectable.first ?? ""
            }
        }
        if type == .macvtap {
            let names = vm.hostInterfaces.compactMap(\.name)
            if !names.contains(sourceInterface) {
                sourceInterface = names.first ?? ""
            }
        }
    }

    // MARK: 校验与提交

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch type {
        case .nat: return !cidr.isEmpty
        case .bridge: return !bridgeName.isEmpty && !unselectableBridges.contains(bridgeName)
        case .macvtap: return !sourceInterface.isEmpty
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        // 非 NAT 类型地址区隐藏，请求体仍带网页端同款默认值（见类型注释）
        let isNAT = type == .nat
        let request = KVMNetworkCreateRequest(
            name: name.trimmingCharacters(in: .whitespaces),
            type: type.rawValue,
            bridgeName: type == .bridge ? bridgeName : "",
            sourceInterface: type == .macvtap ? sourceInterface : "",
            cidr: isNAT ? cidr : Self.hiddenCIDR,
            gateway: isNAT ? gateway : Self.hiddenGateway,
            dhcpStart: isNAT ? dhcpStart : Self.hiddenDHCPStart,
            dhcpEnd: isNAT ? dhcpEnd : Self.hiddenDHCPEnd,
            autoStart: autoStart,
            description: description)
        if await vm.createNetwork(request) {
            dismiss()
        }
    }
}

// MARK: - 存储池

struct KVMStorageListView: View {
    @ObservedObject var vm: KVMViewModel

    @State private var showCreate = false
    @State private var deletePool: KVMStoragePool?
    @State private var forceDelete = false

    var body: some View {
        List {
            if vm.storages.isEmpty {
                Section {
                    if vm.isLoading {
                        LoadingStateView(compact: true)
                            .padding(.vertical, 30)
                    } else {
                        ContentUnavailableView(
                            L10n.t("暂无存储池"),
                            systemImage: "internaldrive",
                            description: Text(L10n.t("点击右上角 + 以本地目录创建存储池"))
                        )
                        .listRowBackground(Color.clear)
                    }
                }
            } else {
                // 每个存储池一张卡：信息行（含容量条）+ 启停 / 自启 / 删除按钮行
                ForEach(vm.storages) { pool in
                    storageCard(pool)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await vm.loadStorages() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("创建存储池"))
            }
        }
        .navigationDestination(isPresented: $showCreate) {
            KVMStorageFormView(vm: vm)
        }
        .sheet(item: $deletePool) { pool in
            TextInputConfirmSheet(
                title: L10n.t("删除存储池"),
                message: L10n.f("将删除存储池「%@」（不删除目录内文件），该操作不可回滚。如果确认操作，请手动输入 %@。",
                                pool.displayName, pool.displayName),
                expectedText: pool.displayName
            ) {
                await vm.deleteStorage(pool, force: forceDelete)
            } options: {
                Section {
                    Toggle(L10n.t("强制删除"), isOn: $forceDelete)
                } footer: {
                    Text(L10n.t("有关联虚拟机时不可直接删除，需开启强制删除。"))
                }
            }
            .onAppear { forceDelete = false }
        }
    }

    // MARK: 卡片

    /// 单个存储池卡：头行（图标 / 名称 / 类型 / 状态）+ 路径 + 容量条 + 快捷按钮行
    private func storageCard(_ pool: KVMStoragePool) -> some View {
        Section {
            HStack(spacing: 12) {
                IconBadge(systemName: "internaldrive", color: .gray)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(pool.displayName)
                            .font(.body.bold())
                            .lineLimit(1)
                        StatusBadge(text: (pool.type ?? "").lowercased() == "dir" ? L10n.t("本地目录") : (pool.type ?? "-"),
                                    color: .indigo)
                    }
                    Text(pool.path ?? "-")
                        .font(.dataMonospacedFootnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if pool.capacity != nil {
                        VStack(alignment: .leading, spacing: 2) {
                            ProgressView(value: min(max((pool.usedPercent ?? 0) / 100, 0), 1))
                                .tint((pool.usedPercent ?? 0) > 90 ? .red : .blue)
                            Text(MetricFormat.usedOverTotal(pool.usedBytes, pool.capacity)
                                 + (pool.usedPercent.map { String(format: "（%.1f%%）", $0) } ?? ""))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }
                    HStack(spacing: 8) {
                        Text(L10n.f("%ld 台虚拟机", pool.vmCount ?? 0))
                        if pool.autoStart == true {
                            Text(L10n.t("开机自启"))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    if let error = pool.error, !error.isEmpty {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
                Spacer()
                StatusBadge(text: pool.isActive ? L10n.t("运行中") : L10n.t("已停止"),
                            color: pool.isActive ? .statusRunning : .secondary)
            }
            .padding(.vertical, 4)
            .listRowSeparator(.hidden)

            storageActionRow(pool)
        }
    }

    /// 启停 / 自启 / 删除三枚按钮（启停与自启按当前状态翻转文案、图标与颜色）
    private func storageActionRow(_ pool: KVMStoragePool) -> some View {
        let autoOn = pool.autoStart == true
        return HStack(spacing: 8) {
            if pool.isActive {
                CardActionButton(title: L10n.t("停止"), icon: "stop.fill", color: .orange) {
                    Task { await vm.setStorageActive(pool, active: false) }
                }
            } else {
                CardActionButton(title: L10n.t("启动"), icon: "play.fill", color: .green) {
                    Task { await vm.setStorageActive(pool, active: true) }
                }
            }
            CardActionButton(
                title: autoOn ? L10n.t("关闭开机自启") : L10n.t("开启开机自启"),
                icon: autoOn ? "power.circle" : "power.circle.fill", color: .blue
            ) {
                Task { await vm.setStorageAutoStart(pool, on: !autoOn) }
            }
            CardActionButton(title: L10n.t("删除"), icon: "trash", color: .red) {
                forceDelete = false
                deletePool = pool
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 4)
    }
}

/// 创建存储池：名称 / 类型（本地目录，固定）/ 路径（目录选择）/ 自启 / 描述
struct KVMStorageFormView: View {
    @ObservedObject var vm: KVMViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var path = ""
    @State private var autoStart = true
    @State private var description = ""
    @State private var isSubmitting = false

    var body: some View {
        Form {
            Section {
                OutlinedTextField(label: L10n.t("名称"), text: $name)
                OutlinedShape(label: L10n.t("类型"), isFocused: false, hasValue: true,
                              trailing: { EmptyView() }) {
                    Text(L10n.t("本地目录"))
                        .foregroundStyle(.primary)
                }
                FilePathBrowseRow(title: L10n.t("路径"), path: $path, client: vm.client)
            } header: {
                SectionLabel(title: L10n.t("基本信息"), systemImage: "internaldrive")
            } footer: {
                Text(L10n.t("以服务器上的一个目录作为虚拟机磁盘与模版的存放位置；目录不存在时由服务端创建。"))
            }

            Section {
                Toggle(L10n.t("开机自启"), isOn: $autoStart)
                OutlinedMultiLineField(label: L10n.t("描述"), lines: 3, text: $description)
            }
        }
        .navigationTitle(L10n.t("创建存储池"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting { ProgressView() } else { Text(L10n.t("创建")).bold() }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || path.isEmpty || isSubmitting)
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let request = KVMStorageCreateRequest(
            name: name.trimmingCharacters(in: .whitespaces),
            path: path,
            autoStart: autoStart,
            description: description)
        if await vm.createStorage(request) {
            dismiss()
        }
    }
}
