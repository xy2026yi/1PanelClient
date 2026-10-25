//
//  RuntimePHPExtensionsView.swift
//  1PanelClient
//
//  PHP 扩展管理：已加载扩展（标签流）、常用扩展安装/卸载（安装任务式带进度）、
//  扩展模版管理（列表/新建/修改/删除）。
//

import SwiftUI

struct RuntimePHPExtensionsView: View {
    let entry: RuntimeEntry
    let client: APIClient

    @State private var loaded: [String] = []
    @State private var support: [RuntimePHPSupportExtension] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var toast: String?
    /// 操作中的扩展名（安装/卸载按钮转圈）
    @State private var busyExtensions: Set<String> = []
    @State private var activeTask: RuntimeTaskTarget?
    /// 卸载确认目标
    @State private var uninstallTarget: RuntimePHPSupportExtension?

    var body: some View {
        List {
            if isLoading && support.isEmpty {
                Section { LoadingStateView(compact: true).padding(.vertical, 20) }
            } else if let err = errorMessage, support.isEmpty {
                Section {
                    Text(err).font(.footnote).foregroundStyle(.red)
                    Button(L10n.t("重试")) { Task { await load() } }
                }
            } else {
                loadedSection
                supportSection
            }
        }
        .navigationTitle(L10n.t("扩展"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .toastOverlay(message: $toast)
        .navigationDestination(item: $activeTask) { target in
            TaskProgressView(taskID: target.taskID, title: target.title, node: "local") { _ in
                // 完成与「后台运行」返回都刷新：任务已提交，不能对同一扩展重复发起安装
                Task { await load() }
                return false
            }
        }
        .alert(L10n.t("卸载扩展"), isPresented: Binding(
            get: { uninstallTarget != nil },
            set: { if !$0 { uninstallTarget = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("卸载"), role: .destructive) {
                let target = uninstallTarget
                Task { if let target { await uninstall(target) } }
            }
        } message: {
            Text(L10n.f("确认卸载扩展「%@」？卸载需重建镜像，期间站点可能短暂不可用。",
                        uninstallTarget?.displayName ?? ""))
        }
    }

    private func load() async {
        isLoading = support.isEmpty
        errorMessage = nil
        defer { isLoading = false }
        do {
            let path = APIEndpoint.runtimesPhpExtList.path
                .replacingOccurrences(of: ":id", with: String(entry.id))
            let resp: RuntimePHPExtensionsResponse = try await client.send(
                path: path, method: APIEndpoint.runtimesPhpExtList.method,
                as: RuntimePHPExtensionsResponse.self
            )
            loaded = resp.extensions ?? []
            support = resp.supportExtensions ?? []
        } catch {
            if !APIError.isCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    // MARK: 已加载扩展

    private var loadedSection: some View {
        Section {
            if loaded.isEmpty {
                Text(L10n.t("暂无已加载扩展"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(loaded, id: \.self) { name in
                        StatusBadge(text: name, color: .secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text(L10n.t("已加载扩展"))
        }
    }

    // MARK: 常用扩展（安装/卸载）

    private var supportSection: some View {
        Section {
            if support.isEmpty {
                Text(L10n.t("暂无可安装扩展"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(support) { ext in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ext.displayName)
                            .font(.system(.body, design: .monospaced))
                        if let desc = ext.description, !desc.isEmpty {
                            Text(desc)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if busyExtensions.contains(ext.displayName) {
                        ProgressView().scaleEffect(0.8)
                    } else if ext.installed == true {
                        Button(L10n.t("卸载")) {
                            uninstallTarget = ext
                        }
                        .font(.subheadline)
                        .buttonStyle(.bordered)
                        .tint(.red)
                    } else {
                        Button(L10n.t("安装")) {
                            Task { await install(ext) }
                        }
                        .font(.subheadline)
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text(L10n.t("常用扩展"))
        } footer: {
            Text(L10n.t("安装为异步任务，卸载即时生效"))
        }
    }

    private func install(_ ext: RuntimePHPSupportExtension) async {
        let taskID = UUID().uuidString.lowercased()
        busyExtensions.insert(ext.displayName)
        defer { busyExtensions.remove(ext.displayName) }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.runtimesPhpExtInstall.path,
                body: RuntimePHPExtensionInstallRequest(
                    id: entry.id, name: ext.displayName, taskID: taskID
                ),
                as: EmptyResponse.self
            )
            activeTask = RuntimeTaskTarget(
                taskID: taskID, title: L10n.f("安装扩展 %@", ext.displayName)
            )
        } catch {
            toast = L10n.f("安装失败：%@", error.localizedDescription)
        }
    }

    private func uninstall(_ ext: RuntimePHPSupportExtension) async {
        guard !busyExtensions.contains(ext.displayName) else { return }
        busyExtensions.insert(ext.displayName)
        defer { busyExtensions.remove(ext.displayName) }
        do {
            // 卸载为同步接口（无 taskID），服务端要重建镜像、数分钟级——
            // 默认 15s 超时会“假失败”（服务端仍在执行），按面板口径放宽
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.runtimesPhpExtUninstall.path,
                body: RuntimePHPExtensionUninstallRequest(id: entry.id, name: ext.displayName),
                timeout: 600,
                as: EmptyResponse.self
            )
            toast = L10n.f("扩展 %@ 已卸载", ext.displayName)
            await load()
        } catch {
            toast = L10n.f("卸载失败：%@", error.localizedDescription)
        }
    }
}

// MARK: - 扩展模版管理（独立入口：列表 + 新建/修改/删除）

struct RuntimePHPTemplatesView: View {
    let client: APIClient

    @State private var templates: [RuntimePHPTemplate] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var toast: String?
    @State private var editingTemplate: RuntimePHPTemplate?
    @State private var showCreate = false
    @State private var deleteTarget: RuntimePHPTemplate?
    /// 模版行长按菜单目标（编辑/删除）
    @State private var actionTpl: RuntimePHPTemplate?

    var body: some View {
        List {
            if isLoading && templates.isEmpty {
                Section { LoadingStateView(compact: true).padding(.vertical, 20) }
            } else if let err = errorMessage {
                Section {
                    Text(err).font(.footnote).foregroundStyle(.red)
                    Button(L10n.t("重试")) { Task { await load() } }
                }
            } else if templates.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无扩展模版"),
                    systemImage: "doc.badge.plus",
                    description: Text(L10n.t("扩展模版可在创建 PHP 运行环境时一键带入扩展"))
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(templates) { tpl in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tpl.displayName)
                                .font(.body.bold())
                            Text(tpl.extensions ?? "")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .rowTapAndLongPress(
                            onTap: { editingTemplate = tpl },
                            onLongPress: { actionTpl = tpl }
                        )
                    }
                }
            }
        }
        .navigationTitle(L10n.t("扩展模版"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCreate = true } label: { Image(systemName: "plus") }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .toastOverlay(message: $toast)
        .sheet(isPresented: $showCreate) {
            RuntimeTemplateEditSheet(client: client, template: nil) {
                Task { await load() }
            }
        }
        .sheet(item: $editingTemplate) { tpl in
            RuntimeTemplateEditSheet(client: client, template: tpl) {
                Task { await load() }
            }
        }
        .sheet(item: $actionTpl) { tpl in
            ActionBottomSheet(
                title: tpl.displayName,
                items: [
                    ActionMenuItem(title: L10n.t("编辑"), icon: "pencil") {
                        editingTemplate = tpl
                    },
                    ActionMenuItem(title: L10n.t("删除"), icon: "trash",
                                   color: .red, role: .destructive) {
                        deleteTarget = tpl
                    },
                ],
                onDismiss: { actionTpl = nil }
            )
        }
        .alert(L10n.t("删除扩展模版"), isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("删除"), role: .destructive) {
                // alert 关闭会把 deleteTarget 置 nil，异步闭包必须先捕获目标
                let target = deleteTarget
                Task { await deleteTemplate(target) }
            }
        } message: {
            Text(L10n.f("确认删除模版「%@」？", deleteTarget?.displayName ?? ""))
        }
    }

    private func load() async {
        isLoading = templates.isEmpty
        errorMessage = nil
        defer { isLoading = false }
        do {
            let resp: RuntimePHPTemplateListResponse = try await client.send(
                path: APIEndpoint.runtimesPhpTplSearch.path,
                body: RuntimePHPTemplateSearchRequest(),
                as: RuntimePHPTemplateListResponse.self
            )
            templates = resp.items ?? []
        } catch {
            if !APIError.isCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    private func deleteTemplate(_ target: RuntimePHPTemplate?) async {
        guard let tpl = target else { return }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.runtimesPhpTplDel.path,
                body: RuntimePHPTemplateDeleteRequest(id: tpl.id),
                as: EmptyResponse.self
            )
            deleteTarget = nil
            toast = L10n.t("已删除")
            await load()
        } catch {
            toast = L10n.f("删除失败：%@", error.localizedDescription)
        }
    }
}

// MARK: - 模版新建/编辑 Sheet

struct RuntimeTemplateEditSheet: View {
    let client: APIClient
    /// nil = 新建
    let template: RuntimePHPTemplate?
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var extensionsText = ""
    @State private var isSaving = false
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    OutlinedTextField(label: L10n.t("名称"), text: $name)
                    OutlinedMultiLineField(label: L10n.t("扩展"),
                                           prompt: "bcmath,ftp,gd,intl,zip",
                                           lines: 3, text: $extensionsText)
                } footer: {
                    Text(L10n.t("多个扩展名用英文逗号分隔"))
                }
            }
            .navigationTitle(template == nil ? L10n.t("新建模版") : L10n.t("修改模版"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(L10n.t("保存")) { Task { await save() } }
                            .disabled(name.isEmpty || extensionsText.isEmpty)
                    }
                }
            }
            .onAppear {
                if let tpl = template {
                    name = tpl.displayName
                    extensionsText = tpl.extensions ?? ""
                }
            }
            .toastOverlay(message: $toast)
        }
        .bottomSheetDetents([.medium])
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            if let tpl = template {
                let _: EmptyResponse = try await client.send(
                    path: APIEndpoint.runtimesPhpTplUpdate.path,
                    body: RuntimePHPTemplateUpdateRequest(
                        id: tpl.id, name: name, extensions: extensionsText
                    ),
                    as: EmptyResponse.self
                )
            } else {
                let _: EmptyResponse = try await client.send(
                    path: APIEndpoint.runtimesPhpTplCreate.path,
                    body: RuntimePHPTemplateCreateRequest(name: name, extensions: extensionsText),
                    as: EmptyResponse.self
                )
            }
            onSaved()
            dismiss()
        } catch {
            toast = L10n.f("保存失败：%@", error.localizedDescription)
        }
    }
}
