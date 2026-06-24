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
    @State private var showUploadSheet = false

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
        if standalone {
            NavigationStack {
                rootContent
            }
            .task { await vm.refresh() }
            .alert(vm.alertMessage, isPresented: $vm.showAlert) {
                Button("好", role: .cancel) {}
            }
        } else {
            rootContent
                .task { await vm.refresh() }
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
                    description: Text(vm.errorMessage ?? "点击右下角 + 上传第一张证书")
                )
            } else {
                certList
            }
        }
        .navigationTitle("SSL 证书")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
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
                showUploadSheet = true
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
            .accessibilityLabel("上传证书")
        }
        .navigationDestination(for: WebsiteSSLCert.self) { cert in
            CertificateDetailView(cert: cert, vm: vm)
        }
        .sheet(isPresented: $showUploadSheet) {
            UploadCertificateView(vm: vm)
        }
    }

    private var certList: some View {
        List {
            ForEach(vm.certificates) { cert in
                NavigationLink(value: cert) {
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

    private enum DetailTab: String, CaseIterable, Identifiable {
        case info    = "证书信息"
        case cert    = "证书"
        case privKey = "私钥"
        var id: String { rawValue }
    }

    var body: some View {
        List {
            Section {
                Picker("", selection: $tab) {
                    ForEach(DetailTab.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }

            switch tab {
            case .info:  infoSection
            case .cert:  pemSection(title: "证书内容", content: (detail ?? cert).pem)
            case .privKey: pemSection(title: "私钥内容", content: (detail ?? cert).privateKey)
            }
        }
        .navigationTitle(cert.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showUpdateSheet = true
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            }
        }
        .sheet(isPresented: $showUpdateSheet) {
            UploadCertificateView(vm: vm, existingCert: detail ?? cert)
        }
        .task { await loadDetail() }
        .onChange(of: vm.needsRefresh) { _, refreshed in
            if refreshed {
                vm.needsRefresh = false
                Task { await loadDetail() }
            }
        }
    }

    private var infoSection: some View {
        Section {
            LabeledRow("主域名", value: (detail ?? cert).displayName)
            LabeledRow("子域名", value: (detail ?? cert).displayDomains)
            LabeledRow("颁发机构", value: (detail ?? cert).displayOrganization)
            LabeledRow("证书类型", value: (detail ?? cert).displayType)
            LabeledRow("来源", value: (detail ?? cert).isManual ? "手动导入" : "自动申请")
            LabeledRow("状态", value: (detail ?? cert).statusDisplay)
            LabeledRow("开始日期", value: (detail ?? cert).displayStartDate)
            LabeledRow("过期日期", value: (detail ?? cert).displayExpireDate)
            if let desc = (detail ?? cert).description, !desc.isEmpty {
                LabeledRow("备注", value: desc)
            }
            let created = (detail ?? cert).displayCreatedAt
            if created != "—" {
                LabeledRow("创建时间", value: created)
            }
        } header: {
            Text("证书信息")
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

    private func loadDetail() async {
        isLoading = true; defer { isLoading = false }
        if let full = await vm.loadDetail(id: cert.id) {
            detail = full
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
        NavigationStack {
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
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
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

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }
}
