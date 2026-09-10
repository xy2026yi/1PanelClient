//
//  GroupManageView.swift
//  1PanelClient
//
//  分组管理页：新建 / 重命名 / 设为默认 / 删除（默认分组不可删改，由 isDefault 判断）
//  网站分组与计划任务/脚本分组共用（GroupScope 决定走 agent 还是 core 端点）
//

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class GroupManageViewModel: ObservableObject {
    @Published var groups: [PanelGroup] = []
    @Published var isLoading = false
    /// 行级操作进行中（只转对应行的按钮，不打断整页）
    @Published var operatingGroupID: Int?

    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var toastMessage: String?
    private var toastTask: Task<Void, Never>?

    let scope: GroupScope
    private let client: APIClient

    init(server: ServerConfig, scope: GroupScope) {
        self.client = APIClient.shared(for: server)
        self.scope = scope
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            groups = try await client.send(
                path: scope.searchPath,
                body: GroupSearchRequest(type: scope.type),
                as: [PanelGroup].self
            )
        } catch {
            // 页面退出取消不是失败
            guard !APIError.isCancellation(error) else { return }
            showAlert(message: L10n.f("加载失败：%@", error.localizedDescription))
        }
    }

    @discardableResult
    func create(name: String) async -> Bool {
        await operate { client in
            let _: EmptyResponse = try await client.send(
                path: self.scope.createPath,
                body: GroupCreateRequest(name: name, type: self.scope.type),
                as: EmptyResponse.self
            )
            self.showToast(L10n.f("分组「%@」已创建", name))
        }
    }

    @discardableResult
    func rename(_ group: PanelGroup, to newName: String) async -> Bool {
        await operate(groupID: group.id) { client in
            let _: EmptyResponse = try await client.send(
                path: self.scope.updatePath,
                body: GroupUpdateRequest(id: group.id, name: newName, type: self.scope.type, isDefault: group.isDefault == true),
                as: EmptyResponse.self
            )
            self.showToast(L10n.f("分组「%@」已重命名", newName))
        }
    }

    /// 设为默认（GroupUpdate.isDefault=true）
    @discardableResult
    func setDefault(_ group: PanelGroup) async -> Bool {
        await operate(groupID: group.id) { client in
            let _: EmptyResponse = try await client.send(
                path: self.scope.updatePath,
                body: GroupUpdateRequest(id: group.id, name: group.name ?? "", type: self.scope.type, isDefault: true),
                as: EmptyResponse.self
            )
            self.showToast(L10n.f("分组「%@」已设为默认", group.displayName))
        }
    }

    @discardableResult
    func delete(_ group: PanelGroup) async -> Bool {
        await operate(groupID: group.id) { client in
            let _: EmptyResponse = try await client.send(
                path: self.scope.deletePath,
                body: GroupDeleteRequest(id: group.id),
                as: EmptyResponse.self
            )
            self.showToast(L10n.f("分组「%@」已删除", group.displayName))
        }
    }

    /// 行级操作统一收口：占位对应行 → 执行 → 成功后整表重查
    private func operate(groupID: Int? = nil, _ body: (APIClient) async throws -> Void) async -> Bool {
        operatingGroupID = groupID
        defer { operatingGroupID = nil }
        do {
            try await body(client)
            await load()
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("操作失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("操作失败：%@", error.localizedDescription))
            return false
        }
    }

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

// MARK: - 分组管理页

struct GroupManageView: View {
    @StateObject private var vm: GroupManageViewModel
    /// 任一分组变更后回调宿主页（刷新分组筛选条与列表）
    var onChanged: (() -> Void)?

    @State private var showCreate = false
    @State private var renamingGroup: PanelGroup?
    @State private var deletingGroup: PanelGroup?
    /// 点击分组行弹出的操作菜单目标（重命名 / 设为默认 / 删除）
    @State private var actionGroup: PanelGroup?

    init(server: ServerConfig, scope: GroupScope, onChanged: (() -> Void)? = nil) {
        _vm = StateObject(wrappedValue: GroupManageViewModel(server: server, scope: scope))
        self.onChanged = onChanged
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.groups.isEmpty {
                LoadingStateView()
            } else if vm.groups.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无分组"),
                    systemImage: "folder",
                    description: Text(L10n.t("点击右上角 + 新建分组"))
                )
            } else {
                groupList
            }
        }
        .navigationTitle(L10n.t("分组管理"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("新建分组"))
            }
        }
        .sheet(isPresented: $showCreate) {
            GroupNameSheet(title: L10n.t("新建分组")) { name in
                Task {
                    if await vm.create(name: name) { onChanged?() }
                }
            }
        }
        .sheet(item: $renamingGroup) { group in
            GroupNameSheet(title: L10n.t("重命名"), initialText: group.name ?? "") { name in
                Task {
                    if await vm.rename(group, to: name) { onChanged?() }
                }
            }
        }
        .alert(
            L10n.t("删除分组"),
            isPresented: Binding(
                get: { deletingGroup != nil },
                set: { if !$0 { deletingGroup = nil } }
            ),
            presenting: deletingGroup
        ) { group in
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("删除"), role: .destructive) {
                Task {
                    if await vm.delete(group) { onChanged?() }
                }
            }
        } message: { group in
            Text(L10n.f("删除分组「%@」后，其成员将移入默认分组，是否继续？", group.displayName))
        }
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .task { await vm.load() }
    }

    private var groupList: some View {
        List {
            ForEach(vm.groups) { group in
                groupRow(group)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await vm.load() }
        .sheet(item: $actionGroup) { group in
            ActionBottomSheet(
                title: group.displayName,
                items: menuItems(for: group),
                onDismiss: { actionGroup = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: menuItems(for: group).count))])
            .presentationDragIndicator(.visible)
        }
    }

    /// 分组行：点击弹出操作菜单（重命名 / 设为默认 / 删除）
    private func groupRow(_ group: PanelGroup) -> some View {
        Button {
            actionGroup = group
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.displayName)
                        .font(.body.bold())
                        .foregroundStyle(.primary)
                    if group.isDefault == true {
                        StatusBadge(text: L10n.t("默认"), color: .blue, icon: "star.fill")
                    }
                }
                Spacer()
                if vm.operatingGroupID == group.id {
                    ProgressView()
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 操作菜单项：默认组不可设默认/删除，仅可重命名
    private func menuItems(for group: PanelGroup) -> [ActionMenuItem] {
        var items: [ActionMenuItem] = [
            ActionMenuItem(title: L10n.t("重命名"), icon: "pencil") {
                renamingGroup = group
            },
        ]
        if group.isDefault != true {
            items.append(ActionMenuItem(title: L10n.t("设为默认"), icon: "star") {
                Task {
                    if await vm.setDefault(group) { onChanged?() }
                }
            })
            items.append(ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red, role: .destructive) {
                deletingGroup = group
            })
        }
        return items
    }
}

// MARK: - 分组名称编辑 Sheet（新建 / 重命名共用）

struct GroupNameSheet: View {
    let title: String
    var initialText: String = ""
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.t("分组名称"), text: $name)
                        .focused($focused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { submit() }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                name = initialText
                focused = true
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("保存")) { submit() }
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
        .bottomSheetDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func submit() {
        guard !trimmedName.isEmpty else { return }
        onSave(trimmedName)
        dismiss()
    }
}
