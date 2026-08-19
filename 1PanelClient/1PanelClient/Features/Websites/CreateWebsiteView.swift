//
//  CreateWebsiteView.swift
//  1PanelClient
//

import SwiftUI

// MARK: - 创建网站

struct CreateWebsiteView: View {
    @ObservedObject var vm: WebsitesViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedType: WebsiteType = .deployment
    @State private var primaryDomain = ""
    @State private var port: Int = 80
    @State private var remark = ""

    // 一键部署专用
    @State private var selectedAppInstallId: Int? = nil

    // 反向代理专用
    @State private var proxyProtocol = "http://"
    @State private var proxyAddress = ""

    // SSL
    @State private var enableSSL = false
    @State private var selectedSSLId: Int? = nil

    // 本地反馈
    @State private var showLocalAlert = false
    @State private var localAlertMessage: String?
    @State private var didCreateSucceed = false

    var body: some View {
        Form {
            Section(L10n.t("类型")) {
                Picker(L10n.t("网站类型"), selection: $selectedType) {
                    ForEach(WebsiteType.allCases) { t in
                            Label(t.displayName, systemImage: t.icon).tag(t)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    Text(selectedType.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField(L10n.t("主域名"), text: $primaryDomain)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Text(L10n.t("端口"))
                        Spacer()
                        TextField(L10n.t("端口"), value: $port, format: .number)
                            .keyboardType(.numberPad)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                    TextField(L10n.t("备注（可选）"), text: $remark)
                } header: {
                    Text(L10n.t("域名"))
                } footer: {
                    if !primaryDomain.isEmpty {
                        Text(L10n.f("预览：%@:%ld", primaryDomain, port))
                            .font(.caption.monospaced())
                            .foregroundStyle(.blue)
                    }
                }

                // 类型特定字段
                switch selectedType {
                case .deployment:
                    deploymentSection
                case .proxy:
                    proxySection
                case .staticSite:
                    EmptyView()
                }

                // SSL
                Section {
                    Toggle(L10n.t("启用 HTTPS"), isOn: $enableSSL)
                    if enableSSL {
                        Picker(L10n.t("SSL 证书"), selection: $selectedSSLId) {
                            Text(L10n.t("请选择证书")).tag(nil as Int?)
                            ForEach(vm.availableSSLs) { ssl in
                                VStack(alignment: .leading) {
                                    Text(ssl.displayName)
                                    Text(L10n.f("有效期至 %@", ssl.displayExpireDate))
                                        .font(.caption2)
                                        .foregroundStyle(ssl.isExpired ? .red : .secondary)
                                }
                                .tag(ssl.id as Int?)
                            }
                        }
                    }
                } header: {
                    Text("HTTPS")
                }

                // 创建进度
                if vm.isCreating {
                    Section {
                        HStack {
                            ProgressView()
                            Text(L10n.t("创建中…"))
                        }
                    }
                }
            }
            .navigationTitle(L10n.t("创建网站"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("创建")) {
                        Task { await performCreate() }
                    }
                    .disabled(!canSubmit || vm.isCreating)
                }
            }
            .task {
                await vm.loadCreateData(type: selectedType)
            }
            .onChange(of: selectedType) { _, newType in
                Task { await vm.loadCreateData(type: newType) }
            }
            .alert(localAlertMessage ?? "", isPresented: $showLocalAlert) {
                Button(L10n.t("好")) {
                    if didCreateSucceed {
                        dismiss()
                    }
                }
            }
    }

    /// 一键部署的应用选择
    @ViewBuilder
    private var deploymentSection: some View {
        Section {
            if vm.isLoadingCreateData {
                HStack { ProgressView(); Text(L10n.t("加载应用列表…")) }
            } else if vm.availableApps.isEmpty {
                Text(L10n.t("暂无可用应用，请先在应用页面安装一个网站类应用（如 WordPress）"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker(L10n.t("选择应用"), selection: $selectedAppInstallId) {
                    Text(L10n.t("请选择")).tag(nil as Int?)
                    ForEach(vm.availableApps) { app in
                        Text("\(app.appName ?? app.name ?? "") (v\(app.version ?? ""))")
                            .tag(app.id as Int?)
                    }
                }
            }
        } header: {
            Text(L10n.t("应用"))
        } footer: {
            Text(L10n.t("仅显示类型为「网站」且未被使用的已安装应用"))
        }
    }

    /// 反向代理目标
    @ViewBuilder
    private var proxySection: some View {
        Section {
            Picker(L10n.t("协议"), selection: $proxyProtocol) {
                Text("http://").tag("http://")
                Text("https://").tag("https://")
            }
            TextField(L10n.t("目标地址"), text: $proxyAddress)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text(L10n.t("代理目标"))
        } footer: {
            if !proxyAddress.isEmpty {
                Text(L10n.f("代理地址：%@%@", proxyProtocol, proxyAddress))
                    .font(.caption.monospaced())
                    .foregroundStyle(.blue)
            }
        }
    }

    private var canSubmit: Bool {
        guard !primaryDomain.contains(" "), !primaryDomain.isEmpty,
              port > 0, port < 65536 else { return false }
        switch selectedType {
        case .deployment:
            return selectedAppInstallId != nil
        case .proxy:
            return !proxyAddress.isEmpty
        case .staticSite:
            return true
        }
    }

    private func performCreate() async {
        var req = WebsiteCreateRequest()
        req.type = selectedType.rawValue
        // alias 从主域名生成（去掉端口/路径）
        req.alias = primaryDomain.split(separator: ":").first.map(String.init) ?? primaryDomain
        req.primaryDomain = ""
        req.remark = remark
        req.enableSSL = enableSSL
        req.websiteSSLID = selectedSSLId ?? 0
        req.taskID = UUID().uuidString
        // 端口：HTTPS 启用时端口字段常被设为 443/自定义；未启用时默认 80
        req.port = port
        // domains 数组必须包含 {domain, host, port, ssl} —— 关键字段
        req.domains = [WebsiteDomainBody(
            domain: primaryDomain,
            host: primaryDomain,
            port: port,
            ssl: enableSSL
        )]

        switch selectedType {
        case .deployment:
            req.appInstallId = selectedAppInstallId ?? 0
        case .proxy:
            req.proxy = "\(proxyProtocol)\(proxyAddress)"
            req.proxyProtocol = proxyProtocol
            req.proxyAddress = proxyAddress
        case .staticSite:
            break
        }

        localAlertMessage = nil
        didCreateSucceed = false
        let result = await vm.createWebsite(req: req)
        if result.success {
            // 成功：直接返回列表，列表刷新即为反馈，不弹窗
            dismiss()
        } else {
            // 失败：弹窗显示错误，留在当前页
            localAlertMessage = result.message
            showLocalAlert = true
        }
    }
}

