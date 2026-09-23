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

    init(server: ServerConfig) {
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(key: ManageItem.database.storeKey(server: server)) {
            DatabasesViewModel(server: server)
        })
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
        // 未安装引导页：binding 收回（含安装完成后由子页回调触发）
        .navigationDestination(item: $notInstalledCategory) { category in
            NotInstalledDatabaseView(category: category) {
                withAnimation { notInstalledCategory = nil }
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

/// 未安装数据库的详情页：提示未安装并提供跳转应用商店安装的入口
struct NotInstalledDatabaseView: View {
    let category: DBCategory
    /// 安装完成/检测到已安装时收回本页（父页置 nil binding，比 env dismiss 可靠）
    var onInstallCompleted: () -> Void = {}

    /// 应用商店 ViewModel（详情页 + 安装表单共用）
    @StateObject private var storeVM: AppStoreViewModel = {
        let server = ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        return AppStoreViewModel(server: server)
    }()
    /// 是否已进入安装表单（用于区分「自己的安装完成」与无关的全局 installCompleted 通知）
    @State private var didEnterInstall = false

    private let client: APIClient

    init(category: DBCategory, onInstallCompleted: @escaping () -> Void = {}) {
        self.category = category
        self.onInstallCompleted = onInstallCompleted
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

            // 用 NavigationLink 直接 push 应用详情页（避免 isPresented 时序问题）
            NavigationLink {
                AppStoreDetailView(appKey: category.appKey, vm: storeVM)
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
        // 安装表单的 push 由 AppStoreDetailView 上的同名 destination 统一处理
        //（点「安装」时的栈顶页，注册页=触发页）。此前本页也挂了一份注册，
        // 数据库入口的栈内出现两层同名 isPresented 注册竞争同一次 push，
        // 偶发表现为点了安装被弹回/无反应，多试几次才进
        // 跟踪是否进入过安装表单（showInstall true→false 表示用户开始了安装流程）
        .onChange(of: storeVM.showInstall) { _, isShown in
            if isShown { didEnterInstall = true }
        }
        // 安装完成通知：仅当确实进入了本页发起的安装流程时才收回本页，
        // 避免无关的全局 installCompleted 通知误触发（表现为点击安装变返回）；
        // 收回走父页 binding（onInstallCompleted），不依赖 env dismiss()。
        // 安装表单由 AppInstallView 自行收栈（0.35s 延迟 + pop 转场），
        // 本页须等其彻底结束再收，否则两级 pop 动画竞争、后者被丢弃，
        // 表现为安装完成后停在应用详情页少返回一层
        .onReceive(NotificationCenter.default.publisher(for: .installCompleted)) { _ in
            guard didEnterInstall else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                onInstallCompleted()
            }
        }
        // 兜底：回到本页时重查安装状态，已安装则收回本页（列表页已按通知刷新）。
        // 覆盖「后台运行」等通知链路未覆盖的返回路径
        .onAppear {
            Task { await dismissIfInstalled() }
        }
    }

    /// 重查该分类是否已有实例：有则收回本页（列表数据由 installCompleted 通知刷新）
    private func dismissIfInstalled() async {
        // 安装表单仍在展示时不查（后台运行中途返回的场景查了也是未完成态）
        guard !storeVM.showInstall else { return }
        guard let list: [DatabaseSystem] = try? await client.send(
            path: APIEndpoint.databasesDbList.path.replacingOccurrences(of: ":types", with: category.listTypes),
            method: "GET",
            as: [DatabaseSystem].self) else { return }
        if !list.isEmpty {
            onInstallCompleted()
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

