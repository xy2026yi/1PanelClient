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
    /// 高级设置展开开关（默认收起；编辑回填时若有任一高级项已启用则展开）
    @State private var advancedEnabled = false
    @State private var isSubmitting = false

    /// 向导分页：0 域名（+备注） 1 申请配置 2 高级设置（原「其他选项」并入）
    @State private var wizardPage = 0
    private let wizardPageNames = [L10n.t("域名"), L10n.t("申请配置"), L10n.t("高级设置")]

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
            // 向导流的提交移至底部导航（末页主操作）；自签编辑仍为单页工具栏提交
            if isSelfSignedEdit {
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
                OutlinedTextField(label: L10n.t("主域名"), text: $primaryDomain)
            } header: {
                Text(L10n.t("域名"))
            }

            Section {
                OutlinedMultiLineField(label: L10n.t("其他域名（一行一个）"), text: $otherDomains)
                    .lineLimit(3, reservesSpace: true)
            } header: {
                Text(L10n.t("其他域名"))
            }

            Section {
                InfoRow(L10n.t("密钥算法"), value: selectedKeyType.displayName)
                Toggle(L10n.t("自动续签"), isOn: $autoRenew)
            } header: {
                Text(L10n.t("配置"))
            }

            // 备注统一置底
            Section {
                OutlinedMultiLineField(label: L10n.t("备注"), prompt: L10n.t("可选"), text: $description_)
            }
        }
    }

    // MARK: - ACME 申请表单（分页向导：域名 → 申请配置 → 高级设置）

    private var acmeForm: some View {
        VStack(spacing: 0) {
            WizardStepsBar(pageNames: wizardPageNames, current: wizardPage)
            Form {
                Group {
                    switch wizardPage {
                    case 0:
                        domainSection
                        remarkSection
                    case 1:
                        applyConfigSection
                    default:
                        advancedSection
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WizardBottomBar(
                page: wizardPage,
                totalPages: wizardPageNames.count,
                primaryTitle: isEdit ? L10n.t("保存") : L10n.t("申请"),
                isBusy: isSubmitting,
                primaryDisabled: primaryDomain.trimmingCharacters(in: .whitespaces).isEmpty,
                onBack: { withAnimation { wizardPage -= 1 } },
                onNext: { withAnimation { wizardPage += 1 } },
                onPrimary: { Task { await submit() } }
            )
        }
        .animation(.easeInOut(duration: 0.22), value: wizardPage)
    }

    private var domainSection: some View {
        Section(L10n.t("域名")) {
            OutlinedTextField(label: L10n.t("主域名（必填）"), text: $primaryDomain)
            OutlinedMultiLineField(label: L10n.t("其他域名（可选，一行一个）"), text: $otherDomains)
                .lineLimit(3, reservesSpace: true)
        }
    }

    private var applyConfigSection: some View {
        Section(L10n.t("申请配置")) {
            OutlinedPicker(label: L10n.t("Acme 账户"),
                           options: acmeOptionKeys, selection: acmeBinding,
                           optionLabels: acmeOptionLabels)

            OutlinedPicker(label: L10n.t("密匙算法"), options: SSLKeyType.allCases,
                           selection: $selectedKeyType) { $0.displayName }

            OutlinedPicker(label: L10n.t("验证方式"), options: SSLProvider.allCases,
                           selection: $selectedProvider) { $0.displayName }

            if selectedProvider == .dnsAccount {
                OutlinedPicker(label: L10n.t("DNS 账户"),
                               options: dnsOptionKeys, selection: dnsBinding,
                               optionLabels: dnsOptionLabels)
            }

            Toggle(L10n.t("自动续签"), isOn: $autoRenew)
        }
    }

    /// 高级设置（原「其他选项」并入同一分组）：主开关默认收起，展开后可设置
    /// 禁用 CNAME / 跳过 DNS 校验 / DNS 服务器 / 推送到本地 / 执行脚本
    private var advancedSection: some View {
        Section {
            Toggle(L10n.t("启用高级选项"), isOn: $advancedEnabled)
            if advancedEnabled {
                Toggle(L10n.t("禁用 CNAME"), isOn: $disableCNAME)
                Toggle(L10n.t("跳过 DNS 校验"), isOn: $skipDNS)
                OutlinedTextField(label: L10n.t("DNS 服务器 1"), text: $nameserver1)
                OutlinedTextField(label: L10n.t("DNS 服务器 2"), text: $nameserver2)
                Toggle(L10n.t("推送证书到本地"), isOn: $pushDir)
                if pushDir {
                    OutlinedTextField(label: L10n.t("推送路径（如 /tmp）"), text: $dir)
                }
                Toggle(L10n.t("申请证书之后执行脚本"), isOn: $execShell)
                if execShell {
                    OutlinedMultiLineField(label: L10n.t("脚本内容"), text: $shell)
                        .lineLimit(5, reservesSpace: true)
                }
            }
        } header: {
            Text(L10n.t("高级设置"))
        } footer: {
            Text(L10n.t("禁用 CNAME：有 CNAME 配置的域名如果申请失败可以开启。跳过 DNS 校验：如果出现申请超时问题请开启，其他情况请勿开启。"))
        }
    }

    /// 备注统一置底
    private var remarkSection: some View {
        Section {
            OutlinedMultiLineField(label: L10n.t("备注"), prompt: L10n.t("可选"), text: $description_)
        }
    }

    // MARK: - 账户选项（OutlinedPicker 用 String 键）

    private var acmeOptionKeys: [String] { acmeAccounts.map { String($0.id) } }
    private var acmeOptionLabels: [String: String] {
        Dictionary(uniqueKeysWithValues: acmeAccounts.map {
            (String($0.id), "\($0.email) (\(AcmeType(rawValue: $0.type)?.displayName ?? $0.type))")
        })
    }

    private var acmeBinding: Binding<String> {
        Binding<String>(
            get: { String(selectedAcmeId) },
            set: { selectedAcmeId = Int($0) ?? selectedAcmeId }
        )
    }

    private var dnsOptionKeys: [String] { dnsAccounts.map { String($0.id) } }
    private var dnsOptionLabels: [String: String] {
        Dictionary(uniqueKeysWithValues: dnsAccounts.map {
            (String($0.id), "\($0.name) (\(DnsType(rawValue: $0.type)?.displayName ?? $0.type))")
        })
    }

    private var dnsBinding: Binding<String> {
        Binding<String>(
            get: { String(selectedDnsId) },
            set: { selectedDnsId = Int($0) ?? selectedDnsId }
        )
    }

    // MARK: - 数据加载

    private func loadAccounts() async {
        do {
            async let acme = vm.loadAcmeAccounts()
            async let dns = vm.loadDnsAccounts()
            let (acmeList, dnsList) = try await (acme, dns)
            acmeAccounts = acmeList
            dnsAccounts = dnsList
            if selectedAcmeId == 0, let first = acmeList.first { selectedAcmeId = first.id }
            if selectedDnsId == 0, let first = dnsList.first { selectedDnsId = first.id }
        } catch {
            // 表单仍可用，仅提示账户加载失败（沿用原行为）
            vm.showAlert(message: L10n.f("加载失败：%@", error.localizedDescription))
        }
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
        // 任一高级项已启用时回填展开高级设置开关
        advancedEnabled = disableCNAME || skipDNS
            || !nameserver1.isEmpty || !nameserver2.isEmpty
            || pushDir || execShell
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
