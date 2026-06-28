//
//  CertificatesTab.swift
//  1PanelClient
//
//  SSL 证书管理：列表 / 详情 / 上传 / 删除
//  基于 doc/网站-证书.md
//

import SwiftUI
import Combine

struct CertificatesTab: View {
    @ObservedObject var manager: ServerManager
    @StateObject private var vm: CertificatesViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showUpload = false
    @State private var showApply = false
    @State private var showAcme = false
    @State private var showDns = false
    @State private var showCA = false

    /// 是否显示关闭按钮（fullScreen 模式用 true）
    var showCloseButton: Bool = true
    /// true=自带 NavigationStack；false=仅提供内容
    var standalone: Bool = true

    init(manager: ServerManager, showCloseButton: Bool = true, standalone: Bool = true) {
        self.manager = manager
        self.showCloseButton = showCloseButton
        self.standalone = standalone
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: CertificatesViewModel(server: server))
    }

    var body: some View {
        Group {
            if standalone {
                NavigationStack {
                    rootContent
                }
            } else {
                rootContent
            }
        }
        .task { await vm.refresh() }
        .alert(vm.alertMessage, isPresented: $vm.showAlert) {
            Button("好", role: .cancel) {}
        }
    }

    /// 列表根内容（不含 NavigationStack/task）
    var rootContent: some View {
        Group {
            if vm.isLoading && vm.certificates.isEmpty {
                ProgressView("加载中…")
            } else if vm.certificates.isEmpty {
                ContentUnavailableView(
                    "暂无证书",
                    systemImage: "lock.shield",
                    description: Text(vm.errorMessage ?? "点击右下角「申请」创建第一张证书")
                )
            } else {
                certList
            }
        }
        .navigationTitle("SSL 证书")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showAcme = true
                    } label: {
                        Label("Acme 账户", systemImage: "person.badge.key")
                    }
                    Button {
                        showDns = true
                    } label: {
                        Label("DNS 账户", systemImage: "globe.asia.australia")
                    }
                    Divider()
                    Button {
                        showUpload = true
                    } label: {
                        Label("上传证书", systemImage: "icloud.and.arrow.up")
                    }
                    Button {
                        showCA = true
                    } label: {
                        Label("自签证书", systemImage: "certificate")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            if showCloseButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                showApply = true
            } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor, in: Circle())
                    .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 4)
            }
            .padding(.trailing, 20)
            .padding(.bottom, 20)
            .accessibilityLabel("申请证书")
        }
        .navigationDestination(isPresented: $showUpload) {
            UploadCertificateView(vm: vm)
        }
        .navigationDestination(isPresented: $showApply) {
            ApplyCertificateView(vm: vm)
        }
        .navigationDestination(isPresented: $showAcme) {
            AcmeAccountListView(vm: vm)
        }
        .navigationDestination(isPresented: $showDns) {
            DNSAccountListView(vm: vm)
        }
        .navigationDestination(isPresented: $showCA) {
            CAListView(vm: vm)
        }
    }

    private var certList: some View {
        List {
            ForEach(vm.certificates) { cert in
                NavigationLink {
                    CertificateDetailView(cert: cert, vm: vm)
                } label: {
                    CertificateRow(cert: cert)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        vm.pendingDeleteCert = cert
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await vm.refresh()
        }
        .alert("删除证书", isPresented: Binding(
            get: { vm.pendingDeleteCert != nil },
            set: { if !$0 { vm.pendingDeleteCert = nil } }
        )) {
            Button("取消", role: .cancel) {
                vm.pendingDeleteCert = nil
            }
            Button("删除", role: .destructive) {
                if let cert = vm.pendingDeleteCert {
                    Task {
                        await vm.delete(cert: cert)
                    }
                }
            }
        } message: {
            if let cert = vm.pendingDeleteCert {
                Text("确定要删除证书「\(cert.displayName)」吗？此操作不可撤销。")
            }
        }
    }
}

// MARK: - 证书列表项

struct CertificateRow: View {
    let cert: WebsiteSSLCert

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(
                systemName: cert.isExpired ? "exclamationmark.triangle.fill" : "checkmark.seal.fill",
                color: cert.statusColor,
                cornerRadius: 22  // 圆形
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(cert.displayName)
                    .font(.body.bold())
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(cert.displayOrganization)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(cert.statusDisplay)
                        .font(.caption)
                        .foregroundStyle(cert.statusColor)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(cert.displayExpireDate)
                    .font(.caption.bold())
                Text("到期")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 证书详情

struct CertificateDetailView: View {
    let cert: WebsiteSSLCert
    @ObservedObject var vm: CertificatesViewModel

    @State private var detail: WebsiteSSLCert?
    @State private var isLoading = false
    @State private var tab: DetailTab = .info
    @State private var showUpdateSheet = false
    @State private var showEditView = false
    @State private var pendingRenew = false
    @State private var isRenewing = false
    @State private var logLines: [String] = []
    @State private var isLoadingLog = false

    private enum DetailTab: String, CaseIterable, Identifiable {
        case info    = "证书信息"
        case cert    = "证书"
        case privKey = "私钥"
        case log     = "日志"
        var id: String { rawValue }
    }

    /// 是否通过 ACME 申请（非手动导入），用于显示日志标签
    private var isAcmeCert: Bool {
        !(detail ?? cert).isManual
    }

    /// 是否手动导入（仅手动导入才显示"更新证书内容"）
    private var isManualCert: Bool {
        (detail ?? cert).isManual
    }

    var body: some View {
        List {
            Section {
                Picker("", selection: $tab) {
                    ForEach(visibleTabs) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }

            switch tab {
            case .info:     infoSection
            case .cert:     pemSection(title: "证书内容", content: (detail ?? cert).pem)
            case .privKey:  pemSection(title: "私钥内容", content: (detail ?? cert).privateKey)
            case .log:      logSection
            }
        }
        .navigationTitle(cert.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if isAcmeCert {
                        Button {
                            showEditView = true
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        Button {
                            pendingRenew = true
                        } label: {
                            Label("重新申请", systemImage: "arrow.clockwise")
                        }
                    }
                    if isManualCert {
                        Button {
                            showUpdateSheet = true
                        } label: {
                            Label("更新证书内容", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .navigationDestination(isPresented: $showUpdateSheet) {
            UploadCertificateView(vm: vm, existingCert: detail ?? cert)
        }
        .navigationDestination(isPresented: $showEditView) {
            ApplyCertificateView(vm: vm, existingCert: detail ?? cert)
        }
        .alert("重新申请", isPresented: $pendingRenew) {
            Button("取消", role: .cancel) {}
            Button("确认申请", role: .destructive) {
                Task { await renewCert() }
            }
        } message: {
            Text("将重新申请证书「\((detail ?? cert).displayName)」，是否继续？")
        }
        .task { await loadDetail() }
        .onChange(of: vm.needsRefresh) { _, refreshed in
            if refreshed {
                vm.needsRefresh = false
                Task { await loadDetail() }
            }
        }
        .onChange(of: tab) { _, newTab in
            if newTab == .log && logLines.isEmpty {
                Task { await loadLog() }
            }
        }
    }

    private var visibleTabs: [DetailTab] {
        if isAcmeCert {
            return [.info, .cert, .privKey, .log]
        }
        return [.info, .cert, .privKey]
    }

    private var infoSection: some View {
        let d = detail ?? cert
        return Section {
            LabeledRow("主域名", value: d.primaryDomain ?? "—")
            LabeledRow("其他域名", value: d.displayDomains)
            LabeledRow("证书主体名称(CN)", value: d.displayType)
            LabeledRow("颁发组织", value: d.displayOrganization)
            LabeledRow("申请方式", value: d.providerDisplay)

            if (d.provider ?? "").lowercased() == "dnsaccount" {
                if let dns = d.dnsAccount, !dns.name.isEmpty {
                    LabeledRow("DNS 账号", value: dns.name)
                }
                if let acc = d.acmeAccount, !acc.email.isEmpty {
                    LabeledRow("Acme 账号", value: acc.email)
                }
            }

            LabeledRow("生效时间", value: d.displayStartDate)
            LabeledRow("过期时间", value: d.displayExpireDate)

            if d.pushDir == true {
                LabeledRow("推送证书到本地目录", value: d.dir ?? "")
            }
            if d.execShell == true {
                LabeledRow("申请证书之后执行脚本", value: d.shell ?? "")
            }

            LabeledRow("状态", value: d.statusDisplay)
            if let msg = d.message, !msg.isEmpty {
                LabeledRow("状态详情", value: msg)
            }

            if isAcmeCert {
                Toggle("自动续签", isOn: Binding(
                    get: { d.autoRenew ?? false },
                    set: { newVal in
                        Task {
                            await vm.updateSSLAutoRenew(cert: d, autoRenew: newVal)
                            detail?.autoRenew = newVal
                        }
                    }
                ))
            }

            if let desc = d.description, !desc.isEmpty {
                LabeledRow("备注", value: desc)
            }
        } header: {
            Text("证书信息")
        } footer: {
            if isAcmeCert {
                EmptyView()
            } else {
                Text("手动导入的证书不支持自动续签和重新申请")
            }
        }
    }

    private func pemSection(title: String, content: String?) -> some View {
        Section {
            if let content, !content.isEmpty {
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                HStack {
                    ProgressView()
                    Text("加载中…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(title)
        }
    }

    private var logSection: some View {
        Section {
            if isLoadingLog && logLines.isEmpty {
                HStack {
                    ProgressView()
                    Text("加载日志…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if logLines.isEmpty {
                Text("暂无日志")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .listRowSeparator(.hidden)
                }
            }
        } header: {
            Text("申请日志")
        } footer: {
            if let path = (detail ?? cert).logPath, !path.isEmpty {
                Text(path)
                    .font(.system(size: 9))
            }
        }
    }

    private func loadDetail() async {
        isLoading = true; defer { isLoading = false }
        if let full = await vm.loadDetail(id: cert.id) {
            detail = full
        }
    }

    private func loadLog() async {
        isLoadingLog = true
        defer { isLoadingLog = false }
        logLines = await vm.loadSSLLog(id: cert.id)
    }

    private func renewCert() async {
        isRenewing = true
        defer { isRenewing = false }
        if await vm.obtainSSL(id: cert.id) {
            tab = .log
            logLines = []
            await loadLog()
        }
    }
}

// MARK: - 上传证书

struct UploadCertificateView: View {
    @ObservedObject var vm: CertificatesViewModel
    @Environment(\.dismiss) private var dismiss

    /// 传入则进入「更新」模式（覆盖原证书），为 nil 则为「上传」新证书
    var existingCert: WebsiteSSLCert?

    @State private var mode: UploadMode = .paste
    @State private var description = ""
    @State private var privateKey = ""
    @State private var certificate = ""
    @State private var privateKeyPath = ""
    @State private var certificatePath = ""

    private enum UploadMode: String, CaseIterable, Identifiable {
        case paste = "粘贴内容"
        case local = "服务器文件"
        var id: String { rawValue }
    }

    private var isUpdate: Bool { existingCert != nil }

    var body: some View {
        Form {
            Section {
                Picker("上传方式", selection: $mode) {
                    ForEach(UploadMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                TextField("备注（可选）", text: $description)
            } header: {
                if isUpdate {
                    Text("更新证书")
                } else {
                    Text("上传方式")
                }
            } footer: {
                if isUpdate {
                    Text("将用新的证书内容替换「\(existingCert?.displayName ?? "")」。原证书的 ID 保持不变，已绑定该证书的网站会自动生效。")
                } else {
                    EmptyView()
                }
            }

            switch mode {
            case .paste:
                Section {
                    TextEditor(text: $privateKey)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 120)
                } header: { Text("私钥（PRIVATE KEY）") }
                footer: { Text("粘贴以 -----BEGIN PRIVATE KEY----- 开头的完整内容") }

                Section {
                    TextEditor(text: $certificate)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 120)
                } header: { Text("证书（CERTIFICATE）") }
                footer: { Text("粘贴以 -----BEGIN CERTIFICATE----- 开头的完整内容") }

            case .local:
                Section {
                    TextField("如 /home/user/privkey.pem", text: $privateKeyPath)
                } header: { Text("私钥文件路径") }

                Section {
                    TextField("如 /home/user/fullchain.pem", text: $certificatePath)
                } header: { Text("证书文件路径") }
            }
        }
        .navigationTitle(isUpdate ? "更新证书" : "上传证书")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await submit() }
                } label: {
                    if vm.isUploading {
                        ProgressView()
                    } else {
                        Text(isUpdate ? "保存" : "上传").bold()
                    }
                }
                .disabled(!canSubmit || vm.isUploading)
            }
        }
    }

    private var canSubmit: Bool {
        switch mode {
        case .paste:
            return !privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !certificate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .local:
            return !privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !certificatePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func submit() async {
        var req = WebsiteSSLUploadRequest()
        req.type = (mode == .paste) ? "paste" : "local"
        req.description = description
        req.sslID = existingCert?.id ?? 0
        switch mode {
        case .paste:
            req.privateKey = privateKey
            req.certificate = certificate
        case .local:
            req.privateKeyPath = privateKeyPath
            req.certificatePath = certificatePath
        }

        if await vm.upload(req: req, isUpdate: isUpdate) {
            dismiss()
        }
    }
}

// MARK: - ViewModel

final class CertificatesViewModel: ObservableObject {
    @Published var certificates: [WebsiteSSLCert] = []
    @Published var isLoading = false
    @Published var isUploading = false
    @Published var errorMessage: String?

    @Published var showAlert = false
    @Published var alertMessage = ""

    /// 列表删除确认
    @Published var pendingDeleteCert: WebsiteSSLCert?

    /// 上传成功后用于触发列表刷新
    @Published var needsRefresh = false

    private(set) var client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let resp: WebsiteSSLListResponse = try await client.send(
                path: APIEndpoint.websitesSSLList.path,
                body: WebsiteSSLListRequest(),
                as: WebsiteSSLListResponse.self
            )
            certificates = resp.items ?? []
        } catch let err as APIError {
            errorMessage = err.errorDescription
            showAlert(message: "加载失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            errorMessage = error.localizedDescription
            showAlert(message: "加载失败：\(error.localizedDescription)")
        }
    }

    func loadDetail(id: Int) async -> WebsiteSSLCert? {
        let path = APIEndpoint.websitesSSLDetail.path
            .replacingOccurrences(of: ":id", with: String(id))
        do {
            return try await client.send(
                path: path,
                method: "GET",
                as: WebsiteSSLCert.self
            )
        } catch {
            showAlert(message: "加载详情失败：\((error as? APIError)?.errorDescription ?? error.localizedDescription)")
            return nil
        }
    }

    func upload(req: WebsiteSSLUploadRequest, isUpdate: Bool = false) async -> Bool {
        isUploading = true
        defer { isUploading = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesSSLUpload.path,
                body: req,
                as: EmptyResponse.self
            )
            showAlert(message: isUpdate ? "证书已更新" : "证书上传成功")
            await refresh()
            needsRefresh = true
            return true
        } catch let err as APIError {
            showAlert(message: "\(isUpdate ? "更新" : "上传")失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "\(isUpdate ? "更新" : "上传")失败：\(error.localizedDescription)")
            return false
        }
    }

    func delete(cert: WebsiteSSLCert) async {
        pendingDeleteCert = nil
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesSSLDelete.path,
                body: WebsiteSSLDeleteRequest(ids: [cert.id]),
                as: EmptyResponse.self
            )
            showAlert(message: "证书已删除")
            await refresh()
        } catch let err as APIError {
            showAlert(message: "删除失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "删除失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 申请证书

    func applySSL(req: WebsiteSSLCreateRequest) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesSSLCreate.path,
                body: req,
                as: EmptyResponse.self
            )
            showAlert(message: "证书申请已提交")
            await refresh()
            return true
        } catch let err as APIError {
            showAlert(message: "申请失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "申请失败：\(error.localizedDescription)")
            return false
        }
    }

    func obtainSSL(id: Int) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesSSLObtain.path,
                body: WebsiteSSLObtainRequest(id: id),
                as: EmptyResponse.self
            )
            showAlert(message: "已重新提交申请")
            return true
        } catch let err as APIError {
            showAlert(message: "申请失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "申请失败：\(error.localizedDescription)")
            return false
        }
    }

    func updateSSLAutoRenew(cert: WebsiteSSLCert, autoRenew: Bool) async {
        var updated = cert
        updated.autoRenew = autoRenew
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesSSLUpdate.path,
                body: updated,
                as: EmptyResponse.self
            )
        } catch let err as APIError {
            showAlert(message: "更新失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "更新失败：\(error.localizedDescription)")
        }
    }

    func loadSSLLog(id: Int) async -> [String] {
        let req = WebsiteSSLLogRequest(id: id, page: 1, pageSize: 500, latest: true)
        do {
            let resp: WebsiteSSLLogResponse = try await client.send(
                path: APIEndpoint.websitesSSLLog.path,
                body: req,
                as: WebsiteSSLLogResponse.self
            )
            return resp.lines ?? []
        } catch {
            return []
        }
    }

    // MARK: - Acme 账户

    func loadAcmeAccounts() async -> [AcmeAccount] {
        do {
            let resp: PageResponse<AcmeAccount> = try await client.send(
                path: APIEndpoint.websitesAcmeSearch.path,
                body: AcmeSearchRequest(),
                as: PageResponse<AcmeAccount>.self
            )
            return resp.items ?? []
        } catch let err as APIError {
            showAlert(message: "加载失败：\(err.errorDescription ?? "未知错误")")
            return []
        } catch {
            showAlert(message: "加载失败：\(error.localizedDescription)")
            return []
        }
    }

    func createAcmeAccount(req: AcmeCreateRequest) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesAcmeCreate.path,
                body: req,
                as: EmptyResponse.self
            )
            return true
        } catch let err as APIError {
            showAlert(message: "创建失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "创建失败：\(error.localizedDescription)")
            return false
        }
    }

    func deleteAcmeAccount(id: Int) async -> Bool {
        struct Req: Encodable { let id: Int }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesAcmeDelete.path,
                body: Req(id: id),
                as: EmptyResponse.self
            )
            return true
        } catch let err as APIError {
            showAlert(message: "删除失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "删除失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - DNS 账户

    func loadDnsAccounts() async -> [DNSAccount] {
        do {
            let resp: PageResponse<DNSAccount> = try await client.send(
                path: APIEndpoint.websitesDnsSearch.path,
                body: DnsSearchRequest(),
                as: PageResponse<DNSAccount>.self
            )
            return resp.items ?? []
        } catch let err as APIError {
            showAlert(message: "加载失败：\(err.errorDescription ?? "未知错误")")
            return []
        } catch {
            showAlert(message: "加载失败：\(error.localizedDescription)")
            return []
        }
    }

    func createDnsAccount(name: String, type: String, auth: [String: String]) async -> Bool {
        struct Req: Encodable {
            let id: Int
            let name: String
            let type: String
            let authorization: [String: String]
        }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesDnsCreate.path,
                body: Req(id: 0, name: name, type: type, authorization: auth),
                as: EmptyResponse.self
            )
            return true
        } catch let err as APIError {
            showAlert(message: "创建失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "创建失败：\(error.localizedDescription)")
            return false
        }
    }

    func deleteDnsAccount(id: Int) async -> Bool {
        struct Req: Encodable { let id: Int }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesDnsDelete.path,
                body: Req(id: id),
                as: EmptyResponse.self
            )
            return true
        } catch let err as APIError {
            showAlert(message: "删除失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "删除失败：\(error.localizedDescription)")
            return false
        }
    }

    func updateDnsAccount(account: DNSAccount) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesDnsUpdate.path,
                body: account,
                as: EmptyResponse.self
            )
            return true
        } catch let err as APIError {
            showAlert(message: "保存失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "保存失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 自签证书（CA 机构）

    func loadCAs() async -> [CertificateAuthority] {
        do {
            let resp: PageResponse<CertificateAuthority> = try await client.send(
                path: APIEndpoint.websitesCaSearch.path,
                body: CASearchRequest(),
                as: PageResponse<CertificateAuthority>.self
            )
            return resp.items ?? []
        } catch let err as APIError {
            showAlert(message: "加载失败：\(err.errorDescription ?? "未知错误")")
            return []
        } catch {
            showAlert(message: "加载失败：\(error.localizedDescription)")
            return []
        }
    }

    func loadCADetail(id: Int) async -> CertificateAuthority? {
        let path = APIEndpoint.websitesCaDetail.path
            .replacingOccurrences(of: ":id", with: String(id))
        do {
            return try await client.send(
                path: path,
                method: "GET",
                as: CertificateAuthority.self
            )
        } catch {
            showAlert(message: "加载详情失败：\((error as? APIError)?.errorDescription ?? error.localizedDescription)")
            return nil
        }
    }

    func createCA(req: CACreateRequest) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesCaCreate.path,
                body: req,
                as: EmptyResponse.self
            )
            return true
        } catch let err as APIError {
            showAlert(message: "创建失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "创建失败：\(error.localizedDescription)")
            return false
        }
    }

    func deleteCA(id: Int) async -> Bool {
        struct Req: Encodable { let id: Int }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesCaDelete.path,
                body: Req(id: id),
                as: EmptyResponse.self
            )
            return true
        } catch let err as APIError {
            showAlert(message: "删除失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "删除失败：\(error.localizedDescription)")
            return false
        }
    }

    func obtainCA(req: CAObtainRequest) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesCaObtain.path,
                body: req,
                as: EmptyResponse.self
            )
            return true
        } catch let err as APIError {
            showAlert(message: "签发失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "签发失败：\(error.localizedDescription)")
            return false
        }
    }

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }
}
