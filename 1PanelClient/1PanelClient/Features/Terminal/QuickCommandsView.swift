//
//  QuickCommandsView.swift
//  1PanelClient
//
//  终端快速命令：列表 / 新建 / 编辑 / 删除（core/commands*）
//  终端页三点菜单进入管理；终端界面内经 QuickCommandPickerSheet 点击直接执行
//

import SwiftUI
import Combine

// MARK: - 管理页

struct QuickCommandsView: View {
    @StateObject private var vm: QuickCommandsViewModel

    init(server: ServerConfig) {
        _vm = StateObject(wrappedValue: QuickCommandsViewModel(server: server))
    }

    @State private var showCreate = false
    @State private var editing: QuickCommand?

    var body: some View {
        Group {
            if vm.isLoading && vm.commands.isEmpty {
                LoadingStateView()
            } else if let err = vm.errorMessage, vm.commands.isEmpty {
                LoadErrorStateView(message: err) {
                    Task { await vm.loadAll(force: true) }
                }
            } else if vm.commands.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无快速命令"),
                    systemImage: "square.and.at.arrowcommand",
                    description: Text(L10n.t("点击右上角 + 创建第一条命令"))
                )
            } else {
                commandList
            }
        }
        .navigationTitle(L10n.t("快速命令"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("创建命令"))
            }
        }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("删除命令"), isPresented: Binding(
            get: { vm.pendingDelete != nil },
            set: { if !$0 { vm.pendingDelete = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { vm.pendingDelete = nil }
            Button(L10n.t("删除"), role: .destructive) {
                if let cmd = vm.pendingDelete {
                    Task { await vm.delete(cmd) }
                }
            }
        } message: {
            Text(L10n.f("确定删除命令「%@」吗？", vm.pendingDelete?.name ?? ""))
        }
        .sheet(isPresented: $showCreate) {
            QuickCommandEditView(vm: vm, editing: nil)
        }
        .sheet(item: $editing) { cmd in
            QuickCommandEditView(vm: vm, editing: cmd)
        }
        .task { await vm.loadAll() }
        .refreshable { await vm.loadAll(force: true) }
    }

    private var commandList: some View {
        List {
            Section {
                ForEach(vm.commands) { cmd in
                    Button {
                        editing = cmd
                    } label: {
                        QuickCommandRow(command: cmd)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            vm.pendingDelete = cmd
                        } label: {
                            Label(L10n.t("删除"), systemImage: "trash")
                        }
                        Button {
                            editing = cmd
                        } label: {
                            Label(L10n.t("编辑"), systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            } footer: {
                Text(L10n.t("在终端界面的菜单中可快速执行这些命令"))
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - 命令行

struct QuickCommandRow: View {
    let command: QuickCommand

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "terminal.fill", color: .teal)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(command.name ?? "—")
                        .font(.body.bold())
                        .lineLimit(1)
                    if let group = command.groupBelong, !group.isEmpty, group != "Default" {
                        StatusBadge(text: group, color: .secondary)
                    }
                }
                Text(command.command ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - 新建 / 编辑表单

struct QuickCommandEditView: View {
    @ObservedObject var vm: QuickCommandsViewModel
    /// 编辑模式传入已有命令；创建模式传 nil
    let editing: QuickCommand?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var commandText = ""
    @State private var groupID = 0
    @State private var isSaving = false
    @State private var didFill = false

    private var isEditing: Bool { editing != nil }
    private var formValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !commandText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.t("名称"), text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(L10n.t("基本信息"))
                }

                Section {
                    if vm.groups.isEmpty {
                        LabeledContent(L10n.t("分组"), value: "Default")
                    } else {
                        Picker(L10n.t("分组"), selection: $groupID) {
                            ForEach(vm.groups) { group in
                                Text(group.name ?? "Default").tag(group.id)
                            }
                        }
                    }
                }

                Section {
                    TextEditor(text: $commandText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 100)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .overlay(alignment: .topLeading) {
                            if commandText.isEmpty {
                                Text(L10n.t("命令内容，如 df -hT"))
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                } header: {
                    Text(L10n.t("命令"))
                }
            }
            .navigationTitle(isEditing ? L10n.t("编辑命令") : L10n.t("创建命令"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            isSaving = true
                            if await vm.upsert(buildRequest()) {
                                dismiss()
                            }
                            isSaving = false
                        }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text(L10n.t("保存")).bold()
                        }
                    }
                    .disabled(!formValid || isSaving)
                }
            }
            .onAppear {
                fillIfEditing()
                if groupID == 0 { groupID = vm.defaultGroupID }
            }
            .onChange(of: vm.groups) { _, _ in
                if groupID == 0 { groupID = vm.defaultGroupID }
            }
        }
        .bottomSheetDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func fillIfEditing() {
        guard let cmd = editing, !didFill else { return }
        didFill = true
        name = cmd.name ?? ""
        commandText = cmd.command ?? ""
        groupID = cmd.groupID ?? 0
    }

    private func buildRequest() -> QuickCommandUpsertRequest {
        QuickCommandUpsertRequest(
            id: editing?.id,
            groupID: groupID == 0 ? vm.defaultGroupID : groupID,
            name: name.trimmingCharacters(in: .whitespaces),
            command: commandText,
            groupBelong: editing?.groupBelong
        )
    }
}

// MARK: - 终端内执行选择器

/// 终端界面菜单「快速命令」弹出的选择器：点击命令回调原文，由终端发送执行
struct QuickCommandPickerSheet: View {
    let server: ServerConfig
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm: QuickCommandsViewModel

    init(server: ServerConfig, onPick: @escaping (String) -> Void) {
        self.server = server
        self.onPick = onPick
        _vm = StateObject(wrappedValue: QuickCommandsViewModel(server: server))
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.commands.isEmpty {
                    LoadingStateView()
                } else if let err = vm.errorMessage, vm.commands.isEmpty {
                    LoadErrorStateView(message: err) {
                        Task { await vm.loadAll(force: true) }
                    }
                } else if vm.commands.isEmpty {
                    ContentUnavailableView(
                        L10n.t("暂无快速命令"),
                        systemImage: "square.and.at.arrowcommand",
                        description: Text(L10n.t("可在 终端页右上角菜单 快速命令 中创建"))
                    )
                } else {
                    List {
                        Section {
                            ForEach(vm.commands) { cmd in
                                Button {
                                    dismiss()
                                    onPick(cmd.command ?? "")
                                } label: {
                                    QuickCommandRow(command: cmd)
                                }
                                .buttonStyle(.plain)
                            }
                        } footer: {
                            Text(L10n.t("点击命令将输入终端并回车执行"))
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(L10n.t("快速命令"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
            }
        }
        .bottomSheetDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await vm.loadAll() }
    }
}

// MARK: - ViewModel

@MainActor
final class QuickCommandsViewModel: ObservableObject {
    @Published var commands: [QuickCommand] = []
    @Published var groups: [SSHHostGroup] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var toastMessage: String?
    @Published var pendingDelete: QuickCommand?

    private var groupsLoaded = false
    private let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    var defaultGroupID: Int {
        groups.first(where: { $0.isDefault == true })?.id ?? groups.first?.id ?? 0
    }

    func loadAll(force: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        async let cmds: Void = loadCommands()
        if force || !groupsLoaded {
            groupsLoaded = true
            async let grps: Void = loadGroups()
            _ = await grps
        }
        _ = await cmds
    }

    func loadCommands() async {
        do {
            let resp: PageResponse<QuickCommand> = try await client.send(
                path: APIEndpoint.commandsSearch.path,
                body: QuickCommandSearchRequest(),
                as: PageResponse<QuickCommand>.self
            )
            commands = resp.items ?? []
            errorMessage = nil
        } catch let err as APIError {
            errorMessage = err.errorDescription ?? L10n.t("未知错误")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadGroups() async {
        do {
            groups = try await client.send(
                path: APIEndpoint.commandGroupsSearch.path,
                body: QuickCommandGroupRequest(),
                as: [SSHHostGroup].self
            )
        } catch {
            groups = []
        }
    }

    @discardableResult
    func upsert(_ req: QuickCommandUpsertRequest) async -> Bool {
        let isCreate = req.id == nil
        do {
            let _: EmptyResponse = try await client.send(
                path: isCreate ? APIEndpoint.commandsCreate.path : APIEndpoint.commandsUpdate.path,
                body: req,
                as: EmptyResponse.self
            )
            showToast(isCreate ? L10n.t("命令已创建") : L10n.t("命令已更新"))
            await loadCommands()
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("保存失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("保存失败：%@", error.localizedDescription))
            return false
        }
    }

    func delete(_ cmd: QuickCommand) async {
        pendingDelete = nil
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.commandsDelete.path,
                body: QuickCommandDeleteRequest(ids: [cmd.id]),
                as: EmptyResponse.self
            )
            showToast(L10n.f("命令「%@」已删除", cmd.name ?? ""))
            await loadCommands()
        } catch let err as APIError {
            showAlert(message: L10n.f("删除失败：%@", err.errorDescription ?? L10n.t("未知错误")))
        } catch {
            showAlert(message: L10n.f("删除失败：%@", error.localizedDescription))
        }
    }

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { self?.toastMessage = nil }
        }
    }
}
