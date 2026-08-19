//
//  ServerStatusWidget.swift
//  PanelWidgets
//
//  服务器概览小组件：在线状态 + CPU / 内存 / 负载，30 分钟刷新。
//

import WidgetKit
import SwiftUI

struct StatusEntry: TimelineEntry {
    let date: Date
    let serverName: String
    let online: Bool
    let message: String?
    let cpu: Double?
    let memory: Double?
    let load1: Double?
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: .now, serverName: "1Panel", online: true,
                    message: nil, cpu: 12.5, memory: 45.0, load1: 0.8)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        Task {
            completion(await makeEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        Task {
            let entry = await makeEntry()
            // WidgetKit 对时间线的预算有限，30 分钟 + 系统自行裁量
            let next = Calendar.current.date(byAdding: .minute, value: 30, to: entry.date) ?? entry.date.addingTimeInterval(1800)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    @MainActor
    private func makeEntry() async -> StatusEntry {
        guard let server = WidgetServerStore.serverConfig(for: nil) else {
            return StatusEntry(date: .now, serverName: L10n.t("服务器"), online: false,
                               message: L10n.t("请先添加服务器"), cpu: nil, memory: nil, load1: nil)
        }
        let (ok, msg) = await ConnectionTester.test(server)
        var cpu: Double?
        var memory: Double?
        var load1: Double?
        if ok, let current = try? await IntentService.dashboardCurrent(server) {
            cpu = current.cpuUsedPercent
            memory = current.memoryUsedPercent
            load1 = current.load1
        }
        return StatusEntry(date: .now, serverName: server.name, online: ok,
                           message: ok ? nil : msg, cpu: cpu, memory: memory, load1: load1)
    }
}

struct ServerStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ServerStatusWidget", provider: StatusProvider()) { entry in
            ServerStatusEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(L10n.t("服务器状态"))
        .description(L10n.t("在线检查与 CPU / 内存 / 负载概览"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ServerStatusEntryView: View {
    let entry: StatusEntry

    var body: some View {
        if let message = entry.message, !entry.online {
            offlineView(message)
        } else {
            metricsView
        }
    }

    private var metricsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(entry.online ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(entry.serverName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }
            Spacer(minLength: 0)
            metricRow(L10n.t("CPU"), entry.cpu)
            metricRow(L10n.t("内存"), entry.memory)
            metricRow(L10n.t("负载"), entry.load1, percentStyle: false)
        }
        .padding(2)
    }

    private func offlineView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text(entry.serverName).font(.headline).lineLimit(1)
                Spacer()
            }
            Spacer(minLength: 0)
            Text(L10n.f("离线：%@", message))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(2)
    }

    private func metricRow(_ title: String, _ value: Double?, percentStyle: Bool = true) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value.map { percentStyle ? String(format: "%.1f%%", $0) : String(format: "%.2f", $0) } ?? "—")
                .font(.caption.monospacedDigit().weight(.medium))
        }
    }
}
