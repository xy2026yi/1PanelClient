//
//  ClamSettingsView.swift
//  1PanelClient
//
//  ClamAV 设置：扫描设置（clamd.conf）/ 病毒库刷新配置（freshclam.conf）/
//  扫描日志 / 病毒库刷新日志（file/search + file/update）
//

import SwiftUI

// MARK: - 设置入口

struct ClamSettingsView: View {
    let server: ServerConfig

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ClamConfigEditView(server: server, fileName: "clamd", title: L10n.t("扫描设置"))
                } label: {
                    Label(L10n.t("扫描设置"), systemImage: "slider.horizontal.3")
                }
                NavigationLink {
                    ClamConfigEditView(server: server, fileName: "freshclam", title: L10n.t("病毒库刷新配置"))
                } label: {
                    Label(L10n.t("病毒库刷新配置"), systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                }
            } header: {
                SectionLabel(title: L10n.t("配置文件"), systemImage: "doc.text")
            }

            Section {
                NavigationLink {
                    ClamLogTailView(server: server, fileName: "clamd-log", title: L10n.t("扫描日志"))
                } label: {
                    Label(L10n.t("扫描日志"), systemImage: "doc.text.magnifyingglass")
                }
                NavigationLink {
                    ClamLogTailView(server: server, fileName: "freshclam-log", title: L10n.t("病毒库刷新日志"))
                } label: {
                    Label(L10n.t("病毒库刷新日志"), systemImage: "doc.text.magnifyingglass")
                }
            } header: {
                SectionLabel(title: L10n.t("日志"), systemImage: "doc.plaintext")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("ClamAV 设置"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 配置文件编辑

/// 配置全文编辑：file/search {name, tail:"0"} 加载，file/update 保存。
/// 保存前需输入「立即重启」确认（配置重启后生效）
struct ClamConfigEditView: View {
    let server: ServerConfig
    /// clamd / freshclam
    let fileName: String
    let title: String

    @State private var configText = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var showRestartConfirm = false
    @State private var successMessage: String?
    @State private var errorMessage: String?
    /// 加载失败文案：编辑器不落地（防止把加载失败的空内容保存上去覆盖配置）
    @State private var loadErrorMessage: String?

    private let client: APIClient

    init(server: ServerConfig, fileName: String, title: String) {
        self.server = server
        self.fileName = fileName
        self.title = title
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else if let loadError = loadErrorMessage {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(loadError)
                } actions: {
                    Button(L10n.t("重试")) {
                        Task { await loadConfig() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                TextEditor(text: $configText)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("保存")) {
                    showRestartConfirm = true
                }
                .disabled(isSaving || isLoading)
            }
        }
        .task { await loadConfig() }
        .localToast(message: $successMessage)
        .sheet(isPresented: $showRestartConfirm) {
            TextInputConfirmSheet(
                title: L10n.t("保存配置"),
                message: L10n.t("修改配置后需要重启生效。如果确认操作，请手动输入「立即重启」。"),
                expectedText: L10n.t("立即重启"),
                fieldLabel: L10n.t("确认名称"),
                fieldPlaceholder: L10n.t("立即重启")
            ) {
                Task { await save() }
            }
        }
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func loadConfig() async {
        isLoading = true
        let req = ClamFileSearchRequest(name: fileName, tail: "0")
        do {
            configText = try await client.send(
                path: APIEndpoint.clamFileSearch.path, body: req, as: String.self)
            loadErrorMessage = nil
        } catch {
            // 加载失败进错误态（带重试），不进编辑器：空文本一旦保存会清空配置
            loadErrorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        isSaving = true
        let req = ClamFileUpdateRequest(name: fileName, file: configText)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.clamFileUpdate.path, body: req, as: EmptyResponse.self)
            successMessage = L10n.t("已保存，重启服务后生效")
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

// MARK: - 尾行日志查看

/// 日志尾行查看：file/search {name, tail:"200"}
struct ClamLogTailView: View {
    let server: ServerConfig
    /// clamd-log / freshclam-log
    let fileName: String
    let title: String

    @State private var lines: [String] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig, fileName: String, title: String) {
        self.server = server
        self.fileName = fileName
        self.title = title
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else if let err = errorMessage, lines.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button(L10n.t("重试")) {
                        Task { await load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if lines.isEmpty {
                ContentUnavailableView(title, systemImage: "doc.plaintext")
            } else {
                List {
                    LogLinesView(lines: lines)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        let req = ClamFileSearchRequest(name: fileName, tail: "200")
        do {
            let text = try await client.send(
                path: APIEndpoint.clamFileSearch.path, body: req, as: String.self)
            lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
