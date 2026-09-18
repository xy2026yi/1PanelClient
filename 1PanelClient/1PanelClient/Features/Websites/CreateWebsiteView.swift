//
//  CreateWebsiteView.swift
//  1PanelClient
//

import SwiftUI

// MARK: - 创建网站

struct CreateWebsiteView: View {
    @ObservedObject var vm: WebsitesViewModel
    @Environment(\.dismiss) private var dismiss

    /// 由 + 号弹窗预选的类型（向导内不再切换）
    let initialType: WebsiteType
    @State private var selectedType: WebsiteType = .deployment
    @State private var primaryDomain = ""
    @State private var port: Int = 80
    @State private var remark = ""
    // 代号：主域名填入后自动带入（去端口），可手动修改
    @State private var alias = ""
    @State private var lastAutoAlias = ""
    // 其他域名：换行输入，提交时并入 domains 数组
    @State private var otherDomains = ""
    // 监听 IPv6
    @State private var enableIPv6 = false

    // 一键部署专用
    @State private var selectedAppInstallId: Int? = nil

    // 反向代理专用
    @State private var proxyProtocol = "http://"
    @State private var proxyAddress = ""

    // SSL
    @State private var enableSSL = false
    @State private var selectedSSLId: Int? = nil

    // 分组（0 = 未初始化，task 加载后回落默认分组）
    @State private var selectedGroupID = 0

    // 本地反馈
    @State private var showLocalAlert = false
    @State private var localAlertMessage: String?
    @State private var didCreateSucceed = false

    init(vm: WebsitesViewModel, initialType: WebsiteType = .deployment) {
        self.vm = vm
        self.initialType = initialType
        _selectedType = State(initialValue: initialType)
    }

    /// 向导分页：0 基础（类型/域名） 1 配置（类型特定 + HTTPS）
    @State private var wizardPage = 0
    private let wizardPageNames = [L10n.t("基础"), L10n.t("配置")]

    var body: some View {
        VStack(spacing: 0) {
            WizardStepsBar(pageNames: wizardPageNames, current: wizardPage)
            Form {
                Group {
                    switch wizardPage {
                    case 0:
                        domainSection
                    default:
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

                        Section {
                            OutlinedMultiLineField(label: L10n.t("备注"), prompt: L10n.t("可选"),
                                                   text: $remark)
                        }
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
                primaryTitle: L10n.t("创建"),
                isBusy: vm.isCreating,
                primaryDisabled: wizardPage == 0 ? !basicPageReady : !canSubmit,
                onBack: { withAnimation { wizardPage -= 1 } },
                onNext: { withAnimation { wizardPage += 1 } },
                onPrimary: { Task { await performCreate() } }
            )
        }
        .animation(.easeInOut(duration: 0.22), value: wizardPage)
        .navigationTitle(L10n.t("创建网站"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .task {
            await vm.loadCreateData(type: selectedType)
            if selectedGroupID == 0 { selectedGroupID = vm.defaultGroupID }
        }
        .onChange(of: primaryDomain) { _, newDomain in
            // 主域名填入后自动带入代号（去端口/路径）；用户手动改过则不再跟随
            let derived = newDomain.split(separator: ":").first.map(String.init) ?? newDomain
            if alias.isEmpty || alias == lastAutoAlias {
                alias = derived
            }
            lastAutoAlias = derived
        }
        .onChange(of: selectedType) { _, newType in
            Task { await vm.loadCreateData(type: newType) }
        }
        .onChange(of: vm.groups) { _, _ in
            // 分组数据晚于表单出现时回落默认分组（重命名默认组后 tag 找回）
            if selectedGroupID == 0 || !vm.groups.contains(where: { $0.id == selectedGroupID }) {
                selectedGroupID = vm.defaultGroupID
            }
        }
            .alert(L10n.t("提示"), isPresented: $showLocalAlert) {
                Button(L10n.t("好的"), role: .cancel) {
                    if didCreateSucceed {
                        dismiss()
                    }
                }
            } message: {
                Text(localAlertMessage ?? "")
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

    /// 反向代理后端
    @ViewBuilder
    private var proxySection: some View {
        Section {
            OutlinedPicker(label: L10n.t("协议"), options: ["http://", "https://"],
                           selection: $proxyProtocol)
            OutlinedTextField(label: L10n.t("后端代理地址"), prompt: "host:port",
                              text: $proxyAddress, keyboardType: .URL)
        } header: {
            Text(L10n.t("后端代理"))
        } footer: {
            if !proxyAddress.isEmpty {
                Text(L10n.f("后端代理地址：%@%@", proxyProtocol, proxyAddress))
                    .font(.caption.monospaced())
                    .foregroundStyle(.blue)
            }
        }
    }

    // MARK: - 域名区（向导第 1 页）

    private var domainSection: some View {
        Section {
            // 分组置顶（未加载到分组数据时仅展示默认分组占位）
            if vm.groups.isEmpty {
                HStack {
                    Text(L10n.t("分组"))
                    Spacer()
                    Text(L10n.t("默认分组"))
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker(L10n.t("分组"), selection: $selectedGroupID) {
                    // tag(0) 兜底：分组数据先于初值就绪的一帧内 selection 仍为 0，
                    // 缺少对应 tag 会触发 Picker invalid selection 运行时警告
                    Text(L10n.t("默认分组")).tag(0)
                    ForEach(vm.groups) { group in
                        Text(group.displayName).tag(group.id)
                    }
                }
            }

            OutlinedTextField(label: L10n.t("主域名"),
                              text: $primaryDomain, keyboardType: .URL,
                              hint: L10n.t("例: example.com 或 example.com:8080"))
            OutlinedMultiLineField(label: L10n.t("其他域名"),
                                   prompt: "abc.test.com\nabc1.test.com:8080",
                                   text: $otherDomains)
            OutlinedTextField(label: L10n.t("端口"), text: portBinding, keyboardType: .numberPad)
            Toggle(L10n.t("监听 IPv6"), isOn: $enableIPv6)
            OutlinedTextField(label: L10n.t("代号"),
                              text: $alias,
                              hint: L10n.t("对应主目录: /opt/1panel/apps/openresty/openresty/www/sites"))
        } header: {
            Text(L10n.t("域名"))
        } footer: {
            if !primaryDomain.isEmpty {
                Text(L10n.f("预览：%@:%ld", primaryDomain, port))
                    .font(.caption.monospaced())
                    .foregroundStyle(.blue)
            }
        }
    }

    /// 第 0 页（基础）必填：主域名非空无空格 + 端口合法；类型特定字段在第 2 页校验
    private var basicPageReady: Bool {
        !primaryDomain.isEmpty && !primaryDomain.contains(" ")
            && port > 0 && port < 65536
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

    /// 端口 String ↔ Int 双向绑定（FormTextField 只接收 String；非法输入回落 0，由 canSubmit 拦截）
    private var portBinding: Binding<String> {
        Binding<String>(
            get: { String(port) },
            set: { port = Int($0) ?? 0 }
        )
    }

    private func performCreate() async {
        var req = WebsiteCreateRequest()
        req.type = selectedType.rawValue
        // 代号：默认由主域名带入，允许手改；为空时回落主域名（去端口）
        req.alias = alias.isEmpty
            ? (primaryDomain.split(separator: ":").first.map(String.init) ?? primaryDomain)
            : alias
        req.primaryDomain = ""
        req.remark = remark
        req.IPV6 = enableIPv6
        // 分组（0 = 未选中，回落默认分组）
        req.webSiteGroupId = selectedGroupID != 0 ? selectedGroupID : vm.defaultGroupID
        req.enableSSL = enableSSL
        req.websiteSSLID = selectedSSLId ?? 0
        req.taskID = UUID().uuidString
        // 端口：HTTPS 启用时端口字段常被设为 443/自定义；未启用时默认 80
        req.port = port
        // domains 数组必须包含 {domain, host, port, ssl} —— 关键字段。
        // 其他域名按行并入（与网页端一致，otherDomains 字段本身留空），
        // 每行可带 :端口，未带时沿用主域名端口
        var domainBodies = [WebsiteDomainBody(
            domain: primaryDomain,
            host: primaryDomain,
            port: port,
            ssl: enableSSL
        )]
        for rawLine in otherDomains.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var host = line
            var linePort = port
            if let colon = line.lastIndex(of: ":"), let parsed = Int(line[line.index(after: colon)...]),
               parsed > 0, parsed < 65536 {
                host = String(line[..<colon])
                linePort = parsed
            }
            domainBodies.append(WebsiteDomainBody(domain: host, host: host, port: linePort, ssl: enableSSL))
        }
        req.domains = domainBodies

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

