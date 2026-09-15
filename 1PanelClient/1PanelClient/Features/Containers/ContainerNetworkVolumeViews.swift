//
//  ContainerNetworkVolumeViews.swift
//  1PanelClient
//
//  容器网络 / 存储卷管理（logs/推荐实现-容器.md 抓包 2026-09-14）：
//  列表 + 创建（网络 driver/IPv4/IPv6/排除IP；卷 NFS）+ 删除 + 清理（任务进度）
//

import SwiftUI

// MARK: - inspect 详情（网络 / 存储卷共用）

/// inspect 目标（点击行 push 详情页）
struct ContainerInspectTarget: Identifiable, Hashable {
    /// 网络用网络 id、存储卷用卷名
    let id: String
    /// network / volume
    let type: String
    let name: String
}

/// POST /containers/inspect {id, type, detail:""} → data 为 JSON 字符串，
/// 结构化分组展示（网络 / 存储卷，抓包 2026-09-14 确认）
struct ContainerInspectDetailView: View {
    let client: APIClient
    let target: ContainerInspectTarget

    @State private var sections: [InspectSectionModel]?
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else if let sections {
                List {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        Section {
                            ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                                InfoRow(row.key, value: row.value, monospaced: row.monospaced)
                            }
                            ForEach(section.containerRows) { c in
                                InfoRow(c.name, value: c.ip, monospaced: true)
                            }
                            if let raw = section.rawJSON {
                                Text(raw)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        } header: {
                            SectionLabel(title: section.title, systemImage: section.icon)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            } else {
                LoadErrorStateView(message: loadError ?? L10n.t("加载失败")) {
                    Task { await load() }
                }
            }
        }
        .navigationTitle(target.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        do {
            let raw: String = try await client.send(
                path: APIEndpoint.containersInspect.path,
                body: ContainerInspectRequest(id: target.id, type: target.type, detail: ""),
                as: String.self)
            // 服务端返回 JSON 字符串：解析后按网络/卷结构化分组
            guard let data = raw.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw APIError.invalidResponse
            }
            sections = InspectSectionsBuilder.build(type: target.type, obj: obj)
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - inspect 结构化分组

/// 单个展示分组：键值行 + 容器连接行（网络）+ 原始 JSON 兜底块
struct InspectSectionModel {
    let title: String
    let icon: String
    var rows: [(key: String, value: String, monospaced: Bool)] = []
    var containerRows: [InspectContainerRow] = []
    var rawJSON: String?
}

/// 网络连接的容器行（名称 → IP）
struct InspectContainerRow: Identifiable {
    let name: String
    let ip: String
    var id: String { name + ip }
}

nonisolated enum InspectSectionsBuilder {

    /// 按网络 / 存储卷分别结构化；未覆盖的顶层键收进「其他」
    static func build(type: String, obj: [String: Any]) -> [InspectSectionModel] {
        type == "volume" ? volumeSections(obj) : networkSections(obj)
    }

    // MARK: 网络（docker network inspect）

    private static func networkSections(_ obj: [String: Any]) -> [InspectSectionModel] {
        var used = Set<String>()
        var base = InspectSectionModel(title: L10n.t("基本信息"), icon: "info.circle")
        func kv(_ key: String, _ label: String, monospaced: Bool = false) {
            used.insert(key)
            if let v = plainValue(obj[key]), !v.isEmpty {
                base.rows.append((label, v, monospaced))
            }
        }
        kv("Name", L10n.t("名称"))
        kv("Id", "ID", monospaced: true)
        kv("Created", L10n.t("创建时间"))
        kv("Driver", L10n.t("驱动"))
        kv("Scope", L10n.t("作用域"))
        kv("EnableIPv6", L10n.t("启用 IPv6"))
        kv("Internal", L10n.t("内部网络"))
        kv("Attachable", L10n.t("可附加"))
        kv("Ingress", "Ingress")
        var sections = [base]

        used.insert("IPAM")
        if let ipam = obj["IPAM"] as? [String: Any] {
            var s = InspectSectionModel(title: "IPAM", icon: "point.3.connected.trianglepath.dotted")
            if let driver = plainValue(ipam["Driver"]), !driver.isEmpty {
                s.rows.append((L10n.t("驱动"), driver, false))
            }
            if let configs = ipam["Config"] as? [[String: Any]] {
                for (idx, cfg) in configs.enumerated() {
                    let prefix = configs.count > 1 ? "\(idx + 1) · " : ""
                    if let subnet = plainValue(cfg["Subnet"]), !subnet.isEmpty {
                        s.rows.append((prefix + L10n.t("子网"), subnet, true))
                    }
                    if let gateway = plainValue(cfg["Gateway"]), !gateway.isEmpty {
                        s.rows.append((prefix + L10n.t("网关"), gateway, true))
                    }
                    if let aux = cfg["AuxiliaryAddresses"] as? [String: Any], !aux.isEmpty {
                        for (k, v) in aux.sorted(by: { $0.key < $1.key }) {
                            s.rows.append((L10n.t("辅助 IP") + " \(k)", plainValue(v) ?? "", true))
                        }
                    }
                }
            }
            if let opts = ipam["Options"] as? [String: Any], !opts.isEmpty {
                for (k, v) in opts.sorted(by: { $0.key < $1.key }) {
                    s.rows.append((k, plainValue(v) ?? "", false))
                }
            }
            if !s.rows.isEmpty { sections.append(s) }
        }

        used.insert("Containers")
        if let containers = obj["Containers"] as? [String: Any], !containers.isEmpty {
            var s = InspectSectionModel(title: L10n.t("容器"), icon: "shippingbox")
            for value in containers.values {
                guard let c = value as? [String: Any] else { continue }
                let name = plainValue(c["Name"]) ?? L10n.t("未知")
                let ip = plainValue(c["IPv4Address"]) ?? plainValue(c["IPv6Address"]) ?? "—"
                s.containerRows.append(InspectContainerRow(name: name, ip: ip))
            }
            if !s.containerRows.isEmpty {
                s.containerRows.sort { $0.name < $1.name }
                sections.append(s)
            }
        }

        sections.append(contentsOf: dictSection(obj["Labels"], title: L10n.t("标签"), icon: "tag", used: &used, key: "Labels"))
        sections.append(contentsOf: dictSection(obj["Options"], title: L10n.t("选项"), icon: "slider.horizontal.3", used: &used, key: "Options"))
        sections.append(contentsOf: remainderSections(obj, used: used))
        return sections
    }

    // MARK: 存储卷（docker volume inspect）

    private static func volumeSections(_ obj: [String: Any]) -> [InspectSectionModel] {
        var used = Set<String>()
        var base = InspectSectionModel(title: L10n.t("基本信息"), icon: "info.circle")
        func kv(_ key: String, _ label: String, monospaced: Bool = false) {
            used.insert(key)
            if let v = plainValue(obj[key]), !v.isEmpty {
                base.rows.append((label, v, monospaced))
            }
        }
        kv("Name", L10n.t("名称"))
        kv("Driver", L10n.t("驱动"))
        kv("Mountpoint", L10n.t("挂载点"), monospaced: true)
        kv("CreatedAt", L10n.t("创建时间"))
        kv("Scope", L10n.t("作用域"))
        var sections = [base]
        sections.append(contentsOf: dictSection(obj["Labels"], title: L10n.t("标签"), icon: "tag", used: &used, key: "Labels"))
        sections.append(contentsOf: dictSection(obj["Options"], title: L10n.t("选项"), icon: "slider.horizontal.3", used: &used, key: "Options"))
        sections.append(contentsOf: remainderSections(obj, used: used))
        return sections
    }

    // MARK: 通用

    /// 字典值分组（Labels / Options 等；空/缺失不生成）
    private static func dictSection(
        _ value: Any?, title: String, icon: String, used: inout Set<String>, key: String
    ) -> [InspectSectionModel] {
        used.insert(key)
        guard let dict = value as? [String: Any], !dict.isEmpty else { return [] }
        var s = InspectSectionModel(title: title, icon: icon)
        for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
            s.rows.append((k, plainValue(v) ?? "", false))
        }
        return [s]
    }

    /// 未覆盖的顶层键收进「其他」：字典逐行、标量键值、数组/嵌套 pretty JSON
    private static func remainderSections(_ obj: [String: Any], used: Set<String>) -> [InspectSectionModel] {
        let rest = obj.filter { !used.contains($0.key) && !isEmptyValue($0.value) }
        guard !rest.isEmpty else { return [] }
        var s = InspectSectionModel(title: L10n.t("其他"), icon: "ellipsis.circle")
        for (k, v) in rest.sorted(by: { $0.key < $1.key }) {
            if let dict = v as? [String: Any] {
                for (dk, dv) in dict.sorted(by: { $0.key < $1.key }) where !isEmptyValue(dv) {
                    s.rows.append(("\(k).\(dk)", plainValue(dv) ?? "", false))
                }
            } else if let arr = v as? [Any], !arr.isEmpty {
                s.rows.append((k, arr.map { plainValue($0) ?? "" }.joined(separator: ", "), false))
            } else {
                s.rows.append((k, plainValue(v) ?? "", false))
            }
        }
        return s.rows.isEmpty ? [] : [s]
    }

    /// 任意 JSON 值 → 展示字符串（Bool true/false、数字、字符串原样）
    static func plainValue(_ v: Any?) -> String? {
        switch v {
        case nil: return nil
        case is NSNull: return nil
        case let b as Bool: return b ? "true" : "false"
        case let n as NSNumber: return n.stringValue
        case let s as String: return s.isEmpty ? nil : s
        case let arr as [Any]:
            let parts = arr.compactMap { plainValue($0) }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        default:
            return nil
        }
    }

    private static func isEmptyValue(_ v: Any?) -> Bool {
        switch v {
        case nil: return true
        case is NSNull: return true
        case let s as String: return s.isEmpty
        case let dict as [String: Any]: return dict.isEmpty
        case let arr as [Any]: return arr.isEmpty
        default: return false
        }
    }
}

// MARK: - 动态 key=value 行编辑器（参数/标签/环境变量共用）

/// 一组 "key=value" 行的增删编辑（提交时同时产出数组和换行串，匹配请求体双字段）
struct KVRowsEditor: View {
    let title: String
    @Binding var rows: [ContainerKVPair]

    var body: some View {
        Section {
            ForEach($rows) { $row in
                HStack(spacing: 8) {
                    TextField(L10n.t("标签"), text: $row.key)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField(L10n.t("值"), text: $row.value)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button {
                        rows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.t("删除"))
                }
            }
            Button {
                rows.append(ContainerKVPair(key: "", value: ""))
            } label: {
                Label(L10n.t("添加"), systemImage: "plus.circle")
            }
        } header: {
            SectionLabel(title: title, systemImage: "list.bullet.rectangle")
        } footer: {
            Text(L10n.t("可选，一行一个，格式 key=value"))
        }
    }

    /// "k=v" 数组（空行过滤）
    static func pairs(_ rows: [ContainerKVPair]) -> [String] {
        rows.map { "\($0.key)=\($0.value)" }.filter { !$0.isEmpty && $0 != "=" }
    }

    /// "k=v\nk=v" 串
    static func joined(_ rows: [ContainerKVPair]) -> String {
        pairs(rows).joined(separator: "\n")
    }
}

// MARK: - 网络管理

struct ContainerNetworksView: View {
    let server: ServerConfig

    @State private var networks: [ContainerNetwork] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var showCreate = false
    @State private var toastMessage: String?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var pendingDelete: ContainerNetwork?
    @State private var showPruneConfirm = false
    /// 清理任务（提交后跳任务进度页）
    @State private var pruneTask: ContainerPruneTask?
    /// 长按弹出的操作菜单对应的网络
    @State private var actionItem: ContainerNetwork?
    /// 点击行查看详情（inspect）
    @State private var detailTarget: ContainerInspectTarget?
    /// 菜单收起后再执行的动作（避免与下一级弹窗竞争）
    @State private var pendingMenuAction: (() -> Void)?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); LoadingStateView(); Spacer() }
                    .listRowBackground(Color.clear)
            } else if let err = loadError {
                LoadErrorStateView(message: err) {
                    Task { await load() }
                }
                .listRowBackground(Color.clear)
            } else if networks.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无网络"),
                    systemImage: "network",
                    description: Text(L10n.t("点击右上角 + 创建网络")))
                .listRowBackground(Color.clear)
            } else {
                ForEach(networks) { network in
                    networkRow(network)
                        .contentShape(Rectangle())
                        // 点击查看详情（inspect JSON）；长按弹操作菜单
                        .onTapGesture {
                            detailTarget = ContainerInspectTarget(
                                id: network.id, type: "network", name: network.name)
                        }
                        .onLongPressGesture(minimumDuration: 0.5) {
                            Haptic.selection()
                            actionItem = network
                        }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("容器网络"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("创建网络"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showPruneConfirm = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(L10n.t("更多操作"))
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .toastOverlay(message: $toastMessage)
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(L10n.t("删除网络"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingDelete = nil }
            Button(L10n.t("删除"), role: .destructive) {
                if let network = pendingDelete {
                    Task { await delete(network) }
                }
            }
        } message: {
            Text(L10n.f("确定删除网络「%@」吗？", pendingDelete?.name ?? ""))
        }
        .alert(L10n.t("清理网络"), isPresented: $showPruneConfirm) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("确认清理"), role: .destructive) {
                Task { await prune(type: "network", title: L10n.t("清理网络")) }
            }
        } message: {
            Text(L10n.t("清理网络 将删除所有未被使用的网络，该操作无法回滚，是否继续？"))
        }
        .sheet(isPresented: $showCreate) {
            ContainerNetworkCreateSheet(server: server) {
                Task { await load() }
            }
        }
        .sheet(item: $actionItem, onDismiss: {
            runPendingMenuAction()
        }) { network in
            ActionBottomSheet(
                title: network.name,
                items: [
                    ActionMenuItem(title: L10n.t("详情"), icon: "info.circle", color: .blue) {
                        pendingMenuAction = {
                            detailTarget = ContainerInspectTarget(
                                id: network.id, type: "network", name: network.name)
                        }
                    },
                    ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red, role: .destructive) {
                        pendingMenuAction = { pendingDelete = network }
                    },
                ],
                onDismiss: { actionItem = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: 2))])
            .presentationDragIndicator(.visible)
        }
        .navigationDestination(item: $detailTarget) { target in
            ContainerInspectDetailView(client: client, target: target)
        }
        .navigationDestination(item: $pruneTask) { task in
            TaskProgressView(taskID: task.taskID, title: task.title) { isDone in
                if isDone { Task { await load() } }
                return false
            }
        }
    }

    /// 菜单完全收起后再执行挂起动作（与文件模块一致）
    private func runPendingMenuAction() {
        guard let action = pendingMenuAction else { return }
        pendingMenuAction = nil
        action()
    }

    private func networkRow(_ network: ContainerNetwork) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(network.name).font(.body.weight(.medium))
                Spacer()
                Text(network.driver ?? "-")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let subnet = network.subnet, !subnet.isEmpty {
                HStack(spacing: 8) {
                    Text(subnet)
                    if let gateway = network.gateway, !gateway.isEmpty {
                        Text("· " + gateway)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        do {
            let resp: PageResponse<ContainerNetwork> = try await client.send(
                path: APIEndpoint.containersNetworkSearch.path,
                body: ContainerPageRequest(page: 1, pageSize: 100),
                as: PageResponse<ContainerNetwork>.self)
            networks = resp.items ?? []
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func delete(_ network: ContainerNetwork) async {
        pendingDelete = nil
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersNetworkDelete.path,
                body: ContainerNamesDeleteRequest(names: [network.name]),
                as: EmptyResponse.self)
            toastMessage = L10n.f("已删除「%@」", network.name)
            await load()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// 清理未使用资源（网络/存储卷共用；抓包：pruneType + taskID 任务日志）；
    /// 失败抛错，由调用方提示（用户已确认不可回滚操作，不能静默吞掉失败）
    static func prune(client: APIClient, type: String, title: String) async throws -> String {
        let taskID = UUID().uuidString
        let _: EmptyResponse = try await client.send(
            path: APIEndpoint.containersPrune.path,
            body: ContainerPruneRequest(taskID: taskID, pruneType: type, withTagAll: false),
            as: EmptyResponse.self)
        return taskID
    }

    private func prune(type: String, title: String) async {
        do {
            let taskID = try await Self.prune(client: client, type: type, title: title)
            pruneTask = ContainerPruneTask(taskID: taskID, title: title)
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

/// 清理任务（任务进度页参数）
struct ContainerPruneTask: Identifiable, Hashable {
    let taskID: String
    let title: String
    var id: String { taskID }
}

// MARK: - 网络创建 Sheet

private struct ContainerNetworkCreateSheet: View {
    let server: ServerConfig
    let onCreated: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var driver = "bridge"
    @State private var parentCard = ""
    @State private var netCards: [String] = []
    @State private var ipv4 = true
    @State private var subnet = ""
    @State private var gateway = ""
    @State private var ipRange = ""
    @State private var auxRows: [ContainerKVPair] = []
    @State private var ipv6 = false
    @State private var subnetV6 = ""
    @State private var gatewayV6 = ""
    @State private var ipRangeV6 = ""
    @State private var auxRowsV6: [ContainerKVPair] = []
    @State private var optionRows: [ContainerKVPair] = []
    @State private var labelRows: [ContainerKVPair] = []
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showError = false

    private let client: APIClient
    private let drivers = ["bridge", "ipvlan", "macvlan", "overlay"]

    init(server: ServerConfig, onCreated: @escaping () async -> Void) {
        self.server = server
        self.onCreated = onCreated
        self.client = APIClient.shared(for: server)
    }

    private var canSubmit: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && (!ipv4 || !subnet.isEmpty) && (!ipv6 || !subnetV6.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.t("网络名"), text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Picker(L10n.t("模式"), selection: $driver) {
                        ForEach(drivers, id: \.self) { Text($0).tag($0) }
                    }
                    // 父网卡仅 macvlan / overlay 需要（抓包：ipvlan 未携带）
                    if driver == "macvlan" || driver == "overlay" {
                        Picker(L10n.t("父网卡"), selection: $parentCard) {
                            ForEach(netCards, id: \.self) { Text($0).tag($0) }
                        }
                    }
                } header: {
                    SectionLabel(title: L10n.t("基本信息"), systemImage: "network")
                }

                if ipv6Section {
                    Section {
                        Toggle("IPv4", isOn: $ipv4)
                        if ipv4 {
                            ipv4Fields
                        }
                    } header: {
                        SectionLabel(title: "IPv4", systemImage: "4.circle")
                    }
                    Section {
                        Toggle("IPv6", isOn: $ipv6)
                        if ipv6 {
                            ipv6Fields
                        }
                    } header: {
                        SectionLabel(title: "IPv6", systemImage: "6.circle")
                    }
                }

                KVRowsEditor(title: L10n.t("参数"), rows: $optionRows)
                KVRowsEditor(title: L10n.t("标签"), rows: $labelRows)
            }
            .navigationTitle(L10n.t("创建网络"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("创建")) {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit || isSubmitting)
                }
            }
            .alert(L10n.t("提示"), isPresented: $showError) {
                Button(L10n.t("好的"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task { await loadNetCards() }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.large])
        .interactiveDismissDisabled(isSubmitting)
    }

    /// 桥接模式无独立地址段配置（抓包：bridge 只带 subnet；简化为 IPv4/IPv6 面板常显）
    private var ipv6Section: Bool { true }

    @ViewBuilder private var ipv4Fields: some View {
        TextField(L10n.t("子网"), text: $subnet)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        TextField(L10n.t("网关（可选）"), text: $gateway)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        TextField(L10n.t("IP 范围（可选）"), text: $ipRange)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        auxRowsEditor($auxRows, title: L10n.t("排除 IP"))
    }

    @ViewBuilder private var ipv6Fields: some View {
        TextField(L10n.t("子网"), text: $subnetV6)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        TextField(L10n.t("网关（可选）"), text: $gatewayV6)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        TextField(L10n.t("IP 范围（可选）"), text: $ipRangeV6)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        auxRowsEditor($auxRowsV6, title: L10n.t("排除 IP"))
    }

    /// 排除 IP 行（标签 + IP）
    private func auxRowsEditor(_ rows: Binding<[ContainerKVPair]>, title: String) -> some View {
        Section {
            ForEach(rows.wrappedValue.indices, id: \.self) { idx in
                HStack(spacing: 8) {
                    TextField(L10n.t("标签"), text: rows[idx].key)
                        .frame(maxWidth: 90)
                        .autocorrectionDisabled()
                    TextField("IP", text: rows[idx].value)
                        // IPv6 排除地址需输入冒号，不用 decimalPad
                        .autocorrectionDisabled()
                }
            }
            .onDelete { rows.wrappedValue.remove(atOffsets: $0) }
            Button {
                rows.wrappedValue.append(ContainerKVPair(key: "", value: ""))
            } label: {
                Label(title, systemImage: "plus.circle")
            }
        }
    }

    private func loadNetCards() async {
        // GET /hosts/monitor/netoptions（复用监控模块端点；过滤 all）
        if let options: [String] = try? await client.send(
            path: APIEndpoint.monitorNetOptions.path, method: "GET", as: [String].self) {
            netCards = options.filter { $0 != "all" }
            parentCard = netCards.first ?? ""
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let req = ContainerNetworkCreateRequest(
            name: name.trimmingCharacters(in: .whitespaces),
            parentNetworkCard: driver == "macvlan" || driver == "overlay" ? parentCard : "",
            labelStr: KVRowsEditor.joined(labelRows),
            labels: KVRowsEditor.pairs(labelRows),
            optionStr: KVRowsEditor.joined(optionRows),
            options: KVRowsEditor.pairs(optionRows),
            driver: driver,
            ipv4: ipv4,
            subnet: ipv4 ? subnet : "",
            gateway: ipv4 ? gateway : "",
            ipRange: ipv4 ? ipRange : "",
            auxAddress: ipv4 ? auxRows : [],
            ipv6: ipv6,
            subnetV6: ipv6 ? subnetV6 : "",
            gatewayV6: ipv6 ? gatewayV6 : "",
            ipRangeV6: ipv6 ? ipRangeV6 : "",
            auxAddressV6: ipv6 ? auxRowsV6 : [])
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersNetworkCreate.path, body: req, as: EmptyResponse.self)
            await onCreated()
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - 存储卷管理

struct ContainerVolumesView: View {
    let server: ServerConfig

    @State private var volumes: [ContainerVolume] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var showCreate = false
    @State private var toastMessage: String?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var pendingDelete: ContainerVolume?
    @State private var showPruneConfirm = false
    @State private var pruneTask: ContainerPruneTask?
    /// 长按弹出的操作菜单对应的存储卷
    @State private var actionItem: ContainerVolume?
    /// 点击行查看详情（inspect）
    @State private var detailTarget: ContainerInspectTarget?
    /// 菜单收起后再执行的动作
    @State private var pendingMenuAction: (() -> Void)?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); LoadingStateView(); Spacer() }
                    .listRowBackground(Color.clear)
            } else if let err = loadError {
                LoadErrorStateView(message: err) {
                    Task { await load() }
                }
                .listRowBackground(Color.clear)
            } else if volumes.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无存储卷"),
                    systemImage: "externaldrive.fill.badge.timemachine",
                    description: Text(L10n.t("点击右上角 + 创建存储卷")))
                .listRowBackground(Color.clear)
            } else {
                ForEach(volumes) { volume in
                    volumeRow(volume)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            detailTarget = ContainerInspectTarget(
                                id: volume.name, type: "volume", name: volume.name)
                        }
                        .onLongPressGesture(minimumDuration: 0.5) {
                            Haptic.selection()
                            actionItem = volume
                        }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("存储卷"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("创建存储卷"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showPruneConfirm = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(L10n.t("更多操作"))
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .toastOverlay(message: $toastMessage)
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(L10n.t("删除存储卷"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingDelete = nil }
            Button(L10n.t("删除"), role: .destructive) {
                if let volume = pendingDelete {
                    Task { await delete(volume) }
                }
            }
        } message: {
            Text(L10n.f("确定删除存储卷「%@」吗？", pendingDelete?.name ?? ""))
        }
        .alert(L10n.t("清理存储卷"), isPresented: $showPruneConfirm) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("确认清理"), role: .destructive) {
                Task {
                    do {
                        let taskID = try await ContainerNetworksView.prune(
                            client: client, type: "volume", title: L10n.t("清理存储卷"))
                        pruneTask = ContainerPruneTask(taskID: taskID, title: L10n.t("清理存储卷"))
                    } catch {
                        guard !APIError.isCancellation(error) else { return }
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            }
        } message: {
            Text(L10n.t("清理存储卷 将删除所有未被使用的本地存储卷，该操作无法回滚，是否继续？"))
        }
        .sheet(isPresented: $showCreate) {
            ContainerVolumeCreateSheet(server: server) {
                Task { await load() }
            }
        }
        .sheet(item: $actionItem, onDismiss: {
            runPendingMenuAction()
        }) { volume in
            ActionBottomSheet(
                title: volume.name,
                items: [
                    ActionMenuItem(title: L10n.t("详情"), icon: "info.circle", color: .blue) {
                        pendingMenuAction = {
                            detailTarget = ContainerInspectTarget(
                                id: volume.name, type: "volume", name: volume.name)
                        }
                    },
                    ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red, role: .destructive) {
                        pendingMenuAction = { pendingDelete = volume }
                    },
                ],
                onDismiss: { actionItem = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: 2))])
            .presentationDragIndicator(.visible)
        }
        .navigationDestination(item: $detailTarget) { target in
            ContainerInspectDetailView(client: client, target: target)
        }
        .navigationDestination(item: $pruneTask) { task in
            TaskProgressView(taskID: task.taskID, title: task.title) { isDone in
                if isDone { Task { await load() } }
                return false
            }
        }
    }

    /// 菜单完全收起后再执行挂起动作
    private func runPendingMenuAction() {
        guard let action = pendingMenuAction else { return }
        pendingMenuAction = nil
        action()
    }

    private func volumeRow(_ volume: ContainerVolume) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(volume.name).font(.body.weight(.medium))
                Spacer()
                Text(volume.driver ?? "-")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let mountpoint = volume.mountpoint, !mountpoint.isEmpty {
                Text(mountpoint)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            // NFS 等挂载参数（type=nfs4 / o=addr… / device）
            if let options = volume.options, !options.isEmpty {
                Text(options.map { "\($0.key)=\($0.value)" }.joined(separator: "  "))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        do {
            let resp: PageResponse<ContainerVolume> = try await client.send(
                path: APIEndpoint.containersVolumeSearch.path,
                body: ContainerPageRequest(page: 1, pageSize: 100),
                as: PageResponse<ContainerVolume>.self)
            volumes = resp.items ?? []
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func delete(_ volume: ContainerVolume) async {
        pendingDelete = nil
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersVolumeDelete.path,
                body: ContainerNamesDeleteRequest(names: [volume.name]),
                as: EmptyResponse.self)
            toastMessage = L10n.f("已删除「%@」", volume.name)
            await load()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - 存储卷创建 Sheet（NFS 可选）

private struct ContainerVolumeCreateSheet: View {
    let server: ServerConfig
    let onCreated: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var nfsEnabled = false
    @State private var nfsAddress = ""
    @State private var nfsVersion = "v4"
    @State private var nfsMount = ""
    @State private var nfsOption = "rw,noatime,rsize=8192,wsize=8192,tcp,timeo=14"
    @State private var optionRows: [ContainerKVPair] = []
    @State private var labelRows: [ContainerKVPair] = []
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showError = false

    private let client: APIClient

    init(server: ServerConfig, onCreated: @escaping () async -> Void) {
        self.server = server
        self.onCreated = onCreated
        self.client = APIClient.shared(for: server)
    }

    private var canSubmit: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        if nfsEnabled {
            return !nfsAddress.isEmpty && !nfsMount.isEmpty
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.t("名称"), text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Picker(L10n.t("模式"), selection: .constant("local")) {
                        Text("local").tag("local")
                    }
                } header: {
                    SectionLabel(title: L10n.t("基本信息"), systemImage: "externaldrive")
                }

                Section {
                    Toggle(L10n.t("启用 NFS 存储"), isOn: $nfsEnabled)
                    if nfsEnabled {
                        TextField(L10n.t("地址"), text: $nfsAddress)
                            // NFS 地址可为域名（含字母），不用 decimalPad
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Picker(L10n.t("版本"), selection: $nfsVersion) {
                            Text("NFS").tag("v3")
                            Text("NFS4").tag("v4")
                        }
                        TextField(L10n.t("挂载点"), text: $nfsMount)
                            .autocorrectionDisabled()
                        TextField(L10n.t("可选参数"), text: $nfsOption)
                            .font(.system(.footnote, design: .monospaced))
                            .autocorrectionDisabled()
                    }
                } header: {
                    SectionLabel(title: "NFS", systemImage: "externaldrive.badge.icloud")
                }

                KVRowsEditor(title: L10n.t("参数"), rows: $optionRows)
                KVRowsEditor(title: L10n.t("标签"), rows: $labelRows)
            }
            .navigationTitle(L10n.t("创建存储卷"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("创建")) {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit || isSubmitting)
                }
            }
            .alert(L10n.t("提示"), isPresented: $showError) {
                Button(L10n.t("好的"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.large])
        .interactiveDismissDisabled(isSubmitting)
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        // NFS 开启时按抓包推导三条挂载参数（type / o / device），并入 options
        var options = KVRowsEditor.pairs(optionRows)
        if nfsEnabled {
            let nfsType = nfsVersion == "v3" ? "nfs" : "nfs4"
            options += [
                "type=\(nfsType)",
                "o=addr=\(nfsAddress),\(nfsOption)",
                "device=:\(nfsMount)",
            ]
        }
        var req = ContainerVolumeCreateRequest(
            name: name.trimmingCharacters(in: .whitespaces),
            driver: "local",
            labelStr: KVRowsEditor.joined(labelRows),
            labels: KVRowsEditor.pairs(labelRows),
            optionStr: KVRowsEditor.joined(optionRows),
            options: options)
        if nfsEnabled {
            req.nfsStatus = "enable"
            req.nfsAddress = nfsAddress
            req.nfsVersion = nfsVersion
            req.nfsMount = nfsMount
            req.nfsOption = nfsOption
        }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersVolumeCreate.path, body: req, as: EmptyResponse.self)
            await onCreated()
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
