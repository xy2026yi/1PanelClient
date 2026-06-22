//
//  AppsTab.swift
//  1PanelClient
//

import SwiftUI
import Combine

struct AppsTab: View {
    @ObservedObject var manager: ServerManager
    @StateObject private var vm: AppsViewModel
    @State private var searchText = ""

    init(manager: ServerManager) {
        self.manager = manager
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: AppsViewModel(server: server))
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.apps.isEmpty {
                    ProgressView("加载中…")
                } else if vm.apps.isEmpty {
                    ContentUnavailableView(
                        "暂无已安装应用",
                        systemImage: "shippingbox",
                        description: Text(vm.errorMessage ?? "这台服务器上没有已安装的应用")
                    )
                } else {
                    appList
                }
            }
            .navigationTitle("应用")
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
            .navigationDestination(for: AppInstall.self) { app in
                AppDetailView(app: app, vm: vm)
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
            if vm.updatableCount > 0 {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(vm.updatableCount) 个应用可更新")
                                .font(.subheadline.bold())
                            Text("点击应用进入详情查看升级选项")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                ForEach(vm.apps) { app in
                    NavigationLink(value: app) {
                        AppRow(
                            app: app,
                            isOperating: vm.operatingAppIds.contains(app.id)
                        )
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if app.isRunning {
                            Button {
                                Task { await vm.operate(app: app, op: .stop) }
                            } label: { Label("停止", systemImage: "stop.fill") }
                            .tint(.orange)
                        } else {
                            Button {
                                Task { await vm.operate(app: app, op: .start) }
                            } label: { Label("启动", systemImage: "play.fill") }
                            .tint(.green)
                        }
                        Button {
                            Task { await vm.operate(app: app, op: .restart) }
                        } label: { Label("重启", systemImage: "arrow.triangle.2.circlepath") }
                        .tint(.blue)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - 应用详情页

struct AppDetailView: View {
    let app: AppInstall
    @ObservedObject var vm: AppsViewModel

    var body: some View {
        List {
            // 基本信息
            Section("应用信息") {
                LabeledRow("名称", value: app.displayName)
                if let n = app.name, !n.isEmpty {
                    LabeledRow("内部名称", value: n)
                }
                if let key = app.appKey, !key.isEmpty {
                    LabeledRow("App Key", value: key)
                }
                if let v = app.version, !v.isEmpty {
                    LabeledRow("版本", value: "v\(v)")
                }
                if let port = app.httpPort, port > 0 {
                    LabeledRow("HTTP 端口", value: "\(port)")
                }
                if let ports = app.httpsPort, ports > 0 {
                    LabeledRow("HTTPS 端口", value: "\(ports)")
                }
                if let container = app.container, !container.isEmpty {
                    LabeledRow("容器名", value: container)
                }
                if let created = app.createdAt, !created.isEmpty {
                    LabeledRow("安装时间", value: String(created.prefix(19)))
                }
            }

            // 状态
            Section("状态") {
                HStack {
                    Image(systemName: app.statusIcon)
                        .foregroundStyle(app.statusColor)
                    Text((app.status ?? "未知").capitalized)
                        .foregroundStyle(app.statusColor)
                }
                if let msg = app.message, !msg.isEmpty {
                    LabeledRow("消息", value: msg)
                }
            }

            // 操作
            Section("操作") {
                if app.isRunning {
                    Button {
                        Task { await vm.operate(app: app, op: .stop) }
                    } label: {
                        Label("停止应用", systemImage: "stop.fill")
                    }
                } else {
                    Button {
                        Task { await vm.operate(app: app, op: .start) }
                    } label: {
                        Label("启动应用", systemImage: "play.fill")
                    }
                }
                Button {
                    Task { await vm.operate(app: app, op: .restart) }
                } label: {
                    Label("重启应用", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            // 升级（仅有新版本时显示）
            if app.canUpdate == true {
                Section {
                    Button {
                        Task { await vm.loadVersions(for: app) }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading) {
                                Text("检查更新")
                                    .foregroundStyle(.primary)
                                Text("查看可用的新版本")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)

                    Button(role: .destructive) {
                        Task { await vm.ignoreUpgrade(app: app) }
                    } label: {
                        Label("忽略所有升级", systemImage: "eye.slash")
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("升级")
                        Text("NEW")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2))
                            .clipShape(Capsule())
                            .foregroundStyle(.orange)
                    }
                }
            }

            // 相关链接
            if let links = app.app {
                Section("相关链接") {
                    if let website = links.website, let url = URL(string: website) {
                        Link("官方网站", destination: url)
                    }
                    if let doc = links.document, let url = URL(string: doc) {
                        Link("文档", destination: url)
                    }
                    if let github = links.github, let url = URL(string: github) {
                        Link("GitHub", destination: url)
                    }
                }
            }
        }
        .navigationTitle(app.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $vm.showUpgradeSheet) {
            UpgradeSheetView(app: app, vm: vm)
        }
        .onDisappear {
            // 返回列表时，如有待刷新（忽略升级/升级完成），重新加载
            if vm.needsRefresh {
                vm.needsRefresh = false
                Task { await vm.refresh() }
            }
        }
    }
}

struct LabeledRow: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

// MARK: - 升级版本选择 Sheet

struct UpgradeSheetView: View {
    let app: AppInstall
    @ObservedObject var vm: AppsViewModel
    @State private var showComposeEditor = false

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoadingVersions {
                    ProgressView("查询可用版本…")
                } else if vm.availableVersions.isEmpty {
                    ContentUnavailableView(
                        "无可用版本",
                        systemImage: "arrow.up.circle.slash",
                        description: Text("该应用暂无更高版本可供升级")
                    )
                } else {
                    versionList
                }
            }
            .navigationTitle("升级 \(app.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { vm.showUpgradeSheet = false }
                }
            }
            .navigationDestination(isPresented: $showComposeEditor) {
                if let version = vm.selectedVersion {
                    ComposeEditorView(
                        app: app,
                        version: version,
                        vm: vm,
                        onBack: { showComposeEditor = false }
                    )
                }
            }
        }
    }

    private var versionList: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("升级将替换 docker-compose.yml，如有自定义修改请查看对比")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("当前版本")
            }

            Section("可升级到") {
                ForEach(vm.availableVersions) { ver in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ver.version ?? "v\(ver.detailId)")
                                    .font(.body.bold())
                                Text("ID: \(ver.detailId)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if vm.upgradingVersionId == ver.detailId {
                                ProgressView()
                            }
                        }

                        HStack(spacing: 8) {
                            Button {
                                Task { await vm.confirmUpgrade(app: app, to: ver, customCompose: nil) }
                            } label: {
                                Label("直接升级", systemImage: "arrow.up.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .disabled(vm.upgradingVersionId != nil)

                            Button {
                                vm.selectedVersion = ver
                                showComposeEditor = true
                            } label: {
                                Label("对比/编辑", systemImage: "doc.text.magnifyingglass")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(vm.upgradingVersionId != nil)
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task { await vm.ignoreUpgrade(app: app, version: ver) }
                        } label: {
                            Label("忽略此版本", systemImage: "eye.slash")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Compose 文件对比/编辑页

struct ComposeEditorView: View {
    let app: AppInstall
    let version: AppVersion
    @ObservedObject var vm: AppsViewModel
    let onBack: () -> Void

    @State private var useCustom = false
    @State private var editedCompose = ""
    @State private var showDiff = true

    private var newCompose: String {
        version.dockerCompose ?? ""
    }

    private var oldCompose: String {
        app.currentDockerCompose ?? app.dockerCompose ?? ""
    }

    var body: some View {
        List {
            // 模式切换
            Section {
                Toggle(isOn: $useCustom) {
                    Label(useCustom ? "使用自定义配置" : "使用默认配置",
                          systemImage: useCustom ? "wand.and.stars" : "doc")
                }
                .tint(.orange)

                if useCustom {
                    Text("已启用自定义 docker-compose.yml，请仔细检查内容")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("配置模式")
            }

            // 操作按钮
            Section {
                Button {
                    Task {
                        let compose = useCustom ? editedCompose : nil
                        await vm.confirmUpgrade(app: app, to: version, customCompose: compose)
                        if vm.upgradeSuccess {
                            onBack()
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        Label(useCustom ? "使用自定义配置升级" : "使用默认配置升级",
                              systemImage: "arrow.up.circle.fill")
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(vm.upgradingVersionId != nil)

                if vm.upgradingVersionId != nil {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text("正在升级…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            // 当前版本（只读）
            Section {
                CodePreview(text: oldCompose, color: .secondary)
                    .frame(minHeight: 160)
            } header: {
                HStack {
                    Text("当前版本")
                    Spacer()
                    Text("v\(app.version ?? "?")")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            // 新版本（可编辑）
            Section {
                if useCustom {
                    TextEditor(text: $editedCompose)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 240)
                        .scrollContentBackground(.hidden)
                        .background(Color(.secondarySystemBackground))
                } else {
                    CodePreview(text: newCompose, color: .primary)
                        .frame(minHeight: 200)
                }
            } header: {
                HStack {
                    Text(useCustom ? "自定义配置（可编辑）" : "新版本")
                    Spacer()
                    Text("v\(version.version ?? "?")")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            // 重置自定义编辑
            if useCustom {
                Section {
                    Button(role: .destructive) {
                        editedCompose = newCompose
                    } label: {
                        Label("重置为新版本默认值", systemImage: "arrow.counterclockwise")
                    }
                }
            }
        }
        .navigationTitle("docker-compose.yml")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if editedCompose.isEmpty {
                editedCompose = newCompose
            }
        }
    }
}

/// 只读代码预览
struct CodePreview: View {
    let text: String
    let color: Color

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "(空)" : text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

// MARK: - 应用行

struct AppRow: View {
    let app: AppInstall
    var isOperating: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(app.statusColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                if isOperating {
                    ProgressView()
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: app.statusIcon)
                        .font(.title3)
                        .foregroundStyle(app.statusColor)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(app.displayName)
                        .font(.body.bold())
                        .lineLimit(1)

                    if let v = app.version, !v.isEmpty {
                        Text("v\(v)")
                            .font(.caption2.monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                            .foregroundStyle(.secondary)
                    }

                    if app.canUpdate == true {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.up.circle.fill")
                            Text("可更新")
                        }
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .clipShape(Capsule())
                        .foregroundStyle(.orange)
                    }
                }

                if let container = app.container, !container.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "cylinder")
                            .font(.caption2)
                        Text(container)
                            .lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text((app.status ?? "未知").capitalized)
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(app.statusColor.opacity(0.15))
                        .foregroundStyle(app.statusColor)
                        .clipShape(Capsule())

                    if let port = app.httpPort, port > 0 {
                        Label("\(port)", systemImage: "network")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - ViewModel

@MainActor
final class AppsViewModel: ObservableObject {
    @Published var apps: [AppInstall] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var operatingAppIds: Set<Int> = []

    // 升级相关
    @Published var showUpgradeSheet = false
    @Published var availableVersions: [AppVersion] = []
    @Published var isLoadingVersions = false
    @Published var upgradingVersionId: Int?
    /// 当前选中的要升级到的版本（在 ComposeEditorView 里使用）
    @Published var selectedVersion: AppVersion?
    /// 标记升级是否成功完成（用于编辑器返回时的判断）
    @Published var upgradeSuccess = false

    // 操作提示
    @Published var showAlert = false
    @Published var alertMessage = ""

    /// 标记列表需要刷新（在详情页操作后置 true，返回列表时触发刷新）
    @Published var needsRefresh = false

    private var client: APIClient

    var updatableCount: Int {
        apps.filter { $0.canUpdate == true }.count
    }

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

        // update=false 返回全部应用但 canUpdate 始终 false（后端不计算）
        // update=true  只返回可更新的应用，但正确计算 canUpdate
        // 通过 logs/输出20.log 验证：两者 total 不同
        // 解决方案：先拿全部应用，再并发拿可更新列表，用后者标记前者的 canUpdate
        let allReq = AppInstalledSearchRequest(
            page: 1, pageSize: 100, name: query, type: "", tags: [],
            update: false, all: false, unused: false, sync: false
        )
        // 查询可更新列表时不用 name 过滤，因为可能被搜索词过滤掉
        let updatableReq = AppInstalledSearchRequest(
            page: 1, pageSize: 100, name: "", type: "", tags: [],
            update: true, all: false, unused: false, sync: false
        )

        do {
            async let allResp: AppInstalledListResponse = client.send(
                path: APIEndpoint.appsInstalledSearch.path,
                body: allReq,
                as: AppInstalledListResponse.self
            )
            async let updatableResp: AppInstalledListResponse = client.send(
                path: APIEndpoint.appsInstalledSearch.path,
                body: updatableReq,
                as: AppInstalledListResponse.self
            )

            let (all, updatable) = try await (allResp, updatableResp)
            var apps = all.items ?? []
            let updatableMap = Dictionary((updatable.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

            // 合并可更新状态和 dockerCompose（当前版本）
            for i in apps.indices {
                if let updatableApp = updatableMap[apps[i].id] {
                    apps[i].canUpdate = true
                    apps[i].currentDockerCompose = updatableApp.dockerCompose
                } else {
                    apps[i].canUpdate = false
                }
            }
            self.apps = apps
        } catch let err as APIError {
            self.errorMessage = err.errorDescription
            self.apps = []
        } catch {
            self.errorMessage = error.localizedDescription
            self.apps = []
        }
    }

    // MARK: - 启动/停止/重启

    func operate(app: AppInstall, op: AppOperation) async {
        operatingAppIds.insert(app.id)
        defer { operatingAppIds.remove(app.id) }

        let req = AppInstalledOperateRequest(installId: app.id, operate: op.rawValue)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledOperate.path,
                body: req,
                as: EmptyResponse.self
            )
            try? await Task.sleep(for: .seconds(1))
            await load(query: "")
        } catch let err as APIError {
            showAlert(message: "\(op.displayName)失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "\(op.displayName)失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 升级流程

    func loadVersions(for app: AppInstall) async {
        availableVersions = []
        isLoadingVersions = true
        showUpgradeSheet = true

        do {
            let versions: [AppVersion] = try await client.send(
                path: APIEndpoint.appsUpdateVersions.path,
                body: AppUpdateVersionsRequest(appInstallId: app.id),
                as: [AppVersion].self
            )
            let currentDetailId = app.appDetailID ?? -1
            self.availableVersions = versions.filter { $0.detailId != currentDetailId }
        } catch let err as APIError {
            showAlert(message: "查询版本失败：\(err.errorDescription ?? "未知错误")")
            showUpgradeSheet = false
        } catch {
            showAlert(message: "查询版本失败：\(error.localizedDescription)")
            showUpgradeSheet = false
        }
        isLoadingVersions = false
    }

    func confirmUpgrade(app: AppInstall, to version: AppVersion, customCompose: String?) async {
        upgradingVersionId = version.detailId
        upgradeSuccess = false
        defer { upgradingVersionId = nil }

        let req = AppInstalledOperateRequest(
            installId: app.id,
            operate: AppOperation.upgrade.rawValue,
            detailId: version.detailId,
            backup: false,
            pullImage: true,
            dockerCompose: customCompose
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledOperate.path,
                body: req,
                as: EmptyResponse.self
            )
            upgradeSuccess = true
            showUpgradeSheet = false
            // 延迟显示 alert，避免 sheet 关闭动画"吞掉" alert 状态
            try? await Task.sleep(for: .milliseconds(300))
            showAlert(message: "升级请求已提交，应用正在后台更新中…")
            try? await Task.sleep(for: .seconds(4))
            await load(query: "")
        } catch let err as APIError {
            showAlert(message: "升级失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "升级失败：\(error.localizedDescription)")
        }
    }

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }

    // MARK: - 忽略升级

    /// 忽略指定版本的升级（在版本列表里左滑）
    func ignoreUpgrade(app: AppInstall, version: AppVersion) async {
        let req = AppIgnoreUpgradeRequest(
            appID: app.appID ?? 0,
            scope: "version",
            appDetailID: version.detailId
        )
        await performIgnore(req: req, app: app, successMsg: "已忽略 v\(version.version ?? "") 的升级提示")
    }

    /// 忽略所有版本的升级（在详情页）
    func ignoreUpgrade(app: AppInstall) async {
        let req = AppIgnoreUpgradeRequest(
            appID: app.appID ?? 0,
            scope: "all",
            appDetailID: nil
        )
        await performIgnore(req: req, app: app, successMsg: "已忽略该应用的所有升级提示")
    }

    private func performIgnore(req: AppIgnoreUpgradeRequest, app: AppInstall, successMsg: String) async {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledIgnore.path,
                body: req,
                as: EmptyResponse.self
            )
            showUpgradeSheet = false
            // 延迟显示 alert，避免 sheet 关闭动画"吞掉" alert 状态
            try? await Task.sleep(for: .milliseconds(300))
            showAlert(message: successMsg)
            // 不立即修改 apps 数组（会破坏 NavigationStack），标记返回列表时再刷新
            needsRefresh = true
        } catch let err as APIError {
            showAlert(message: "操作失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "操作失败：\(error.localizedDescription)")
        }
    }
}

extension AppOperation {
    var displayName: String {
        switch self {
        case .start: return "启动"
        case .stop: return "停止"
        case .restart: return "重启"
        case .upgrade: return "升级"
        }
    }
}
