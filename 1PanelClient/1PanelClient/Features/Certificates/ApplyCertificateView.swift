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

    var body: some View {
        Form {
            Section("域名") {
                TextField("主域名（必填）", text: $primaryDomain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("其他域名（可选，一行一个）", text: $otherDomains, axis: .vertical)
                    .lineLimit(3, reservesSpace: true)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("备注（可选）", text: $description_)
            }

            Section("申请配置") {
                Picker("Acme 账户", selection: $selectedAcmeId) {
                    ForEach(acmeAccounts) { acc in
                        Text("\(acc.email) (\(AcmeType(rawValue: acc.type)?.displayName ?? acc.type))")
                            .tag(acc.id)
                    }
                }

                Picker("密匙算法", selection: $selectedKeyType) {
                    ForEach(SSLKeyType.allCases) { Text($0.displayName).tag($0) }
                }

                Picker("验证方式", selection: $selectedProvider) {
                    ForEach(SSLProvider.allCases) { Text($0.displayName).tag($0) }
                }

                if selectedProvider == .dnsAccount {
                    Picker("DNS 账户", selection: $selectedDnsId) {
                        ForEach(dnsAccounts) { acc in
                            Text("\(acc.name) (\(DnsType(rawValue: acc.type)?.displayName ?? acc.type))")
                                .tag(acc.id)
                        }
                    }
                }

                Toggle("自动续签", isOn: $autoRenew)
            }

            Section {
                Toggle("禁用 CNAME", isOn: $disableCNAME)
                Toggle("跳过 DNS 校验", isOn: $skipDNS)
                TextField("DNS 服务器 1（可选）", text: $nameserver1)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("DNS 服务器 2（可选）", text: $nameserver2)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("高级设置")
            } footer: {
                Text("禁用 CNAME：有 CNAME 配置的域名如果申请失败可以开启。跳过 DNS 校验：如果出现申请超时问题请开启，其他情况请勿开启。")
            }

            Section {
                Toggle("推送证书到本地", isOn: $pushDir)
                if pushDir {
                    TextField("推送路径（如 /tmp）", text: $dir)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Toggle("申请证书之后执行脚本", isOn: $execShell)
                if execShell {
                    TextField("脚本内容", text: $shell, axis: .vertical)
                        .lineLimit(5, reservesSpace: true)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("其他选项")
            }
        }
        .navigationTitle(existingCert == nil ? "申请证书" : "编辑证书")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text(isEdit ? "保存" : "申请").bold()
                    }
                }
                .disabled(primaryDomain.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
            }
        }
        .task {
            await loadAccounts()
            if let existing = existingCert { prefill(from: existing) }
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
        otherDomains = cert.otherDomains ?? ""
        description_ = cert.description ?? ""
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
        req.otherDomains = otherDomains
        req.description = description_
        req.acmeAccountId = selectedAcmeId
        req.keyType = selectedKeyType.rawValue
        req.provider = selectedProvider.rawValue
        req.dnsAccountId = selectedDnsId
        req.autoRenew = autoRenew
        req.disableCNAME = disableCNAME
        req.skipDNS = skipDNS
        req.nameserver1 = nameserver1
        req.nameserver2 = nameserver2
        req.pushDir = pushDir
        req.dir = dir
        req.execShell = execShell
        req.shell = shell

        let success = await vm.applySSL(req: req)
        if success { dismiss() }
    }
}
