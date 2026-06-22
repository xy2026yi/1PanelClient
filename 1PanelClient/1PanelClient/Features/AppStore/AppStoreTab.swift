//
//  AppStoreTab.swift
//  1PanelClient
//
//  应用商店：搜索应用、查看详情、安装应用、忽略升级
//

import SwiftUI
import Combine

struct AppStoreTab: View {
    @ObservedObject var manager: ServerManager
    @StateObject private var vm: AppStoreViewModel
    @State private var searchText = ""

    init(manager: ServerManager) {
        self.manager = manager
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: AppStoreViewModel(server: server))
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.apps.isEmpty {
                    ProgressView("加载中…")
                } else if vm.apps.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    appList
                }
            }
            .navigationTitle("应用商店")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "搜索应用名")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await vm.refresh() }
                    } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .onChange(of: searchText) { _, newValue in
                Task { await vm.search(query: newValue) }
            }
            .navigationDestination(for: AppStoreApp.self) { app in
                AppStoreDetailView(appKey: app.key ?? "", vm: vm)
            }
            .alert("提示", isPresented: $vm.showAlert) {
                Button("好的", role: .cancel) {}
            } message: {
                Text(vm.alertMessage)
            }
        }
        .task { await vm.refresh() }
    }

    private var appList: some View {
        List {
            // 推荐区
            let recommended = vm.apps.filter { ($0.recommend ?? 0) > 0 }
            if !recommended.isEmpty {
                Section {
                    ForEach(recommended) { app in
                        NavigationLink(value: app) {
                            AppStoreRow(app: app, highlightRecommend: true)
                        }
                    }
                } header: {
                    Label("推荐", systemImage: "star.fill")
                }
            }

            // 全部应用
            Section {
                ForEach(vm.apps.filter { ($0.recommend ?? 0) == 0 }) { app in
                    NavigationLink(value: app) {
                        AppStoreRow(app: app, highlightRecommend: false)
                    }
                }
            } header: {
                Label("全部应用", systemImage: "square.grid.2x2")
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - 应用商店详情页

struct AppStoreDetailView: View {
    let appKey: String
    @ObservedObject var vm: AppStoreViewModel
    @State private var detail: AppStoreDetail?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("加载详情…")
            } else if let detail {
                detailContent(detail)
            } else {
                ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle(detail?.name ?? "应用详情")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadDetail() }
    }

    @ViewBuilder
    private func detailContent(_ detail: AppStoreDetail) -> some View {
        List {
            // 概览
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "app.dashed")
                            .font(.largeTitle)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(detail.name ?? "")
                                .font(.title3.bold())
                            Text(detail.type ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if detail.installed == true {
                            Text("已安装")
                                .font(.caption2.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.green.opacity(0.15))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        }
                    }

                    if let desc = detail.shortDescZh ?? detail.shortDescEn, !desc.isEmpty {
                        Text(desc)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            // 可用版本
            if let versions = detail.versions, !versions.isEmpty {
                Section {
                    ForEach(versions, id: \.self) { version in
                        HStack {
                            Image(systemName: "tag")
                                .foregroundStyle(.tint)
                            Text(version)
                                .font(.subheadline.monospaced())
                            if version == detail.latestVersion {
                                Spacer()
                                Text("最新")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.15))
                                    .foregroundStyle(.blue)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                } header: {
                    Text("可用版本（\(versions.count)）")
                }
            }

            // 描述
            if let readme = detail.readMe, !readme.isEmpty {
                Section("介绍") {
                    Text(readme)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // 标签
            if let tags = detail.tags, !tags.isEmpty {
                Section("标签") {
                    FlowingTags(tags: tags.compactMap { $0.name })
                }
            }

            // 相关链接
            let hasLinks = (detail.website != nil && !(detail.website?.isEmpty ?? true)) ||
                          (detail.document != nil && !(detail.document?.isEmpty ?? true)) ||
                          (detail.github != nil && !(detail.github?.isEmpty ?? true))
            if hasLinks {
                Section("相关链接") {
                    if let website = detail.website, let url = URL(string: website) {
                        Link(destination: url) { Label("官方网站", systemImage: "globe") }
                    }
                    if let doc = detail.document, let url = URL(string: doc) {
                        Link(destination: url) { Label("文档", systemImage: "book") }
                    }
                    if let github = detail.github, let url = URL(string: github) {
                        Link(destination: url) { Label("GitHub", systemImage: "network") }
                    }
                }
            }

            // 安装按钮
            if detail.installed != true {
                Section {
                    Button {
                        vm.showInstallSheet(for: detail)
                    } label: {
                        HStack {
                            Spacer()
                            Label("安装此应用", systemImage: "square.and.arrow.down")
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }
            } else {
                Section {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("此应用已安装")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .sheet(isPresented: $vm.showInstall) {
            if let installDetail = vm.installDetail {
                AppInstallView(detail: installDetail, vm: vm)
            }
        }
    }

    private func loadDetail() async {
        isLoading = true
        do {
            let path = APIEndpoint.appsStoreDetail.path.replacingOccurrences(of: ":key", with: appKey)
            let resp: AppStoreDetail = try await vm.client.send(
                path: path, method: "GET", as: AppStoreDetail.self
            )
            self.detail = resp
        } catch {
            self.detail = nil
        }
        isLoading = false
    }
}

// MARK: - 安装页（参数表单）

struct AppInstallView: View {
    let detail: AppStoreDetail
    @ObservedObject var vm: AppStoreViewModel
    @Environment(\.dismiss) private var dismiss

    // 基础
    @State private var installName = ""
    @State private var selectedVersion = ""
    @State private var loadError: String?
    @State private var appDetail: AppDetail?
    @State private var isLoadingDetail = true
    @State private var paramValues: [String: String] = [:]

    // 高级设置（默认值参考抓包日志）
    @State private var advancedEnabled = true
    @State private var containerName = ""
    @State private var allowPort = false
    @State private var restartPolicy = "always"
    @State private var cpuQuota = 0
    @State private var memoryLimit = 0
    @State private var memoryUnit = "M"
    @State private var pullImage = true
    @State private var editCompose = false
    @State private var customCompose = ""

    private let restartPolicies = ["no", "always", "on-failure", "unless-stopped"]
    private let memoryUnits = ["M", "G"]

    var body: some View {
        NavigationStack {
            Group {
                if isLoadingDetail {
                    ProgressView("加载安装参数…")
                } else if let appDetail {
                    installForm(appDetail)
                } else {
                    ContentUnavailableView {
                        Label("无法加载安装参数", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError ?? "请稍后重试，或尝试其他版本")
                    } actions: {
                        Button("重试") {
                            Task { await loadDetail() }
                        }
                    }
                }
            }
            .navigationTitle("安装 \(detail.name ?? "")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { vm.showInstall = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("安装") {
                        Task { await performInstall() }
                    }
                    .disabled(installName.isEmpty || vm.isInstalling)
                }
            }
            .task { await loadDetail() }
        }
    }

    @ViewBuilder
    private func installForm(_ appDetail: AppDetail) -> some View {
        List {
            // MARK: 基础配置
            Section {
                HStack {
                    Text("名称").foregroundStyle(.secondary)
                    TextField(detail.key ?? "app", text: $installName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if let versions = detail.versions, !versions.isEmpty {
                    Picker("版本", selection: $selectedVersion) {
                        ForEach(versions, id: \.self) { v in
                            Text(v).tag(v)
                        }
                    }
                    .onChange(of: selectedVersion) { _, newValue in
                        Task { await loadDetailForVersion(newValue) }
                    }
                }
            } header: {
                Text("基础配置")
            } footer: {
                Text("名称只能包含小写字母、数字和连字符")
            }

            // MARK: 应用参数（动态表单）
            if let fields = appDetail.params?.formFields, !fields.isEmpty {
                Section {
                    ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                        if let envKey = field.envKey {
                            ParamFieldRow(
                                field: field,
                                value: Binding(
                                    get: { paramValues[envKey] ?? "" },
                                    set: { paramValues[envKey] = $0 }
                                )
                            )
                        }
                    }
                } header: {
                    Text("应用参数")
                }
            }

            // MARK: 高级设置开关
            Section {
                Toggle("高级设置", isOn: $advancedEnabled)
            }

            // MARK: 高级设置详情
            if advancedEnabled {
                Section("容器") {
                    HStack {
                        Text("容器名称").foregroundStyle(.secondary)
                        TextField("留空则自动生成", text: $containerName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Toggle("端口外部访问", isOn: $allowPort)
                    Picker("重启规则", selection: $restartPolicy) {
                        ForEach(restartPolicies, id: \.self) { Text($0).tag($0) }
                    }
                }

                Section("资源限制") {
                    HStack {
                        Text("CPU 核心").foregroundStyle(.secondary)
                        Spacer()
                        TextField("0", value: $cpuQuota, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("核")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    HStack {
                        Text("内存限制").foregroundStyle(.secondary)
                        Spacer()
                        TextField("0", value: $memoryLimit, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Picker("", selection: $memoryUnit) {
                            ForEach(memoryUnits, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 80)
                    }
                } footer: {
                    Text("填 0 表示不限制")
                }

                Section("镜像与编排") {
                    Toggle("拉取镜像", isOn: $pullImage)
                    Toggle("编辑 docker-compose.yml", isOn: $editCompose)
                        .onChange(of: editCompose) { _, isOn in
                            if isOn && customCompose.isEmpty {
                                customCompose = appDetail.dockerCompose ?? ""
                            }
                        }
                }

                if editCompose {
                    Section {
                        TextEditor(text: $customCompose)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 200)
                    } header: {
                        Text("docker-compose.yml")
                    } footer: {
                        Text("编辑后将使用自定义内容覆盖默认编排文件")
                    }
                }
            }

            // MARK: 安装进度
            if vm.isInstalling {
                Section {
                    HStack {
                        ProgressView()
                        Text("正在安装…")
                    }
                }
            }
        }
    }

    private func loadDetail() async {
        isLoadingDetail = true
        loadError = nil
        let version = selectedVersion.isEmpty ? (detail.latestVersion ?? "") : selectedVersion
        await loadDetailForVersion(version)
        isLoadingDetail = false
    }

    private func loadDetailForVersion(_ version: String) async {
        guard !version.isEmpty else {
            loadError = "未找到可用版本"
            return
        }
        // type=app 用于安装新应用（通过 doc/1panel_install_new_app.py 验证）
        let path = "/api/v2/apps/detail/\(detail.id)/\(version)/app"
        do {
            let resp: AppDetail = try await vm.client.send(
                path: path, method: "GET", as: AppDetail.self
            )
            self.appDetail = resp
            if let fields = resp.params?.formFields {
                for f in fields {
                    if let key = f.envKey, let def = f.default {
                        paramValues[key] = def.stringValue
                    }
                }
            }
            // 初始化自定义 compose 为默认值
            if customCompose.isEmpty {
                customCompose = resp.dockerCompose ?? ""
            }
        } catch let err as APIError {
            loadError = err.errorDescription ?? "服务器返回错误，该应用可能尚未同步安装文件"
            self.appDetail = nil
        } catch {
            loadError = error.localizedDescription
            self.appDetail = nil
        }
    }

    private func performInstall() async {
        guard let appDetail = appDetail else { return }

        // 构建 params：保留原始类型（number → Int，text → String）
        var params: [String: AnyCodableValue] = [:]
        for (k, v) in paramValues {
            // 端口等数字参数保持 Int 类型
            if let intVal = Int(v) {
                params[k] = .int(intVal)
            } else {
                params[k] = .string(v)
            }
        }

        let compose = editCompose ? customCompose : (appDetail.dockerCompose ?? "")
        let req = AppInstallCreateRequest(
            appDetailId: appDetail.id,
            params: params,
            name: installName,
            advanced: advancedEnabled,
            cpuQuota: cpuQuota,
            memoryLimit: memoryLimit,
            memoryUnit: memoryUnit,
            containerName: containerName,
            allowPort: allowPort,
            editCompose: editCompose,
            dockerCompose: compose,
            version: selectedVersion.isEmpty ? (detail.latestVersion ?? "") : selectedVersion,
            appID: "",
            pullImage: pullImage,
            taskID: UUID().uuidString,
            gpuConfig: false,
            specifyIP: "",
            restartPolicy: restartPolicy
        )
        await vm.installApp(req: req)
        if vm.installSuccess {
            vm.showInstall = false
        }
    }
}

// MARK: - 参数表单字段行

struct ParamFieldRow: View {
    let field: AppFormField
    @Binding var value: String

    var body: some View {
        switch field.type ?? "text" {
        case "number":
            HStack {
                Text(field.displayLabel)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("", text: $value)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
            }
        case "select":
            Picker(field.displayLabel, selection: $value) {
                ForEach(field.values ?? [], id: \.self) { v in
                    Text(v).tag(v)
                }
            }
        default:
            HStack {
                Text(field.displayLabel)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("", text: $value)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

// MARK: - 应用商店列表行

struct AppStoreRow: View {
    let app: AppStoreApp
    var highlightRecommend: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 44, height: 44)
                Image(systemName: app.typeIcon)
                    .font(.title3)
                    .foregroundStyle(.blue)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(app.name ?? "")
                        .font(.body.bold())
                    if highlightRecommend {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }

                if let desc = app.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    Text(app.typeDisplayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())

                    if app.installed == true {
                        Text("已安装")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 流式标签布局

struct FlowingTags: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var width: CGFloat = 0
        var height: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth + size.width > maxWidth {
                width = max(width, lineWidth)
                height += lineHeight + spacing
                lineWidth = size.width + spacing
                lineHeight = size.height
            } else {
                lineWidth += size.width + spacing
                lineHeight = max(lineHeight, size.height)
            }
        }
        width = max(width, lineWidth)
        height += lineHeight
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - ViewModel

@MainActor
final class AppStoreViewModel: ObservableObject {
    @Published var apps: [AppStoreApp] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    // 安装相关
    @Published var showInstall = false
    @Published var installDetail: AppStoreDetail?
    @Published var isInstalling = false
    @Published var installSuccess = false

    // 提示
    @Published var showAlert = false
    @Published var alertMessage = ""

    let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    func refresh() async {
        await search(query: "")
    }

    func search(query: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let req = AppSearchRequest(
            name: query, page: 1, pageSize: 200,
            recommend: false, resource: "", showCurrentArch: false,
            tags: [], type: ""
        )
        do {
            let resp: AppSearchResponse = try await client.send(
                path: APIEndpoint.appsStoreSearch.path,
                body: req,
                as: AppSearchResponse.self
            )
            self.apps = resp.items ?? []
        } catch let err as APIError {
            self.errorMessage = err.errorDescription
            self.apps = []
        } catch {
            self.errorMessage = error.localizedDescription
            self.apps = []
        }
    }

    func showInstallSheet(for detail: AppStoreDetail) {
        installDetail = detail
        installSuccess = false
        showInstall = true
    }

    func installApp(req: AppInstallCreateRequest) async {
        isInstalling = true
        installSuccess = false
        defer { isInstalling = false }

        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstall.path,
                body: req,
                as: EmptyResponse.self
            )
            installSuccess = true
            showAlert(message: "安装请求已提交，应用正在后台部署中…")
        } catch let err as APIError {
            showAlert(message: "安装失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "安装失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 忽略升级

    func ignoreUpgrade(appID: Int, appDetailID: Int?, scope: String = "version") async {
        let req = AppIgnoreUpgradeRequest(
            appID: appID,
            scope: scope,
            appDetailID: scope == "version" ? appDetailID : nil
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledIgnore.path,
                body: req,
                as: EmptyResponse.self
            )
            showAlert(message: "已忽略该版本升级")
        } catch let err as APIError {
            showAlert(message: "操作失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "操作失败：\(error.localizedDescription)")
        }
    }

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }
}
