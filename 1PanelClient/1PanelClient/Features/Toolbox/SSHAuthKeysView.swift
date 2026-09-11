//
//  SSHAuthKeysView.swift
//  1PanelClient
//
//  授权密钥（authorized_keys）编辑：从 SSH 服务管理页移出，
//  现经「SSH 密钥」页右上角菜单进入
//

import SwiftUI

/// 面板主机的 authorized_keys 查看与编辑：
/// 读取 POST /api/v2/hosts/ssh/file {"name":"authKeys"}
/// 保存 POST /api/v2/hosts/ssh/file/update {"key":"authKeys","path":"","value":…}
struct SSHAuthKeysView: View {
    let server: ServerConfig

    @State private var keysText = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var successMessage: String?
    @State private var errorMessage: String?
    /// 读取失败文案：编辑器不落地（防止把加载失败的空内容保存上去清空 authorized_keys）
    @State private var loadErrorMessage: String?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient.shared(for: server)
    }

    /// 按行解析公钥条数（空行不计数），标题栏摘要用
    private var keyCount: Int {
        keysText.split(separator: "\n", omittingEmptySubsequences: true).count
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
                        Task { await loadKeys() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                VStack(spacing: 0) {
                    if keyCount > 0 {
                        Text(L10n.f("共 %ld 个公钥", keyCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }
                    TextEditor(text: $keysText)
                        .font(.system(.caption, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
        }
        .navigationTitle(L10n.t("授权密钥"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("保存")) {
                    Task { await save() }
                }
                .disabled(isSaving || isLoading)
            }
        }
        .task { await loadKeys() }
        .localToast(message: $successMessage)
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func loadKeys() async {
        isLoading = true
        let req = SSHFileRequest(name: "authKeys")
        do {
            let resp: String = try await client.send(path: APIEndpoint.sshFile.path, body: req, as: String.self)
            keysText = resp
            loadErrorMessage = nil
        } catch {
            // 加载失败进错误态（带重试），不进编辑器：空文本一旦保存会清空 authorized_keys
            loadErrorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        isSaving = true
        let req = SSHFileUpdateRequest(key: "authKeys", path: "", value: keysText)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.sshFileUpdate.path, body: req, as: EmptyResponse.self)
            successMessage = L10n.t("已保存")
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}
