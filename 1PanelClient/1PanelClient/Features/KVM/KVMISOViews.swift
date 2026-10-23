//
//  KVMISOViews.swift
//  1PanelClient
//
//  虚拟机镜像 ISO（/xpack/vms/iso/*，logs/高级功能-KVM.md 抓包 2026-10-23）：
//  卡片列表（每镜像一卡：类型 / 大小 / 路径 / 状态 + 编辑·删除按钮行）/ 添加（三种来源）/
//  编辑 / 删除（半屏弹窗，可选删源文件）。
//  - 服务器选择：POST iso {type, name, path, description}
//  - 本地上传：iso/import/start（status=uploading, tempFileID=uploadID, tempFileType=upload）→ {id}
//    → files/chunkupload 分片（filename/uploadID/path/chunkIndex/chunkCount/overwrite=True，5MB/片）
//    → iso/import/update {id, status=ready}
//  - 远程下载：iso/import/start（status=downloading, tempFileID=""）→ {id} → files/check 目标目录
//    → files/wget → {key} → iso/import/update {id, status=downloading, tempFileID=key, tempFileType=download}
//    → WS wget/process 轮询到完成 → iso/import/update {id, status=ready}
//  上传 / 下载进度内嵌在表单底部（任务进行中禁止返回），复用 FileWgetProcessSession。
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - 列表

struct KVMISOListView: View {
    @ObservedObject var vm: KVMViewModel

    @State private var showCreate = false
    @State private var editISO: KVMISOImage?
    @State private var deleteISO: KVMISOImage?

    var body: some View {
        List {
            if vm.isos.isEmpty {
                Section {
                    if vm.isLoading {
                        LoadingStateView(compact: true)
                            .padding(.vertical, 30)
                    } else {
                        ContentUnavailableView(
                            L10n.t("暂无镜像"),
                            systemImage: "opticaldisc",
                            description: Text(L10n.t("点击右上角 + 从服务器选择、本地上传或远程下载 ISO 镜像"))
                        )
                        .listRowBackground(Color.clear)
                    }
                }
            } else {
                // 每个镜像一张卡：信息行 + 编辑 / 删除按钮行
                ForEach(vm.isos) { iso in
                    isoCard(iso)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await vm.loadISOs() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("添加镜像"))
            }
        }
        // 上传 / 下载中的镜像轮询状态
        .adaptivePolling(interval: 5, isActive: { vm.isos.contains { !$0.isReady && ($0.status ?? "").lowercased() != "error" } }) {
            await vm.loadISOs()
        }
        .navigationDestination(isPresented: $showCreate) {
            KVMISOFormView(vm: vm)
        }
        .navigationDestination(item: $editISO) { iso in
            KVMISOFormView(vm: vm, iso: iso)
        }
        .sheet(item: $deleteISO) { iso in
            KVMISODeleteSheet(iso: iso) { deleteFile in
                await vm.deleteISO(iso, deleteFile: deleteFile)
            }
        }
    }

    // MARK: 卡片

    /// 单个镜像卡：信息行（图标 / 名称 / 类型 / 大小 / 路径 / 状态）+ 编辑 / 删除按钮行
    private func isoCard(_ iso: KVMISOImage) -> some View {
        Section {
            KVMISORow(iso: iso)
                .listRowSeparator(.hidden)

            HStack(spacing: 8) {
                CardActionButton(title: L10n.t("编辑"), icon: "pencil", color: .teal) {
                    editISO = iso
                }
                CardActionButton(title: L10n.t("删除"), icon: "trash", color: .red) {
                    deleteISO = iso
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 4)
        }
    }
}

// MARK: - 删除镜像（半屏弹窗，可选删除源文件）

/// 删除镜像确认：默认仅删除镜像记录，开启「删除源文件」后连同服务器上的 ISO 一并删除
struct KVMISODeleteSheet: View {
    let iso: KVMISOImage
    /// (是否删除源文件) → 已提交（关闭弹层由调用方按结果处理）
    let onSubmit: (Bool) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var deleteFile = false
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L10n.f("将删除镜像「%@」，是否继续？", iso.displayName))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Toggle(L10n.t("删除源文件"), isOn: $deleteFile)
                } footer: {
                    Text(L10n.t("开启后连同服务器上的源文件一并删除；关闭则仅删除镜像记录，保留源文件。"))
                }
            }
            .navigationTitle(L10n.t("删除镜像"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            isSubmitting = true
                            defer { isSubmitting = false }
                            await onSubmit(deleteFile)
                            dismiss()
                        }
                    } label: {
                        if isSubmitting { ProgressView() } else { Text(L10n.t("确认")).bold() }
                    }
                    .disabled(isSubmitting)
                    .tint(.red)
                }
            }
            .interactiveDismissDisabled(isSubmitting)
        }
        .bottomSheetDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

struct KVMISORow: View {
    let iso: KVMISOImage

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "opticaldisc", color: .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(iso.displayName)
                    .font(.body.bold())
                    .lineLimit(1)
                HStack(spacing: 6) {
                    StatusBadge(text: KVMISOType.display(iso.type), color: .indigo)
                    if let size = iso.size, size > 0 {
                        let parts = MetricFormat.byteParts(size)
                        Text("\(parts.value) \(parts.unit)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(iso.path ?? "-")
                    .font(.dataMonospacedFootnote)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let error = iso.error, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            statusBadge
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch (iso.status ?? "").lowercased() {
        case "ready":
            if iso.isExist == false {
                StatusBadge(text: L10n.t("文件缺失"), color: .statusError)
            } else {
                StatusBadge(text: L10n.t("就绪"), color: .statusRunning)
            }
        case "uploading":
            StatusBadge(text: L10n.t("上传中"), color: .blue)
        case "downloading":
            StatusBadge(text: L10n.t("下载中"), color: .blue)
        case "error":
            StatusBadge(text: L10n.t("失败"), color: .statusError)
        default:
            StatusBadge(text: iso.status ?? "-", color: .secondary)
        }
    }
}

// MARK: - 表单（添加 / 编辑）

/// POST /files/check {path, withInit}（远程下载前校验目标目录；结果不阻断流程）
private struct KVMFilesCheckRequest: Encodable {
    let path: String
    let withInit: Bool
}

struct KVMISOFormView: View {
    @ObservedObject var vm: KVMViewModel
    let iso: KVMISOImage?

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type: KVMISOType = .debian
    @State private var source: KVMISOSource = .server
    @State private var path = ""
    @State private var targetDirectory = KVMISOSource.defaultImportDirectory
    @State private var downloadURL = ""
    @State private var description = ""

    // 本地上传
    @State private var showFileImporter = false
    @State private var pickedFile: URL?
    @State private var pickedFileSize: Int64 = 0

    // 传输进度
    @State private var isSubmitting = false
    @State private var uploadProgress: Double?
    @State private var uploadTask: Task<Void, Never>?
    @State private var downloadSession: FileWgetProcessSession?
    @State private var importRecordID: Int?

    init(vm: KVMViewModel, iso: KVMISOImage? = nil) {
        self.vm = vm
        self.iso = iso
    }

    private var isEdit: Bool { iso != nil }
    private var isTransferring: Bool { uploadProgress != nil || downloadSession != nil }

    var body: some View {
        Form {
            Section {
                OutlinedTextField(label: L10n.t("名称"), text: $name)
                OutlinedPicker(label: L10n.t("类型"), options: KVMISOType.allCases,
                               selection: $type) { $0.displayName }
                if !isEdit {
                    OutlinedPicker(label: L10n.t("镜像来源"), options: KVMISOSource.allCases,
                                   selection: $source) { $0.displayName }
                }
            } header: {
                SectionLabel(title: L10n.t("基本信息"), systemImage: "opticaldisc")
            }

            sourceSection

            Section {
                OutlinedMultiLineField(label: L10n.t("描述"), lines: 3, text: $description)
            }

            if isTransferring {
                transferSection
            }
        }
        .navigationTitle(isEdit ? L10n.t("编辑镜像") : L10n.t("添加镜像"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isTransferring)
        .interactiveDismissDisabled(isTransferring)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting && !isTransferring {
                        ProgressView()
                    } else {
                        Text(isEdit ? L10n.t("保存") : L10n.t("添加")).bold()
                    }
                }
                .disabled(!isValid || isSubmitting || isTransferring)
            }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.diskImage, .data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                pickedFile = url
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                pickedFileSize = (attrs?[.size] as? Int64) ?? 0
                if name.isEmpty { name = url.lastPathComponent }
            }
        }
        .onChange(of: downloadURL) { _, url in
            // 名称跟随下载地址的文件名（用户已改名则不覆盖）
            if source == .download, let last = URL(string: url)?.lastPathComponent, !last.isEmpty,
               name.isEmpty || name == previousURLFileName {
                name = last
            }
            previousURLFileName = URL(string: url)?.lastPathComponent ?? ""
        }
        .onAppear {
            guard let iso, name.isEmpty else { return }
            name = iso.name ?? ""
            type = KVMISOType(rawValue: (iso.type ?? "").lowercased()) ?? .debian
            path = iso.path ?? ""
            description = iso.description ?? ""
        }
        .onDisappear {
            uploadTask?.cancel()
            downloadSession?.stop()
        }
    }

    @State private var previousURLFileName = ""

    // MARK: 来源分区

    @ViewBuilder
    private var sourceSection: some View {
        if isEdit {
            Section {
                FilePathBrowseRow(title: L10n.t("镜像源文件"), path: $path, client: vm.client, fileExtensions: [])
            } header: {
                SectionLabel(title: L10n.t("镜像源文件"), systemImage: "doc")
            }
        } else {
            switch source {
            case .server:
                Section {
                    FilePathBrowseRow(title: L10n.t("镜像源文件"), path: $path, client: vm.client, fileExtensions: [])
                } header: {
                    SectionLabel(title: L10n.t("服务器选择"), systemImage: "server.rack")
                } footer: {
                    Text(L10n.t("选择服务器上已存在的 ISO 文件，仅登记路径不复制文件。"))
                }
            case .upload:
                Section {
                    Button {
                        showFileImporter = true
                    } label: {
                        HStack {
                            Label(pickedFile == nil ? L10n.t("选择文件") : L10n.t("重新选择"), systemImage: "doc.badge.arrow.up")
                            Spacer()
                            if let pickedFile {
                                let parts = MetricFormat.byteParts(pickedFileSize)
                                Text("\(pickedFile.lastPathComponent) · \(parts.value) \(parts.unit)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .disabled(isTransferring)
                    FilePathBrowseRow(title: L10n.t("镜像目标路径"), path: $targetDirectory, client: vm.client)
                } header: {
                    SectionLabel(title: L10n.t("本地上传"), systemImage: "iphone.and.arrow.forward")
                } footer: {
                    Text(L10n.t("从本机选择 ISO 文件分片上传到目标目录（5MB/片），上传期间请保持页面打开。"))
                }
            case .download:
                Section {
                    OutlinedTextField(label: L10n.t("下载地址"), prompt: "https://", text: $downloadURL,
                                      keyboardType: .URL)
                    FilePathBrowseRow(title: L10n.t("镜像目标路径"), path: $targetDirectory, client: vm.client)
                } header: {
                    SectionLabel(title: L10n.t("远程下载"), systemImage: "arrow.down.circle")
                } footer: {
                    Text(L10n.t("由服务器直接下载到目标目录；可在下方进度中停止，下载完成后自动登记为就绪。"))
                }
            }
        }
    }

    // MARK: 传输进度

    @ViewBuilder
    private var transferSection: some View {
        Section {
            if let uploadProgress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L10n.t("上传中"))
                        Spacer()
                        Text("\(Int(uploadProgress * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: uploadProgress)
                }
                Button(role: .destructive) {
                    uploadTask?.cancel()
                } label: {
                    Label(L10n.t("取消上传"), systemImage: "xmark.circle")
                }
            }
            if let downloadSession {
                KVMISODownloadProgressRow(session: downloadSession) { success in
                    await finishDownload(success: success)
                }
            }
        } header: {
            SectionLabel(title: L10n.t("传输进度"), systemImage: "arrow.up.arrow.down")
        }
    }

    // MARK: 校验与提交

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if isEdit { return !path.isEmpty }
        switch source {
        case .server: return !path.isEmpty
        case .upload: return pickedFile != nil && !targetDirectory.isEmpty
        case .download:
            return !targetDirectory.isEmpty && URL(string: downloadURL)?.scheme?.hasPrefix("http") == true
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)

        if let iso {
            let ok = await vm.updateISO(KVMISOUpdateRequest(
                id: iso.id, type: type.rawValue, name: trimmedName, path: path, description: description))
            if ok { dismiss() }
            return
        }

        switch source {
        case .server:
            let ok = await vm.createISO(KVMISOCreateRequest(
                type: type.rawValue, name: trimmedName, path: path, description: description))
            if ok { dismiss() }
        case .upload:
            await startUpload(name: trimmedName)
        case .download:
            await startDownload(name: trimmedName)
        }
    }

    /// 目标目录 + 文件名（目录尾部斜杠归一）
    private func targetFilePath(_ fileName: String) -> String {
        let dir = targetDirectory.hasSuffix("/") ? String(targetDirectory.dropLast()) : targetDirectory
        return dir + "/" + fileName
    }

    // MARK: 本地上传

    private func startUpload(name displayName: String) async {
        guard let file = pickedFile else { return }
        let fileName = file.lastPathComponent
        // 上传 ID 对齐网页端格式：毫秒时间戳-随机串
        let uploadID = "\(Int(Date().timeIntervalSince1970 * 1000))-\(Self.randomToken(11))"
        guard let recordID = await vm.importStart(KVMISOImportStartRequest(
            type: type.rawValue, name: displayName, path: targetFilePath(fileName),
            status: "uploading", tempFileID: uploadID, tempFileType: "upload",
            description: description)) else { return }
        importRecordID = recordID
        uploadProgress = 0

        let client = vm.client
        let directory = targetDirectory
        let size = pickedFileSize
        uploadTask = Task {
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            do {
                try await Self.chunkUpload(client: client, url: file, name: fileName, size: size,
                                           targetDir: directory, uploadID: uploadID) { progress in
                    uploadProgress = progress
                }
                let ok = await vm.importUpdate(KVMISOImportUpdateRequest(id: recordID, status: "ready"))
                uploadProgress = nil
                if ok {
                    Haptic.success()
                    vm.toastMessage = L10n.t("镜像上传完成")
                    await vm.loadISOs()
                    dismiss()
                }
            } catch {
                uploadProgress = nil
                if APIError.isCancellation(error) || error is CancellationError {
                    vm.toastMessage = L10n.t("已取消上传")
                } else {
                    vm.alertMessage = L10n.f("上传失败：%@", error.localizedDescription)
                    vm.showAlert = true
                }
                await vm.loadISOs()
            }
        }
    }

    /// 分片上传（5MB/片，逐片读取不整体载入内存，与文件页 chunkUpload 同构）；
    /// 字段对齐抓包：含 uploadID 与 overwrite=True
    private static func chunkUpload(client: APIClient, url: URL, name: String, size: Int64,
                                    targetDir: String, uploadID: String,
                                    progress: (Double) -> Void) async throws {
        let chunkSize = 5 * 1024 * 1024
        let chunkCount = max(Int(ceil(Double(size) / Double(chunkSize))), 1)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sent: Int64 = 0
        for index in 0..<chunkCount {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(index) * UInt64(chunkSize))
            let length = min(chunkSize, Int(size) - index * chunkSize)
            guard length > 0, let data = try handle.read(upToCount: length), !data.isEmpty else { break }
            try await client.uploadMultipart(
                path: APIEndpoint.filesChunkUpload.path,
                fields: [
                    "filename": name,
                    "uploadID": uploadID,
                    "path": targetDir,
                    "chunkIndex": String(index),
                    "chunkCount": String(chunkCount),
                    "overwrite": "True",
                ],
                fileFieldName: "chunk",
                fileName: name,
                mimeType: "application/octet-stream",
                fileData: data)
            sent += Int64(data.count)
            progress(min(Double(sent) / Double(max(size, 1)), 1))
        }
    }

    private static func randomToken(_ length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }

    // MARK: 远程下载

    private func startDownload(name displayName: String) async {
        guard let url = URL(string: downloadURL) else { return }
        let fileName = url.lastPathComponent.isEmpty ? displayName : url.lastPathComponent
        guard let recordID = await vm.importStart(KVMISOImportStartRequest(
            type: type.rawValue, name: displayName, path: targetFilePath(fileName),
            status: "downloading", tempFileID: "", description: description)) else { return }
        importRecordID = recordID

        let client = vm.client
        // 目标目录存在性检查（对齐网页端；结果仅作提示，不阻断）
        _ = try? await client.send(path: APIEndpoint.filesCheck.path,
                                   body: KVMFilesCheckRequest(path: targetDirectory, withInit: false),
                                   as: Bool.self)
        do {
            let resp: FileWgetKeyResponse = try await client.send(
                path: APIEndpoint.filesWget.path,
                body: FileWgetRequest(url: downloadURL, path: targetDirectory, name: fileName,
                                      ignoreCertificate: true, useProxy: false),
                as: FileWgetKeyResponse.self)
            guard let key = resp.key, !key.isEmpty else {
                vm.alertMessage = L10n.t("下载任务未返回标识")
                vm.showAlert = true
                return
            }
            await vm.importUpdate(KVMISOImportUpdateRequest(id: recordID, status: "downloading",
                                                           tempFileID: key, tempFileType: "download"))
            let session = FileWgetProcessSession(server: vm.server, keys: [key])
            downloadSession = session
            session.start()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            vm.alertMessage = L10n.f("下载失败：%@", (error as? APIError)?.errorDescription ?? error.localizedDescription)
            vm.showAlert = true
            await vm.loadISOs()
        }
    }

    /// 下载结束：成功 → 回写 ready；取消 / 失败 → 保留记录供用户处理
    private func finishDownload(success: Bool) async {
        downloadSession?.stop()
        downloadSession = nil
        if success, let recordID = importRecordID {
            let ok = await vm.importUpdate(KVMISOImportUpdateRequest(id: recordID, status: "ready"))
            if ok {
                Haptic.success()
                vm.toastMessage = L10n.t("镜像下载完成")
            }
        } else {
            vm.toastMessage = L10n.t("下载未完成，镜像记录已保留")
        }
        await vm.loadISOs()
        dismiss()
    }
}

// MARK: - 下载进度行（复用 wget WS 会话）

/// 内嵌下载进度：名称 / 进度条 / 已下载·总量 / 停止；全部完成时按状态回调成功与否
struct KVMISODownloadProgressRow: View {
    @ObservedObject var session: FileWgetProcessSession
    let onDone: (Bool) async -> Void

    @State private var finished = false

    var body: some View {
        Group {
            if let item = session.items.first {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.name ?? L10n.t("下载中"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("\(Int(item.percent ?? 0))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    if (item.total ?? 0) > 0 {
                        ProgressView(value: max(0, min(100, item.percent ?? 0)) / 100)
                    } else {
                        ProgressView()
                    }
                    if let written = item.written, let total = item.total, total > 0 {
                        let w = MetricFormat.byteParts(Int64(written))
                        let t = MetricFormat.byteParts(Int64(total))
                        Text("\(w.value) \(w.unit) / \(t.value) \(t.unit)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let status = item.status, status.lowercased() == "retrying" {
                        Text(L10n.t("连接重试中…"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                if !item.isFinished {
                    Button(role: .destructive) {
                        Task { await session.stopDownload(item) }
                    } label: {
                        Label(L10n.t("停止下载"), systemImage: "stop.circle")
                    }
                }
            } else if let error = session.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(L10n.t("正在获取下载进度…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: session.isAllDone) { _, done in
            guard done, !finished else { return }
            finished = true
            // 收到 null 即全部结束；按最后一次进度判断是否成功（取消 / 失败不置 ready）
            let failed = session.items.contains {
                let s = ($0.status ?? "").lowercased()
                return s == "canceled" || s == "error"
            }
            Task { await onDone(!failed) }
        }
    }
}
