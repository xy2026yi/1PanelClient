//
//  DatabaseMySQLAdvancedViews.swift
//  1PanelClient
//
//  MySQL/MariaDB 参数 / 性能调整 / 配置修改（抓包 2026-09-15）：
//  · 参数：databases/variables（SHOW VARIABLES 全量展示）
//  · 性能调整：databases/variables + 1-2GB…16-32GB 预设，应用走
//    databases/variables/update（需输入「立即重启」确认）
//  · 配置修改：databases/common/load/file 读取 → common/update/conf 保存，
//    apps/installed/conf 取默认配置
//

import SwiftUI

// MARK: - 参数（SHOW VARIABLES）

struct DatabaseMySQLVariablesView: View {
    let system: DatabaseSystem

    @State private var variables: [String: String]?
    @State private var isLoading = true
    @State private var loadError: String?

    private let client: APIClient

    init(system: DatabaseSystem) {
        self.system = system
        self.client = APIClient.shared(for: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
    }

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); LoadingStateView(); Spacer() }
                    .listRowBackground(Color.clear)
            } else if let loadError {
                LoadErrorStateView(message: loadError) {
                    Task { await load() }
                }
                .listRowBackground(Color.clear)
            } else if let variables {
                Section {
                    ForEach(MySQLVariablesDisplay.displayKeys(variables), id: \.self) { key in
                        InfoRow(key, value: MySQLVariablesDisplay.value(key, variables[key]), monospaced: true)
                    }
                } header: {
                    SectionLabel(title: L10n.t("参数"), systemImage: "slider.horizontal.3")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("参数"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            let resp: [String: String] = try await client.send(
                path: APIEndpoint.databasesVariables.path,
                body: DatabaseStatusRequest(type: system.type, name: system.database),
                as: [String: String].self)
            variables = resp
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - 性能调整（优化方案预设 + 应用）

struct DatabaseMySQLPerformanceView: View {
    let system: DatabaseSystem

    @State private var variables: [String: String]?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selectedPreset: MySQLTunePreset?
    @State private var isApplying = false
    @State private var showApplyConfirm = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var successToast: String?

    private let client: APIClient

    init(system: DatabaseSystem) {
        self.system = system
        self.client = APIClient.shared(for: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
    }

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); LoadingStateView(); Spacer() }
                    .listRowBackground(Color.clear)
            } else if let loadError {
                LoadErrorStateView(message: loadError) {
                    Task { await load() }
                }
                .listRowBackground(Color.clear)
            } else if let variables {
                presetSection
                paramSection(variables)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("性能调整"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("保存")) {
                    guard selectedPreset != nil else { return }
                    showApplyConfirm = true
                }
                .disabled(selectedPreset == nil || isApplying)
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .toastOverlay(message: $successToast)
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        // 应用前需输入「立即重启」确认（与网页端一致）
        .sheet(isPresented: $showApplyConfirm) {
            TextInputConfirmSheet(
                title: L10n.t("应用优化方案"),
                message: L10n.f("将应用「%@」优化方案并重启 %@，期间数据库短暂不可用。",
                                selectedPreset?.name ?? "", system.displayName),
                expectedText: L10n.t("立即重启"),
                fieldLabel: L10n.t("确认重启"),
                fieldPlaceholder: L10n.t("请输入「立即重启」")
            ) {
                Task { await applyPreset() }
            }
        }
    }

    // MARK: 优化方案预设

    private var presetSection: some View {
        Section {
            ForEach(MySQLTunePresets.all) { preset in
                Button {
                    withAnimation(Motion.standard) { selectedPreset = preset }
                } label: {
                    HStack {
                        Text(preset.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        if selectedPreset?.name == preset.name {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            SectionLabel(title: L10n.t("优化方案"), systemImage: "square.grid.2x2")
        } footer: {
            Text(L10n.t("按服务器内存选择预设方案；应用后部分参数需重启数据库生效。"))
        }
    }

    // MARK: 当前参数与预设对比

    private func paramSection(_ variables: [String: String]) -> some View {
        Section {
            ForEach(MySQLTunePresets.paramOrder, id: \.self) { param in
                let current = Int(variables[param] ?? "")
                HStack {
                    Text(param)
                        .font(.system(.subheadline, design: .monospaced))
                    Spacer()
                    if let presetValue = selectedPreset?.values[param], presetValue != current {
                        // 当前值 → 预设值（选中方案且值有变化时展示变化方向）
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(current.map { MySQLTunePresets.displayValue(param: param, $0) } ?? "—")
                                .font(.caption)
                                .strikethrough()
                                .foregroundStyle(.secondary)
                            Text(MySQLTunePresets.displayValue(param: param, presetValue))
                                .font(.system(.subheadline, design: .monospaced).bold())
                                .foregroundStyle(Color.accentColor)
                        }
                    } else {
                        Text(current.map { MySQLTunePresets.displayValue(param: param, $0) } ?? "—")
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            SectionLabel(title: L10n.t("参数对比"), systemImage: "list.bullet.rectangle")
        } footer: {
            if let preset = selectedPreset {
                Text(L10n.f("已选「%@」，蓝字为应用后的值", preset.name))
            }
        }
    }

    private func load() async {
        do {
            let resp: [String: String] = try await client.send(
                path: APIEndpoint.databasesVariables.path,
                body: DatabaseStatusRequest(type: system.type, name: system.database),
                as: [String: String].self)
            variables = resp
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    /// 应用预设：POST /databases/variables/update（提交预设全部参数）
    private func applyPreset() async {
        guard let preset = selectedPreset else { return }
        isApplying = true
        defer { isApplying = false }
        let items = MySQLTunePresets.paramOrder.compactMap { param -> MySQLVariableItem? in
            guard let v = preset.values[param] else { return nil }
            return MySQLVariableItem(param: param, value: v)
        }
        let req = DatabaseVariablesUpdateRequest(
            type: system.type, database: system.database, variables: items)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.databasesVariablesUpdate.path, body: req, as: EmptyResponse.self)
            successToast = L10n.t("优化方案已应用")
            await load()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - 配置修改（my.cnf 编辑 / 保存 / 默认配置）

struct DatabaseMySQLConfView: View {
    let system: DatabaseSystem

    @State private var content = ""
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isSaving = false
    @State private var successToast: String?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showResetConfirm = false

    private let client: APIClient

    init(system: DatabaseSystem) {
        self.system = system
        self.client = APIClient.shared(for: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
    }

    var body: some View {
        Form {
            if isLoading {
                Section { HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 24) }
            } else if let loadError {
                Section {
                    ContentUnavailableView {
                        Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button(L10n.t("重试")) { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    TextEditor(text: $content)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 360)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .scrollContentBackground(.hidden)
                } header: {
                    SectionLabel(title: system.displayName, systemImage: "doc.plaintext")
                } footer: {
                    Text(L10n.t("修改保存后需重启数据库才能生效。"))
                }
            }
        }
        .navigationTitle(L10n.t("配置修改"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSaving {
                    ProgressView()
                } else {
                    Menu {
                        Button {
                            Task { await save() }
                        } label: {
                            Label(L10n.t("保存"), systemImage: "square.and.arrow.down")
                        }
                        .disabled(isLoading || loadError != nil)
                        Button(role: .destructive) {
                            showResetConfirm = true
                        } label: {
                            Label(L10n.t("恢复默认配置"), systemImage: "arrow.counterclockwise")
                        }
                        .disabled(isLoading || loadError != nil)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(L10n.t("更多操作"))
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .toastOverlay(message: $successToast)
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(L10n.t("恢复默认配置"), isPresented: $showResetConfirm) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("恢复"), role: .destructive) {
                Task { await resetToDefault() }
            }
        } message: {
            Text(L10n.t("将用默认配置覆盖编辑区当前内容（未保存的修改会丢失），确认后请手动保存。"))
        }
    }

    // MARK: 数据

    /// 读取当前配置：POST /databases/common/load/file {type:"<db>-conf",name}
    private func load() async {
        do {
            let resp: String = try await client.send(
                path: APIEndpoint.databasesCommonLoadFile.path,
                body: DatabaseConfFileRequest(type: "\(system.type)-conf", name: system.database),
                as: String.self)
            content = resp
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    /// 保存：POST /databases/common/update/conf {type,database,file}
    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let req = DatabaseConfUpdateRequest(type: system.type, database: system.database, file: content)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.databasesCommonUpdateConf.path, body: req, as: EmptyResponse.self)
            successToast = L10n.t("已保存")
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// 恢复默认：POST /apps/installed/conf {type,name} → 填入编辑区（不自动保存）
    private func resetToDefault() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let resp: String = try await client.send(
                path: APIEndpoint.appsInstalledConf.path,
                body: AppInstalledConfRequest(type: system.type, name: system.database),
                as: String.self)
            content = resp
            successToast = L10n.t("已填入默认配置，请检查后保存")
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
