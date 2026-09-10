//
//  DisksView.swift
//  1PanelClient
//
//  磁盘管理：磁盘总览（系统盘含分区 / 未分区盘 / 数据盘）、立即分区、挂载 / 取消挂载。
//  GET /api/v2/hosts/disks；POST /disks/partition、/disks/mount、/disks/unmount
//  接口见 logs/SSH服务管理.md 抓包
//

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class DisksViewModel: ObservableObject {
    @Published var info: DisksResponse?
    @Published var isLoading = false
    @Published var errorMessage: String?

    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var toastMessage: String?
    private var toastTask: Task<Void, Never>?

    /// 挂载表单（分区 or 挂载共用）
    @Published var formTarget: MountFormTarget?
    /// 取消挂载确认
    @Published var pendingUnmount: DiskBasicInfo?

    /// 挂载表单目标：未分区磁盘（立即分区）或已有分区（挂载，文件系统沿用）
    enum MountFormTarget: Identifiable {
        /// 未分区磁盘：立即分区（device 如 "sdb"）
        case partitionDisk(DiskBasicInfo)
        /// 已有分区未挂载：挂载（device 如 "/dev/sdb1"，文件系统不可改）
        case mountPartition(DiskBasicInfo)

        var id: String {
            switch self {
            case .partitionDisk(let d): return "partition-\(d.device ?? "")"
            case .mountPartition(let d): return "mount-\(d.device ?? "")"
            }
        }

        var disk: DiskBasicInfo {
            switch self {
            case .partitionDisk(let d), .mountPartition(let d): return d
            }
        }

        var isPartitionMode: Bool {
            if case .partitionDisk = self { return true }
            return false
        }
    }

    private(set) var client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient.shared(for: server)
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            info = try await client.send(
                path: APIEndpoint.disksList.path,
                method: APIEndpoint.disksList.method,
                as: DisksResponse.self
            )
        } catch let err as APIError {
            guard !err.isCancellation else { return }
            errorMessage = err.errorDescription
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// 立即分区（成功返回新建分区名，如 /dev/sdb1）
    @discardableResult
    func partition(disk: DiskBasicInfo, filesystem: String, mountPoint: String, autoMount: Bool, noFail: Bool) async -> Bool {
        let req = DiskPartitionRequest(
            device: disk.device ?? "",
            filesystem: filesystem,
            autoMount: autoMount,
            noFail: noFail,
            mountPoint: mountPoint
        )
        do {
            let newPartition: String = try await client.send(
                path: APIEndpoint.disksPartition.path,
                body: req,
                as: String.self
            )
            showToast(L10n.f("分区 %@ 已创建并挂载", (newPartition as NSString).lastPathComponent))
            await load()
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("分区失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("分区失败：%@", error.localizedDescription))
            return false
        }
    }

    @discardableResult
    func mount(partition: DiskBasicInfo, mountPoint: String, autoMount: Bool, noFail: Bool) async -> Bool {
        let req = DiskMountRequest(
            device: partition.device ?? "",
            mountPoint: mountPoint,
            filesystem: partition.filesystem ?? "",
            autoMount: autoMount,
            noFail: noFail
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.disksMount.path,
                body: req,
                as: EmptyResponse.self
            )
            showToast(L10n.f("分区 %@ 已挂载", partition.shortDevice))
            await load()
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("挂载失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("挂载失败：%@", error.localizedDescription))
            return false
        }
    }

    @discardableResult
    func unmount(partition: DiskBasicInfo) async -> Bool {
        pendingUnmount = nil
        let req = DiskUnmountRequest(mountPoint: partition.mountPoint ?? "")
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.disksUnmount.path,
                body: req,
                as: EmptyResponse.self
            )
            showToast(L10n.f("分区 %@ 已取消挂载", partition.shortDevice))
            await load()
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("取消挂载失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("取消挂载失败：%@", error.localizedDescription))
            return false
        }
    }

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { self?.toastMessage = nil }
        }
    }
}

// MARK: - 磁盘管理页

struct DisksView: View {
    @StateObject private var vm: DisksViewModel
    /// 长按弹出的操作菜单目标（分区行；携带所属磁盘以判断系统盘）
    @State private var actionPartition: PartitionAction?
    /// 长按弹出的操作菜单目标（未分区磁盘行）
    @State private var actionUnpartitioned: DiskBasicInfo?

    /// 分区操作目标：分区 + 所属磁盘（系统盘分区不支持取消挂载）
    struct PartitionAction: Identifiable {
        let disk: DiskInfo
        let partition: DiskBasicInfo
        var id: String { partition.id }
    }

    init(server: ServerConfig) {
        _vm = StateObject(wrappedValue: DisksViewModel(server: server))
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.info == nil {
                LoadingStateView()
            } else if let err = vm.errorMessage, !err.isEmpty, vm.info == nil {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button(L10n.t("重试")) {
                        Task { await vm.load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if vm.info == nil
                || ((vm.info?.systemDisks?.isEmpty ?? true)
                    && (vm.info?.unpartitionedDisks?.isEmpty ?? true)
                    && (vm.info?.disks?.isEmpty ?? true)) {
                ContentUnavailableView(
                    L10n.t("未获取到磁盘信息"),
                    systemImage: "internaldrive"
                )
            } else {
                diskList
            }
        }
        .navigationTitle(L10n.t("磁盘管理"))
        .navigationBarTitleDisplayMode(.inline)
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .alert(
            L10n.t("取消挂载"),
            isPresented: Binding(
                get: { vm.pendingUnmount != nil },
                set: { if !$0 { vm.pendingUnmount = nil } }
            ),
            presenting: vm.pendingUnmount
        ) { partition in
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("确认"), role: .destructive) {
                Task { await vm.unmount(partition: partition) }
            }
        } message: { partition in
            Text(L10n.f("是否取消挂载分区 %@？", partition.shortDevice))
        }
        .sheet(item: $vm.formTarget) { target in
            DiskMountFormSheet(target: target, vm: vm)
        }
        .sheet(item: $actionPartition) { partition in
            partitionMenu(partition)
        }
        .sheet(item: $actionUnpartitioned) { disk in
            unpartitionedMenu(disk)
        }
        .task { await vm.load() }
        .refreshable { await vm.load() }
    }

    private var diskList: some View {
        List {
            // 总览
            Section {
                InfoRow(L10n.t("磁盘数量"), value: "\(vm.info?.totalDisks ?? 0)")
                if let capacity = vm.info?.totalCapacity, capacity > 0 {
                    InfoRow(L10n.t("总容量"), value: ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file))
                }
            } header: {
                SectionLabel(title: L10n.t("总览"), systemImage: "internaldrive")
            }

            // 系统磁盘（含分区）
            if let systemDisks = vm.info?.systemDisks, !systemDisks.isEmpty {
                Section {
                    ForEach(systemDisks) { disk in
                        DiskCard(disk: disk, onPartitionAction: { partition in
                            actionPartition = PartitionAction(disk: disk, partition: partition)
                        })
                    }
                } header: {
                    SectionLabel(title: L10n.t("系统磁盘"), systemImage: "internaldrive.fill")
                }
            }

            // 数据磁盘（已挂载的非系统盘）
            if let dataDisks = vm.info?.disks, !dataDisks.isEmpty {
                Section {
                    ForEach(dataDisks) { disk in
                        DiskCard(disk: disk, onPartitionAction: { partition in
                            actionPartition = PartitionAction(disk: disk, partition: partition)
                        })
                    }
                } header: {
                    SectionLabel(title: L10n.t("数据磁盘"), systemImage: "externaldrive.fill")
                }
            }

            // 未分区磁盘（可立即分区）
            if let unpartitioned = vm.info?.unpartitionedDisks, !unpartitioned.isEmpty {
                Section {
                    ForEach(unpartitioned) { disk in
                        UnpartitionedDiskRow(disk: disk)
                            .contentShape(Rectangle())
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                    Haptic.selection()
                                    actionUnpartitioned = disk
                                }
                            )
                    }
                } header: {
                    SectionLabel(title: L10n.t("未分区磁盘"), systemImage: "externaldrive")
                } footer: {
                    Text(L10n.t("长按磁盘可进行分区；分区会格式化所选磁盘，请谨慎操作。"))
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// 分区长按菜单：已挂载（且非系统盘/swap）→ 取消挂载；未挂载且有文件系统 → 挂载。
    /// 系统盘分区（/、/boot 等）不提供取消挂载
    private func partitionMenu(_ action: PartitionAction) -> some View {
        ActionBottomSheet(
            title: action.partition.shortDevice,
            items: partitionMenuItems(action),
            onDismiss: { actionPartition = nil }
        )
        .bottomSheetDetents([.height(ActionBottomSheet.height(for: partitionMenuItems(action).count))])
        .presentationDragIndicator(.visible)
    }

    private func partitionMenuItems(_ action: PartitionAction) -> [ActionMenuItem] {
        let partition = action.partition
        var items: [ActionMenuItem] = []
        if partition.isMounted == true {
            // swap 不可取消挂载；系统盘分区（/、/boot 等）取消挂载会导致系统异常，同样不提供
            if !partition.isSwap && action.disk.isSystem != true {
                items.append(ActionMenuItem(title: L10n.t("取消挂载"), icon: "eject", color: .red, role: .destructive) {
                    vm.pendingUnmount = partition
                })
            }
        } else if let fs = partition.filesystem, !fs.isEmpty, fs != "swap" {
            items.append(ActionMenuItem(title: L10n.t("挂载"), icon: "arrow.down.to.line.compact") {
                vm.formTarget = .mountPartition(partition)
            })
        }
        if items.isEmpty {
            // swap / 无文件系统 / 系统盘已挂载分区：无可执行操作，给出只读说明
            let reason: String
            if partition.isSwap {
                reason = L10n.t("交换分区")
            } else if action.disk.isSystem == true {
                reason = L10n.t("系统盘分区不支持取消挂载")
            } else {
                reason = L10n.t("无可用操作")
            }
            items.append(ActionMenuItem(title: reason, icon: "info.circle") {})
        }
        return items
    }

    /// 未分区磁盘长按菜单：立即分区
    private func unpartitionedMenu(_ disk: DiskBasicInfo) -> some View {
        ActionBottomSheet(
            title: disk.shortDevice,
            items: [
                ActionMenuItem(title: L10n.t("立即分区"), icon: "square.split.2x1", color: .red, role: .destructive) {
                    vm.formTarget = .partitionDisk(disk)
                },
            ],
            onDismiss: { actionUnpartitioned = nil }
        )
        .bottomSheetDetents([.height(ActionBottomSheet.height(for: 1))])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - 磁盘卡片（磁盘头 + 分区列表）

private struct DiskCard: View {
    let disk: DiskInfo
    /// 分区长按回调（弹操作菜单）
    var onPartitionAction: (DiskBasicInfo) -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 磁盘头
            HStack(spacing: 10) {
                Image(systemName: "internaldrive.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(disk.model?.isEmpty == false ? disk.model! : disk.shortDevice)
                        .font(.body.bold())
                        .lineLimit(1)
                    Text("\(disk.shortDevice) · \(disk.size ?? "—") · \(disk.diskType ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if disk.isSystem == true {
                    StatusBadge(text: L10n.t("系统盘"), color: .blue)
                }
            }

            // 分区列表（长按弹操作菜单）
            if let partitions = disk.partitions, !partitions.isEmpty {
                Divider()
                ForEach(partitions) { partition in
                    PartitionRow(partition: partition)
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                Haptic.selection()
                                onPartitionAction(partition)
                            }
                        )
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 分区行

private struct PartitionRow: View {
    let partition: DiskBasicInfo

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(partition.shortDevice)
                        .font(.subheadline.monospaced().weight(.medium))
                    if partition.isSwap {
                        StatusBadge(text: L10n.t("交换分区"), color: .secondary)
                    }
                }
                if let mountPoint = partition.mountPoint, !mountPoint.isEmpty {
                    Text(L10n.f("挂载点：%@", mountPoint))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(partition.used ?? "—") / \(partition.size ?? "—")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let percent = partition.usePercent, percent > 0 {
                    Text("\(percent)%")
                        .font(.caption2.monospaced().bold())
                        .foregroundStyle(percent >= 90 ? .red : .secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 未分区磁盘行

private struct UnpartitionedDiskRow: View {
    let disk: DiskBasicInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(disk.model?.isEmpty == false ? disk.model! : disk.shortDevice)
                    .font(.body.bold())
                    .lineLimit(1)
                Text("\(disk.shortDevice) · \(disk.size ?? "—") · \(disk.diskType ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(L10n.t("未分区"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 分区 / 挂载表单（共用）

/// 立即分区与挂载共用表单：挂载模式文件系统沿用分区现有格式不可改
private struct DiskMountFormSheet: View {
    let target: DisksViewModel.MountFormTarget
    @ObservedObject var vm: DisksViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var filesystem = "ext4"
    @State private var mountPoint = ""
    @State private var autoMount = true
    @State private var noFail = true
    @State private var showDirPicker = false

    private var disk: DiskBasicInfo { target.disk }
    private var isPartitionMode: Bool { target.isPartitionMode }

    private var canSubmit: Bool {
        mountPoint.hasPrefix("/") && !mountPoint.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.t("目标")) {
                    InfoRow(isPartitionMode ? L10n.t("磁盘") : L10n.t("分区"),
                            value: disk.shortDevice, monospaced: true)
                    InfoRow(L10n.t("容量"), value: disk.size ?? "—")
                }

                Section {
                    Picker(L10n.t("文件系统"), selection: $filesystem) {
                        Text("ext4").tag("ext4")
                        Text("xfs").tag("xfs")
                    }
                    .disabled(!isPartitionMode)
                    .foregroundStyle(isPartitionMode ? .primary : .secondary)

                    HStack {
                        TextField(L10n.t("挂载目录"), text: $mountPoint)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            showDirPicker = true
                        } label: {
                            Image(systemName: "folder.badge.plus")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L10n.t("浏览目录"))
                    }

                    Toggle(L10n.t("开机自动挂载"), isOn: $autoMount)
                    Toggle(L10n.t("挂载失败不影响系统启动"), isOn: $noFail)
                } header: {
                    Text(L10n.t("挂载设置"))
                } footer: {
                    if isPartitionMode {
                        Text(L10n.t("分区将格式化该磁盘并挂载到指定目录，磁盘上现有数据会全部丢失。"))
                    } else {
                        Text(L10n.f("文件系统沿用分区现有格式（%@），不可更改。", filesystem))
                    }
                }
            }
            .navigationTitle(isPartitionMode ? L10n.t("立即分区") : L10n.t("挂载分区"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("确认")) {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit)
                }
            }
            .sheet(isPresented: $showDirPicker) {
                DirectoryPickerSheet { path in
                    mountPoint = path
                }
            }
            .onAppear {
                // 挂载模式沿用分区现有文件系统且不可改
                if !isPartitionMode, let fs = disk.filesystem, !fs.isEmpty {
                    filesystem = fs
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func submit() async {
        let point = mountPoint.trimmingCharacters(in: .whitespaces)
        let ok: Bool
        if isPartitionMode {
            ok = await vm.partition(disk: disk, filesystem: filesystem, mountPoint: point, autoMount: autoMount, noFail: noFail)
        } else {
            ok = await vm.mount(partition: disk, mountPoint: point, autoMount: autoMount, noFail: noFail)
        }
        if ok { dismiss() }
    }
}

// MARK: - 服务端目录选择器（挂载点浏览；支持新建文件夹）

/// 轻量目录浏览器：仅列子目录，可逐级进入/返回、新建文件夹、选定当前目录。
/// 数据来自 POST /api/v2/files/search（只取 isDir 项），复用 FileItem / FileCreateSheet。
struct DirectoryPickerSheet: View {
    /// 选定目录回调（绝对路径，以 / 开头）
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentPath = "/"
    @State private var dirs: [FileItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showCreateFolder = false
    @State private var loadGeneration = 0

    private let client: APIClient

    init(onPick: @escaping (String) -> Void) {
        self.onPick = onPick
        self.client = APIClient.shared(for: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && dirs.isEmpty {
                    LoadingStateView()
                } else if let err = errorMessage, !err.isEmpty, dirs.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(err)
                    } actions: {
                        Button(L10n.t("重试")) { Task { await loadDir(currentPath) } }
                            .buttonStyle(.borderedProminent)
                    }
                } else if dirs.isEmpty {
                    ContentUnavailableView(
                        L10n.t("此目录下没有子目录"),
                        systemImage: "folder"
                    )
                } else {
                    dirList
                }
            }
            .navigationTitle(L10n.t("选择目录"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreateFolder = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .accessibilityLabel(L10n.t("新建文件夹"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("选择此目录")) {
                        onPick(currentPath)
                        dismiss()
                    }
                }
            }
        }
        .bottomSheetDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showCreateFolder) {
            FileCreateSheet(isDir: true, currentPath: currentPath) {
                Task { await loadDir(currentPath) }
            }
        }
        .task { await loadDir("/") }
    }

    private var dirList: some View {
        List {
            // 逐级向上（根目录时隐藏）
            if currentPath != "/" {
                Button {
                    let parent = (currentPath as NSString).deletingLastPathComponent
                    Task { await loadDir(parent.isEmpty ? "/" : parent) }
                } label: {
                    Label("..", systemImage: "arrow.up.folder")
                        .foregroundStyle(.primary)
                }
            }
            ForEach(dirs) { item in
                Button {
                    Task { await loadDir(item.path) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.yellow)
                        Text(item.name)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func loadDir(_ path: String) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { isLoading = false }
        currentPath = path
        let req = FileSearchRequest(path: path, expand: true, page: 1, pageSize: 200, showHidden: false)
        do {
            let resp: FileSearchResponse = try await client.send(
                path: APIEndpoint.filesSearch.path, body: req,
                as: FileSearchResponse.self
            )
            guard generation == loadGeneration else { return }
            dirs = (resp.items ?? [])
                .filter { $0.isDir }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            errorMessage = nil
        } catch {
            guard generation == loadGeneration, !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            dirs = []
        }
    }
}
