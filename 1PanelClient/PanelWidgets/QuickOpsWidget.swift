//
//  QuickOpsWidget.swift
//  PanelWidgets
//
//  快捷操作小组件：可配置服务器，列出容器并提供重启/启停按钮。
//  按钮走 OperateContainerIntent（Widget 进程内执行，操作后系统自动刷新时间线）。
//

import WidgetKit
import SwiftUI
import AppIntents

// MARK: - 配置 Intent

struct QuickOpsConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "快捷操作"
    static var description = IntentDescription("选择服务器并列出可操作的容器")

    @Parameter(title: "服务器")
    var server: PanelServerEntity?
}

// MARK: - 时间线

struct QuickOpsEntry: TimelineEntry {
    let date: Date
    let serverName: String
    let containers: [ContainerEntity]
    let failure: String?

    var isConfigured: Bool { !serverName.isEmpty }
}

struct QuickOpsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuickOpsEntry {
        QuickOpsEntry(date: .now, serverName: "1Panel",
                      containers: [ContainerEntity(name: "nginx", state: "running",
                                                   imageName: nil, serverID: UUID())],
                      failure: nil)
    }

    func snapshot(for configuration: QuickOpsConfig, in context: Context) async -> QuickOpsEntry {
        await makeEntry(for: configuration)
    }

    func timeline(for configuration: QuickOpsConfig, in context: Context) async -> Timeline<QuickOpsEntry> {
        let entry = await makeEntry(for: configuration)
        let next = entry.date.addingTimeInterval(30 * 60)
        return Timeline(entries: [entry], policy: .after(next))
    }

    @MainActor
    private func makeEntry(for config: QuickOpsConfig) async -> QuickOpsEntry {
        guard let server = WidgetServerStore.serverConfig(for: config.server) else {
            return QuickOpsEntry(date: .now, serverName: "", containers: [], failure: nil)
        }
        do {
            let containers = try await IntentService.listContainers(server)
            let sorted = containers
                .sorted { ($0.isFromApp ?? false ? 1 : 0, $0.displayName) < ($1.isFromApp ?? false ? 1 : 0, $1.displayName) }
            return QuickOpsEntry(date: .now, serverName: server.name,
                                 containers: sorted.prefix(6).map { ContainerEntity(container: $0, serverID: server.id) },
                                 failure: nil)
        } catch {
            return QuickOpsEntry(date: .now, serverName: server.name, containers: [],
                                 failure: error.localizedDescription)
        }
    }
}

// MARK: - Widget

struct QuickOpsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "QuickOpsWidget",
                               intent: QuickOpsConfig.self,
                               provider: QuickOpsProvider()) { entry in
            QuickOpsEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(L10n.t("容器操作"))
        .description(L10n.t("启动 / 停止 / 重启 / 关闭指定容器"))
        .supportedFamilies([.systemMedium])
    }
}

struct QuickOpsEntryView: View {
    let entry: QuickOpsEntry

    var body: some View {
        if !entry.isConfigured {
            unconfiguredView
        } else if let failure = entry.failure {
            Text(L10n.f("离线：%@", failure))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if entry.containers.isEmpty {
            Text(L10n.t("暂无容器"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            containerList
        }
    }

    private var unconfiguredView: some View {
        VStack(spacing: 6) {
            Image(systemName: "server.rack")
                .font(.title2)
            Text(L10n.t("请先添加服务器"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var containerList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.serverName).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(L10n.t("容器")).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(entry.containers, id: \.name) { container in
                row(container)
            }
        }
        .padding(2)
    }

    private func row(_ container: ContainerEntity) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(container.state == "running" ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
            Text(container.name)
                .font(.caption2)
                .lineLimit(1)
            Spacer(minLength: 4)
            // 交互按钮：在 Widget 进程执行 intent，完成后 WidgetKit 自动刷新
            Button(intent: restartIntent(container)) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    private func restartIntent(_ container: ContainerEntity) -> OperateContainerIntent {
        let intent = OperateContainerIntent()
        intent.container = container
        intent.operation = .restart
        return intent
    }
}
