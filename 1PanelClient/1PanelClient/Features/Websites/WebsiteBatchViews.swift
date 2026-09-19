//
//  WebsiteBatchViews.swift
//  1PanelClient
//
//  网站批量操作（logs/网站批量抓包 2026-09-14）：
//  多选模式底部操作栏（启停/分组/证书/删除）· 分组 Sheet · 证书设置 Sheet
//

import SwiftUI

// MARK: - 批量操作栏（多选模式底部）

struct WebsiteBatchBar: View {
    let selectedCount: Int
    let totalCount: Int
    let isOperating: Bool
    let onSelectAll: () -> Void
    let onOperate: (String) -> Void      // start / stop / delete
    let onGroup: () -> Void
    let onSSL: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                onSelectAll()
            } label: {
                Label(
                    selectedCount >= totalCount ? L10n.t("取消全选") : L10n.t("全选"),
                    systemImage: selectedCount >= totalCount ? "circle" : "checkmark.circle"
                )
                .font(.subheadline)
            }
            .disabled(totalCount == 0)

            Spacer()

            Text(L10n.f("已选 %ld 项", selectedCount))
                .font(.caption)
                .foregroundStyle(.secondary)

            // 操作收进下拉菜单：6 个并排按钮在窄屏显示不全；
            // 退出按钮在右上角工具栏（与文件页一致）
            Menu {
                Button { onOperate("start") } label: {
                    Label(L10n.t("启动"), systemImage: "play.fill")
                }
                Button { onOperate("stop") } label: {
                    Label(L10n.t("停止"), systemImage: "stop.fill")
                }
                Button { onGroup() } label: {
                    Label(L10n.t("分组"), systemImage: "folder")
                }
                Button { onSSL() } label: {
                    Label(L10n.t("证书"), systemImage: "lock.shield")
                }
                Button(role: .destructive) { onOperate("delete") } label: {
                    Label(L10n.t("删除"), systemImage: "trash")
                }
            } label: {
                Label(L10n.t("批量操作"), systemImage: "ellipsis.circle")
                    .font(.subheadline.bold())
            }
            .disabled(selectedCount == 0 || isOperating)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - 批量分组 Sheet

struct WebsiteBatchGroupSheet: View {
    let server: ServerConfig
    let ids: [Int]
    let groups: [PanelGroup]
    let onDone: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var groupID: Int?
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showError = false

    private let client: APIClient

    init(server: ServerConfig, ids: [Int], groups: [PanelGroup], onDone: @escaping () async -> Void) {
        self.server = server
        self.ids = ids
        self.groups = groups
        self.onDone = onDone
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L10n.t("分组"), selection: $groupID) {
                        ForEach(groups) { group in
                            Text(group.name ?? "-").tag(Optional(group.id))
                        }
                    }
                } footer: {
                    Text(L10n.f("将 %ld 个网站移入所选分组", ids.count))
                }
            }
            .navigationTitle(L10n.t("批量设置分组"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { groupID = groups.first?.id }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("保存")) {
                        Task { await submit() }
                    }
                    .disabled(groupID == nil || isSubmitting)
                }
            }
            .alert(L10n.t("提示"), isPresented: $showError) {
                Button(L10n.t("好的"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.medium])
        .interactiveDismissDisabled(isSubmitting)
    }

    private func submit() async {
        guard let groupID else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesBatchGroup.path,
                body: WebsiteBatchGroupRequest(ids: ids, groupID: groupID),
                as: EmptyResponse.self)
            await onDone()
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - 批量设置证书 Sheet

/// POST /websites/batch/ssl（type=existed：选择已有证书）；
/// 证书列表按 Acme 账户过滤（ssl/list {acmeAccountID}，"0"=全部，抓包确认）
struct WebsiteBatchSSLSheet: View {
    let server: ServerConfig
    let ids: [Int]
    /// 提交成功（taskID → 任务进度页）
    let onStarted: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [AcmeAccount] = []
    @State private var certificates: [WebsiteSSL] = []
    @State private var selectedAccountID = 0
    @State private var selectedSSLID: Int?
    @State private var httpConfig = "HTTPToHTTPS"
    @State private var hsts = true
    @State private var hstsSubDomains = false
    @State private var http3 = false
    @State private var tls13 = true
    @State private var tls12 = true
    @State private var tls11 = false
    @State private var tls10 = false
    @State private var isLoading = true
    /// 证书列表加载失败（与「账户下无证书」区分，提供重试）
    @State private var certLoadFailed = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showError = false

    private let client: APIClient

    /// v2 oneof：HTTPToHTTPS / HTTPAlso / HTTPSOnly（enable/disable 为 v1 取值，提交必 400）
    private let httpOptions: [(value: String, label: String)] = [
        ("HTTPToHTTPS", L10n.t("访问 HTTP 自动跳转到 HTTPS")),
        ("HTTPAlso", L10n.t("HTTP 可直接访问")),
        ("HTTPSOnly", L10n.t("禁止 HTTP 访问")),
    ]

    init(server: ServerConfig, ids: [Int], onStarted: @escaping (String) -> Void) {
        self.server = server
        self.ids = ids
        self.onStarted = onStarted
        self.client = APIClient.shared(for: server)
    }

    private var sslProtocols: [String] {
        var list: [String] = []
        if tls13 { list.append("TLSv1.3") }
        if tls12 { list.append("TLSv1.2") }
        if tls11 { list.append("TLSv1.1") }
        if tls10 { list.append("TLSv1.0") }
        return list
    }

    /// Acme 账户选项（OutlinedPicker 用 String 键；0=全部）
    private var accountOptionKeys: [String] {
        ["0"] + accounts.map { String($0.id) }
    }

    private var accountOptionLabels: [String: String] {
        var labels = ["0": L10n.t("全部")]
        for account in accounts {
            labels[String(account.id)] = account.email.isEmpty ? "#\(account.id)" : account.email
        }
        return labels
    }

    private var accountText: Binding<String> {
        Binding<String>(
            get: { String(selectedAccountID) },
            set: { selectedAccountID = Int($0) ?? 0 }
        )
    }

    private var sslOptionLabels: [String: String] {
        var labels: [String: String] = [:]
        for ssl in certificates { labels[String(ssl.id)] = ssl.displayName }
        return labels
    }

    private var sslText: Binding<String> {
        Binding<String>(
            get: { selectedSSLID.map(String.init) ?? "" },
            set: { selectedSSLID = Int($0) }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    OutlinedPicker(label: L10n.t("Acme 账户"),
                                   options: accountOptionKeys, selection: accountText,
                                   optionLabels: accountOptionLabels)
                        .onChange(of: selectedAccountID) { _, _ in
                            Task { await loadCertificates() }
                        }

                    if isLoading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if certLoadFailed {
                        VStack(spacing: 8) {
                            Text(L10n.t("证书加载失败"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(L10n.t("重试")) {
                                Task {
                                    isLoading = true
                                    await loadAccounts()
                                    await loadCertificates()
                                    isLoading = false
                                }
                            }
                            .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                    } else if certificates.isEmpty {
                        Text(L10n.t("该账户下暂无证书"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        OutlinedPicker(label: L10n.t("证书"),
                                       options: certificates.map { String($0.id) },
                                       selection: sslText,
                                       optionLabels: sslOptionLabels)
                    }
                } header: {
                    SectionLabel(title: L10n.t("证书"), systemImage: "lock.shield")
                }

                Section {
                    OutlinedPicker(label: L10n.t("HTTP 选项"),
                                   options: httpOptions.map(\.value),
                                   selection: $httpConfig,
                                   optionLabels: Dictionary(uniqueKeysWithValues:
                                       httpOptions.map { ($0.value, $0.label) }))
                    Toggle(L10n.t("启用 HSTS"), isOn: $hsts)
                    Toggle(L10n.t("HSTS 子域"), isOn: $hstsSubDomains)
                    Toggle(L10n.t("启用 HTTP3"), isOn: $http3)
                } header: {
                    SectionLabel(title: L10n.t("HTTPS 设置"), systemImage: "lock")
                }

                Section {
                    Toggle("TLSv1.3", isOn: $tls13)
                    Toggle("TLSv1.2", isOn: $tls12)
                    Toggle("TLSv1.1（" + L10n.t("不安全") + "）", isOn: $tls11)
                    Toggle("TLSv1.0（" + L10n.t("不安全") + "）", isOn: $tls10)
                } header: {
                    SectionLabel(title: L10n.t("SSL 协议"), systemImage: "shield.lefthalf.filled")
                } footer: {
                    Text(L10n.t("加密算法使用服务器默认配置"))
                }
            }
            .navigationTitle(L10n.t("批量设置证书"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("保存")) {
                        Task { await submit() }
                    }
                    .disabled(selectedSSLID == nil || sslProtocols.isEmpty || isSubmitting)
                }
            }
            .alert(L10n.t("提示"), isPresented: $showError) {
                Button(L10n.t("好的"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                await loadAccounts()
                await loadCertificates()
                isLoading = false
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.large])
        .interactiveDismissDisabled(isSubmitting)
    }

    private func loadAccounts() async {
        if let resp: PageResponse<AcmeAccount> = try? await client.send(
            path: APIEndpoint.websitesAcmeSearch.path,
            body: AISearchPageRequest(page: 1, pageSize: 100),
            as: PageResponse<AcmeAccount>.self) {
            accounts = resp.items ?? []
        }
    }

    private func loadCertificates() async {
        selectedSSLID = nil
        do {
            let list: [WebsiteSSL] = try await client.send(
                path: APIEndpoint.websitesSSLSearch.path,
                body: WebsiteSSLByAccountRequest(acmeAccountID: String(selectedAccountID)),
                as: [WebsiteSSL].self)
            certificates = list
            selectedSSLID = list.first?.id
            certLoadFailed = false
        } catch {
            // 失败不伪装成「无证书」：保留失败态 + 重试入口
            guard !APIError.isCancellation(error) else { return }
            certificates = []
            certLoadFailed = true
        }
    }

    private func submit() async {
        guard let sslID = selectedSSLID else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        let taskID = UUID().uuidString
        let req = WebsiteBatchSSLRequest(
            ids: ids,
            acmeAccountID: selectedAccountID,
            enable: false,
            websiteSSLId: sslID,
            type: "existed",
            importType: "paste",
            privateKey: "",
            certificate: "",
            privateKeyPath: "",
            certificatePath: "",
            httpConfig: httpConfig,
            hsts: hsts,
            hstsIncludeSubDomains: hstsSubDomains,
            algorithm: WebsiteBatchSSLRequest.defaultAlgorithm,
            SSLProtocol: sslProtocols,
            // 网页端批量表单无端口输入（抓包无此字段展示），固定 443
            httpsPorts: [443],
            http3: http3,
            taskID: taskID)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesBatchSsl.path, body: req, as: EmptyResponse.self)
            onStarted(taskID)
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
