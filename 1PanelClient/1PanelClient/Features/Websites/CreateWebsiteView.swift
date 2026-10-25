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
    /// 端口从主域名解析：a.a.a:8080 → 8080；无后缀按 HTTPS 启用与否取 443/80
    private var port: Int {
        if let idx = primaryDomain.lastIndex(of: ":"),
           let parsed = Int(primaryDomain[primaryDomain.index(after: idx)...]),
           parsed > 0, parsed < 65536 {
            return parsed
        }
        return enableSSL ? 443 : 80
    }
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

    // 运行环境网站专用
    @State private var runtimeType = "php"
    @State private var selectedRuntimeID: Int? = nil
    // 创建数据库（运行环境网站；抓包 2026-10-25：dbHost 取所选服务 value）
    @State private var createDB = false
    @State private var dbType = "mysql"
    @State private var selectedDBService: String? = nil
    @State private var dbName = ""
    @State private var dbFormat = "utf8mb4"
    @State private var dbUser = ""
    @State private var dbPassword = ""
    @State private var lastAutoDBUser = ""

    // SSL
    @State private var enableSSL = false
    // FTP（静态网站；创建后随站点开通 FTP 访问）
    @State private var enableFtp = false
    @State private var ftpUser = ""
    @State private var ftpPassword = ""
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
                        case .runtime:
                            runtimeSection
                        case .staticSite:
                            EmptyView()
                        }

                        // 创建数据库（仅运行环境网站）
                        if selectedType == .runtime {
                            dbSection
                        }

                        // FTP（静态网站 / 运行环境网站，网页端两类均有）
                        if selectedType == .staticSite || selectedType == .runtime {
                            Section {
                                Toggle(L10n.t("创建 FTP"), isOn: $enableFtp)
                                if enableFtp {
                                    OutlinedTextField(label: L10n.t("FTP 账号"), text: $ftpUser)
                                    // 随机按钮内嵌描边框右侧（与密码访问一致）
                                    OutlinedShape(label: L10n.t("FTP 密码"), isFocused: false,
                                                  hasValue: !ftpPassword.isEmpty,
                                                  trailing: {
                                        Button {
                                            ftpPassword = Self.randomPassword()
                                        } label: {
                                            Image(systemName: "dice")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.borderless)
                                    }) {
                                        SecureField("", text: $ftpPassword)
                                            .textInputAutocapitalization(.never)
                                            .autocorrectionDisabled()
                                    }
                                }
                            } footer: {
                                Text(selectedType == .staticSite
                                     ? L10n.t("创建站点时同步开通 FTP，用于上传静态资源")
                                     : L10n.t("创建站点时同步开通 FTP"))
                            }
                        }

                        // SSL
                        Section {
                            Toggle(L10n.t("启用"), isOn: $enableSSL)
                            if enableSSL {
                                OutlinedPicker(label: L10n.t("SSL 证书"),
                                               options: sslOptionKeys, selection: sslText,
                                               optionLabels: sslOptionLabels)
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
            if selectedType == .runtime {
                await vm.loadRuntimeOptions(typeKey: runtimeType)
            }
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
        .onChange(of: runtimeType) { _, newKey in
            // 切类型重查运行环境，已选失效
            selectedRuntimeID = nil
            Task { await vm.loadRuntimeOptions(typeKey: newKey) }
        }
        .onChange(of: createDB) { _, on in
            guard on else { return }
            if dbPassword.isEmpty { dbPassword = Self.randomPassword() }
            if dbName.isEmpty {
                // 名称缺省由代号带入（php.test.com → php-test），用户名跟随名称
                dbName = alias.replacingOccurrences(of: ".", with: "-")
            }
            if vm.availableDBServices.isEmpty {
                Task { await vm.loadDBServices(dbType: dbType) }
            }
        }
        .onChange(of: dbType) { _, newDBType in
            selectedDBService = nil
            if createDB {
                Task { await vm.loadDBServices(dbType: newDBType) }
            }
        }
        .onChange(of: dbName) { _, newName in
            // 用户名跟随名称（手动改过则不再跟随）
            if dbUser.isEmpty || dbUser == lastAutoDBUser {
                dbUser = newName
            }
            lastAutoDBUser = newName
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
                OutlinedPicker(label: L10n.t("选择应用"),
                               options: appOptionKeys, selection: appText,
                               optionLabels: appOptionLabels)
            }
        } header: {
            Text(L10n.t("应用"))
        } footer: {
            Text(L10n.t("仅显示类型为「网站」且未被使用的已安装应用"))
        }
    }

    // MARK: - 部署应用选项（OutlinedPicker 用 String 键；0=请选择）

    private var appOptionKeys: [String] {
        ["0"] + vm.availableApps.map { String($0.id) }
    }

    private var appOptionLabels: [String: String] {
        var labels = ["0": L10n.t("请选择")]
        for app in vm.availableApps {
            labels[String(app.id)] = "\(app.appName ?? app.name ?? "") (v\(app.version ?? ""))"
        }
        return labels
    }

    private var appText: Binding<String> {
        Binding<String>(
            get: { selectedAppInstallId.map(String.init) ?? "0" },
            set: { selectedAppInstallId = $0 == "0" ? nil : Int($0) }
        )
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

    // MARK: - 运行环境网站（类型 + 运行环境 + 创建数据库）

    /// 运行环境类型（顺序对齐网页端：PHP、Node.js、Java、Go、Python、.NET；key 为 searchKey）
    private let runtimeTypeOptions: [(key: String, label: String)] = [
        ("php", "PHP"), ("node", "Node.js"), ("java", "Java"),
        ("go", "Go"), ("python", "Python"), ("dotnet", ".NET"),
    ]

    /// 数据库类型（key 为服务查询与 dbType 请求值）
    private let dbTypeOptions: [(key: String, label: String)] = [
        ("mysql", "MySQL"), ("mariadb", "MariaDB"), ("postgresql", "PostgreSQL"),
    ]

    /// 字符集（value 为 dbFormat 请求值；utf8 显示为 utf-8）
    private let dbFormatOptions: [(key: String, label: String)] = [
        ("utf8mb4", "utf8mb4"), ("utf8", "utf-8"), ("gbk", "gbk"), ("big5", "big5"),
    ]

    @ViewBuilder
    private var runtimeSection: some View {
        Section {
            OutlinedPicker(label: L10n.t("类型"),
                           options: runtimeTypeOptions.map(\.key),
                           selection: $runtimeType,
                           optionLabels: Dictionary(uniqueKeysWithValues:
                               runtimeTypeOptions.map { ($0.key, $0.label) }))
            if vm.isLoadingRuntimeOptions {
                HStack { ProgressView(); Text(L10n.t("加载运行环境…")) }
            } else if vm.availableRuntimes.isEmpty {
                Text(L10n.t("暂无运行中的运行环境，请先创建并启动"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                OutlinedPicker(label: L10n.t("运行环境"),
                               options: runtimeOptionKeys,
                               selection: runtimeText,
                               optionLabels: runtimeOptionLabels)
            }
        } header: {
            Text(L10n.t("运行环境"))
        } footer: {
            Text(L10n.t("仅显示运行中的运行环境，网站代理端口取其 HTTP 端口"))
        }
    }

    // 运行环境选项（OutlinedPicker 用 String 键；0=请选择）

    private var runtimeOptionKeys: [String] {
        ["0"] + vm.availableRuntimes.map { String($0.id) }
    }

    private var runtimeOptionLabels: [String: String] {
        var labels = ["0": L10n.t("请选择")]
        for entry in vm.availableRuntimes {
            labels[String(entry.id)] = entry.displayName
        }
        return labels
    }

    private var runtimeText: Binding<String> {
        Binding<String>(
            get: { selectedRuntimeID.map(String.init) ?? "0" },
            set: { selectedRuntimeID = $0 == "0" ? nil : Int($0) }
        )
    }

    /// 代理端口：所选运行环境的 HTTP 端口（抓包口径：PANEL_APP_PORT_HTTP → port → 80）
    private var runtimePort: Int {
        guard let entry = vm.availableRuntimes.first(where: { $0.id == selectedRuntimeID }) else {
            return 80
        }
        if let p = entry.params?["PANEL_APP_PORT_HTTP"],
           let v = p.intValue ?? Int(p.stringValue), v > 0 {
            return v
        }
        if let port = entry.port, let v = Int(port), v > 0 { return v }
        return 80
    }

    /// 创建数据库段（开启后展开类型/已安装库/名称/字符集/用户名/密码）
    @ViewBuilder
    private var dbSection: some View {
        Section {
            Toggle(L10n.t("创建数据库"), isOn: $createDB)
            if createDB {
                OutlinedPicker(label: L10n.t("数据库"),
                               options: dbTypeOptions.map(\.key),
                               selection: $dbType,
                               optionLabels: Dictionary(uniqueKeysWithValues:
                                   dbTypeOptions.map { ($0.key, $0.label) }))
                if vm.isLoadingDBServices {
                    HStack { ProgressView(); Text(L10n.t("加载数据库服务…")) }
                } else if vm.availableDBServices.isEmpty {
                    Text(L10n.t("暂无已安装的该类型数据库，请先安装对应数据库应用"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    OutlinedPicker(label: L10n.t("选择已安装数据库"),
                                   options: dbServiceKeys,
                                   selection: dbServiceText,
                                   optionLabels: dbServiceLabels)
                }
                OutlinedTextField(label: L10n.t("名称"), text: $dbName)
                OutlinedPicker(label: L10n.t("字符集"),
                               options: dbFormatOptions.map(\.key),
                               selection: $dbFormat,
                               optionLabels: Dictionary(uniqueKeysWithValues:
                                   dbFormatOptions.map { ($0.key, $0.label) }))
                OutlinedTextField(label: L10n.t("用户名"), text: $dbUser)
                // 随机按钮内嵌描边框右侧（与 FTP 密码一致）
                OutlinedShape(label: L10n.t("密码"), isFocused: false,
                              hasValue: !dbPassword.isEmpty,
                              trailing: {
                    Button {
                        dbPassword = Self.randomPassword()
                    } label: {
                        Image(systemName: "dice")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }) {
                    SecureField("", text: $dbPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
        } header: {
            Text(L10n.t("数据库"))
        } footer: {
            Text(L10n.t("创建站点时同步创建数据库，用户名缺省跟随名称"))
        }
    }

    // 已安装数据库服务选项（OutlinedPicker 用 String 键；0=请选择）

    private var dbServiceKeys: [String] {
        ["0"] + vm.availableDBServices.map { $0.value ?? $0.label ?? "" }.filter { !$0.isEmpty }
    }

    private var dbServiceLabels: [String: String] {
        var labels = ["0": L10n.t("请选择")]
        for svc in vm.availableDBServices {
            let value = svc.value ?? svc.label ?? ""
            guard !value.isEmpty else { continue }
            // 服务 value 理论唯一，uniquing 兜底防重复键崩溃
            labels[value] = svc.label ?? value
        }
        return labels
    }

    private var dbServiceText: Binding<String> {
        Binding<String>(
            get: { selectedDBService ?? "0" },
            set: { selectedDBService = $0 == "0" ? nil : $0 }
        )
    }

    // MARK: - 域名区（向导第 1 页）

    private var domainSection: some View {
        Section {
            // 分组置顶（未加载到分组数据时仅展示默认分组占位）
            WebsiteGroupPicker(selection: $selectedGroupID, groups: vm.groups)

            OutlinedTextField(label: L10n.t("主域名"),
                              text: $primaryDomain, keyboardType: .URL,
                              hint: L10n.t("例: example.com 或 example.com:8080"))
            OutlinedMultiLineField(label: L10n.t("其他域名"),
                                   prompt: "abc.test.com\nabc1.test.com:8080",
                                   text: $otherDomains)
            Toggle(L10n.t("监听 IPv6"), isOn: $enableIPv6)
            OutlinedTextField(label: L10n.t("代号"),
                              text: $alias,
                              hint: L10n.t("对应主目录: /opt/1panel/apps/openresty/openresty/www/sites"))
        } header: {
            Text(L10n.t("域名"))
        } footer: {
        }
    }

    // MARK: - SSL 证书选项（OutlinedPicker 用 String 键；0=请选择证书）

    private var sslOptionKeys: [String] {
        ["0"] + vm.availableSSLs.map { String($0.id) }
    }

    private var sslOptionLabels: [String: String] {
        var labels = ["0": L10n.t("请选择证书")]
        for ssl in vm.availableSSLs {
            labels[String(ssl.id)] = ssl.displayName
        }
        return labels
    }

    private var sslText: Binding<String> {
        Binding<String>(
            get: { selectedSSLId.map(String.init) ?? "0" },
            set: { selectedSSLId = $0 == "0" ? nil : Int($0) }
        )
    }

    /// 第 0 页（基础）必填：主域名非空无空格 + 端口合法；类型特定字段在第 2 页校验
    private var basicPageReady: Bool {
        guard !primaryDomain.isEmpty, !primaryDomain.contains(" ") else { return false }
        // 显式端口后缀（:8080）须为合法端口；无后缀恒通过（回落 80/443）
        if let idx = primaryDomain.lastIndex(of: ":") {
            let suffix = primaryDomain[primaryDomain.index(after: idx)...]
            if let parsed = Int(suffix) {
                return parsed > 0 && parsed < 65536
            }
        }
        return true
    }

    private var canSubmit: Bool {
        guard basicPageReady else { return false }
        switch selectedType {
        case .deployment:
            return selectedAppInstallId != nil
        case .proxy:
            return !proxyAddress.isEmpty
        case .runtime:
            guard selectedRuntimeID != nil else { return false }
            if createDB {
                guard !dbName.isEmpty && !dbUser.isEmpty && !dbPassword.isEmpty
                        && selectedDBService != nil else { return false }
            }
            if enableFtp {
                return !ftpUser.isEmpty && !ftpPassword.isEmpty
            }
            return true
        case .staticSite:
            if enableFtp {
                return !ftpUser.isEmpty && !ftpPassword.isEmpty
            }
            return true
        }
    }

    /// 16 位随机字母数字密码（FTP / 创建数据库共用）
    private static func randomPassword() -> String {
        let chars = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<16).map { _ in chars.randomElement() ?? "x" })
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
        // FTP：静态网站/运行环境网站均有（网页端同口径）
        let ftpEnabled = enableFtp && (selectedType == .staticSite || selectedType == .runtime)
        req.enableFtp = ftpEnabled
        req.ftpUser = ftpEnabled ? ftpUser : ""
        // FTP 密码按网页端口径 base64 编码后提交（抓包 eGg1NndYV1d0d2Y1UEdKYw== ← 16 位随机串）
        req.ftpPassword = ftpEnabled
            ? Data(ftpPassword.utf8).base64EncodedString()
            : ""
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
        case .runtime:
            // 运行环境网站：port 取所选环境的 HTTP 端口（与域名端口无关，抓包 9000 vs 443）
            req.runtimeID = selectedRuntimeID ?? 0
            req.runtimeType = runtimeType
            req.port = runtimePort
            req.createDb = createDB
            if createDB {
                req.dbName = dbName
                req.dbUser = dbUser
                req.dbPassword = dbPassword
                req.dbFormat = dbFormat
                req.dbType = dbType
                req.dbHost = selectedDBService ?? ""
            }
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

