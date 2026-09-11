//
//  AIMcpDomainView.swift
//  1PanelClient
//
//  域名绑定（MCP /ai/mcp/domain 与 Ollama 网关 /ai/domain 共用表单）：
//  域名 / 白名单 IP（多行）/ 开启 HTTPS（ACME 账户 + 证书下拉）；
//  已绑定时进入编辑模式（域名只读），保存走 update
//

import SwiftUI

// MARK: - 共用域名绑定表单

struct DomainBindFormView: View {
    let title: String
    let footerHint: String
    /// 已绑定信息（nil = 未绑定，创建模式）
    let info: AIDomainInfo?
    /// 保存（绑定/更新各一个，返回错误文案，nil = 成功）
    let onSave: (AIDomainBindRequest) async -> String?

    @Environment(\.dismiss) private var dismiss

    @State private var domain = ""
    @State private var ipList = "0.0.0.0/0\n::0/0"
    @State private var enableSSL = false
    @State private var acmeAccounts: [AcmeAccount] = []
    @State private var selectedAcmeId: Int?
    @State private var certs: [WebsiteSSL] = []
    @State private var selectedSSLId: Int?
    @State private var isLoadingCerts = false

    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var didFill = false

    private let client: APIClient

    init(
        server: ServerConfig,
        title: String,
        footerHint: String,
        info: AIDomainInfo?,
        onSave: @escaping (AIDomainBindRequest) async -> String?
    ) {
        self.client = APIClient.shared(for: server)
        self.title = title
        self.footerHint = footerHint
        self.info = info
        self.onSave = onSave
    }

    private var isBound: Bool { info != nil }

    private var canSubmit: Bool {
        !domain.isEmpty && (!enableSSL || (selectedSSLId != nil)) && !isSaving
    }

    var body: some View {
        Form {
            Section {
                TextField(L10n.t("域名"), text: $domain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .disabled(isBound)

                TextEditor(text: $ipList)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 72)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                SectionLabel(title: L10n.t("域名"), systemImage: "globe")
            } footer: {
                Text(L10n.t("白名单 IP：一行一个 IP 或 IP 段，支持 IPv4 和 IPv6"))
            }

            Section {
                Toggle(L10n.t("开启 HTTPS"), isOn: $enableSSL)
                    .onChange(of: enableSSL) { _, on in
                        if on, acmeAccounts.isEmpty {
                            Task { await loadAcmeAccounts() }
                        }
                    }

                if enableSSL {
                    Picker(L10n.t("Acme 账户"), selection: $selectedAcmeId) {
                        // 手动创建（不在 Acme 账户列表中，acmeAccountID=0）
                        Text(L10n.t("手动创建")).tag(Optional(0))
                        ForEach(acmeAccounts) { account in
                            Text(account.email.isEmpty ? "#\(account.id)" : account.email).tag(Optional(account.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedAcmeId) { _, _ in
                        Task { await loadCerts() }
                    }

                    HStack {
                        Text(L10n.t("证书"))
                        Spacer()
                        if isLoadingCerts {
                            ProgressView()
                        }
                    }
                    if !certs.isEmpty {
                        Picker("", selection: $selectedSSLId) {
                            ForEach(certs) { cert in
                                Text(cert.displayName).tag(Optional(cert.id))
                            }
                        }
                        .labelsHidden()
                    }
                }
            } header: {
                SectionLabel(title: "HTTPS", systemImage: "lock.shield")
            } footer: {
                Text(footerHint)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() } else { Text(isBound ? L10n.t("保存") : L10n.t("绑定")).bold() }
                }
                .disabled(!canSubmit)
            }
        }
        .task {
            guard !didFill else { return }
            didFill = true
            if let info {
                domain = info.domain ?? ""
                let ips = info.allowIPs ?? []
                if !ips.isEmpty {
                    ipList = ips.joined(separator: "\n")
                }
                enableSSL = (info.sslID ?? 0) > 0
                selectedSSLId = info.sslID
                selectedAcmeId = info.acmeAccountID
                if enableSSL {
                    await loadAcmeAccounts()
                }
            }
        }
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - 数据

    private func loadAcmeAccounts() async {
        do {
            let resp: PageResponse<AcmeAccount> = try await client.send(
                path: APIEndpoint.websitesAcmeSearch.path,
                body: AcmeSearchRequest(page: 1, pageSize: 100),
                as: PageResponse<AcmeAccount>.self)
            acmeAccounts = resp.items ?? []
            if selectedAcmeId == nil {
                selectedAcmeId = acmeAccounts.first?.id ?? 0
            }
            await loadCerts()
        } catch {
            // 静默：Picker 展示为空
        }
    }

    private func loadCerts() async {
        let acmeId = selectedAcmeId ?? 0
        isLoadingCerts = true
        defer { isLoadingCerts = false }
        do {
            certs = try await client.send(
                path: APIEndpoint.websitesSSLSearch.path,
                body: WebsiteSSLSearchRequest(acmeAccountID: String(acmeId)),
                as: [WebsiteSSL].self)
            if selectedSSLId == nil || !certs.contains(where: { $0.id == selectedSSLId }) {
                selectedSSLId = certs.first?.id
            }
        } catch {
            certs = []
        }
    }

    // MARK: - 保存

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let req = AIDomainBindRequest(
            domain: domain,
            sslID: enableSSL ? selectedSSLId : nil,
            ipList: ipList,
            acmeAccountID: selectedAcmeId ?? 0,
            enableSSL: enableSSL,
            allowIPs: [],
            websiteID: info?.websiteID ?? 0
        )
        if let error = await onSave(req) {
            errorMessage = error
            showError = true
        } else {
            dismiss()
        }
    }
}

// MARK: - MCP 域名绑定页

struct AIMcpDomainView: View {
    let server: ServerConfig

    @State private var info: AIDomainInfo?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var hasLoaded = false
    @State private var toastMessage: String?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else {
                DomainBindFormView(
                    server: server,
                    title: L10n.t("域名绑定"),
                    footerHint: L10n.t("绑定网站之后会修改所有已安装 MCP Server 的访问地址，并关闭端口的外部访问"),
                    info: info,
                    onSave: { req in
                        await saveDomain(req)
                    }
                )
            }
        }
        .navigationTitle(L10n.t("域名绑定"))
        .navigationBarTitleDisplayMode(.inline)
        .toastOverlay(message: $toastMessage)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            info = try await client.send(
                path: APIEndpoint.aiMcpDomainGet.path,
                method: "GET",
                as: AIDomainInfo.self)
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            // 未绑定时接口可能返回空 data：视为未绑定
            info = nil
        }
        isLoading = false
    }

    /// 绑定（websiteID=0）/ 更新按是否已绑定区分
    private func saveDomain(_ req: AIDomainBindRequest) async -> String? {
        do {
            let _: EmptyResponse = try await client.send(
                path: (info?.websiteID ?? 0) > 0 ? APIEndpoint.aiMcpDomainUpdate.path : APIEndpoint.aiMcpDomainBind.path,
                body: req,
                as: EmptyResponse.self)
            await load()
            return nil
        } catch {
            guard !APIError.isCancellation(error) else { return nil }
            return error.localizedDescription
        }
    }
}
