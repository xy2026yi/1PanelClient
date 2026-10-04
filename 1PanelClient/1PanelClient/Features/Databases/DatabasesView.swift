//
//  DatabasesView.swift
//  1PanelClient
//
//  数据库模块：MySQL / PostgreSQL / Redis
//

import SwiftUI
import Combine

// MARK: - 数据库首页 ViewModel

@MainActor
final class DatabasesViewModel: ObservableObject {
    @Published var systems: [DatabaseSystem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient.shared(for: server)
    }

    var mysqlSystems: [DatabaseSystem] { systems.filter { ["mysql","mariadb","mysql-cluster"].contains($0.type.lowercased()) } }
    var pgSystems: [DatabaseSystem] { systems.filter { ["postgresql","postgresql-cluster"].contains($0.type.lowercased()) } }
    var redisSystems: [DatabaseSystem] { systems.filter { ["redis","redis-cluster"].contains($0.type.lowercased()) } }
    var mongoSystems: [DatabaseSystem] { systems.filter { ["mongodb","mongodb-cluster"].contains($0.type.lowercased()) } }

    /// 最近一次请求失败的错误信息（仅用于全部请求失败时展示）
    private var lastError: String?

    func loadSystems() async {
        isLoading = true
        defer { isLoading = false }

        async let mysql: [DatabaseSystem]? = fetchList(types: "mysql,mariadb,mysql-cluster")
        async let pg: [DatabaseSystem]? = fetchList(types: "postgresql,postgresql-cluster")
        async let redis: [DatabaseSystem]? = fetchList(types: "redis,redis-cluster")
        async let mongo: [DatabaseSystem]? = fetchList(types: "mongodb,mongodb-cluster")

        // nil = 请求失败（与「已安装但列表为空」区分开），全部失败才算加载失败
        let results = [await mysql, await pg, await redis, await mongo]
        // 页面退出取消不是失败：不写空列表/错误态，保留原快照
        if Task.isCancelled { return }
        var all: [DatabaseSystem] = []
        var loaded = 0
        for list in results {
            if let list {
                all.append(contentsOf: list)
                loaded += 1
            }
        }
        self.systems = all
        self.errorMessage = (loaded == 0 && all.isEmpty)
            ? (lastError ?? L10n.t("数据库列表加载失败，请检查服务器连接"))
            : nil
        lastError = nil
    }

    private func fetchList(types: String) async -> [DatabaseSystem]? {
        let path = APIEndpoint.databasesDbList.path.replacingOccurrences(of: ":types", with: types)
        do {
            return try await client.send(path: path, method: "GET", as: [DatabaseSystem].self)
        } catch {
            // 页面退出取消不记为失败原因（上层按取消整体跳过写状态）
            guard !APIError.isCancellation(error) else { return nil }
            lastError = L10n.f("加载失败：%@", error.localizedDescription)
            return nil
        }
    }
}

// MARK: - 数据库首页（DB 系统列表）

/// 数据库类型分类（始终展示的 4 类，未安装时显示占位行 + 安装入口）
enum DBCategory: String, CaseIterable, Identifiable {
    case mysql, postgresql, redis, mongodb

    var id: String { rawValue }

    /// 分组标题
    var title: String {
        switch self {
        case .mysql:       return "MySQL / MariaDB"
        case .postgresql:  return "PostgreSQL"
        case .redis:       return "Redis"
        case .mongodb:     return "MongoDB"
        }
    }

    /// 安装跳转用的应用 key（对应应用商店中的应用标识）
    var appKey: String {
        switch self {
        case .mysql:       return "mysql"
        case .postgresql:  return "postgresql"
        case .redis:       return "redis"
        case .mongodb:     return "mongodb"
        }
    }

    /// db/list 请求的 types 参数（与 DatabasesViewModel.fetchList 同口径）
    var listTypes: String {
        switch self {
        case .mysql:       return "mysql,mariadb,mysql-cluster"
        case .postgresql:  return "postgresql,postgresql-cluster"
        case .redis:       return "redis,redis-cluster"
        case .mongodb:     return "mongodb,mongodb-cluster"
        }
    }

    /// 品牌图标
    var brand: Brand {
        switch self {
        case .mysql:       return .mysql
        case .postgresql:  return .postgresql
        case .redis:       return .redis
        case .mongodb:     return .mongodb
        }
    }
}

struct DatabasesView: View {
    @StateObject private var vm: DatabasesViewModel
    /// 未安装引导页目标分类（nil = 未推入）。
    /// 用 item binding 而非静态 NavigationLink：安装完成后由父页置 nil 收回，
    /// 不依赖子页 dismiss()（多层 push 收栈时 env dismiss 不可靠，会停留在引导页）
    @State private var notInstalledCategory: DBCategory?
    /// 安装完成后直达该分类新实例的管理页（item binding，pop 后自动置 nil）
    @State private var installedSystem: DatabaseSystem?
    /// 提示页「安装」推入的商店详情页（item binding；推入/收栈全在父页——
    /// isPresented 挂在提示页自身的收法在嵌套链上会被 iOS 26 延迟写回吞掉，
    /// 实测表现为详情页孤儿化在栈顶、手动返回直达 hub）
    @State private var installCategory: DBCategory?
    /// 是否已进入安装表单（区分「自己的安装完成」与无关的全局 installCompleted 通知）
    @State private var didEnterInstall = false
    /// 安装链共用的商店 VM（详情页 + 安装表单）
    @StateObject private var installVM: AppStoreViewModel

    init(server: ServerConfig) {
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(key: ManageItem.database.storeKey(server: server)) {
            DatabasesViewModel(server: server)
        })
        _installVM = StateObject(wrappedValue: AppStoreViewModel(server: server))
    }

    var body: some View {
        List {
            // 全部请求失败：显示错误态 + 重试（而不是误显示为「未安装」）
            if vm.systems.isEmpty, let msg = vm.errorMessage, !vm.isLoading {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(msg)
                } actions: {
                    Button(L10n.t("重试")) {
                        Task { await vm.loadSystems() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(DBCategory.allCases, id: \.rawValue) { category in
                    systemGroup(for: category)
                }
            }
        }
        .navigationTitle(L10n.t("数据库"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.loadSystems() }
        .task {
            // 重访（已有快照）时门控不转圈，这里静默刷新拿最新列表（5 秒内重访节流）
            await PageVMStore.shared.autoRefresh(vm: vm) {
                await vm.loadSystems()
            }
        }
        // 应用安装完成时刷新（如从「安装 XX」流程返回后，新装的数据库需重新拉取）
        .onReceive(NotificationCenter.default.publisher(for: .installCompleted)) { _ in
            Task { await vm.loadSystems() }
        }
        // 未安装引导页：纯展示 + 回调，安装链的全部导航状态由本页（父级 binding）持有
        .navigationDestination(item: $notInstalledCategory) { category in
            NotInstalledDatabaseView(
                category: category,
                onInstallRequested: {
                    installCategory = category
                },
                onCompleted: {
                    Task { await completeInstall(for: category) }
                })
        }
        // 提示页「安装」推入的商店详情页（item binding，back 后自动置 nil）
        .navigationDestination(item: $installCategory) { category in
            AppStoreDetailView(appKey: category.appKey, vm: installVM)
        }
        // 安装完成后直达的分类管理页（item binding，pop 后自动置 nil）
        .navigationDestination(item: $installedSystem) { sys in
            DatabaseSystemView(system: sys)
        }
        // 跟踪本链是否进入过安装表单（详情页上的 showInstall 变化）
        .onChange(of: installVM.showInstall) { _, isShown in
            if isShown { didEnterInstall = true }
        }
        // 详情页被手动退出（back 写回置 nil）时复位跟踪，避免后续无关通知误触发收栈
        .onChange(of: installCategory) { _, newValue in
            if newValue == nil { didEnterInstall = false }
        }
        // 安装完成：分步收栈（同帧多级 pop 会动画竞争、后者被丢弃）——
        // 进度页自弹 → 安装表单 0.35s（AppInstallView 自理）→ 商店详情 0.9s（父级
        // binding，可靠）→ 1.25s 起收提示页并直达该分类管理页（completeInstall）
        .onReceive(NotificationCenter.default.publisher(for: .installCompleted)) { _ in
            guard didEnterInstall, let category = installCategory else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                installCategory = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    Task { await completeInstall(for: category) }
                }
            }
        }
        .overlay {
            if vm.isLoading && vm.systems.isEmpty {
                LoadingStateView()
            }
        }
    }

    /// 单个分类分组：有实例则列出，无实例则显示未安装占位行
    @ViewBuilder
    private func systemGroup(for category: DBCategory) -> some View {
        let items = systems(for: category)
        if items.isEmpty {
            // 未安装：占位行（推入方式见 notInstalledCategory 注释）
            Section(category.title) {
                Button {
                    notInstalledCategory = category
                } label: {
                    NotInstalledDatabaseRow(category: category)
                }
            }
        } else {
            // 已安装：列出实例
            Section(category.title) {
                ForEach(items) { sys in
                    NavigationLink {
                        DatabaseSystemView(system: sys)
                    } label: {
                        DatabaseSystemRow(system: sys)
                    }
                }
            }
        }
    }

    /// 取某分类下已安装的数据库实例
    private func systems(for category: DBCategory) -> [DatabaseSystem] {
        switch category {
        case .mysql:       return vm.mysqlSystems
        case .postgresql:  return vm.pgSystems
        case .redis:       return vm.redisSystems
        case .mongodb:     return vm.mongoSystems
        }
    }

    /// 安装完成后收提示页并直达该分类新实例的管理页；
    /// 新实例未就位（列表滞后/安装失败）则仅收提示页回列表
    private func completeInstall(for category: DBCategory) async {
        await vm.loadSystems()
        let system = systems(for: category).first
        withAnimation { notInstalledCategory = nil }
        if let system {
            // 等提示页 pop 转场结束再推管理页，避免同帧叠层
            try? await Task.sleep(for: .seconds(0.35))
            installedSystem = system
        }
    }
}

// MARK: - 未安装占位行

/// 未安装数据库的占位行：灰色品牌图标 + 名称 + 「未安装」标签
/// （行已改为 Button 推入，补 chevron 保持 NavigationLink 的可点视觉提示）
struct NotInstalledDatabaseRow: View {
    let category: DBCategory

    var body: some View {
        HStack(spacing: 14) {
            BrandIcon(brand: category.brand, size: 44)
                .opacity(0.4)   // 未安装：图标变淡
            VStack(alignment: .leading, spacing: 3) {
                Text(category.title).font(.headline).foregroundStyle(.secondary)
                Text(L10n.t("未安装"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - 未安装数据库详情页（提示 + 安装按钮）

/// 未安装数据库的详情页：纯展示 + 两个回调——「安装」由父页推商店详情，
/// 兜底检测到已安装时收回；安装链的全部导航状态与收栈都在父页（父级 binding 可靠）
struct NotInstalledDatabaseView: View {
    let category: DBCategory
    /// 点「安装」：父页推入商店详情页
    var onInstallRequested: () -> Void = {}
    /// 检测到已安装（回到本页的兜底路径）：父页收提示页并直达管理页
    var onCompleted: () -> Void = {}

    private let client: APIClient

    init(category: DBCategory,
         onInstallRequested: @escaping () -> Void = {},
         onCompleted: @escaping () -> Void = {}) {
        self.category = category
        self.onInstallRequested = onInstallRequested
        self.onCompleted = onCompleted
        self.client = APIClient.shared(for: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            BrandIcon(brand: category.brand, size: 72)
                .opacity(0.5)

            VStack(spacing: 8) {
                Text(L10n.f("%@未安装", category.title))
                    .font(.headline)
                Text(L10n.f("请先安装 %@ 后再使用此功能", category.title))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                onInstallRequested()
            } label: {
                Label(L10n.f("安装 %@", category.title), systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)

            Spacer()
        }
        .padding()
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        // 兜底：回到本页时重查安装状态，已安装则通知父页收回（覆盖手动返回等路径）
        .onAppear {
            Task { await dismissIfInstalled() }
        }
    }

    /// 重查该分类是否已有实例：有则通知父页收回
    private func dismissIfInstalled() async {
        guard let list: [DatabaseSystem] = try? await client.send(
            path: APIEndpoint.databasesDbList.path.replacingOccurrences(of: ":types", with: category.listTypes),
            method: "GET",
            as: [DatabaseSystem].self) else { return }
        if !list.isEmpty {
            onCompleted()
        }
    }
}

struct DatabaseSystemRow: View {
    let system: DatabaseSystem

    var body: some View {
        HStack(spacing: 14) {
            // 优先显示内置品牌图标，未知类型回退到 SF Symbol
            if let brand = Brand.from(dbType: system.type) {
                BrandIcon(brand: brand, size: 44)
            } else {
                IconBadge(
                    systemName: system.systemIcon,
                    color: Color.fromDBString(system.systemColor)
                )
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(system.displayName).font(.headline)
                if let v = system.version, !v.isEmpty {
                    Text("v\(v)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

