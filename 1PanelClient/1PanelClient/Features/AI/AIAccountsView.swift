//
//  AIAccountsView.swift
//  1PanelClient
//
//  AI 模型账号列表（/api/v2/ai/accounts）：分页搜索 / 创建 / 编辑 / 删除 /
//  模型池管理（行点击进入）；接口见 logs/AI.md 抓包
//

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class AIAccountViewModel: ObservableObject {
    @Published var accounts: [AIAccount] = []
    @Published private(set) var total = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?

    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var toastMessage: String?
    private var toastTask: Task<Void, Never>?

    @Published var pendingDelete: AIAccount?
    @Published private(set) var isDeleting = false

    private var page = 1
    private var loadGeneration = 0
    private static let pageSize = 20

    private(set) var client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient.shared(for: server)
    }

    // MARK: 列表

    func load(name: String = "") async {
        isLoading = true
        defer { isLoading = false }
        page = 1
        loadGeneration += 1
        let req = AISearchPageRequest(page: 1, pageSize: Self.pageSize, name: name)
        do {
            let resp: PageResponse<AIAccount> = try await client.send(
                path: APIEndpoint.aiAccountsSearch.path, body: req, as: PageResponse<AIAccount>.self)
            accounts = resp.items ?? []
            total = resp.total ?? 0
            errorMessage = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            accounts = []
            total = 0
            errorMessage = error.localizedDescription
        }
    }

    func loadMore(name: String = "") async {
        guard accounts.count < total, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let next = page + 1
        let generation = loadGeneration
        let req = AISearchPageRequest(page: next, pageSize: Self.pageSize, name: name)
        do {
            let resp: PageResponse<AIAccount> = try await client.send(
                path: APIEndpoint.aiAccountsSearch.path, body: req, as: PageResponse<AIAccount>.self)
            guard generation == loadGeneration else { return }
            let existing = Set(accounts.map(\.id))
            let newItems = (resp.items ?? []).filter { !existing.contains($0.id) }
            if newItems.isEmpty {
                total = accounts.count
                return
            }
            accounts += newItems
            total = resp.total ?? total
            page = next
        } catch {
            // 追加失败不打断列表，下拉刷新可重试
        }
    }

    // MARK: 供应商预设（创建表单用）

    func loadProviders() async -> [AIProvider] {
        do {
            return try await client.send(
                path: APIEndpoint.aiAccountProviders.path, method: "GET", as: [AIProvider].self)
        } catch {
            guard !APIError.isCancellation(error) else { return [] }
            showAlert(message: L10n.f("供应商列表加载失败：%@", error.localizedDescription))
            return []
        }
    }

    /// POST /api/v2/ai/accounts/models/discover：按表单当前连接信息发现远端模型
    func discoverModels(provider: String, baseURL: String, apiKey: String, apiType: String) async -> [AIModelRef]? {
        let req = AIAccountDiscoverRequest(provider: provider, baseURL: baseURL, apiKey: apiKey, apiType: apiType)
        do {
            return try await client.send(
                path: APIEndpoint.aiAccountModelsDiscover.path, body: req, as: [AIModelRef].self)
        } catch {
            guard !APIError.isCancellation(error) else { return nil }
            showAlert(message: L10n.f("获取模型失败：%@", error.localizedDescription))
            return nil
        }
    }

    // MARK: 增删改

    @discardableResult
    func create(req: AIAccountCreateRequest) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAccountsCreate.path, body: req, as: EmptyResponse.self)
            showToast(L10n.f("账号「%@」已创建", req.name))
            await load()
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("创建失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("创建失败：%@", error.localizedDescription))
            return false
        }
    }

    @discardableResult
    func update(req: AIAccountUpdateRequest) async -> Bool {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAccountsUpdate.path, body: req, as: EmptyResponse.self)
            showToast(L10n.t("账号已更新"))
            await load()
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("更新失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("更新失败：%@", error.localizedDescription))
            return false
        }
    }

    func delete(account: AIAccount) async {
        pendingDelete = nil
        isDeleting = true
        defer { isDeleting = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.aiAccountsDelete.path,
                body: AIAccountDeleteRequest(id: account.id),
                as: EmptyResponse.self)
            showToast(L10n.f("账号「%@」已删除", account.name))
            await load()
        } catch let err as APIError {
            // 已绑定智能体等后端拦截错误直接透出 message
            showAlert(message: L10n.f("删除失败：%@", err.errorDescription ?? L10n.t("未知错误")))
        } catch {
            showAlert(message: L10n.f("删除失败：%@", error.localizedDescription))
        }
    }

    // MARK: 提示

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { self?.toastMessage = nil }
        }
    }
}

// MARK: - 模型账号列表页

struct AIAccountsView: View {
    @StateObject private var vm: AIAccountViewModel
    private let server: ServerConfig

    @State private var searchText = ""
    @State private var isSearching = false
    @State private var showCreate = false
    @State private var isRefreshing = false
    /// 长按弹出的操作菜单目标
    @State private var actionAccount: AIAccount?
    /// 行「模型池」推入的目标
    @State private var poolAccount: AIAccount?
    /// 行「编辑」推入的表单目标
    @State private var editingAccount: AIAccount?

    /// 搜索防抖
    @State private var searchTask: Task<Void, Never>?

    init(server: ServerConfig) {
        self.server = server
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(key: ManageItem.aiAccounts.storeKey(server: server)) {
            AIAccountViewModel(server: server)
        })
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.accounts.isEmpty {
                LoadingStateView()
            } else if let err = vm.errorMessage, vm.accounts.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button(L10n.t("重试")) { Task { await vm.load(name: searchText) } }
                }
            } else if vm.accounts.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("暂无账号"), systemImage: "key.horizontal")
                } description: {
                    Text(L10n.t("点击右上角 + 添加模型账号"))
                }
            } else {
                accountList
            }
        }
        .searchIconMode(
            text: $searchText,
            isSearching: $isSearching,
            title: L10n.t("模型账号"),
            prompt: L10n.t("搜索账号")
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("添加账号"))
            }
        }
        .refreshable { await vm.load(name: searchText) }
        .task { await PageVMStore.shared.autoRefresh(vm: vm) { await vm.load(name: searchText) } }
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .alert(L10n.t("删除账号"), isPresented: Binding(
            get: { vm.pendingDelete != nil },
            set: { if !$0 { vm.pendingDelete = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { vm.pendingDelete = nil }
            Button(L10n.t("删除"), role: .destructive) {
                Haptic.warning()
                if let account = vm.pendingDelete {
                    Task { await vm.delete(account: account) }
                }
            }
        } message: {
            Text(L10n.f("确定删除账号「%@」吗？已绑定智能体的账号无法删除。", vm.pendingDelete?.name ?? ""))
        }
        .navigationDestination(isPresented: $showCreate) {
            AIAccountFormView(server: server, editing: nil, vm: vm)
        }
        .navigationDestination(isPresented: Binding(
            get: { poolAccount != nil },
            set: { if !$0 { poolAccount = nil } }
        )) {
            if let account = poolAccount {
                AIAccountModelsPoolView(server: server, account: account, listVM: vm)
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { editingAccount != nil },
            set: { if !$0 { editingAccount = nil } }
        )) {
            if let account = editingAccount {
                AIAccountFormView(server: server, editing: account, vm: vm)
            }
        }
        .onChange(of: searchText) { _, newValue in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                await vm.load(name: newValue)
            }
        }
    }

    private var accountList: some View {
        List {
            Section {
                ForEach(vm.accounts) { account in
                    Button {
                        poolAccount = account
                    } label: {
                        AIAccountRow(account: account)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                            Haptic.selection()
                            actionAccount = account
                        }
                    )
                    .onAppear {
                        if account.id == vm.accounts.last?.id {
                            Task { await vm.loadMore(name: searchText) }
                        }
                    }
                }

                if vm.accounts.count < vm.total || vm.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .onAppear { Task { await vm.loadMore(name: searchText) } }
                }
            } header: {
                SectionLabel(
                    title: L10n.f("共 %@ 个", String(vm.total)),
                    systemImage: "key.horizontal"
                )
            }
        }
        .listStyle(.insetGrouped)
        .sheet(item: $actionAccount) { account in
            ActionBottomSheet(
                title: account.name,
                items: [
                    ActionMenuItem(title: L10n.t("模型池"), icon: "shippingbox") {
                        poolAccount = account
                    },
                    ActionMenuItem(title: L10n.t("编辑"), icon: "pencil") {
                        editingAccount = account
                    },
                    ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red, role: .destructive) {
                        vm.pendingDelete = account
                    },
                ],
                onDismiss: { actionAccount = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: 3))])
            .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - 账号行

struct AIAccountRow: View {
    let account: AIAccount

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "key.horizontal.fill", color: .blue)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(account.name)
                        .font(.body.bold())
                        .lineLimit(1)
                    if account.verified == true {
                        StatusBadge(text: L10n.t("已验证"), color: .statusRunning, icon: "checkmark.circle.fill")
                    } else if account.verified == false {
                        StatusBadge(text: L10n.t("未验证"), color: .secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text(account.providerName ?? account.provider)
                    Text("·")
                    Text(account.apiType ?? "")
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Label(
                        L10n.f("%@ 个模型", String(account.models?.count ?? 0)),
                        systemImage: "shippingbox"
                    )
                    Text(account.displayCreatedAt)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
