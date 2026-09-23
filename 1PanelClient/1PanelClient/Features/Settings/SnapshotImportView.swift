//
//  SnapshotImportView.swift
//  1PanelClient
//
//  快照导入：选备份账号 → 拉取账号内快照文件（/backups/search/files）→ 多选 → 提交导入
//  POST /settings/snapshot/import {backupAccountID, names, description}
//

import SwiftUI

struct SnapshotImportView: View {
    let server: ServerConfig
    /// 导入成功回调（父页刷新列表）
    var onImported: () -> Void

    @State private var accounts: [BackupAccount] = []
    @State private var selectedAccountName = ""
    @State private var files: [String] = []
    @State private var selectedFiles: Set<String> = []
    @State private var description = ""
    @State private var isLoadingAccounts = true
    @State private var isLoadingFiles = false
    @State private var filesError: String?
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showError = false

    @Environment(\.dismiss) private var dismiss
    private let client: APIClient

    private let maxDescriptionLength = 256

    init(server: ServerConfig, onImported: @escaping () -> Void) {
        self.server = server
        self.onImported = onImported
        self.client = APIClient.shared(for: server)
    }

    private var selectedAccount: BackupAccount? {
        accounts.first { $0.displayName == selectedAccountName }
    }

    private var canSubmit: Bool {
        selectedAccount != nil && !selectedFiles.isEmpty && !isSubmitting
    }

    var body: some View {
        Form {
            Section {
                if isLoadingAccounts {
                    HStack { Spacer(); LoadingStateView(); Spacer() }
                        .listRowBackground(Color.clear)
                } else if accounts.isEmpty {
                    Text(L10n.t("暂无备份账号"))
                        .foregroundStyle(.secondary)
                } else {
                    OutlinedPicker(label: L10n.t("备份账号"),
                                   options: accounts.map(\.displayName),
                                   selection: $selectedAccountName)
                }
            } header: {
                Text(L10n.t("来源"))
            } footer: {
                if let account = selectedAccount {
                    Text(L10n.f("将从备份账号「%@」拉取快照文件", account.displayName))
                }
            }

            Section {
                if let account = selectedAccount {
                    if isLoadingFiles {
                        HStack { Spacer(); LoadingStateView(); Spacer() }
                            .listRowBackground(Color.clear)
                    } else if let err = filesError {
                        LoadErrorStateView(message: err) {
                            Task { await loadFiles(for: account) }
                        }
                        .listRowBackground(Color.clear)
                    } else if files.isEmpty {
                        Text(L10n.t("该账号下未找到快照文件"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(files, id: \.self) { file in
                            fileRow(file)
                        }
                    }
                } else {
                    Text(L10n.t("请先选择备份账号"))
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text(L10n.t("快照文件"))
                    Spacer()
                    if !selectedFiles.isEmpty {
                        Text(L10n.f("已选 %ld 项", selectedFiles.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                OutlinedTextField(label: L10n.t("描述"),
                                  prompt: L10n.t("选填"),
                                  text: $description)
            } footer: {
                Text(L10n.f("%ld / 256", description.count))
            }
        }
        .navigationTitle(L10n.t("导入快照"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.t("导入")) {
                    Task { await submit() }
                }
                .disabled(!canSubmit)
            }
        }
        .task { await loadAccounts() }
        .onChange(of: selectedAccountName) { _, newName in
            files = []
            selectedFiles = []
            filesError = nil
            if let account = accounts.first(where: { $0.displayName == newName }) {
                Task { await loadFiles(for: account) }
            }
        }
        .onChange(of: description) { _, newValue in
            if newValue.count > maxDescriptionLength {
                description = String(newValue.prefix(maxDescriptionLength))
            }
        }
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// 文件多选行（等宽文件名 + 勾选圈）
    private func fileRow(_ file: String) -> some View {
        Button {
            if selectedFiles.contains(file) {
                selectedFiles.remove(file)
            } else {
                selectedFiles.insert(file)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selectedFiles.contains(file)
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedFiles.contains(file) ? Color.accentColor : Color.secondary)
                Text(file)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func loadAccounts() async {
        defer { isLoadingAccounts = false }
        do {
            let pageSize = 100
            var all: [BackupAccount] = []
            var page = 1
            var total = Int.max
            while all.count < total && page <= 20 {
                let resp: BackupAccountListResponse = try await client.send(
                    path: APIEndpoint.backupAccountsSearch.path,
                    body: BackupAccountSearchRequest(page: page, pageSize: pageSize, type: "", name: ""),
                    as: BackupAccountListResponse.self
                )
                let items = resp.items ?? []
                all.append(contentsOf: items)
                total = resp.total
                if items.count < pageSize { break }
                page += 1
            }
            accounts = all
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func loadFiles(for account: BackupAccount) async {
        isLoadingFiles = true
        filesError = nil
        defer { isLoadingFiles = false }
        do {
            let names: [String] = try await client.send(
                path: APIEndpoint.backupsSearchFiles.path,
                body: BackupAccountIDRequest(id: account.id),
                as: [String].self
            )
            files = names.sorted()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            filesError = error.localizedDescription
        }
    }

    private func submit() async {
        guard let account = selectedAccount else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.settingsSnapshotImport.path,
                body: SnapshotImportRequest(
                    backupAccountID: account.id,
                    names: files.filter { selectedFiles.contains($0) },
                    description: description.trimmingCharacters(in: .whitespacesAndNewlines)),
                as: EmptyResponse.self)
            onImported()
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

/// POST /backups/search/files 请求体（备份账号 id）
nonisolated struct BackupAccountIDRequest: Encodable {
    let id: Int
}
