//
//  WebsitesTab.swift
//  1PanelClient
//

import SwiftUI
import Combine

struct WebsitesTab: View {
    @ObservedObject var manager: ServerManager
    @StateObject private var vm: WebsitesViewModel
    @State private var searchText = ""
    @State private var showCreateSheet = false

    init(manager: ServerManager) {
        self.manager = manager
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: WebsitesViewModel(server: server))
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.websites.isEmpty {
                    ProgressView("加载中…")
                } else if vm.websites.isEmpty {
                    ContentUnavailableView(
                        "暂无网站",
                        systemImage: "globe",
                        description: Text(vm.errorMessage ?? "点击右上角创建第一个网站")
                    )
                } else {
                    websiteList
                }
            }
            .navigationTitle("网站")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "搜索域名")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await vm.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .onChange(of: searchText) { _, newValue in
                Task { await vm.search(query: newValue) }
            }
            .navigationDestination(for: Website.self) { website in
                WebsiteDetailView(website: website, vm: vm)
            }
        }
        .task { await vm.refresh() }
        .alert(vm.alertMessage, isPresented: $vm.showAlert) {
            Button("好", role: .cancel) {}
        }
    }

    private var websiteList: some View {
        List {
            ForEach(vm.websites) { w in
                NavigationLink(value: w) {
                    WebsiteRow(website: w)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await vm.refresh()
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateWebsiteView(vm: vm)
        }
    }
}

// MARK: - 网站详情

struct WebsiteDetailView: View {
    let website: Website
    @ObservedObject var vm: WebsitesViewModel
    @State private var showDeleteAlert = false

    var body: some View {
        List {
            // 基本信息
            Section("基本信息") {
                LabeledRow("主域名", value: website.primaryDomain ?? "—")
                if let alias = website.alias, !alias.isEmpty {
                    LabeledRow("别名", value: alias)
                }
                LabeledRow("类型", value: website.typeDisplayName)
                if let protocolStr = website.protocolStr, !protocolStr.isEmpty {
                    LabeledRow("协议", value: protocolStr)
                }
                if let port = website.port, port > 0 {
                    LabeledRow("端口", value: "\(port)")
                }
            }

            // 反向代理信息
            if let proxy = website.proxy, !proxy.isEmpty {
                Section("反向代理") {
                    LabeledRow("代理地址", value: proxy)
                    if let addr = website.proxyAddress, !addr.isEmpty {
                        LabeledRow("目标地址", value: addr)
                    }
                }
            }

            // 状态
            Section("状态") {
                HStack {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(website.statusColor)
                        .font(.caption)
                    Text(website.status ?? "未知")
                        .foregroundStyle(website.statusColor)
                }
                if let remark = website.remark, !remark.isEmpty {
                    LabeledRow("备注", value: remark)
                }
                if let appName = website.appName, !appName.isEmpty {
                    LabeledRow("应用", value: appName)
                }
                if let runtime = website.runtimeName, !runtime.isEmpty {
                    LabeledRow("运行环境", value: runtime)
                }
                LabeledRow("创建时间", value: website.displayCreatedAt)
            }

            // 路径
            if let dir = website.siteDir, !dir.isEmpty {
                Section("路径") {
                    Text(dir)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            // 危险操作
            Section {
                Button(role: .destructive) {
                    showDeleteAlert = true
                } label: {
                    Label("删除网站", systemImage: "trash")
                }
            } header: {
                Text("危险操作")
            } footer: {
                Text("删除将移除网站配置及相关文件")
            }
        }
        .navigationTitle(website.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .alert("删除网站", isPresented: $showDeleteAlert) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task { await vm.deleteWebsite(id: website.id) }
            }
        } message: {
            Text("确定要删除 \(website.displayName) 吗？此操作不可撤销。")
        }
    }
}

// MARK: - 网站列表行

struct WebsiteRow: View {
    let website: Website

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(website.statusColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: website.typeIcon)
                    .font(.title3)
                    .foregroundStyle(website.statusColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(website.displayName)
                        .font(.body.bold())
                        .lineLimit(1)
                    if website.ssl == true {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }

                HStack(spacing: 6) {
                    Text(website.typeDisplayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())

                    if let app = website.appName, !app.isEmpty {
                        Text(app)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
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

    var body: some View {
        NavigationStack {
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

                Section("域名") {
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
                } footer: {
                    if !primaryDomain.isEmpty {
                        Text("预览：\(primaryDomain):\(port)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.blue)
                    }
                }

                // 类型特定字段
                if selectedType == .deployment {
                    deploymentSection
                } else {
                    proxySection
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
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
        }

        let ok = await vm.createWebsite(req: req)
        if ok {
            dismiss()
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

    private(set) var client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    func refresh() async {
        await load(query: "")
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

    /// 提交创建网站请求
    @discardableResult
    func createWebsite(req: WebsiteCreateRequest) async -> Bool {
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
            showAlert(message: "环境检查失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "环境检查失败：\(error.localizedDescription)")
            return false
        }

        // 提交创建
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.websitesCreate.path,
                body: req,
                as: EmptyResponse.self
            )
            showAlert(message: "网站创建请求已提交，正在后台配置…")
            try? await Task.sleep(for: .seconds(1))
            await load(query: "")
            return true
        } catch let err as APIError {
            showAlert(message: "创建失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "创建失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 删除网站

    func deleteWebsite(id: Int) async {
        // 注意：删除网站的接口暂未提供，这里先弹提示
        showAlert(message: "删除网站功能暂未接入（待后端接口确认）")
    }

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }
}
