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

    /// Acme 账户选项（0=手动创建，不在账户列表时 acmeAccountID=0）
    private var acmeOptionKeys: [String] {
        ["0"] + acmeAccounts.map { String($0.id) }
    }

    private var acmeOptionLabels: [String: String] {
        var labels = ["0": L10n.t("手动创建")]
        for account in acmeAccounts {
            labels[String(account.id)] = account.email.isEmpty ? "#\(account.id)" : account.email
        }
        return labels
    }

    private var acmeText: Binding<String> {
        Binding<String>(
            get: { String(selectedAcmeId ?? 0) },
            set: { selectedAcmeId = Int($0) ?? 0 }
        )
    }

    /// 证书选项；已绑定证书不在当前账户列表时保留原选择并以占位项展示，不悄悄改绑
    private var certOptionKeys: [String] {
        var keys: [String] = []
        if let bound = selectedSSLId, !certs.contains(where: { $0.id == bound }) {
            keys.append(String(bound))
        }
        return keys + certs.map { String($0.id) }
    }

    private var certOptionLabels: [String: String] {
        var labels: [String: String] = [:]
        if let bound = selectedSSLId, !certs.contains(where: { $0.id == bound }) {
            labels[String(bound)] = L10n.f("当前绑定证书 · %d", bound)
        }
        for cert in certs { labels[String(cert.id)] = cert.displayName }
        return labels
    }

    private var certText: Binding<String> {
        Binding<String>(
            get: { selectedSSLId.map(String.init) ?? "" },
            set: { selectedSSLId = Int($0) }
        )
    }

    private var canSubmit: Bool {
        !domain.isEmpty && (!enableSSL || (selectedSSLId != nil)) && !isSaving
    }

    var body: some View {
        Form {
            Section {
                OutlinedTextField(label: L10n.t("域名"), text: $domain, keyboardType: .URL)
                    .disabled(isBound)

                OutlinedMultiLineField(label: L10n.t("白名单 IP"), prompt: "1.2.3.4",
                                       text: $ipList)
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
                    OutlinedPicker(label: L10n.t("Acme 账户"),
                                   options: acmeOptionKeys, selection: acmeText,
                                   optionLabels: acmeOptionLabels)
                        .onChange(of: selectedAcmeId) { _, _ in
                            Task { await loadCerts() }
                        }

                    if isLoadingCerts {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                    if !certs.isEmpty {
                        OutlinedPicker(label: L10n.t("证书"),
                                       options: certOptionKeys, selection: certText,
                                       optionLabels: certOptionLabels)
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
                if let ssl = info.sslID, ssl > 0 {
                    selectedSSLId = ssl
                }
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
            // 仅未选择时自动取第一张；已绑定证书不在列表时保留原值
            // （由 Picker 占位项展示），避免原样保存被静默换绑
            if selectedSSLId == nil {
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
            } else if let err = loadError {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button(L10n.t("重试")) { Task { await load() } }
                }
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
        } catch let err as APIError {
            guard !err.isCancellation else { return }
            if case .businessError(200, _) = err {
                // code=200 但 data=null：服务端「未绑定」语义，进创建模式
                info = nil
                loadError = nil
            } else {
                // 业务失败 / 网络错误：不能当未绑定（已绑定的会被误判进创建模式）
                loadError = err.errorDescription
            }
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
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
