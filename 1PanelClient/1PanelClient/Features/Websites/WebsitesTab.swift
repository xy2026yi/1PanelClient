//
//  WebsitesTab.swift
//  1PanelClient
//

import SwiftUI
import Combine

struct WebsitesTab: View {
    @ObservedObject var manager: ServerManager
    @StateObject private var vm: WebsitesViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var showCreateSheet = false
    @State private var showCerts = false

    /// 是否显示关闭按钮（fullScreen 模式用 true）
    var showCloseButton: Bool = true
    /// true=自带 NavigationStack；false=仅提供内容
    var standalone: Bool = true

    init(manager: ServerManager, showCloseButton: Bool = true, standalone: Bool = true) {
        self.manager = manager
        self.showCloseButton = showCloseButton
        self.standalone = standalone
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: WebsitesViewModel(server: server))
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
        .alert(vm.alertMessage, isPresented: $vm.showAlert) {
            Button("好", role: .cancel) {}
        }
        .task { await vm.refresh() }
    }

    /// 列表根内容（不含 NavigationStack）
    var rootContent: some View {
        Group {
            if vm.isLoading && vm.websites.isEmpty {
                ProgressView("加载中…")
            } else {
                websiteList
            }
        }
        .searchIconMode(
            text: $searchText,
            isSearching: $isSearching,
            title: "网站",
            prompt: "搜索域名",
            showCloseButton: showCloseButton,
            onClose: { dismiss() }
        )
        .toolbar {
            // SSL 证书入口：仅非搜索态显示
            if !isSearching {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCerts = true
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("SSL 证书")
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                showCreateSheet = true
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
            .accessibilityLabel("创建网站")
        }
        .onChange(of: searchText) { _, newValue in
            Task { await vm.search(query: newValue) }
        }
        .navigationDestination(for: Website.self) { website in
            WebsiteDetailView(website: website, vm: vm)
        }
        .navigationDestination(isPresented: $showCerts) {
            CertificatesTab(manager: manager, showCloseButton: false, standalone: false)
        }
        .navigationDestination(isPresented: $showCreateSheet) {
            CreateWebsiteView(vm: vm)
        }
    }

    private var websiteList: some View {
        List {
            // 顶部 OpenResty 信息与管理卡片
            OpenRestyCard(vm: vm, manager: manager)

            if vm.websites.isEmpty {
                if let err = vm.errorMessage, !err.isEmpty {
                    Section {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Text("点击右下角 + 创建第一个网站")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    ForEach(vm.websites) { w in
                        NavigationLink(value: w) {
                            WebsiteRow(website: w)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await vm.refresh()
        }
    }
}

// MARK: - OpenResty 信息与管理卡片

struct OpenRestyCard: View {
    @ObservedObject var vm: WebsitesViewModel
    @ObservedObject var manager: ServerManager
    @State private var isExpanded = false
    @State private var showConfigAlert = false
    @State private var pendingAction: String?

    init(vm: WebsitesViewModel, manager: ServerManager) {
        self.vm = vm
        self.manager = manager
    }

    var body: some View {
        Section {
            if vm.isLoadingOpenResty && vm.openresty == nil {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("加载 OpenResty 状态…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if let app = vm.openresty {
                headerRow(app)
                if isExpanded {
                    actionsRow(app)
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("OpenResty 未安装或加载失败")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .alert("配置", isPresented: $showConfigAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("OpenResty 配置编辑暂未开放")
        }
        .alert(
            pendingAction.map { openRestyActionDisplayName($0) } ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingAction = nil }
            Button("确认", role: .destructive) { executeOpenRestyAction() }
        } message: {
            if let action = pendingAction {
                Text("将对 OpenResty 进行 \(openRestyActionDisplayName(action)) 操作，是否继续？")
            }
        }
    }

    private func openRestyActionDisplayName(_ action: String) -> String {
        switch action {
        case "stop":    return "停止"
        case "start":   return "启动"
        case "restart": return "重启"
        case "reload":  return "重载"
        default:        return action
        }
    }

    private func executeOpenRestyAction() {
        let action = pendingAction
        pendingAction = nil
        guard let action else { return }
        let op: AppOperation
        switch action {
        case "stop":    op = .stop
        case "start":   op = .start
        case "restart": op = .restart
        case "reload":  op = .reload
        default:        return
        }
        Task { await vm.operateOpenResty(op: op) }
    }

    @ViewBuilder
    private func headerRow(_ app: AppInstall) -> some View {
        HStack(spacing: 12) {
            AppIconView(
                appID: app.appID,
                baseURL: manager.current?.baseURL ?? "",
                fallbackIcon: "globe",
                fallbackColor: app.statusColor,
                size: 40,
                cornerRadius: 10
            )
            VStack(alignment: .leading, spacing: 3) {
                Text("OpenResty")
                    .font(.body.bold())
                if let v = app.version, !v.isEmpty {
                    Text("v\(v)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                Circle()
                    .fill(app.statusColor)
                    .frame(width: 6, height: 6)
                Text(app.status ?? "未知")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(vm.openRestyOperating)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func actionsRow(_ app: AppInstall) -> some View {
        HStack(spacing: 8) {
            actionButton(
                title: app.isRunning ? "停止" : "启动",
                icon: app.isRunning ? "stop.fill" : "play.fill",
                color: app.isRunning ? .orange : .green
            ) {
                pendingAction = app.isRunning ? "stop" : "start"
            }
            actionButton(
                title: "重启",
                icon: "arrow.triangle.2.circlepath",
                color: .blue
            ) {
                pendingAction = "restart"
            }
            actionButton(
                title: "重载",
                icon: "arrow.clockwise",
                color: .teal
            ) {
                pendingAction = "reload"
            }
            actionButton(
                title: "配置",
                icon: "slider.horizontal.3",
                color: .purple
            ) {
                showConfigAlert = true
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func actionButton(
        title: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if vm.openRestyOperating {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(color)
                        .frame(width: 22, height: 22)
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(vm.openRestyOperating)
    }
}

// MARK: - 网站详情

struct WebsiteDetailView: View {
    let website: Website
    @ObservedObject var vm: WebsitesViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var detail: WebsiteFull?
    @State private var isLoadingDetail = false
    @State private var showDeleteSheet = false
    @State private var isOperating = false
    @State private var pendingToggle: Bool?

    var body: some View {
        List {
            if isLoadingDetail && detail == nil {
                Section { HStack { ProgressView(); Text("加载中…") } }
            } else if let d = detail {
                Section {
                    if let alias = d.alias, !alias.isEmpty {
                        LabeledRow("别名", value: alias)
                    }
                    HStack {
                        Text("状态").foregroundStyle(.secondary)
                        Spacer()
                        Text(d.status ?? "—")
                            .foregroundStyle(statusColor(d.status))
                    }
                    Toggle("操作", isOn: Binding(
                        get: { (d.status ?? "").lowercased() == "running" },
                        set: { newVal in
                            pendingToggle = newVal
                        }
                    ))
                    .disabled(isOperating)
                    if let port = d.primaryDomain, !port.isEmpty {
                        LabeledRow("主域名", value: port)
                    }
                    NavigationLink {
                        WebsiteHTTPSView(websiteId: website.id, vm: vm)
                    } label: {
                        HStack {
                            Text("HTTPS").foregroundStyle(.secondary)
                            Spacer()
                            if d.webSiteSSLId ?? 0 > 0 {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    LabeledRow("类型", value: d.type ?? website.typeDisplayName)
                    NavigationLink {
                        WebsiteLogPage(websiteId: website.id, vm: vm)
                    } label: {
                        Text("日志").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    if let p = d.sitePath, !p.isEmpty {
                        LabeledRow("根目录", value: p)
                    }
                    if let created = d.createdAt, !created.isEmpty {
                        LabeledRow("创建时间", value: String(created.prefix(19)))
                    }
                }
            } else {
                Section {
                    LabeledRow("主域名", value: website.primaryDomain ?? "—")
                    LabeledRow("类型", value: website.typeDisplayName)
                }
            }
        }
        .navigationTitle(website.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink {
                        WebsiteProxiesView(websiteId: website.id, vm: vm)
                    } label: {
                        Label("反向代理", systemImage: "arrow.left.arrow.right")
                    }
                    NavigationLink {
                        WebsiteNginxView(websiteId: website.id, vm: vm)
                    } label: {
                        Label("配置文件", systemImage: "doc.text")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showDeleteSheet = true
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            await loadDetail()
        }
        .onReceive(vm.$deletedWebsiteId) { deletedId in
            if let deletedId = deletedId, deletedId == website.id {
                dismiss()
            }
        }
        .sheet(isPresented: $showDeleteSheet) {
            WebsiteDeleteSheet(website: website, vm: vm)
        }
        .alert(
            (pendingToggle == true) ? "启动" : "停止",
            isPresented: Binding(
                get: { pendingToggle != nil },
                set: { if !$0 { pendingToggle = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingToggle = nil }
            Button("确认", role: .destructive) {
                let target = pendingToggle
                pendingToggle = nil
                guard let target else { return }
                Task { await toggleStatus(current: detail?.status, to: target) }
            }
        } message: {
            Text("将对网站「\(website.displayName)」进行 \(pendingToggle == true ? "启动" : "停止") 操作，是否继续？")
        }
    }

    private func loadDetail() async {
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        detail = await vm.loadDetail(id: website.id)
    }

    private func statusColor(_ status: String?) -> Color {
        guard let s = status?.lowercased() else { return .secondary }
        return s == "running" ? .green : .orange
    }

    private func toggleStatus(current: String?, to running: Bool) async {
        isOperating = true
        let op = running ? "start" : "stop"
        let ok = await vm.operateWebsite(id: website.id, operate: op)
        if ok {
            try? await Task.sleep(for: .seconds(1))
            await loadDetail()
        }
        isOperating = false
    }
}

// MARK: - 网站列表行

struct WebsiteRow: View {
    let website: Website

    /// 上：主域名:端口；下：类型 [appName]；右：状态
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(domainLine)
                    .font(.body.bold())
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(website.typeDisplayName)
                    if let app = website.appName, !app.isEmpty {
                        Text("[\(app)]")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 4) {
                Circle()
                    .fill(website.statusColor)
                    .frame(width: 6, height: 6)
                Text(website.status ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    /// 域名:端口 组合显示
    private var domainLine: String {
        var line = website.displayName
        if let port = website.port, port > 0 {
            line += ":\(port)"
        }
        return line
    }
}

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
            Section("类型") {
                Picker("网站类型", selection: $selectedType) {
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
                    TextField("主域名", text: $primaryDomain)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Text("端口")
                        Spacer()
                        TextField("端口", value: $port, format: .number)
                            .keyboardType(.numberPad)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                    TextField("备注（可选）", text: $remark)
                } header: {
                    Text("域名")
                } footer: {
                    if !primaryDomain.isEmpty {
                        Text("预览：\(primaryDomain):\(port)")
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
                    Toggle("启用 HTTPS", isOn: $enableSSL)
                    if enableSSL {
                        Picker("SSL 证书", selection: $selectedSSLId) {
                            Text("请选择证书").tag(nil as Int?)
                            ForEach(vm.availableSSLs) { ssl in
                                VStack(alignment: .leading) {
                                    Text(ssl.displayName)
                                    Text("有效期至 \(ssl.displayExpireDate)")
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
                            Text("创建中…")
                        }
                    }
                }
            }
            .navigationTitle("创建网站")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("创建") {
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
                Button("好") {
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
                HStack { ProgressView(); Text("加载应用列表…") }
            } else if vm.availableApps.isEmpty {
                Text("暂无可用应用，请先在应用页面安装一个网站类应用（如 WordPress）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("选择应用", selection: $selectedAppInstallId) {
                    Text("请选择").tag(nil as Int?)
                    ForEach(vm.availableApps) { app in
                        Text("\(app.appName ?? app.name ?? "") (v\(app.version ?? ""))")
                            .tag(app.id as Int?)
                    }
                }
            }
        } header: {
            Text("应用")
        } footer: {
            Text("仅显示类型为「网站」且未被使用的已安装应用")
        }
    }

    /// 反向代理目标
    @ViewBuilder
    private var proxySection: some View {
        Section {
            Picker("协议", selection: $proxyProtocol) {
                Text("http://").tag("http://")
                Text("https://").tag("https://")
            }
            TextField("目标地址", text: $proxyAddress)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("代理目标")
        } footer: {
            if !proxyAddress.isEmpty {
                Text("代理地址：\(proxyProtocol)\(proxyAddress)")
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

// MARK: - ViewModel

@MainActor
final class WebsitesViewModel: ObservableObject {
    @Published var websites: [Website] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    // 创建网站相关
    @Published var isCreating = false
    @Published var isLoadingCreateData = false
    @Published var availableApps: [AppInstall] = []
    @Published var availableSSLs: [WebsiteSSL] = []

    // 提示
    @Published var showAlert = false
    @Published var alertMessage = ""

    /// 标记列表需要刷新（详情页操作后）
    @Published var needsRefresh = false
    @Published var deletedWebsiteId: Int?

    // OpenResty 应用状态
    @Published var openresty: AppInstall?
    @Published var isLoadingOpenResty = false
    @Published var openRestyOperating = false
    /// 是否已尝试加载过（避免 List 重绘时 .task 反复触发）
    private var openRestyLoaded = false

    private(set) var client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    func refresh() async {
        await load(query: "")
        await loadOpenResty(force: false)
    }

    func search(query: String) async {
        await load(query: query)
    }

    private func load(query: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let req = WebsiteSearchRequest(
            name: query,
            page: 1,
            pageSize: 20,
            orderBy: "favorite",
            order: "descending",
            websiteGroupId: 0,
            type: ""
        )
        do {
            let resp: WebsiteListResponse = try await client.send(
                path: APIEndpoint.websitesSearch.path,
                body: req,
                as: WebsiteListResponse.self
            )
            self.websites = resp.items ?? []
        } catch let err as APIError {
            self.errorMessage = err.errorDescription
            self.websites = []
        } catch {
            self.errorMessage = error.localizedDescription
            self.websites = []
        }
    }

    // MARK: - 创建网站

    /// 加载创建网站所需的公共数据（可用应用 + SSL 证书）
    func loadCreateData(type: WebsiteType) async {
        isLoadingCreateData = true
        defer { isLoadingCreateData = false }

        let appType: String
        switch type {
        case .deployment: appType = "website"
        case .proxy:      appType = "proxy"
        case .staticSite: appType = "static"
        }

        let appReq = WebsiteAppSearchRequest(
            type: appType, unused: true, all: true, page: 1, pageSize: 100
        )
        let sslReq = WebsiteSSLSearchRequest(acmeAccountID: "0")

        do {
            async let appsResp: AppInstalledListResponse = client.send(
                path: APIEndpoint.appsInstalledSearch.path,
                body: appReq,
                as: AppInstalledListResponse.self
            )
            async let sslsResp: [WebsiteSSL] = client.send(
                path: APIEndpoint.websitesSSLSearch.path,
                body: sslReq,
                as: [WebsiteSSL].self
            )
            let (apps, ssls) = try await (appsResp, sslsResp)
            self.availableApps = apps.items ?? []
            self.availableSSLs = ssls
        } catch {
            // 静默失败，让用户至少能填表
            self.availableApps = []
            self.availableSSLs = []
        }
    }

    /// 仅加载 SSL 证书列表（用于 HTTPS 配置页，不依赖应用搜索）
    func loadSSLCerts() async {
        let sslReq = WebsiteSSLSearchRequest(acmeAccountID: "0")
        do {
            let ssls: [WebsiteSSL] = try await client.send(
                path: APIEndpoint.websitesSSLSearch.path,
                body: sslReq,
                as: [WebsiteSSL].self
            )
            self.availableSSLs = ssls
        } catch {
            self.availableSSLs = []
        }
    }

    /// 提交创建网站请求
    @discardableResult
    func createWebsite(req: WebsiteCreateRequest) async -> (success: Bool, message: String) {
        isCreating = true
        defer { isCreating = false }

        // 先做环境检查（后端 data 为 null）
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesCheck.path,
                body: WebsiteCheckRequest(),
                as: EmptyResponse.self
            )
        } catch let err as APIError {
            return (false, "环境检查失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            return (false, "环境检查失败：\(error.localizedDescription)")
        }

        // 提交创建
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesCreate.path,
                body: req,
                as: EmptyResponse.self
            )
            try? await Task.sleep(for: .seconds(1))
            await load(query: "")
            return (true, "网站创建请求已提交，正在后台配置…")
        } catch let err as APIError {
            return (false, "创建失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            return (false, "创建失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 删除网站

    func deleteWebsite(id: Int, deleteApp: Bool, deleteBackup: Bool, forceDelete: Bool, deleteDB: Bool) async {
        let req = WebsiteDeleteRequest(
            id: id,
            deleteApp: deleteApp,
            deleteBackup: deleteBackup,
            forceDelete: forceDelete,
            deleteDB: deleteDB
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesDelete.path,
                body: req,
                as: EmptyResponse.self
            )
            deletedWebsiteId = id
            showAlert(message: "网站删除成功")
            try? await Task.sleep(for: .seconds(1))
            await load(query: "")
        } catch let err as APIError {
            showAlert(message: "删除失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "删除失败：\(error.localizedDescription)")
        }
    }

    // MARK: - OpenResty 状态

    /// 加载 OpenResty 应用信息
    /// - Parameter force: true 强制刷新（如操作后）；false 仅首次加载
    func loadOpenResty(force: Bool) async {
        if !force && openRestyLoaded { return }
        openRestyLoaded = true
        isLoadingOpenResty = true
        defer { isLoadingOpenResty = false }

        let req = AppInstalledSearchRequest(
            page: 1, pageSize: 100, name: "", type: "", tags: [],
            update: false, all: true, unused: false, sync: false
        )
        do {
            let resp: AppInstalledListResponse = try await client.send(
                path: APIEndpoint.appsInstalledSearch.path,
                body: req,
                as: AppInstalledListResponse.self
            )
            self.openresty = (resp.items ?? []).first { $0.appKey?.lowercased() == "openresty" }
        } catch {
            self.openresty = nil
        }
    }

    /// 操作 OpenResty（start/stop/restart/reload）
    func operateOpenResty(op: AppOperation) async {
        guard let app = openresty else { return }
        openRestyOperating = true
        defer { openRestyOperating = false }
        let req = AppInstalledOperateRequest(installId: app.id, operate: op.rawValue)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledOperate.path,
                body: req,
                as: EmptyResponse.self
            )
            try? await Task.sleep(for: .seconds(1))
            await loadOpenResty(force: true)
        } catch {
            showAlert(message: "\(op.displayName)失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 网站详情

    func loadDetail(id: Int) async -> WebsiteFull? {
        let path = APIEndpoint.websitesDetail.path
            .replacingOccurrences(of: ":id", with: String(id))
        do {
            return try await client.send(
                path: path,
                method: "GET",
                as: WebsiteFull.self
            )
        } catch let err as APIError {
            showAlert(message: "加载详情失败：\(err.errorDescription ?? "未知错误")")
            return nil
        } catch {
            showAlert(message: "加载详情失败：\(error.localizedDescription)")
            return nil
        }
    }

    func operateWebsite(id: Int, operate: String) async -> Bool {
        struct Req: Encodable { let id: Int; let operate: String }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesOperate.path,
                body: Req(id: id, operate: operate),
                as: EmptyResponse.self
            )
            return true
        } catch let err as APIError {
            showAlert(message: "操作失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "操作失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Nginx 配置

    func loadNginxConfig(id: Int) async -> WebsiteNginxConfig? {
        let path = APIEndpoint.websitesNginxConfig.path
            .replacingOccurrences(of: ":id", with: String(id))
        do {
            return try await client.send(
                path: path,
                method: "GET",
                as: WebsiteNginxConfig.self
            )
        } catch let err as APIError {
            showAlert(message: "加载配置失败：\(err.errorDescription ?? "未知错误")")
            return nil
        } catch {
            showAlert(message: "加载配置失败：\(error.localizedDescription)")
            return nil
        }
    }

    func updateNginxConfig(id: Int, content: String) async -> Bool {
        let req = WebsiteNginxUpdateRequest(id: id, content: content)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesNginxUpdate.path,
                body: req,
                as: EmptyResponse.self
            )
            showAlert(message: "配置已保存，OpenResty 正在重载…")
            return true
        } catch let err as APIError {
            showAlert(message: "保存失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "保存失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 网站日志

    func loadLog(websiteId: Int, name: String) async -> [String] {
        let req = WebsiteLogReadRequest(
            id: websiteId,
            type: "website",
            name: name,
            page: 1,
            pageSize: 500,
            latest: true
        )
        do {
            let resp: WebsiteLogResponse = try await client.send(
                path: APIEndpoint.websitesLogRead.path,
                body: req,
                as: WebsiteLogResponse.self
            )
            return resp.lines ?? []
        } catch let err as APIError {
            // 404 表示日志文件尚未产生，静默返回空数组
            if case .httpError(let code, _) = err, code == 404 {
                return []
            }
            return []
        } catch {
            return []
        }
    }

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }

    // MARK: - HTTPS 配置

    func loadHTTPSConfig(id: Int) async -> WebsiteHTTPS? {
        let path = APIEndpoint.websitesHTTPSRead.path
            .replacingOccurrences(of: ":id", with: String(id))
        do {
            return try await client.send(
                path: path,
                method: "GET",
                as: WebsiteHTTPS.self
            )
        } catch let err as APIError {
            showAlert(message: "加载 HTTPS 配置失败：\(err.errorDescription ?? "未知错误")")
            return nil
        } catch {
            showAlert(message: "加载 HTTPS 配置失败：\(error.localizedDescription)")
            return nil
        }
    }

    func updateHTTPSConfig(websiteId: Int, sslId: Int, req: WebsiteHTTPSUpdateRequest) async -> Bool {
        let path = APIEndpoint.websitesHTTPSUpdate.path
            .replacingOccurrences(of: ":id", with: String(websiteId))
        do {
            let _: EmptyResponse = try await client.send(
                path: path,
                body: req,
                as: EmptyResponse.self
            )
            showAlert(message: "HTTPS 配置已保存，正在重载 OpenResty…")
            return true
        } catch let err as APIError {
            showAlert(message: "保存失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "保存失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 反向代理路由

    func loadProxies(websiteId: Int) async -> [WebsiteProxy] {
        let req = WebsiteProxiesListRequest(id: websiteId)
        do {
            let resp: WebsiteProxiesResponse = try await client.send(
                path: APIEndpoint.websitesProxiesList.path,
                body: req,
                as: WebsiteProxiesResponse.self
            )
            return resp.proxies ?? []
        } catch let err as APIError {
            // 一键部署类网站的反向代理查询可能返回 data=null（code 200），
            // 此时按"空列表"处理，不弹错误窗，允许用户继续创建代理
            if case .businessError(200, _) = err {
                return []
            }
            // 其他错误静默处理（避免阻塞 UI），返回空列表
            return []
        } catch {
            return []
        }
    }

    func operateProxy(websiteId: Int, operate: WebsiteProxyOperate, req: WebsiteProxyUpdateRequest) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesProxiesUpdate.path,
                body: req,
                as: EmptyResponse.self
            )
            let action = operate == .create ? "创建" : operate == .edit ? "修改" : "删除"
            showAlert(message: "反向代理\(action)成功")
            return true
        } catch let err as APIError {
            showAlert(message: "操作失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "操作失败：\(error.localizedDescription)")
            return false
        }
    }

    func saveProxyFile(websiteId: Int, name: String, content: String) async -> Bool {
        let req = WebsiteProxyFileRequest(name: name, websiteID: websiteId, content: content)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesProxiesFile.path,
                body: req,
                as: EmptyResponse.self
            )
            showAlert(message: "源文已保存")
            return true
        } catch let err as APIError {
            showAlert(message: "保存失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "保存失败：\(error.localizedDescription)")
            return false
        }
    }
}

/// 反向代理列表响应包装（data 可能是 null 或数组）
private struct WebsiteProxiesResponse: Decodable {
    let proxies: [WebsiteProxy]?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let arr = try? container.decode([WebsiteProxy].self) {
            proxies = arr
        } else {
            proxies = nil
        }
    }
}

// MARK: - 日志类型

enum WebsiteLogType {
    case access, error

    var displayName: String {
        switch self {
        case .access: return "访问日志"
        case .error:  return "错误日志"
        }
    }

    var fileName: String {
        switch self {
        case .access: return "access.log"
        case .error:  return "error.log"
        }
    }

    var icon: String {
        switch self {
        case .access: return "list.bullet.rectangle"
        case .error:  return "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .access: return .blue
        case .error:  return .orange
        }
    }
}

// MARK: - 删除网站表单

struct WebsiteDeleteSheet: View {
    let website: Website
    @ObservedObject var vm: WebsitesViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var forceDelete = false
    @State private var deleteBackup = false
    @State private var deleteApp = false
    @State private var deleteDB = false
    @State private var isDeleting = false

    /// 是否为一键部署（关联应用）
    private var isDeployment: Bool {
        (website.type ?? "").lowercased() == "deployment"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("确定要删除 \(website.displayName) 吗？")
                            .bold()
                    }
                } footer: {
                    Text("删除操作不可撤销，请谨慎操作")
                }

                Section("删除选项") {
                    Toggle("强制删除", isOn: $forceDelete)
                    Toggle("删除备份", isOn: $deleteBackup)
                    if isDeployment {
                        Toggle("删除关联应用", isOn: $deleteApp)
                    }
                    Toggle("删除数据库", isOn: $deleteDB)
                }
            }
            .navigationTitle("删除网站")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("删除", role: .destructive) {
                        Task { await performDelete() }
                    }
                    .disabled(isDeleting)
                }
            }
        }
    }

    private func performDelete() async {
        isDeleting = true
        await vm.deleteWebsite(
            id: website.id,
            deleteApp: deleteApp,
            deleteBackup: deleteBackup,
            forceDelete: forceDelete,
            deleteDB: deleteDB
        )
        dismiss()
    }
}

// MARK: - Nginx 配置编辑

struct WebsiteNginxView: View {
    let websiteId: Int
    @ObservedObject var vm: WebsitesViewModel

    @State private var config: WebsiteNginxConfig?
    @State private var content: String = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var isEditing = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView("加载配置…")
            } else {
                configEditor
            }
        }
        .navigationTitle("配置文件")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() } else { Text("保存").bold() }
                    }
                    .disabled(isSaving)
                }
            }
        }
        .task {
            await load()
        }
    }

    private var configEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let cfg = config {
                    HStack {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                        Text(cfg.name ?? "nginx.conf")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal)
                }

                if isEditing {
                    TextEditor(text: $content)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 480)
                        .padding(8)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)
                        .padding(.horizontal)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(content)
                            .font(.system(size: 12, design: .monospaced))
                            .padding()
                            .textSelection(.enabled)
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                    .padding(.horizontal)
                }

                Button {
                    isEditing.toggle()
                    if !isEditing {
                        // 取消编辑时还原
                        content = config?.content ?? content
                    }
                } label: {
                    Label(isEditing ? "取消编辑" : "编辑配置", systemImage: isEditing ? "xmark" : "pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        config = await vm.loadNginxConfig(id: websiteId)
        content = config?.content ?? ""
    }

    private func save() async {
        isSaving = true
        let ok = await vm.updateNginxConfig(id: websiteId, content: content)
        isSaving = false
        if ok {
            isEditing = false
        }
    }
}

// MARK: - TLS 协议 Pills

struct FlowingTLSPills: View {
    @Binding var selected: Set<String>

    private let allProtocols: [(key: String, label: String)] = [
        ("TLSv1.3", "TLS 1.3"),
        ("TLSv1.2", "TLS 1.2"),
        ("TLSv1.1", "TLS 1.1"),
        ("TLSv1",   "TLS 1.0"),
    ]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(allProtocols, id: \.key) { p in
                let isEnabled = selected.contains(p.key)
                Button {
                    if isEnabled {
                        selected.remove(p.key)
                    } else {
                        selected.insert(p.key)
                    }
                } label: {
                    HStack(spacing: 3) {
                        if isEnabled {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                        }
                        Text(p.label)
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        isEnabled ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.1)
                    )
                    .foregroundStyle(isEnabled ? .blue : .secondary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - HTTPS 配置

struct WebsiteHTTPSView: View {
    let websiteId: Int
    @ObservedObject var vm: WebsitesViewModel

    @State private var config: WebsiteHTTPS?
    @State private var isLoading = false
    @State private var isSaving = false

    // 可编辑状态
    @State private var enable = false
    @State private var httpConfig = "HTTPToHTTPS"
    @State private var hsts = false
    @State private var hstsIncludeSubDomains = true
    @State private var http3 = false
    @State private var sslProtocol: Set<String> = ["TLSv1.3", "TLSv1.2"]
    @State private var algorithm = ""
    @State private var selectedSSLId = 0
    @State private var httpsPort = ""
    // 从响应里读取的当前证书 ID，保存时若用户未修改则用它
    @State private var originalSSLId = 0

    private let availableProtocols = ["TLSv1.3", "TLSv1.2", "TLSv1.1", "TLSv1"]
    private let availableHttpConfigs = [
        ("HTTPToHTTPS", "HTTP 自动跳转 HTTPS"),
        ("HTTPOnly",    "仅 HTTP"),
        ("HTTPSOnly",   "仅 HTTPS"),
    ]

    var body: some View {
        Group {
            if isLoading {
                ProgressView("加载 HTTPS 配置…")
            } else {
                editor
            }
        }
        .navigationTitle("HTTPS")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() } else { Text("保存").bold() }
                }
                .disabled(isSaving)
            }
        }
        .task {
            await load()
            await vm.loadSSLCerts()
            // 证书列表加载完成后选中当前证书
            selectedSSLId = originalSSLId
        }
    }

    private var editor: some View {
        Form {
            Section("基本") {
                Toggle("启用 HTTPS", isOn: $enable)
                if enable {
                    Picker("HTTP 配置", selection: $httpConfig) {
                        ForEach(availableHttpConfigs, id: \.0) { v in
                            Text(v.1).tag(v.0)
                        }
                    }
                    HStack {
                        Text("HTTPS 端口")
                        Spacer()
                        TextField("端口", text: $httpsPort)
                            .keyboardType(.numberPad)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            if enable {
                Section("SSL 证书") {
                    Picker("选择证书", selection: $selectedSSLId) {
                        ForEach(vm.availableSSLs) { ssl in
                            VStack(alignment: .leading) {
                                Text(ssl.displayName)
                                Text("有效期至 \(ssl.displayExpireDate)")
                                    .font(.caption2)
                                    .foregroundStyle(ssl.isExpired ? .red : .secondary)
                            }
                            .tag(ssl.id)
                        }
                    }
                }

                Section("支持的协议版本") {
                    FlowingTLSPills(selected: $sslProtocol)
                }

                Section("高级") {
                    Toggle("HTTP/3 (QUIC)", isOn: $http3)
                    Toggle("HSTS", isOn: $hsts)
                    if hsts {
                        Toggle("HSTS 包含子域名", isOn: $hstsIncludeSubDomains)
                    }
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let c = await vm.loadHTTPSConfig(id: websiteId) else { return }
        config = c
        enable = c.enable ?? false
        httpConfig = c.httpConfig ?? "HTTPToHTTPS"
        hsts = c.hsts ?? false
        hstsIncludeSubDomains = c.hstsIncludeSubDomains ?? true
        http3 = c.http3 ?? false
        sslProtocol = Set(c.sslProtocol ?? ["TLSv1.3", "TLSv1.2"])
        algorithm = c.algorithm ?? ""
        httpsPort = c.httpsPort ?? ""
        // 关键：保存响应里的当前证书 ID，保存时若用户未改证书则用它
        originalSSLId = c.currentSSLId
        // 默认显示当前使用证书
        selectedSSLId = c.currentSSLId
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let sslId = selectedSSLId == 0 ? originalSSLId : selectedSSLId
        let req = WebsiteHTTPSUpdateRequest(
            enable: enable,
            websiteId: websiteId,
            websiteSSLId: sslId,
            httpConfig: httpConfig,
            hsts: hsts,
            hstsIncludeSubDomains: hstsIncludeSubDomains,
            algorithm: algorithm,
            sslProtocol: Array(sslProtocol),
            httpsPort: httpsPort,
            http3: http3
        )
        _ = await vm.updateHTTPSConfig(websiteId: websiteId, sslId: sslId, req: req)
        await load()
    }
}

// MARK: - 反向代理路由

struct WebsiteProxiesView: View {
    let websiteId: Int
    @ObservedObject var vm: WebsitesViewModel

    @State private var proxies: [WebsiteProxy] = []
    @State private var isLoading = false
    @State private var showEditSheet = false
    @State private var editingProxy: WebsiteProxy?
    @State private var showSourceSheet = false
    @State private var sourceProxy: WebsiteProxy?

    var body: some View {
        Group {
            if isLoading && proxies.isEmpty {
                ProgressView("加载反向代理…")
            } else if proxies.isEmpty {
                ContentUnavailableView(
                    "暂无反向代理",
                    systemImage: "arrow.left.arrow.right",
                    description: Text("点击右上角创建第一个反向代理路由")
                )
            } else {
                list
            }
        }
        .navigationTitle("反向代理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingProxy = nil
                    showEditSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task {
            await load()
        }
        .navigationDestination(isPresented: $showEditSheet) {
            WebsiteProxyEditView(
                websiteId: websiteId,
                proxy: editingProxy,
                vm: vm
            ) {
                Task { await load() }
            }
        }
        .navigationDestination(isPresented: $showSourceSheet) {
            if let p = sourceProxy {
                WebsiteProxySourceView(websiteId: websiteId, proxy: p, vm: vm)
            }
        }
    }

    private var list: some View {
        List {
            ForEach(proxies) { p in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(p.displayName)
                            .font(.body.bold())
                        Spacer()
                        if p.enable == true {
                            Text("已启用")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.1))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        } else {
                            Text("已停用")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.gray.opacity(0.1))
                                .foregroundStyle(.secondary)
                                .clipShape(Capsule())
                        }
                    }
                    HStack {
                        Label(p.displayMatch, systemImage: "arrow.triangle.branch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(p.displayProxyPass)
                            .font(.caption.monospaced())
                            .foregroundStyle(.blue)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        Task { await deleteProxy(p) }
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        sourceProxy = p
                        showSourceSheet = true
                    } label: {
                        Label("源文", systemImage: "doc.text")
                    }
                    .tint(.blue)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    editingProxy = p
                    showEditSheet = true
                }
            }
        }
        .refreshable {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        proxies = await vm.loadProxies(websiteId: websiteId)
    }

    private func deleteProxy(_ p: WebsiteProxy) async {
        let req = WebsiteProxyUpdateRequest(
            id: websiteId,
            operate: WebsiteProxyOperate.delete.rawValue,
            enable: p.enable ?? true,
            name: p.name ?? "",
            match: p.match ?? "",
            proxyPass: p.proxyPass ?? "",
            content: p.content ?? "",
            filePath: p.filePath ?? "",
            proxyProtocol: "http://",
            proxyAddress: p.proxyPass ?? ""
        )
        let ok = await vm.operateProxy(websiteId: websiteId, operate: .delete, req: req)
        if ok {
            await load()
        }
    }
}

/// 反向代理创建/编辑
struct WebsiteProxyEditView: View {
    let websiteId: Int
    let proxy: WebsiteProxy?
    @ObservedObject var vm: WebsitesViewModel
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var match = "/"
    @State private var proxyProtocol = "http://"
    @State private var proxyAddress = ""
    @State private var enable = true
    @State private var isSaving = false

    private var isEdit: Bool { proxy != nil }

    var body: some View {
        Form {
            Section("路由") {
                TextField("名称", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("路径 (例如 /api)", text: $match)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                Picker("协议", selection: $proxyProtocol) {
                    Text("http://").tag("http://")
                    Text("https://").tag("https://")
                }
                TextField("目标地址 (host:port)", text: $proxyAddress)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("代理目标")
            } footer: {
                if !proxyAddress.isEmpty {
                    Text("完整地址：\(proxyProtocol)\(proxyAddress)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.blue)
                }
            }

            Section("状态") {
                Toggle("启用", isOn: $enable)
            }
        }
        .navigationTitle(isEdit ? "编辑代理" : "创建代理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEdit ? "保存" : "创建") {
                    Task { await save() }
                }
                .disabled(!canSubmit || isSaving)
            }
        }
        .onAppear(perform: fillFromProxy)
    }

    private var canSubmit: Bool {
        !name.isEmpty && !match.isEmpty && !proxyAddress.isEmpty
    }

    private func fillFromProxy() {
        guard let p = proxy else { return }
        name = p.name ?? ""
        match = p.match ?? "/"
        enable = p.enable ?? true
        let pass = p.proxyPass ?? ""
        if pass.hasPrefix("https://") {
            proxyProtocol = "https://"
            proxyAddress = String(pass.dropFirst("https://".count))
        } else if pass.hasPrefix("http://") {
            proxyProtocol = "http://"
            proxyAddress = String(pass.dropFirst("http://".count))
        } else {
            proxyAddress = pass
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let operate: WebsiteProxyOperate = isEdit ? .edit : .create
        let req = WebsiteProxyUpdateRequest(
            id: websiteId,
            operate: operate.rawValue,
            enable: enable,
            name: name,
            match: match,
            proxyPass: "\(proxyProtocol)\(proxyAddress)",
            proxyProtocol: proxyProtocol,
            proxyAddress: proxyAddress
        )
        let ok = await vm.operateProxy(websiteId: websiteId, operate: operate, req: req)
        if ok {
            onDone()
            dismiss()
        }
    }
}

/// 反向代理源文（修改 nginx 配置片段）
struct WebsiteProxySourceView: View {
    let websiteId: Int
    let proxy: WebsiteProxy
    @ObservedObject var vm: WebsitesViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var content = ""
    @State private var isSaving = false
    @State private var isEditing = false

    var body: some View {
        Group {
            ScrollView(.horizontal, showsIndicators: false) {
                if isEditing {
                    TextEditor(text: $content)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 480)
                        .padding(8)
                } else {
                    Text(content)
                        .font(.system(size: 12, design: .monospaced))
                        .padding()
                        .textSelection(.enabled)
                }
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(8)
            .padding()
        }
        .navigationTitle("源文：\(proxy.displayName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    Button {
                        isEditing.toggle()
                        if !isEditing {
                            content = proxy.content ?? content
                        }
                    } label: {
                        Label(isEditing ? "取消" : "编辑", systemImage: isEditing ? "xmark" : "pencil")
                    }
                    if isEditing {
                        Button {
                            Task { await save() }
                        } label: {
                            if isSaving { ProgressView() } else { Text("保存").bold() }
                        }
                        .disabled(isSaving)
                    }
                }
            }
        }
        .onAppear {
            content = proxy.content ?? ""
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await vm.saveProxyFile(
            websiteId: websiteId,
            name: proxy.name ?? "",
            content: content
        )
        if ok {
            isEditing = false
        }
    }
}

// MARK: - 网站日志（合并页）

struct WebsiteLogPage: View {
    let websiteId: Int
    @ObservedObject var vm: WebsitesViewModel

    @State private var selectedTab: WebsiteLogType = .access
    @State private var lines: [String] = []
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("访问日志").tag(WebsiteLogType.access)
                Text("错误日志").tag(WebsiteLogType.error)
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            if isLoading && lines.isEmpty {
                ProgressView("加载日志…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if lines.isEmpty {
                ContentUnavailableView(
                    "暂无日志",
                    systemImage: selectedTab.icon,
                    description: Text("暂未产生\(selectedTab.displayName)记录")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task { await load() }
        .onChange(of: selectedTab) { _, _ in
            Task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        lines = await vm.loadLog(websiteId: websiteId, name: selectedTab.fileName)
    }
}

// MARK: - 网站日志（单类型）

struct WebsiteLogView: View {
    let websiteId: Int
    let logType: WebsiteLogType
    @ObservedObject var vm: WebsitesViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var lines: [String] = []
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && lines.isEmpty {
                    ProgressView("加载日志…")
                } else if lines.isEmpty {
                    ContentUnavailableView(
                        "暂无日志",
                        systemImage: logType.icon,
                        description: Text("暂未产生\(logType.displayName)记录")
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding()
                    }
                    .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle(logType.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task {
                await load()
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        lines = await vm.loadLog(websiteId: websiteId, name: logType.fileName)
    }
}
