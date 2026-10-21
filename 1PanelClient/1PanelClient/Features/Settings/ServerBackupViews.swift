//
//  ServerBackupViews.swift
//  1PanelClient
//
//  服务器配置备份与恢复：设置「服务器」组的「备份」入口推入本页（导出/导入
//  两个功能）；导出成功页展示/复制随机密钥（密钥不落盘，只此一屏）；导入页
//  粘贴密钥 → 解密预览 → 确认合并（按 baseURL 去重）。
//

import SwiftUI
import UniformTypeIdentifiers

/// 服务器备份页：导出 / 导入 两个功能入口（含文件选择器与两张结果表单）
struct ServerBackupView: View {
    @State private var exportResult: BackupExportResult?
    @State private var showImporter = false
    @State private var importFile: BackupImportFile?
    @State private var toast: String?

    var body: some View {
        List {
            Section {
                Button {
                    runExport()
                } label: {
                    Label(L10n.t("导出"), systemImage: "square.and.arrow.up")
                }
                Button {
                    showImporter = true
                } label: {
                    Label(L10n.t("导入"), systemImage: "square.and.arrow.down")
                }
            }
        }
        .navigationTitle(L10n.t("备份"))
        .navigationBarTitleDisplayMode(.inline)
        .localToast(message: $toast)
        // 导入：文件选择器（即读即闭安全作用域，Data 进 sheet 避免 URL 授权时效问题）
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                importFile = BackupImportFile(data: data)
            } else {
                toast = L10n.t("不是有效的备份文件")
            }
        }
        .sheet(item: $exportResult) { result in
            BackupKeySheet(result: result) { exportResult = nil }
                .bottomSheetDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $importFile) { file in
            BackupImportSheet(file: file) { message in
                importFile = nil
                if let message { toast = message }
            }
            // 密钥输入多行 + 预览列表可长：默认半屏，可上拉全屏
            .bottomSheetDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    /// 导出：随机密钥加密落盘 Documents/Backups，成功后弹密钥展示页
    ///（密钥不落盘，仅此一屏展示/复制）
    private func runExport() {
        let servers = ServerManager.shared.servers
        guard !servers.isEmpty else {
            toast = L10n.t("暂无服务器可导出")
            return
        }
        do {
            let key = ServerBackup.generateKey()
            let data = try ServerBackup.seal(servers, keyBase64: key)
            let saved = try LocalDownloads.save(
                data: data, fileName: ServerBackup.backupFileName(), category: .backups)
            exportResult = BackupExportResult(saved: saved, key: key)
        } catch {
            toast = L10n.f("导出失败：%@", error.localizedDescription)
        }
    }
}

/// sheet(item:) 的载荷：导出结果（落盘路径 + 随机密钥）
struct BackupExportResult: Identifiable {
    let id = UUID()
    let saved: LocalDownloads.Saved
    let key: String
}

/// sheet(item:) 的载荷：导入文件内容（fileImporter 回调里即读即闭安全作用域）
struct BackupImportFile: Identifiable {
    let id = UUID()
    let data: Data
}

/// 导出成功页：文件路径 + 备份密钥（等宽可全选）+ 一键复制
struct BackupKeySheet: View {
    let result: BackupExportResult
    var onDone: () -> Void

    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(result.saved.displayPath, systemImage: "lock.doc")
                        .font(.footnote)
                } header: {
                    Text(L10n.t("备份文件"))
                }
                Section {
                    Text(result.key)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = result.key
                        copied = true
                        Haptic.success()
                    } label: {
                        Label(copied ? L10n.t("已复制") : L10n.t("复制密钥"),
                              systemImage: "doc.on.doc")
                    }
                } header: {
                    Text(L10n.t("备份密钥"))
                } footer: {
                    Text(L10n.t("请妥善保存密钥，丢失后备份文件将无法恢复；备份含 API Key，文件与密钥请分开存放"))
                }
            }
            .navigationTitle(L10n.t("备份已创建"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("完成"), action: onDone)
                }
            }
        }
    }
}

/// 导入页：粘贴密钥 → 解密预览（台数 + 别名）→ 确认导入（按 baseURL 去重合并）
struct BackupImportSheet: View {
    let file: BackupImportFile
    /// 完成回调：携带结果 toast 文案（nil = 无变更，如全部跳过前取消）
    var onDone: (String?) -> Void

    @State private var keyInput = ""
    @State private var preview: [ServerConfig]?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(L10n.t("粘贴备份密钥"), text: $keyInput, axis: .vertical)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button {
                        decrypt()
                    } label: {
                        Label(L10n.t("解密预览"), systemImage: "key")
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    if let errorText {
                        Text(errorText).foregroundStyle(.red)
                    }
                }
                if let preview {
                    Section {
                        ForEach(preview) { server in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name)
                                    Text(server.normalizedBaseURL)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "server.rack")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text(L10n.f("将导入 %ld 台服务器", preview.count))
                    } footer: {
                        Text(L10n.t("已存在的同地址服务器将跳过"))
                    }
                }
            }
            .navigationTitle(L10n.t("导入服务器配置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { onDone(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("导入")) { runImport() }
                        .disabled(preview == nil)
                }
            }
        }
    }

    private func decrypt() {
        do {
            preview = try ServerBackup.open(file.data, keyBase64: keyInput)
            errorText = nil
        } catch {
            preview = nil
            errorText = (error as? ServerBackupError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// 按 baseURL 去重合并：新增走 ServerManager.add（Keychain 写入/小组件
    /// 刷新随现有 CRUD 自动完成），已存在跳过
    private func runImport() {
        guard let preview else { return }
        let manager = ServerManager.shared
        let existing = Set(manager.servers.map { $0.normalizedBaseURL })
        var added = 0
        var skipped = 0
        for server in preview where !server.normalizedBaseURL.isEmpty {
            if existing.contains(server.normalizedBaseURL) {
                skipped += 1
            } else {
                manager.add(server)
                added += 1
            }
        }
        if added > 0 { Haptic.success() }
        onDone(L10n.f("已导入 %ld 台，跳过 %ld 台已存在", added, skipped))
    }
}
