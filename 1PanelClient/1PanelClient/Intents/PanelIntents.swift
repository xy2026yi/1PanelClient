//
//  PanelIntents.swift
//  1PanelClient
//
//  五个核心 Intent + App Shortcuts。
//  静态标题/参数文案用中文 key（系统语言经 Localizable 表自动出英文）；
//  运行时 dialog 走 L10n（跟随应用内语言设置）。
//

import AppIntents
import SwiftUI

// MARK: - 共享枚举

enum ContainerOperationAppEnum: String, AppEnum {
    case start, stop, restart, kill

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "容器操作"

    static var caseDisplayRepresentations: [ContainerOperationAppEnum: DisplayRepresentation] = [
        .start: "启动",
        .stop: "停止",
        .restart: "重启",
        .kill: "关闭",
    ]

    /// 提交给 1Panel API 的操作名
    var apiValue: String { rawValue }

    var displayName: String {
        switch self {
        case .start: return L10n.t("启动")
        case .stop: return L10n.t("停止")
        case .restart: return L10n.t("重启")
        case .kill: return L10n.t("关闭")
        }
    }
}

enum WebsiteToggleAppEnum: String, AppEnum {
    case start, stop

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "网站操作"

    static var caseDisplayRepresentations: [WebsiteToggleAppEnum: DisplayRepresentation] = [
        .start: "启动",
        .stop: "停止",
    ]

    var displayName: String {
        switch self {
        case .start: return L10n.t("启动")
        case .stop: return L10n.t("停止")
        }
    }
}

// MARK: - 检查服务器状态

struct CheckServerStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "检查服务器状态"
    static let description = IntentDescription("在线检查与 CPU / 内存 / 负载概览")

    @Parameter(title: "服务器", description: "留空使用当前服务器")
    var server: PanelServerEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("检查 \(\.$server) 的状态")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        let server = try resolveServer()
        let (ok, message) = await ConnectionTester.test(server)
        guard ok else {
            return .result(dialog: "\(L10n.f("离线：%@", message))", view: EmptyView())
        }
        let current = try? await IntentService.dashboardCurrent(server)
        let snippet = ServerStatusSnippet(serverName: server.name, current: current)
        let dialog = current != nil
            ? L10n.t("连接成功")
            : L10n.f("连接成功（%@ 数据暂不可用）", server.name)
        return .result(dialog: "\(dialog)", view: snippet)
    }
}

/// 概览 Snippet：CPU / 内存 / 负载三行卡片
struct ServerStatusSnippet: View {
    let serverName: String
    let current: DashboardCurrent?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(serverName)
                .font(.headline)
            if let c = current {
                LabeledContent(L10n.t("CPU"), value: percent(c.cpuUsedPercent))
                LabeledContent(L10n.t("内存"), value: percent(c.memoryUsedPercent))
                LabeledContent(L10n.t("负载"), value: load(c))
            } else {
                Text(L10n.t("暂无监控数据"))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func percent(_ v: Double?) -> String {
        v.map { String(format: "%.1f%%", $0) } ?? "—"
    }

    private func load(_ c: DashboardCurrent) -> String {
        [c.load1, c.load5, c.load15]
            .compactMap { $0 }
            .map { String(format: "%.2f", $0) }
            .joined(separator: " / ")
    }
}

// MARK: - 容器操作

struct OperateContainerIntent: AppIntent {
    static let title: LocalizedStringResource = "容器操作"
    static let description = IntentDescription("启动 / 停止 / 重启 / 关闭指定容器")

    @Parameter(title: "容器")
    var container: ContainerEntity

    @Parameter(title: "操作", default: .restart)
    var operation: ContainerOperationAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("对 \(\.$container) 进行 \(\.$operation) 操作")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let server = try resolveServerByID(container.serverID)
        try await IntentService.operateContainer(server, name: container.name,
                                                 operation: operation.apiValue)
        return .result(dialog: "\(L10n.f("%@容器「%@」任务已提交", operation.displayName, container.name))")
    }
}

// MARK: - 网站启停

struct ToggleWebsiteIntent: AppIntent {
    static let title: LocalizedStringResource = "网站启停"
    static let description = IntentDescription("启动或停止指定网站")

    @Parameter(title: "网站")
    var website: WebsiteEntity

    @Parameter(title: "操作", default: .start)
    var operation: WebsiteToggleAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("对 \(\.$website) 进行 \(\.$operation) 操作")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let server = try resolveServerByID(website.serverID)
        try await IntentService.operateWebsite(server, id: website.id,
                                               operate: operation.rawValue)
        return .result(dialog: "\(L10n.f("将对网站「%@」进行 %@ 操作，任务已提交", website.domain, operation.displayName))")
    }
}

// MARK: - 执行计划任务

struct RunCronjobIntent: AppIntent {
    static let title: LocalizedStringResource = "执行计划任务"
    static let description = IntentDescription("手动触发一次计划任务")

    @Parameter(title: "计划任务")
    var job: CronjobEntity

    static var parameterSummary: some ParameterSummary {
        Summary("立即执行 \(\.$job)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let server = try resolveServerByID(job.serverID)
        try await IntentService.runCronjob(server, id: job.id)
        return .result(dialog: "\(L10n.f("任务「%@」已开始执行", job.name))")
    }
}

// MARK: - 服务器概览（供自动化获取数值）

struct GetServerOverviewIntent: AppIntent {
    static let title: LocalizedStringResource = "服务器概览"
    static let description = IntentDescription("读取 CPU / 内存 / 负载的当前值")

    @Parameter(title: "服务器", description: "留空使用当前服务器")
    var server: PanelServerEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("读取 \(\.$server) 的概览")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let server = try resolveServer()
        let current = try await IntentService.dashboardCurrent(server)
        let cpu = current.cpuUsedPercent.map { String(format: "%.1f", $0) } ?? "—"
        let mem = current.memoryUsedPercent.map { String(format: "%.1f", $0) } ?? "—"
        let load1 = current.load1.map { String(format: "%.2f", $0) } ?? "—"
        let text = L10n.f("CPU %@%% · 内存 %@%% · 负载 %@", cpu, mem, load1)
        return .result(dialog: "\(text)")
    }
}

// MARK: - 服务器解析辅助

/// AppIntents 错误：以 dialog 形式向用户呈现，不中断快捷指令编辑
struct PanelIntentError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

@MainActor
func resolveServer(_ entity: PanelServerEntity? = nil) throws -> ServerConfig {
    if let entity,
       let server = IntentService.server(byID: entity.id) {
        return server
    }
    if let current = IntentService.currentServer() {
        return current
    }
    throw PanelIntentError(message: L10n.t("请先添加服务器"))
}

@MainActor
func resolveServerByID(_ id: UUID) throws -> ServerConfig {
    if let server = IntentService.server(byID: id) {
        return server
    }
    throw PanelIntentError(message: L10n.t("请先添加服务器"))
}

// MARK: - App Shortcuts

struct PanelShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CheckServerStatusIntent(),
            phrases: [
                "\(.applicationName) 服务器状态",
                "\(.applicationName) server status",
            ],
            shortTitle: "检查服务器状态",
            systemImageName: "server.rack"
        )
        AppShortcut(
            intent: OperateContainerIntent(),
            phrases: [
                "\(.applicationName) 重启容器",
                "\(.applicationName) restart container",
            ],
            shortTitle: "容器操作",
            systemImageName: "shippingbox"
        )
        AppShortcut(
            intent: RunCronjobIntent(),
            phrases: [
                "\(.applicationName) 执行计划任务",
                "\(.applicationName) run task",
            ],
            shortTitle: "执行计划任务",
            systemImageName: "clock.arrow.circlepath"
        )
    }
}
