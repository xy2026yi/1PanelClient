//
//  SSHCertsView.swift
//  1PanelClient
//
//  SSH 密钥管理：列表 / 创建（自动生成 | 手动输入 | 文件上传）/ 详情（复制/导出公私钥）/
//  编辑（名称/描述）/ 删除（可强制）/ 同步
//  接口见 PanelShared/Models/SSHCert.swift 与 logs/分组与类别.md
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - ViewModel

@MainActor
final class SSHCertsViewModel: ObservableObject {
    @Published var certs: [SSHCertItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isCreating = false
    @Published var isUpdating = false
    @Published var isSyncing = false

    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var toastMessage: String?
    private var toastTask: Task<Void, Never>?

    /// 删除确认（输入密钥名称 + 可选强制删除）
    @Published var pendingDeleteCert: SSHCertItem?
    @Published var forceDelete = false

    private(set) var client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient.shared(for: server)
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let resp: PageResponse<SSHCertItem> = try await client.send(
                path: APIEndpoint.sshCertSearch.path,
                body: SSHCertSearchRequest(),
                as: PageResponse<SSHCertItem>.self
            )
            certs = resp.items ?? []
        } catch let err as APIError {
            guard !err.isCancellation else { return }
            errorMessage = err.errorDescription
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func create(req: SSHCertCreateRequest) async -> Bool {
        isCreating = true
        defer { isCreating = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.sshCertCreate.path,
                body: req,
                as: EmptyResponse.self
            )
            showToast(L10n.f("密钥「%@」已创建", req.name))
            await load()
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("创建失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("创建失败：%@", error.localizedDescription))
            return false
        }
    }

    /// 更新密钥（编辑表单与网页端一致为全字段：名称/加密方式/密码/描述/公私钥均可改；
    /// 未修改的字段由编辑页原样回传服务端值）
    @discardableResult
    func update(req: SSHCertUpdateRequest) async -> Bool {
        isUpdating = true
        defer { isUpdating = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.sshCertUpdate.path,
                body: req,
                as: EmptyResponse.self
            )
            showToast(L10n.f("密钥「%@」已更新", req.name))
            await load()
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("更新失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("更新失败：%@", error.localizedDescription))
            return false
        }
    }

    @discardableResult
    func delete(cert: SSHCertItem) async -> Bool {
        pendingDeleteCert = nil
        // 本次删除用的开关值就地取走并复位：失败重试或下次删除都从「未勾选」开始，
        // 避免上次的强制删除状态无声带到下一次确认弹窗
        let force = forceDelete
        forceDelete = false
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.sshCertDelete.path,
                body: SSHCertDeleteRequest(ids: [cert.id], forceDelete: force),
                as: EmptyResponse.self
            )
            showToast(L10n.f("密钥「%@」已删除", cert.name ?? ""))
            await load()
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("删除失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("删除失败：%@", error.localizedDescription))
            return false
        }
    }

    /// 同步密钥：清理失效密钥并同步新增的完整密钥对（调用方先确认）
    @discardableResult
    func syncKeys() async -> Bool {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.sshCertSync.path,
                body: EmptyRequest(),
                as: EmptyResponse.self
            )
            showToast(L10n.t("密钥同步完成"))
            await load()
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("同步失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("同步失败：%@", error.localizedDescription))
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

// MARK: - 密钥列表页

struct SSHCertsView: View {
    @StateObject private var vm: SSHCertsViewModel
    @State private var showCreate = false
    @State private var showMenu = false
    @State private var confirmSync = false
    /// 授权密钥（authorized_keys）推页入口（右上角菜单）
    @State private var showAuthKeys = false
    /// 长按弹出的操作菜单目标（编辑 / 删除）
    @State private var actionCert: SSHCertItem?
    /// 长按「编辑」推入的编辑页目标
    @State private var editingCert: SSHCertItem?
    /// 授权密钥页所需服务器配置（init 时固定）
    private let server: ServerConfig

    init(server: ServerConfig) {
        self.server = server
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(key: "sshCerts:\(server.id)") {
            SSHCertsViewModel(server: server)
        })
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.certs.isEmpty {
                LoadingStateView()
            } else if let err = vm.errorMessage, !err.isEmpty, vm.certs.isEmpty {
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
            } else if vm.certs.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无密钥"),
                    systemImage: "key",
                    description: Text(L10n.t("点击右上角 + 新建密钥"))
                )
            } else {
                certList
            }
        }
        .navigationTitle(L10n.t("SSH 密钥"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EllipsisMenuButton(isLoading: vm.isSyncing) {
                    withAnimation(Motion.fast) { showMenu.toggle() }
                }
                .accessibilityLabel(L10n.t("更多操作"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("新建密钥"))
            }
        }
        .overlay(alignment: .topTrailing) {
            if showMenu {
                EllipsisMenuPopup(entries: [
                    .action(title: L10n.t("同步密钥"), icon: "arrow.trianglehead.2.clockwise.rotate.90", isDisabled: vm.isSyncing) {
                        confirmSync = true
                    },
                    .action(title: L10n.t("授权密钥"), icon: "checkmark.seal") {
                        showAuthKeys = true
                    },
                ]) {
                    withAnimation(Motion.fast) { showMenu = false }
                }
            }
        }
        .alert(L10n.t("同步密钥"), isPresented: $confirmSync) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("确认")) {
                Task { await vm.syncKeys() }
            }
        } message: {
            Text(L10n.t("同步操作将清理失效密钥并同步新增的完整密钥对，是否继续？"))
        }
        .navigationDestination(isPresented: $showCreate) {
            SSHCertCreateView(vm: vm)
        }
        .navigationDestination(isPresented: $showAuthKeys) {
            SSHAuthKeysView(server: server)
        }
        .navigationDestination(isPresented: Binding(
            get: { editingCert != nil },
            set: { if !$0 { editingCert = nil } }
        )) {
            if let cert = editingCert {
                SSHCertEditView(cert: cert, vm: vm)
            }
        }
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .task { await vm.load() }
    }

    private var certList: some View {
        List {
            ForEach(vm.certs) { cert in
                NavigationLink {
                    SSHCertDetailView(cert: cert, vm: vm)
                } label: {
                    SSHCertRow(cert: cert)
                }
                // 行级操作收进长按菜单（编辑 / 删除），不再用滑动操作；
                // 用 simultaneousGesture 与 NavigationLink 共存——onLongPressGesture
                // 会独占手势导致点击无法进详情
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                        Haptic.selection()
                        actionCert = cert
                    }
                )
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await vm.load() }
        .sheet(item: $actionCert) { cert in
            ActionBottomSheet(
                title: cert.name ?? "—",
                items: [
                    ActionMenuItem(title: L10n.t("编辑"), icon: "pencil") {
                        editingCert = cert
                    },
                    ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red, role: .destructive) {
                        vm.forceDelete = false
                        vm.pendingDeleteCert = cert
                    },
                ],
                onDismiss: { actionCert = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: 2))])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $vm.pendingDeleteCert) { cert in
            TextInputConfirmSheet(
                title: L10n.t("删除密钥"),
                message: L10n.f("此操作不可恢复。请输入密钥名称「%@」以确认删除。", cert.name ?? ""),
                expectedText: cert.name ?? "",
                fieldLabel: L10n.t("确认名称"),
                fieldPlaceholder: L10n.t("名称")
            ) {
                Task { await vm.delete(cert: cert) }
            } options: {
                Section(L10n.t("选项")) {
                    Toggle(L10n.t("强制删除（密钥已被使用时仍删除）"), isOn: $vm.forceDelete)
                }
            }
        }
    }
}

// MARK: - 密钥列表行

struct SSHCertRow: View {
    let cert: SSHCertItem

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "key", color: .indigo)

            VStack(alignment: .leading, spacing: 4) {
                Text(cert.name ?? "—")
                    .font(.body.bold())
                    .lineLimit(1)
                if let desc = cert.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            StatusBadge(text: (cert.encryptionMode ?? "—").uppercased(), color: .blue, monospaced: true)
        }
        .padding(.vertical, 4)
        // 整行（含空白处）可命中长按手势，否则只有文字/图标区域响应
        .contentShape(Rectangle())
    }
}

// MARK: - 创建密钥页（自动生成 | 手动输入 | 文件上传）

struct SSHCertCreateView: View {
    @ObservedObject var vm: SSHCertsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var mode: SSHCertCreateMode = .generate
    @State private var name = ""
    @State private var encryption: SSHCertEncryption = .ed25519
    @State private var passPhrase = ""
    @State private var showPassPhrase = false
    @State private var description = ""

    // 手动输入
    @State private var privateKeyText = ""
    @State private var publicKeyText = ""

    // 文件上传
    private enum PickTarget { case privateKey, publicKey }
    @State private var showFilePicker = false
    @State private var pickTarget: PickTarget?
    @State private var privateKeyFile: (name: String, content: String)?
    @State private var publicKeyFile: (name: String, content: String)?
    @State private var loadFileError: String?

    var body: some View {
        Form {
            Section(L10n.t("基本信息")) {
                TextField(L10n.t("名称"), text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Picker(L10n.t("创建方式"), selection: $mode) {
                    ForEach(SSHCertCreateMode.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                Picker(L10n.t("加密方式"), selection: $encryption) {
                    ForEach(SSHCertEncryption.allCases) { e in
                        Text(e.displayName).tag(e)
                    }
                }
            }

            Section {
                PasswordInputRow(password: $passPhrase, showPassword: $showPassPhrase)
                TextField(L10n.t("描述（可选）"), text: $description)
            } header: {
                Text(L10n.t("密码与描述"))
            } footer: {
                Text(mode == .generate
                     ? L10n.t("密码用于加密私钥，可留空；自动生成将同时生成公私钥对。")
                     : L10n.t("密码需与私钥的加密密码一致，未加密私钥可留空。"))
            }

            switch mode {
            case .generate:
                EmptyView()
            case .input:
                Section {
                    keyEditor(title: L10n.t("私钥"), text: $privateKeyText)
                    keyEditor(title: L10n.t("公钥（可选）"), text: $publicKeyText)
                } header: {
                    Text(L10n.t("密钥内容"))
                } footer: {
                    Text(L10n.t("粘贴 OpenSSH 格式的完整密钥文本，提交时将 base64 编码传输。"))
                }
            case .importFiles:
                Section {
                    fileRow(title: L10n.t("选择私钥文件"),
                            fileName: privateKeyFile?.name) {
                        pickTarget = .privateKey
                        showFilePicker = true
                    }
                    fileRow(title: L10n.t("选择公钥文件"),
                            fileName: publicKeyFile?.name) {
                        pickTarget = .publicKey
                        showFilePicker = true
                    }
                } header: {
                    Text(L10n.t("密钥文件"))
                } footer: {
                    Text(L10n.t("从本机选择 OpenSSH 格式的密钥文本文件（如 id_ed25519 / id_ed25519.pub），公钥可省略。"))
                }
            }
        }
        .navigationTitle(L10n.t("新建密钥"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            loadPickedFile(url)
        }
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { loadFileError != nil },
            set: { if !$0 { loadFileError = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) { loadFileError = nil }
        } message: {
            Text(loadFileError ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await submit() }
                } label: {
                    if vm.isCreating {
                        ProgressView()
                    } else {
                        Text(L10n.t("创建")).bold()
                    }
                }
                .disabled(!canSubmit || vm.isCreating)
            }
        }
    }

    private var canSubmit: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch mode {
        case .generate:
            return true
        case .input:
            return !privateKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .importFiles:
            return privateKeyFile != nil
        }
    }

    /// 密钥文本编辑器：等宽小字 + placeholder 浮层（TextEditor 原生不显示 placeholder）
    private func keyEditor(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 110)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(L10n.t("粘贴密钥内容…"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    /// 文件选择行：标题 + 已选文件名（未选显示「选择文件」）
    private func fileRow(title: String, fileName: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Text(fileName ?? L10n.t("选择文件"))
                    .font(.caption)
                    .foregroundStyle(fileName == nil ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// 读取选中密钥文件（安全作用域内读文本；失败清空旧值防「显示新文件名提交旧内容」）
    private func loadPickedFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        func fail(_ message: String) {
            switch pickTarget {
            case .privateKey: privateKeyFile = nil
            case .publicKey:  publicKeyFile = nil
            case nil: break
            }
            loadFileError = message
        }
        // 密钥为小文本文件：超过 1MB 视为选错文件
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 1_048_576 {
            fail(L10n.f("文件过大（%ld KB），请选择密钥文本文件", size / 1024))
            return
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(L10n.t("无法读取该文件：请选择 UTF-8 文本格式的密钥文件"))
            return
        }
        switch pickTarget {
        case .privateKey: privateKeyFile = (url.lastPathComponent, text)
        case .publicKey:  publicKeyFile = (url.lastPathComponent, text)
        case nil: break
        }
    }

    private func submit() async {
        var req = SSHCertCreateRequest(
            mode: mode.rawValue,
            encryptionMode: encryption.rawValue,
            name: name.trimmingCharacters(in: .whitespaces)
        )
        req.description = description
        if !passPhrase.isEmpty {
            req.passPhrase = Data(passPhrase.utf8).base64EncodedString()
        }
        switch mode {
        case .generate:
            break
        case .input:
            req.privateKey = Data(privateKeyText.utf8).base64EncodedString()
            if !publicKeyText.isEmpty {
                req.publicKey = Data(publicKeyText.utf8).base64EncodedString()
            }
        case .importFiles:
            if let file = privateKeyFile {
                req.privateKey = Data(file.content.utf8).base64EncodedString()
            }
            if let file = publicKeyFile {
                req.publicKey = Data(file.content.utf8).base64EncodedString()
            }
        }
        if await vm.create(req: req) {
            dismiss()
        }
    }
}

// MARK: - 密钥详情页

struct SSHCertDetailView: View {
    /// 打开详情时的快照；实际展示按 id 从 VM 回查（编辑保存、列表刷新后不显示旧值），
    /// 已被删除等回查不到时回退快照
    private let certSnapshot: SSHCertItem
    @ObservedObject var vm: SSHCertsViewModel

    @State private var showEdit = false
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?

    private var cert: SSHCertItem {
        vm.certs.first(where: { $0.id == certSnapshot.id }) ?? certSnapshot
    }

    init(cert: SSHCertItem, vm: SSHCertsViewModel) {
        self.certSnapshot = cert
        self.vm = vm
    }

    var body: some View {
        List {
            Section(L10n.t("基本信息")) {
                InfoRow(L10n.t("名称"), value: cert.name ?? "—")
                InfoRow(L10n.t("加密方式"), value: (cert.encryptionMode ?? "—").uppercased(), monospaced: true)
                if let desc = cert.description, !desc.isEmpty {
                    InfoRow(L10n.t("描述"), value: desc)
                }
                if let phrase = cert.passPhrase, !phrase.isEmpty {
                    PasswordRow(password: SSHCertItem.decodeBase64(phrase) ?? phrase)
                } else {
                    InfoRow(L10n.t("密码"), value: L10n.t("未设置"))
                }
            }

            keySection(title: L10n.t("公钥"), base64: cert.publicKey, fileName: (cert.name ?? "key") + ".pub")
            keySection(title: L10n.t("私钥"), base64: cert.privateKey, fileName: cert.name ?? "key")
        }
        .navigationTitle(cert.name ?? L10n.t("SSH 密钥"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("编辑")) { showEdit = true }
            }
        }
        .navigationDestination(isPresented: $showEdit) {
            SSHCertEditView(cert: cert, vm: vm)
        }
        .toastOverlay(message: $toastMessage)
    }

    /// 公钥/私钥 Section：不展示密钥内容，仅提供同行「复制 / 导出」两个操作
    private func keySection(title: String, base64: String?, fileName: String) -> some View {
        Section(title) {
            if let content = SSHCertItem.decodeBase64(base64), !content.isEmpty {
                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = content
                        showToast(L10n.t("已复制"))
                    } label: {
                        Label(L10n.t("复制"), systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        exportKey(content: content, fileName: fileName)
                    } label: {
                        Label(L10n.t("导出"), systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                // 容器级 borderless：防止 List 把整行变成按钮、点一个触发两个
                .buttonStyle(.borderless)
            } else {
                Text(L10n.t("内容为空"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 导出到 Documents（同名加序号），经「文件」App 取用
    private func exportKey(content: String, fileName: String) {
        let destDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let finalName = Self.uniqueFileName(fileName, in: destDir)
        let destURL = destDir.appendingPathComponent(finalName)
        do {
            try content.data(using: .utf8)?.write(to: destURL)
            showToast(L10n.f("已保存到「文件」App：我的 iPhone/1PanelClient/%@", finalName))
        } catch {
            showToast(L10n.f("导出失败：%@", error.localizedDescription))
        }
    }

    /// 目标目录下不冲突的文件名：同名时追加序号（与 FilesView/BackupListView 一致）
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

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            toastMessage = nil
        }
    }
}

// MARK: - 密钥编辑页（全字段，与创建表单及网页端一致）

/// 编辑密钥：名称/加密方式/密码/描述/公私钥均可修改。
/// 未修改的凭据字段（密码/公钥/私钥）原样回传服务端值，修改过的重新 base64 编码
/// （与 SSH 主机编辑凭据「未修改回传原值」的约定一致）。
struct SSHCertEditView: View {
    let cert: SSHCertItem
    @ObservedObject var vm: SSHCertsViewModel
    @Environment(\.dismiss) private var dismiss

    /// 编辑前的服务端原值（raw = 响应原样；decoded = 展示/编辑用解码文本）
    private let originalPassPhrase: (raw: String, decoded: String)
    private let originalPublicKey: (raw: String, decoded: String)
    private let originalPrivateKey: (raw: String, decoded: String)

    @State private var name: String
    @State private var encryption: SSHCertEncryption
    @State private var passPhrase: String
    @State private var showPassPhrase = false
    @State private var description: String
    @State private var privateKeyText: String
    @State private var publicKeyText: String

    init(cert: SSHCertItem, vm: SSHCertsViewModel) {
        self.cert = cert
        self.vm = vm
        originalPassPhrase = (cert.passPhrase ?? "", SSHCertItem.decodeBase64(cert.passPhrase) ?? "")
        originalPublicKey = (cert.publicKey ?? "", SSHCertItem.decodeBase64(cert.publicKey) ?? "")
        originalPrivateKey = (cert.privateKey ?? "", SSHCertItem.decodeBase64(cert.privateKey) ?? "")
        _name = State(initialValue: cert.name ?? "")
        _encryption = State(initialValue: SSHCertEncryption(rawValue: cert.encryptionMode ?? "") ?? .ed25519)
        _passPhrase = State(initialValue: originalPassPhrase.decoded)
        _description = State(initialValue: cert.description ?? "")
        _privateKeyText = State(initialValue: originalPrivateKey.decoded)
        _publicKeyText = State(initialValue: originalPublicKey.decoded)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var canSubmit: Bool {
        !trimmedName.isEmpty
            && !privateKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section(L10n.t("基本信息")) {
                TextField(L10n.t("名称"), text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Picker(L10n.t("加密方式"), selection: $encryption) {
                    ForEach(SSHCertEncryption.allCases) { e in
                        Text(e.displayName).tag(e)
                    }
                }
            }

            Section {
                PasswordInputRow(password: $passPhrase, showPassword: $showPassPhrase)
                TextField(L10n.t("描述（可选）"), text: $description)
            } header: {
                Text(L10n.t("密码与描述"))
            } footer: {
                Text(L10n.t("密码需与私钥的加密密码一致，未加密私钥可留空。"))
            }

            Section {
                privateKeyEditor
                publicKeyEditor
            } header: {
                Text(L10n.t("密钥内容"))
            } footer: {
                Text(L10n.t("修改后将覆盖服务器上的原密钥；粘贴 OpenSSH 格式的完整密钥文本，提交时将 base64 编码传输。"))
            }
        }
        .navigationTitle(L10n.t("编辑密钥"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await submit() }
                } label: {
                    if vm.isUpdating {
                        ProgressView()
                    } else {
                        Text(L10n.t("保存")).bold()
                    }
                }
                .disabled(!canSubmit || vm.isUpdating)
            }
        }
    }

    /// 私钥编辑器（必填）：等宽字体 + placeholder 浮层
    private var privateKeyEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("私钥"))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $privateKeyText)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 110)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .overlay(alignment: .topLeading) {
                    if privateKeyText.isEmpty {
                        Text(L10n.t("粘贴密钥内容…"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    /// 公钥编辑器（可选）
    private var publicKeyEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("公钥（可选）"))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $publicKeyText)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 80)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .overlay(alignment: .topLeading) {
                    if publicKeyText.isEmpty {
                        Text(L10n.t("粘贴密钥内容…"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    /// 未修改的字段回传服务端原值；修改过的重新 base64 编码
    private func transport(_ newValue: String, original: (raw: String, decoded: String)) -> String {
        newValue == original.decoded ? original.raw : Data(newValue.utf8).base64EncodedString()
    }

    private func submit() async {
        let req = SSHCertUpdateRequest(
            id: cert.id,
            createdAt: cert.createdAt,
            name: trimmedName,
            encryptionMode: encryption.rawValue,
            passPhrase: transport(passPhrase, original: originalPassPhrase),
            publicKey: transport(publicKeyText, original: originalPublicKey),
            privateKey: transport(privateKeyText, original: originalPrivateKey),
            description: description,
            mode: "input"
        )
        if await vm.update(req: req) {
            dismiss()
        }
    }
}
