//
//  AlertNotificationView.swift
//  1PanelClient
//
//  告警通知：告警规则 / 告警日志 / 发送方式设置
//  基于 logs/告警通知/告警通知.md、告警管理.md 抓包
//

import SwiftUI
import Combine

struct AlertNotificationView: View {
    @StateObject private var vm: AlertViewModel

    @State private var segment = 0
    @State private var showCreateRule = false
    @State private var editingRule: AlertRule?
    @State private var editingConfig: AlertConfigItem?
    @State private var showCreateConfig = false
    @State private var selectedLog: AlertLog?

    /// 无发送方式时点击「创建告警」的提示
    @State private var showNoConfigAlert = false

    init(server: ServerConfig) {
        _vm = StateObject(wrappedValue: AlertViewModel(server: server))
    }

    var body: some View {
        List {
            Section {
                segmentPicker
            }
            switch segment {
            case 0: ruleContent
            case 1: logContent
            default: configContent
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            switch segment {
            case 0: await vm.loadRules()
            case 1: await vm.loadLogs()
            default:
                await vm.loadConfigs()
                await vm.loadCommonConfig()
            }
        }
        .navigationTitle(L10n.t("告警通知"))
        .navigationBarTitleDisplayMode(.inline)
        // 右下角悬浮创建按钮（日志段不显示），样式与计划任务页一致
        .overlay(alignment: .bottomTrailing) {
            if segment != 1 {
                FloatingActionButton {
                    if segment == 2 {
                        showCreateConfig = true
                    } else if vm.configs.isEmpty {
                        showNoConfigAlert = true
                    } else {
                        showCreateRule = true
                    }
                }
                .accessibilityLabel(segment == 2 ? L10n.t("添加发送方式") : L10n.t("创建告警"))
            }
        }
        .alert(L10n.t("无法创建告警"), isPresented: $showNoConfigAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(L10n.t("请先在「设置」中配置至少一个告警发送方式"))
        }
        .alert(L10n.t("删除告警"), isPresented: Binding(
            get: { vm.pendingDeleteRule != nil },
            set: { if !$0 { vm.pendingDeleteRule = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { vm.pendingDeleteRule = nil }
            Button(L10n.t("删除"), role: .destructive) {
                if let rule = vm.pendingDeleteRule {
                    Task { await vm.delete(rule: rule) }
                }
            }
        } message: {
            Text(L10n.f("确定删除告警「%@」吗？", vm.pendingDeleteRule?.title ?? ""))
        }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
        Text(vm.alertMessage)
        }
        .alert(L10n.t("删除发送方式"), isPresented: Binding(
            get: { vm.pendingDeleteConfig != nil },
            set: { if !$0 { vm.pendingDeleteConfig = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { vm.pendingDeleteConfig = nil }
            Button(L10n.t("删除"), role: .destructive) {
                if let config = vm.pendingDeleteConfig {
                    Task { await vm.deleteConfig(config) }
                }
            }
        } message: {
            Text(L10n.f("确定删除「%@」吗？使用该方式的告警将无法发送通知", vm.pendingDeleteConfig?.sendConfig.displayName ?? vm.pendingDeleteConfig?.type ?? ""))
        }
        .toastOverlay(message: $vm.toastMessage)
        .sheet(item: $selectedLog) { log in
            AlertLogDetailView(log: log)
        }
        .navigationDestination(isPresented: $showCreateRule) {
            AlertEditView(vm: vm, editing: nil)
        }
        .navigationDestination(isPresented: Binding(
            get: { editingRule != nil },
            set: { if !$0 { editingRule = nil } }
        )) {
            if let rule = editingRule {
                AlertEditView(vm: vm, editing: rule)
            }
        }
        .navigationDestination(isPresented: $showCreateConfig) {
            AlertSendMethodEditView(vm: vm, editing: nil)
        }
        .navigationDestination(isPresented: Binding(
            get: { editingConfig != nil },
            set: { if !$0 { editingConfig = nil } }
        )) {
            if let config = editingConfig {
                AlertSendMethodEditView(vm: vm, editing: config)
            }
        }
        .task { await vm.refreshAll() }
    }

    // MARK: - 段切换（List 首个 Section，与监控/证书详情一致）

    private var segmentPicker: some View {
        Picker(L10n.t("模块"), selection: $segment) {
            Text(L10n.t("告警")).tag(0)
            Text(L10n.t("日志")).tag(1)
            Text(L10n.t("设置")).tag(2)
        }
        .pickerStyle(.segmented)
        .segmentedPickerRow()
        .listRowSeparator(.hidden)
    }

    // MARK: - 告警规则列表

    @ViewBuilder
    private var ruleContent: some View {
        if vm.isLoading && vm.rules.isEmpty {
            Section {
                HStack { Spacer(); LoadingStateView(); Spacer() }
                    .padding(.vertical, 30)
            }
        } else if let err = vm.errorMessage, !err.isEmpty, vm.rules.isEmpty {
            Section {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button(L10n.t("重试")) {
                        Task { await vm.loadRules() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 30)
            }
        } else if vm.rules.isEmpty {
            Section {
                ContentUnavailableView(
                    L10n.t("暂无告警规则"),
                    systemImage: "bell.slash",
                    description: Text(L10n.t("点击右下角创建第一个告警"))
                )
                .padding(.vertical, 30)
            }
        } else {
            Section {
                ForEach(vm.rules) { rule in
                    Button {
                        editingRule = rule
                    } label: {
                        AlertRuleRow(rule: rule)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            vm.pendingDeleteRule = rule
                        } label: {
                            Label(L10n.t("删除"), systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    // MARK: - 告警日志列表

    @ViewBuilder
    private var logContent: some View {
        if vm.isLoadingLogs && vm.logs.isEmpty {
            Section {
                HStack { Spacer(); LoadingStateView(); Spacer() }
                    .padding(.vertical, 30)
            }
        } else if vm.logs.isEmpty {
            Section {
                ContentUnavailableView(
                    L10n.t("暂无告警日志"),
                    systemImage: "list.bullet.rectangle",
                    description: Text(L10n.t("告警触发发送后会在这里产生记录"))
                )
                .padding(.vertical, 30)
            }
        } else {
            Section {
                ForEach(vm.logs) { log in
                    Button {
                        selectedLog = log
                    } label: {
                        AlertLogRow(log: log)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 发送方式列表（设置）

    @ViewBuilder
    private var configContent: some View {
        if vm.isLoadingConfigs && vm.configs.isEmpty && vm.commonConfig == nil {
            Section {
                HStack { Spacer(); LoadingStateView(); Spacer() }
                    .padding(.vertical, 30)
            }
        } else if vm.configs.isEmpty && vm.commonConfig == nil {
            Section {
                ContentUnavailableView(
                    L10n.t("暂无发送方式"),
                    systemImage: "envelope.badge",
                    description: Text(L10n.t("配置邮箱、Bark 等发送方式后才能创建告警"))
                )
                .padding(.vertical, 30)
            }
        } else {
            if let common = vm.commonConfig {
                Section {
                    NavigationLink {
                        AlertGlobalConfigView(vm: vm, item: common)
                    } label: {
                        HStack(spacing: 12) {
                            IconBadge(systemName: "gearshape", color: .gray)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.t("全局配置"))
                                    .font(.body.bold())
                                Text(globalConfigSubtitle(common))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section {
                ForEach(vm.configs) { config in
                    configRow(config)
                }
            } header: {
                Text(L10n.t("发送方式"))
            } footer: {
                Text(L10n.t("触发告警时通过发送方式通知，左滑可停用或删除"))
            }
        }
    }

    /// 发送方式行：邮箱 / Bark 可点击编辑，其余类型仅展示；均支持左滑停用/删除
    private func configRow(_ config: AlertConfigItem) -> some View {
        Group {
            if AlertSendType(rawValue: config.type ?? "") != nil {
                Button {
                    editingConfig = config
                } label: {
                    AlertConfigRow(config: config)
                }
                .buttonStyle(.plain)
            } else {
                AlertConfigRow(config: config)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                vm.pendingDeleteConfig = config
            } label: {
                Label(L10n.t("删除"), systemImage: "trash")
            }

            Button {
                Task { await vm.toggleConfig(config) }
            } label: {
                Label(
                    config.isEnabled ? L10n.t("停用") : L10n.t("启用"),
                    systemImage: config.isEnabled ? "pause.circle" : "play.circle"
                )
            }
            .tint(.orange)
        }
    }

    /// 全局配置行副标题：通知 / 资源告警的可发送时间范围
    private func globalConfigSubtitle(_ item: AlertConfigItem) -> String {
        let range = item.commonConfig.alertSendTimeRange
        let notice = range?.noticeAlert?.sendTimeRange ?? "—"
        let resource = range?.resourceAlert?.sendTimeRange ?? "—"
        return L10n.f("通知 %@ · 资源 %@", notice, resource)
    }
}

// MARK: - 规则行

struct AlertRuleRow: View {
    let rule: AlertRule

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: rule.alertType.icon, color: rule.alertType.color)

            VStack(alignment: .leading, spacing: 4) {
                Text(rule.title ?? rule.alertType.displayName)
                    .font(.body.bold())
                    .lineLimit(1)

                HStack(spacing: 6) {
                    StatusBadge(text: rule.alertType.displayName, color: rule.alertType.color)
                    StatusBadge(
                        text: rule.isEnabled ? L10n.t("启用") : L10n.t("已停用"),
                        color: rule.isEnabled ? .green : .secondary                    )
                }

                Text(rule.conditionDisplay)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

// MARK: - 日志行

struct AlertLogRow: View {
    let log: AlertLog

    var body: some View {
        HStack(spacing: 12) {
                StatusDot(color: log.isSuccess ? .green : .red, diameter: 10)

            VStack(alignment: .leading, spacing: 4) {
                Text(log.alertDetail?.title ?? log.alertType.displayName)
                    .font(.subheadline.bold())
                    .lineLimit(1)

                HStack(spacing: 6) {
                    StatusBadge(text: log.alertType.displayName, color: log.alertType.color)
                    if let message = log.message, !message.isEmpty {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(alertTimeDisplay(log.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(log.isSuccess ? L10n.t("成功") : L10n.t("失败"))
                    .font(.caption2.bold())
                    .foregroundStyle(log.isSuccess ? .green : .red)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - 发送方式行

struct AlertConfigRow: View {
    let config: AlertConfigItem

    private var sendType: AlertSendType? {
        AlertSendType(rawValue: config.type ?? "")
    }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(
                systemName: sendType?.icon ?? "bell.badge",
                color: sendType?.color ?? .gray
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(config.sendConfig.displayName ?? sendType?.displayName ?? (config.type ?? L10n.t("未知")))
                    .font(.body.bold())
                    .lineLimit(1)

                Text(sendType?.displayName ?? (config.type ?? L10n.t("未知")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatusBadge(
                text: config.isEnabled ? L10n.t("启用") : L10n.t("已停用"),
                color: config.isEnabled ? .green : .secondary            )

            if sendType != nil {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        // List 内 plain 按钮需声明整行为点击热区，否则只有文字/图标可点
        .contentShape(Rectangle())
    }
}

// MARK: - 日志详情

struct AlertLogDetailView: View {
    let log: AlertLog
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(L10n.t("发送信息")) {
                    InfoRow(key: L10n.t("告警"), value: log.alertDetail?.title ?? log.alertType.displayName)
                    InfoRow(key: L10n.t("类型"), value: log.alertType.displayName)
                    InfoRow(key: L10n.t("状态"), value: log.isSuccess ? L10n.t("成功") : L10n.t("失败"))
                    if let message = log.message, !message.isEmpty {
                        InfoRow(key: L10n.t("信息"), value: message)
                    }
                    if let project = log.alertDetail?.project, !project.isEmpty {
                        InfoRow(key: L10n.t("对象"), value: project)
                    }
                    InfoRow(key: L10n.t("触发时间"), value: alertTimeDisplay(log.createdAt))
                }

                if let params = log.alertDetail?.params, !params.isEmpty {
                    Section(L10n.t("告警参数")) {
                        ForEach(params) { param in
                            InfoRow(key: param.key ?? "—", value: param.value ?? "—")
                        }
                    }
                }

                if let rule = log.alertRule {
                    Section(L10n.t("关联规则")) {
                        InfoRow(key: L10n.t("标题"), value: rule.title ?? "—")
                        InfoRow(key: L10n.t("剩余天数"), value: rule.cycle.map { L10n.f("%ld 天", $0) } ?? "—")
                        InfoRow(key: L10n.t("状态"), value: rule.isEnabled ? L10n.t("启用") : L10n.t("停用"))
                    }
                }
            }
            .navigationTitle(L10n.t("告警日志"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("完成")) { dismiss() }
                }
            }
        }
    }
}

// MARK: - ViewModel

@MainActor
final class AlertViewModel: ObservableObject {
    @Published var rules: [AlertRule] = []
    @Published var logs: [AlertLog] = []
    @Published var configs: [AlertConfigItem] = []
    /// 全局配置（type == "common"，可发送时间范围）
    @Published var commonConfig: AlertConfigItem?

    @Published var isLoading = false
    @Published var isLoadingLogs = false
    @Published var isLoadingConfigs = false
    @Published var errorMessage: String?

    @Published var showAlert = false
    @Published var alertMessage = ""

    /// 轻量提示（自动消失，无需确认）
    @Published var toastMessage: String?
    private var toastTask: Task<Void, Never>?

    /// 列表删除确认
    @Published var pendingDeleteRule: AlertRule?
    @Published var pendingDeleteConfig: AlertConfigItem?

    /// 创建告警时的证书 / 网站 / 磁盘下拉选项
    @Published var sslOptions: [AlertSSLOption] = []
    @Published var websiteOptions: [AlertWebsiteOption] = []
    @Published var diskOptions: [AlertDiskOption] = []
    @Published var isLoadingOptions = false

    private let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    func refreshAll() async {
        async let rules: Void = loadRules()
        async let configs: Void = loadConfigs()
        async let common: Void = loadCommonConfig()
        async let logs: Void = loadLogs()
        _ = await (rules, configs, common, logs)
    }

    // MARK: 查询

    func loadRules() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let resp: PageResponse<AlertRule> = try await client.send(
                path: APIEndpoint.alertSearch.path,
                body: AlertSearchRequest(),
                as: PageResponse<AlertRule>.self
            )
            rules = resp.items ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadLogs() async {
        isLoadingLogs = true
        defer { isLoadingLogs = false }
        do {
            let resp: PageResponse<AlertLog> = try await client.send(
                path: APIEndpoint.alertLogsSearch.path,
                body: AlertLogSearchRequest(),
                as: PageResponse<AlertLog>.self
            )
            logs = resp.items ?? []
        } catch {
            // 日志加载失败不打断主流程，列表保持为空
        }
    }

    func loadConfigs() async {
        isLoadingConfigs = true
        defer { isLoadingConfigs = false }
        do {
            let resp: PageResponse<AlertConfigItem> = try await client.send(
                path: APIEndpoint.alertConfigSearch.path,
                body: AlertConfigSearchRequest(),
                as: PageResponse<AlertConfigItem>.self
            )
            configs = resp.items ?? []
        } catch {
            // 静默失败：设置段列表为空时会给出空态提示
        }
    }

    /// 全局配置不含在 config/search 结果中，需从 config/info 单独取（type == "common"）
    func loadCommonConfig() async {
        do {
            let items: [AlertConfigItem] = try await client.send(
                path: APIEndpoint.alertConfigInfo.path,
                body: AlertConfigSearchRequest(),
                as: [AlertConfigItem].self
            )
            commonConfig = items.first(where: { $0.type == "common" })
        } catch {
            // 静默失败：无全局配置时设置段不显示该入口
        }
    }

    /// 加载创建告警所需的对象下拉（证书 / 网站 / 磁盘），按需加载一次
    func loadOptions(for type: AlertType) async {
        guard type.needsProject || type.isDisk else { return }
        if type.isDisk {
            guard diskOptions.isEmpty else { return }
            isLoadingOptions = true
            defer { isLoadingOptions = false }
            do {
                diskOptions = try await client.send(
                    path: APIEndpoint.alertDisksList.path,
                    method: "GET",
                    as: [AlertDiskOption].self
                )
            } catch {
                diskOptions = []
            }
            return
        }
        if type == .ssl {
            guard sslOptions.isEmpty else { return }
            isLoadingOptions = true
            defer { isLoadingOptions = false }
            do {
                sslOptions = try await client.send(
                    path: APIEndpoint.websitesSSLSearch.path,
                    body: EmptyRequest(),
                    as: [AlertSSLOption].self
                )
            } catch {
                sslOptions = []
            }
        } else {
            guard websiteOptions.isEmpty else { return }
            isLoadingOptions = true
            defer { isLoadingOptions = false }
            do {
                websiteOptions = try await client.send(
                    path: APIEndpoint.logsWebsitesList.path,
                    method: "GET",
                    as: [AlertWebsiteOption].self
                )
            } catch {
                websiteOptions = []
            }
        }
    }

    // MARK: 规则增删改

    func delete(rule: AlertRule) async {
        pendingDeleteRule = nil
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.alertDelete.path,
                body: AlertDeleteRequest(id: rule.id),
                as: EmptyResponse.self
            )
            showToast(L10n.f("告警「%@」已删除", rule.title ?? ""))
            await loadRules()
        } catch let err as APIError {
            showAlert(message: L10n.f("删除失败：%@", err.errorDescription ?? L10n.t("未知错误")))
        } catch {
            showAlert(message: L10n.f("删除失败：%@", error.localizedDescription))
        }
    }

    @discardableResult
    func upsert(_ req: AlertUpsertRequest) async -> Bool {
        let isCreate = req.id == nil
        do {
            let _: EmptyResponse = try await client.send(
                path: isCreate ? APIEndpoint.alertCreate.path : APIEndpoint.alertUpdate.path,
                body: req,
                as: EmptyResponse.self
            )
            showToast(isCreate ? L10n.t("告警已创建") : L10n.t("告警已更新"))
            await loadRules()
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("%@失败：%@", isCreate ? L10n.t("创建") : L10n.t("更新"), err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("%@失败：%@", isCreate ? L10n.t("创建") : L10n.t("更新"), error.localizedDescription))
            return false
        }
    }

    // MARK: 发送方式

    /// 测试邮箱配置（POST /api/v2/alert/config/test，返回 true 表示发送成功）
    @discardableResult
    func testEmail(_ req: AlertEmailTestRequest) async -> Bool {
        do {
            let success: Bool = try await client.send(
                path: APIEndpoint.alertConfigTest.path,
                body: req,
                as: Bool.self
            )
            if success {
                showToast(L10n.t("测试邮件已发送，请查收"))
            } else {
                showAlert(message: L10n.t("测试发送失败，请检查配置"))
            }
            return success
        } catch let err as APIError {
            showAlert(message: L10n.f("测试失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("测试失败：%@", error.localizedDescription))
            return false
        }
    }

    @discardableResult
    func saveConfig(_ req: AlertConfigUpdateRequest, successMessage: String? = nil) async -> Bool {
        let isCreate = req.id == nil
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.alertConfigUpdate.path,
                body: req,
                as: EmptyResponse.self
            )
            showToast(successMessage ?? (isCreate ? L10n.t("发送方式已添加") : L10n.t("发送方式已更新")))
            if req.type == "common" {
                await loadCommonConfig()
            } else {
                await loadConfigs()
            }
            return true
        } catch let err as APIError {
            showAlert(message: L10n.f("保存失败：%@", err.errorDescription ?? L10n.t("未知错误")))
            return false
        } catch {
            showAlert(message: L10n.f("保存失败：%@", error.localizedDescription))
            return false
        }
    }

    /// 启用/停用发送方式：原 config 原样回传，仅翻转 status（对齐官方请求）
    func toggleConfig(_ item: AlertConfigItem) async {
        let req = AlertConfigUpdateRequest(
            id: item.id,
            type: item.type ?? "",
            title: item.title ?? "",
            status: item.isEnabled ? "Disable" : "Enable",
            config: item.config ?? "",
            displayName: item.sendConfig.displayName ?? item.title ?? ""
        )
        let name = req.displayName ?? L10n.t("发送方式")
        await saveConfig(req, successMessage: item.isEnabled ? L10n.f("已停用「%@」", name) : L10n.f("已启用「%@」", name))
    }

    func deleteConfig(_ item: AlertConfigItem) async {
        pendingDeleteConfig = nil
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.alertConfigDelete.path,
                body: AlertConfigDeleteRequest(id: item.id),
                as: EmptyResponse.self
            )
            showToast(L10n.t("发送方式已删除"))
            await loadConfigs()
        } catch let err as APIError {
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

    func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { self?.toastMessage = nil }
        }
    }
}
