//
//  ApplyCertificateView.swift
//  1PanelClient
//
//  申请 / 编辑 SSL 证书
//  基于 doc/网站-证书.md
//

import SwiftUI

struct ApplyCertificateView: View {
    @ObservedObject var vm: CertificatesViewModel

    /// 传入则进入「编辑」模式（覆盖原证书），为 nil 则为「申请」新证书
    var existingCert: WebsiteSSLCert?

    @Environment(\.dismiss) private var dismiss

    // MARK: - 表单状态

    @State private var primaryDomain = ""
    @State private var otherDomains = ""
    @State private var description_ = ""
    @State private var acmeAccounts: [AcmeAccount] = []
    @State private var dnsAccounts: [DNSAccount] = []
    @State private var selectedAcmeId: Int = 0
    @State private var selectedKeyType: SSLKeyType = .EC256
    @State private var selectedProvider: SSLProvider = .dnsAccount
    @State private var selectedDnsId: Int = 0
    @State private var autoRenew = true
    @State private var disableCNAME = false
    @State private var skipDNS = false
    @State private var nameserver1 = ""
    @State private var nameserver2 = ""
    @State private var pushDir = false
    @State private var dir = ""
    @State private var execShell = false
    @State private var shell = ""
    @State private var isSubmitting = false

    private var isEdit: Bool { existingCert != nil }

    /// 编辑自签证书时使用简化表单
    private var isSelfSignedEdit: Bool {
        (existingCert?.provider ?? "").lowercased() == "selfsigned"
    }

    var body: some View {
        Group {
            if isSelfSignedEdit {
                selfSignedForm
            } else {
                acmeForm
            }
        }
        .navigationTitle(isEdit ? L10n.t("编辑证书") : L10n.t("申请证书"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text(isEdit ? L10n.t("保存") : L10n.t("申请")).bold()
                    }
                }
                .disabled(primaryDomain.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
            }
        }
        .task {
            if !isSelfSignedEdit { await loadAccounts() }
            if let existing = existingCert { prefill(from: existing) }
        }
    }

    // MARK: - 自签证书编辑表单

    private var selfSignedForm: some View {
        Form {
            Section {
                TextField(L10n.t("主域名"), text: $primaryDomain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text(L10n.t("域名"))
            }

            Section {
                TextField(L10n.t("其他域名（一行一个）"), text: $otherDomains, axis: .vertical)
                    .lineLimit(3, reservesSpace: true)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text(L10n.t("其他域名"))
            }

            Section {
                TextField(L10n.t("备注"), text: $description_)
            } header: {
                Text(L10n.t("备注"))
            }

            Section {
                InfoRow(L10n.t("密钥算法"), value: selectedKeyType.displayName)
                Toggle(L10n.t("自动续签"), isOn: $autoRenew)
            } header: {
                Text(L10n.t("配置"))
            }
        }
    }

    // MARK: - ACME 申请表单

    private var acmeForm: some View {
        Form {
            Section(L10n.t("域名")) {
                TextField(L10n.t("主域名（必填）"), text: $primaryDomain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(L10n.t("其他域名（可选，一行一个）"), text: $otherDomains, axis: .vertical)
                    .lineLimit(3, reservesSpace: true)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(L10n.t("备注（可选）"), text: $description_)
            }

            Section(L10n.t("申请配置")) {
                Picker(L10n.t("Acme 账户"), selection: $selectedAcmeId) {
                    ForEach(acmeAccounts) { acc in
                        Text("\(acc.email) (\(AcmeType(rawValue: acc.type)?.displayName ?? acc.type))")
                            .tag(acc.id)
                    }
                }

                Picker(L10n.t("密匙算法"), selection: $selectedKeyType) {
                    ForEach(SSLKeyType.allCases) { Text($0.displayName).tag($0) }
                }

                Picker(L10n.t("验证方式"), selection: $selectedProvider) {
                    ForEach(SSLProvider.allCases) { Text($0.displayName).tag($0) }
                }

                if selectedProvider == .dnsAccount {
                    Picker(L10n.t("DNS 账户"), selection: $selectedDnsId) {
                        ForEach(dnsAccounts) { acc in
                            Text("\(acc.name) (\(DnsType(rawValue: acc.type)?.displayName ?? acc.type))")
                                .tag(acc.id)
                        }
                    }
                }

                Toggle(L10n.t("自动续签"), isOn: $autoRenew)
            }

            Section {
                Toggle(L10n.t("禁用 CNAME"), isOn: $disableCNAME)
                Toggle(L10n.t("跳过 DNS 校验"), isOn: $skipDNS)
                TextField(L10n.t("DNS 服务器 1（可选）"), text: $nameserver1)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(L10n.t("DNS 服务器 2（可选）"), text: $nameserver2)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text(L10n.t("高级设置"))
            } footer: {
                Text(L10n.t("禁用 CNAME：有 CNAME 配置的域名如果申请失败可以开启。跳过 DNS 校验：如果出现申请超时问题请开启，其他情况请勿开启。"))
            }

            Section {
                Toggle(L10n.t("推送证书到本地"), isOn: $pushDir)
                if pushDir {
                    TextField(L10n.t("推送路径（如 /tmp）"), text: $dir)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Toggle(L10n.t("申请证书之后执行脚本"), isOn: $execShell)
                if execShell {
                    TextField(L10n.t("脚本内容"), text: $shell, axis: .vertical)
                        .lineLimit(5, reservesSpace: true)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text(L10n.t("其他选项"))
            }
        }
    }

    // MARK: - 数据加载

    private func loadAccounts() async {
        async let acme = vm.loadAcmeAccounts()
        async let dns = vm.loadDnsAccounts()
        let (acmeList, dnsList) = await (acme, dns)
        acmeAccounts = acmeList
        dnsAccounts = dnsList
        if selectedAcmeId == 0, let first = acmeList.first { selectedAcmeId = first.id }
        if selectedDnsId == 0, let first = dnsList.first { selectedDnsId = first.id }
    }

    /// 编辑模式下用原证书数据回填表单
    private func prefill(from cert: WebsiteSSLCert) {
        primaryDomain = cert.primaryDomain ?? ""
        if isSelfSignedEdit {
            // 自签证书：domains（逗号分隔）转为换行显示
            otherDomains = (cert.domains ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            description_ = cert.message ?? ""
        } else {
            otherDomains = cert.otherDomains ?? ""
            description_ = cert.description ?? ""
        }
        if let id = cert.acmeAccountId, id != 0 { selectedAcmeId = id }
        if let id = cert.dnsAccountId, id != 0 { selectedDnsId = id }
        if let kt = cert.keyType, let type = SSLKeyType(rawValue: kt) { selectedKeyType = type }
        if let p = cert.provider, let provider = SSLProvider(rawValue: p) { selectedProvider = provider }
        if let renew = cert.autoRenew { autoRenew = renew }
        disableCNAME = cert.disableCNAME ?? false
        skipDNS = cert.skipDNS ?? false
        nameserver1 = cert.nameserver1 ?? ""
        nameserver2 = cert.nameserver2 ?? ""
        pushDir = cert.pushDir ?? false
        dir = cert.dir ?? ""
        execShell = cert.execShell ?? false
        shell = cert.shell ?? ""
    }

    // MARK: - 提交

    private func submit() async {
        guard !primaryDomain.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        var req = WebsiteSSLCreateRequest()
        if let existing = existingCert { req.id = existing.id }
        req.primaryDomain = primaryDomain
        req.keyType = selectedKeyType.rawValue
        req.autoRenew = autoRenew

        if isSelfSignedEdit {
            req.provider = "selfSigned"
            req.otherDomains = otherDomains
            req.message = description_
        } else {
            req.otherDomains = otherDomains
            req.description = description_
            req.acmeAccountId = selectedAcmeId
            req.provider = selectedProvider.rawValue
            req.dnsAccountId = selectedDnsId
            req.disableCNAME = disableCNAME
            req.skipDNS = skipDNS
            req.nameserver1 = nameserver1
            req.nameserver2 = nameserver2
            req.pushDir = pushDir
            req.dir = dir
            req.execShell = execShell
            req.shell = shell
        }

        let success = await vm.applySSL(req: req)
        if success { dismiss() }
    }
}
