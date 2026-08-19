//
//  BackupListView.swift
//  1PanelClient
//
//  备份管理页：应用 / 网站 / 数据库（MySQL/MongoDB/PostgreSQL）共用。
//  备份记录以卡片展示（文件名+大小 / 路径 / 类型 / 名称 / 详情），
//  支持新增（压缩密码+描述+MySQL 备份参数）、恢复（压缩密码+超时+清空库）、删除、下载。
//  新增与恢复提交后进入 TaskProgressView 轮询任务日志展示进度。
//

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class BackupViewModel: ObservableObject {
    let target: BackupTarget

    @Published var records: [BackupRecord] = []
    /// 记录 id → 文件字节数（record/size 接口合并）
    @Published var sizeMap: [Int: Int64] = [:]
    /// 备份存放目录（/backups/local，列表 footer 展示）
    @Published var backupDir: String?
    @Published var isLoading = false
    @Published var showAlert = false
    @Published var alertMessage = ""
    /// 首屏加载失败（空态展示重试按钮）；已有数据时刷新失败仅弹提示、保留旧列表
    @Published var loadFailed = false
    /// 正在下载的记录 id 集合（多记录可并行下载）
    @Published var downloadingRecordIDs: Set<Int> = []
    /// 下载进度：记录 id → 0...1（-1 表示总大小未知，无法计算百分比）
    @Published var downloadProgress: [Int: Double] = [:]
    /// 最近一次下载保存到「文件」App 的文件名（完成提示用）
    @Published var downloadedFileName: String?
    /// 正在删除的记录 id
    @Published var deletingRecordID: Int?

    /// 进行中的下载任务：记录 id → Task（支持取消）
    private var downloadTasks: [Int: Task<Void, Never>] = [:]

    private let client: APIClient
    private var backupDirLoaded = false

    init(target: BackupTarget, server: ServerConfig) {
        self.target = target
        self.client = APIClient(server: server)
    }

    // MARK: - 查询

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        // 记录列表是主数据：失败才算加载失败；分页拉全（超过一页时循环取后续页）
        let pageSize = 100
        var all: [BackupRecord] = []
        do {
            var page = 1
            var total = Int.max
            while all.count < total && page <= 20 {
                let req = BackupRecordSearchRequest(
                    page: page, pageSize: pageSize,
                    type: target.type, name: target.name, detailName: target.detailName
                )
                let resp: BackupRecordListResponse = try await client.send(
                    path: APIEndpoint.backupsRecordSearch.path, body: req,
                    as: BackupRecordListResponse.self
                )
                let items = resp.items ?? []
                all.append(contentsOf: items)
                total = resp.total
                if items.count < pageSize { break }
                page += 1
            }
            self.records = all
            self.loadFailed = false
        } catch {
            // 刷新失败保留已加载数据；首屏失败进入可重试的空态
            if records.isEmpty { loadFailed = true }
            showAlert(message: L10n.f("加载备份失败：%@", error.localizedDescription))
            return
        }

        // 大小/目录为辅助数据：失败不影响列表展示（大小显示 —，目录脚注隐藏）
        do {
            let sizeReq = BackupRecordSearchRequest(
                page: 1, pageSize: max(pageSize, all.count),
                type: target.type, name: target.name, detailName: target.detailName
            )
            let sizes: [BackupRecordSizeItem] = try await client.send(
                path: APIEndpoint.backupsRecordSize.path, body: sizeReq,
                as: [BackupRecordSizeItem].self
            )
            var map: [Int: Int64] = [:]
            for s in sizes { map[s.id] = s.size ?? 0 }
            self.sizeMap = map
        } catch {
            self.sizeMap = [:]
        }
        if let dirPath = try? await loadBackupDir() {
            self.backupDir = dirPath
        }
    }

    /// 备份存放目录（GET /backups/local，仅查询一次；失败返回 nil 不提示）
    private func loadBackupDir() async throws -> String? {
        if backupDirLoaded { return backupDir }
        let dir: String = try await client.send(
            path: APIEndpoint.backupsLocal.path,
            method: APIEndpoint.backupsLocal.method,
            as: String.self
        )
        backupDirLoaded = true
        return dir
    }

    // MARK: - 新增备份

    /// 提交备份任务：成功返回 taskID（用于进度页），失败返回错误信息（由表单内展示）
    func createBackup(secret: String, description: String, args: [String]) async -> Result<String, BackupSubmitError> {
        let taskID = UUID().uuidString
        let req = BackupCreateRequest(
            type: target.type, name: target.name, detailName: target.detailName,
            secret: secret, taskID: taskID, description: description, args: args
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.backupsBackup.path, body: req, as: EmptyResponse.self
            )
            return .success(taskID)
        } catch {
            return .failure(BackupSubmitError(message: L10n.f("备份提交失败：%@", error.localizedDescription)))
        }
    }

    // MARK: - 恢复

    func recover(record: BackupRecord, secret: String, timeout: Int, dropAllCollections: Bool) async -> Result<String, BackupSubmitError> {
        let taskID = UUID().uuidString
        let req = BackupRecoverRequest(
            downloadAccountID: record.downloadAccountID ?? 1,
            type: target.type, name: target.name, detailName: target.detailName,
            file: record.fullPath, secret: secret, taskID: taskID,
            backupRecordID: record.id, timeout: timeout, dropAllCollections: dropAllCollections
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.backupsRecover.path, body: req, as: EmptyResponse.self
            )
            return .success(taskID)
        } catch {
            return .failure(BackupSubmitError(message: L10n.f("恢复提交失败：%@", error.localizedDescription)))
        }
    }

    // MARK: - 删除

    func deleteRecord(_ record: BackupRecord) async {
        deletingRecordID = record.id
        defer { deletingRecordID = nil }
        let req = BackupRecordDeleteRequest(ids: [record.id], node: "local")
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.backupsRecordDelete.path, body: req, as: EmptyResponse.self
            )
            await refresh()
        } catch {
            showAlert(message: L10n.f("删除失败：%@", error.localizedDescription))
        }
    }

    // MARK: - 下载

    /// 开始下载（同一记录重复点击忽略；不同记录可并行）
    func startDownload(_ record: BackupRecord) {
        guard !downloadingRecordIDs.contains(record.id) else { return }
        downloadTasks[record.id] = Task { await downloadRecord(record) }
    }

    /// 取消下载（URLSession 请求抛出取消错误，由 downloadRecord 统一清理）
    func cancelDownload(_ record: BackupRecord) {
        downloadTasks[record.id]?.cancel()
    }

    /// 先取备份文件在服务器上的绝对路径，再经 files/download 流式下载到本地 Documents，
    /// 完成后置 downloadedFileName 弹出保存位置提示。
    private func downloadRecord(_ record: BackupRecord) async {
        guard let rawName = record.fileName, !rawName.isEmpty else {
            showAlert(message: L10n.t("备份记录缺少文件名，无法下载"))
            return
        }
        // 本地保存只用最后一段文件名，防止服务端异常数据拼出目录穿越路径
        let fileName = (rawName as NSString).lastPathComponent
        let recordID = record.id
        downloadingRecordIDs.insert(recordID)
        downloadProgress[recordID] = -1
        defer {
            downloadingRecordIDs.remove(recordID)
            downloadProgress[recordID] = nil
            downloadTasks[recordID] = nil
        }
        let req = BackupRecordDownloadRequest(
            downloadAccountID: record.downloadAccountID ?? 1,
            fileDir: record.fileDir ?? "",
            fileName: rawName
        )
        var tempURL: URL?
        do {
            let serverPath: String = try await client.send(
                path: APIEndpoint.backupsRecordDownload.path, body: req, as: String.self
            )
            let downloaded = try await client.downloadFile(
                path: APIEndpoint.filesDownload.path,
                queryItems: [
                    URLQueryItem(name: "operateNode", value: "local"),
                    URLQueryItem(name: "path", value: serverPath),
                ],
                fileName: fileName,
                progress: { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        // 取消后不再回写进度，防止 defer 清理后又写入过期值
                        guard let self, self.downloadingRecordIDs.contains(recordID) else { return }
                        self.downloadProgress[recordID] = fraction
                    }
                }
            )
            tempURL = downloaded
            // 移入 Documents（同名自动加序号，通过 UIFileSharingEnabled 暴露到「文件」App）
            let destDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let finalName = Self.uniqueFileName(fileName, in: destDir)
            let finalURL = destDir.appendingPathComponent(finalName)
            do {
                try FileManager.default.moveItem(at: downloaded, to: finalURL)
            } catch {
                try? FileManager.default.removeItem(at: downloaded)
                throw error
            }
            downloadedFileName = finalName
        } catch {
            if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
            // 用户主动取消不弹错误
            if !error.isUserCancellation {
                showAlert(message: L10n.f("下载失败：%@", error.localizedDescription))
            }
        }
    }

    /// 目标目录下不冲突的文件名：同名时追加序号
    private static func uniqueFileName(_ name: String, in dir: URL) -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.appendingPathComponent(name).path) { return name }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var index = 1
        while true {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if !fm.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
                return candidate
            }
            index += 1
        }
    }

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }
}

private extension Error {
    /// 是否为用户主动取消（Task 取消在 URLSession 中表现为 URLError.cancelled，包在 APIError 里）
    var isUserCancellation: Bool {
        if self is CancellationError { return true }
        if let apiError = self as? APIError, case .networkError(let inner) = apiError {
            if let urlError = inner as? URLError, urlError.code == .cancelled { return true }
            return inner is CancellationError
        }
        return false
    }
}

// MARK: - 进度页参数

/// 提交备份/恢复的失败信息（Result 的 Failure 需遵循 Error）
struct BackupSubmitError: Error {
    let message: String
}

/// 备份/恢复任务进度页状态
struct BackupProgressState: Equatable {
    let taskID: String
    let title: String
    /// 备份=true（追读），恢复=false（从头读），与网页端抓包一致
    let latest: Bool
}

// MARK: - 备份列表页

struct BackupListView: View {
    @StateObject private var vm: BackupViewModel

    @State private var showCreate = false
    @State private var recoveringRecord: BackupRecord?
    @State private var deletingRecord: BackupRecord?
    /// 待跳转的任务进度（表单关闭后再压栈，避免 sheet 与 push 同时动画冲突）
    @State private var pendingProgress: BackupProgressState?
    @State private var progress: BackupProgressState?

    init(target: BackupTarget) {
        _vm = StateObject(wrappedValue: BackupViewModel(
            target: target,
            server: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        ))
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.records.isEmpty {
                ProgressView(L10n.t("加载中…"))
            } else if vm.records.isEmpty && vm.loadFailed {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(L10n.t("无法连接服务器，请检查网络后重试"))
                } actions: {
                    Button(L10n.t("重试")) {
                        Task { await vm.refresh() }
                    }
                }
            } else if vm.records.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无备份"),
                    systemImage: "externaldrive.badge.timemachine",
                    description: Text(L10n.t("点击右下角 + 创建第一个备份"))
                )
            } else {
                recordList
            }
        }
        .navigationTitle(L10n.t("备份"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottomTrailing) {
            FloatingActionButton(action: {
                showCreate = true
            })
            .accessibilityLabel(L10n.t("新增备份"))
        }
        .task {
            await vm.refresh()
        }
        .refreshable {
            await vm.refresh()
        }
        .sheet(isPresented: $showCreate) {
            BackupCreateSheet(target: vm.target) { secret, description, args in
                switch await vm.createBackup(secret: secret, description: description, args: args) {
                case .success(let taskID):
                    pendingProgress = BackupProgressState(
                        taskID: taskID, title: L10n.f("备份 %@", vm.target.detailName), latest: true
                    )
                    return nil
                case .failure(let error):
                    return error.message
                }
            }
        }
        .sheet(item: $recoveringRecord) { record in
            BackupRecoverSheet(record: record, target: vm.target) { secret, timeout, dropAll in
                switch await vm.recover(record: record, secret: secret, timeout: timeout, dropAllCollections: dropAll) {
                case .success(let taskID):
                    pendingProgress = BackupProgressState(
                        taskID: taskID, title: L10n.f("恢复 %@", vm.target.detailName), latest: false
                    )
                    return nil
                case .failure(let error):
                    return error.message
                }
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { progress != nil },
            set: { if !$0 { progress = nil } }
        )) {
            if let p = progress {
                TaskProgressView(taskID: p.taskID, title: p.title, latest: p.latest) { isDone in
                    // 任务完成或后台运行：回到列表并刷新
                    Task { await vm.refresh() }
                    return false
                }
            }
        }
        .onChange(of: showCreate) { _, shown in
            if !shown, let p = pendingProgress {
                pendingProgress = nil
                progress = p
            }
        }
        .onChange(of: recoveringRecord) { old, new in
            if old != nil && new == nil, let p = pendingProgress {
                pendingProgress = nil
                progress = p
            }
        }
        .alert(
            L10n.t("删除备份"),
            isPresented: Binding(
                get: { deletingRecord != nil },
                set: { if !$0 { deletingRecord = nil } }
            )
        ) {
            Button(L10n.t("取消"), role: .cancel) { deletingRecord = nil }
            Button(L10n.t("删除"), role: .destructive) {
                if let record = deletingRecord {
                    Task { await vm.deleteRecord(record) }
                }
                deletingRecord = nil
            }
        } message: {
            if let record = deletingRecord {
                Text(L10n.f("确定删除备份「%@」吗？删除后不可恢复。", record.fileName ?? "—"))
            }
        }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .alert(
            L10n.t("下载完成"),
            isPresented: Binding(
                get: { vm.downloadedFileName != nil },
                set: { if !$0 { vm.downloadedFileName = nil } }
            )
        ) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(L10n.f("已保存到「文件」App：我的 iPhone/1PanelClient/%@", vm.downloadedFileName ?? ""))
        }
    }

    private var recordList: some View {
        List {
            Section {
                ForEach(vm.records) { record in
                    BackupRecordCard(
                        record: record,
                        sizeText: BackupSizeFormatter.format(vm.sizeMap[record.id]),
                        targetType: vm.target.type,
                        targetName: vm.target.name,
                        targetDetailName: vm.target.detailName,
                        isDownloading: vm.downloadingRecordIDs.contains(record.id),
                        downloadProgress: vm.downloadProgress[record.id],
                        isDeleting: vm.deletingRecordID == record.id,
                        onDownload: { vm.startDownload(record) },
                        onCancelDownload: { vm.cancelDownload(record) },
                        onRecover: { recoveringRecord = record },
                        onDelete: { deletingRecord = record }
                    )
                }
            } header: {
                SectionLabel(title: L10n.t("备份记录"), systemImage: "externaldrive.badge.timemachine")
            } footer: {
                if let dir = vm.backupDir, !dir.isEmpty {
                    Text(L10n.f("备份存放位置：%@", dir))
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - 备份卡片

/// 单条备份记录卡片：文件名+大小 / 路径 / 类型 / 名称 / 详情 / 操作按钮
private struct BackupRecordCard: View {
    let record: BackupRecord
    let sizeText: String
    let targetType: String
    let targetName: String
    let targetDetailName: String
    let isDownloading: Bool
    /// 0...1 百分比；-1 表示总大小未知；nil 表示未在下载
    let downloadProgress: Double?
    let isDeleting: Bool
    let onDownload: () -> Void
    let onCancelDownload: () -> Void
    let onRecover: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 文件名 + 大小
            HStack(alignment: .firstTextBaseline) {
                Text(record.fileName ?? "—")
                    .font(.subheadline.bold())
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(sizeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // 文件夹路径
            if let dir = record.fileDir, !dir.isEmpty {
                Label(dir, systemImage: "folder")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            // 类型 / 名称 / 详情
            HStack(spacing: 6) {
                metaBadge(L10n.t("类型"), value: targetType)
                metaBadge(L10n.t("名称"), value: targetName)
                metaBadge(L10n.t("详情"), value: targetDetailName)
            }

            // 时间 + 状态 + 描述
            HStack(spacing: 8) {
                Text(record.displayCreatedAt)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let status = record.status, !status.isEmpty {
                    Text(status)
                        .font(.caption2.bold())
                        .foregroundStyle(record.statusColor)
                }
                if let desc = record.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            // 操作：下载（进行中可取消）/ 恢复 / 删除
            HStack(spacing: 8) {
                if isDownloading {
                    cardButton(title: L10n.t("取消"), icon: "stop.circle.fill", color: .red, loading: false, action: onCancelDownload)
                } else {
                    cardButton(title: L10n.t("下载"), icon: "arrow.down.circle", color: .blue, loading: false, action: onDownload)
                }
                cardButton(title: L10n.t("恢复"), icon: "arrow.counterclockwise", color: .green, loading: false, action: onRecover)
                cardButton(title: L10n.t("删除"), icon: "trash", color: .red, loading: isDeleting, action: onDelete)
            }
            .padding(.top, 2)

            // 下载进度（-1 表示总大小未知）
            if isDownloading, let progress = downloadProgress {
                HStack(spacing: 8) {
                    if progress >= 0 {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                        Text("\(Int(progress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text(L10n.t("下载中…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private func metaBadge(_ key: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
        }
        .font(.caption2)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.08), in: Capsule())
    }

    private func cardButton(
        title: String, icon: String, color: Color, loading: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if loading {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: icon)
                        .font(.caption)
                }
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .tint(color)
        .disabled(loading)
    }
}

// MARK: - 新增备份表单

/// 新增备份：压缩密码 + 描述（MySQL 系多一个备份参数多选）
private struct BackupCreateSheet: View {
    let target: BackupTarget
    /// 返回 nil 表示提交成功（表单自行关闭）；返回非 nil 为失败原因（表单内弹提示）
    let onSubmit: (_ secret: String, _ description: String, _ args: [String]) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var secret = ""
    @State private var showSecret = false
    @State private var description = ""
    @State private var selectedArgs: Set<String> = []
    @State private var showArgsPicker = false
    @State private var isSubmitting = false
    @State private var submitError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        if showSecret {
                            TextField(L10n.t("压缩密码（可选）"), text: $secret)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField(L10n.t("压缩密码（可选）"), text: $secret)
                        }
                        Button {
                            showSecret.toggle()
                        } label: {
                            Image(systemName: showSecret ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    TextField(L10n.t("描述（可选）"), text: $description)
                } header: {
                    Text(L10n.t("备份选项"))
                } footer: {
                    Text(L10n.t("压缩密码用于加密备份文件，恢复时需输入相同密码"))
                }

                if target.isMySQLFamily {
                    Section {
                        NavigationLink {
                            BackupArgsPicker(dbType: target.baseType, selection: $selectedArgs)
                        } label: {
                            HStack {
                                Text(L10n.t("备份参数"))
                                Spacer()
                                if selectedArgs.isEmpty {
                                    Text(L10n.t("默认"))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(L10n.f("%ld 项", selectedArgs.count))
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    } footer: {
                        Text(L10n.t("与计划任务中备份数据库的参数一致；不选则使用默认方式备份"))
                    }
                }
            }
            .navigationTitle(L10n.t("新增备份"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? L10n.t("提交中…") : L10n.t("确认")) {
                        Task {
                            isSubmitting = true
                            let error = await onSubmit(secret, description, Array(selectedArgs).sorted())
                            isSubmitting = false
                            if let error {
                                submitError = error
                            } else {
                                dismiss()
                            }
                        }
                    }
                    .disabled(isSubmitting)
                }
            }
            // 提交失败提示挂在本表单内（挂到被 sheet 覆盖的父视图上不会弹出）
            .alert(L10n.t("提交失败"), isPresented: Binding(
                get: { submitError != nil },
                set: { if !$0 { submitError = nil } }
            )) {
                Button(L10n.t("好的"), role: .cancel) {}
            } message: {
                Text(submitError ?? "")
            }
        }
    }
}

// MARK: - 恢复表单

/// 恢复备份：压缩密码；数据库类多一个超时时间（默认 30 分钟），MongoDB 多一个恢复前清空库开关
private struct BackupRecoverSheet: View {
    let record: BackupRecord
    let target: BackupTarget
    /// 返回 nil 表示提交成功（表单自行关闭）；返回非 nil 为失败原因（表单内弹提示）
    let onSubmit: (_ secret: String, _ timeout: Int, _ dropAllCollections: Bool) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var secret = ""
    @State private var showSecret = false
    @State private var isSubmitting = false
    @State private var submitError: String?

    // 超时时间（仅数据库类备份）
    @State private var timeoutValue = 30
    @State private var timeoutUnit: TimeoutUnit = .minute
    // MongoDB：恢复前清空当前数据库
    @State private var dropAllCollections = false

    enum TimeoutUnit: String, CaseIterable, Identifiable {
case second = "秒"
case minute = "分钟"
case hour = "小时"
        var id: String { rawValue }
        var multiplier: Int {
            switch self {
            case .second: return 1
            case .minute: return 60
            case .hour:   return 3600
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L10n.f("将使用备份「%@」覆盖恢复，恢复期间服务可能短暂中断。", record.fileName ?? "—"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        if showSecret {
                            TextField(L10n.t("压缩密码（可选）"), text: $secret)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField(L10n.t("压缩密码（可选）"), text: $secret)
                        }
                        Button {
                            showSecret.toggle()
                        } label: {
                            Image(systemName: showSecret ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                } header: {
                    Text(L10n.t("恢复选项"))
                } footer: {
                    Text(L10n.t("备份时设置了压缩密码才需要填写"))
                }

                if target.isDatabase {
                    Section {
                        HStack {
                            Text(L10n.t("超时时间"))
                            Spacer()
                            TextField("30", value: $timeoutValue, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 64)
                            Picker("", selection: $timeoutUnit) {
                                ForEach(TimeoutUnit.allCases) { u in
                                    Text(L10n.t(u.rawValue)).tag(u)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    } footer: {
                        Text(L10n.t("恢复操作超过该时长将被中断，默认 30 分钟"))
                    }
                }

                if target.isMongoDB {
                    Section {
                        Toggle(L10n.t("恢复前清空当前数据库"), isOn: $dropAllCollections)
                    } footer: {
                        Text(L10n.t("开启后将在恢复前删除当前数据库中的全部集合"))
                    }
                }
            }
            .navigationTitle(L10n.t("恢复备份"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? L10n.t("提交中…") : L10n.t("确认")) {
                        Task {
                            isSubmitting = true
                            let timeout = max(1, timeoutValue) * timeoutUnit.multiplier
                            let error = await onSubmit(secret, timeout, dropAllCollections)
                            isSubmitting = false
                            if let error {
                                submitError = error
                            } else {
                                dismiss()
                            }
                        }
                    }
                    .disabled(isSubmitting || timeoutValue < 1)
                }
            }
            // 提交失败提示挂在本表单内（挂到被 sheet 覆盖的父视图上不会弹出）
            .alert(L10n.t("提交失败"), isPresented: Binding(
                get: { submitError != nil },
                set: { if !$0 { submitError = nil } }
            )) {
                Button(L10n.t("好的"), role: .cancel) {}
            } message: {
                Text(submitError ?? "")
            }
        }
    }
}

// MARK: - MySQL 备份参数多选（与计划任务一致）

private struct BackupArgsPicker: View {
    /// "mysql" / "mariadb"（mariadb 不提供 --set-gtid-purged=OFF）
    let dbType: String
    @Binding var selection: Set<String>

    private var options: [(value: String, summary: String, detail: String)] {
        let all = CreateCronjobView.backupParamOptions
        if dbType.lowercased() == "mariadb" {
            return all.filter { $0.value != "--set-gtid-purged=OFF" }
        }
        return all
    }

    var body: some View {
        List {
            Section {
                ForEach(options, id: \.value) { opt in
                    Button {
                        if selection.contains(opt.value) {
                            selection.remove(opt.value)
                        } else {
                            selection.insert(opt.value)
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: selection.contains(opt.value) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection.contains(opt.value) ? Color.accentColor : .secondary)
                                .font(.title3)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(opt.value)
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(.primary)
                                Text(opt.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text(L10n.t("可多选；不选任何参数则使用默认方式备份。"))
            }
        }
        .navigationTitle(L10n.t("备份参数"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("清除全部")) { selection.removeAll() }
                    .disabled(selection.isEmpty)
            }
        }
    }
}
