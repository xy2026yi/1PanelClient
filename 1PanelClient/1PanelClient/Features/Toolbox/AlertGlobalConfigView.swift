//
//  AlertGlobalConfigView.swift
//  1PanelClient
//
//  告警全局配置：通知告警 / 资源告警的可发送时间范围
//  基于 logs/告警通知/新增告警设置管理.md 抓包（type == "common"）
//

import SwiftUI

struct AlertGlobalConfigView: View {
    @ObservedObject var vm: AlertViewModel
    /// type == "common" 的配置项
    let item: AlertConfigItem
    @Environment(\.dismiss) private var dismiss

    @State private var noticeStart = Calendar.current.date(from: DateComponents(hour: 8)) ?? Date()
    @State private var noticeEnd = Calendar.current.date(from: DateComponents(hour: 23, minute: 59)) ?? Date()
    @State private var resourceStart = Calendar.current.date(from: DateComponents(hour: 0)) ?? Date()
    @State private var resourceEnd = Calendar.current.date(from: DateComponents(hour: 23, minute: 59)) ?? Date()

    /// 各边界保留原秒数（如 07:00:00 的 00、23:59:59 的 59）
    @State private var noticeStartSec = 0
    @State private var noticeEndSec = 59
    @State private var resourceStartSec = 0
    @State private var resourceEndSec = 59
    /// 原始配置：保存时原样保留 isOffline 与覆盖类型列表
    @State private var original = AlertCommonConfig()
    @State private var isSaving = false
    @State private var didFill = false

    var body: some View {
        Form {
            Section {
                DatePicker("开始时间", selection: $noticeStart, displayedComponents: .hourAndMinute)
                DatePicker("结束时间", selection: $noticeEnd, displayedComponents: .hourAndMinute)
            } header: {
                Text("通知告警")
            } footer: {
                Text("面板密码 / 证书 / 网站到期、面板更新等通知类告警的可发送时间范围")
            }

            Section {
                DatePicker("开始时间", selection: $resourceStart, displayedComponents: .hourAndMinute)
                DatePicker("结束时间", selection: $resourceEnd, displayedComponents: .hourAndMinute)
            } header: {
                Text("资源告警")
            } footer: {
                Text("CPU / 内存 / 磁盘 / 负载、登录异常等资源类告警的可发送时间范围")
            }
        }
        .navigationTitle("全局配置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") {
                    Task {
                        isSaving = true
                        if await vm.saveConfig(buildRequest()) {
                            dismiss()
                        }
                        isSaving = false
                    }
                }
                .disabled(isSaving)
            }
        }
        .onAppear { fill() }
    }

    // MARK: - 预填

    private func fill() {
        guard !didFill else { return }
        didFill = true
        original = item.commonConfig
        guard let range = original.alertSendTimeRange else { return }
        if let notice = parseRange(range.noticeAlert?.sendTimeRange) {
            noticeStart = notice.start
            noticeStartSec = notice.startSec
            noticeEnd = notice.end
            noticeEndSec = notice.endSec
        }
        if let resource = parseRange(range.resourceAlert?.sendTimeRange) {
            resourceStart = resource.start
            resourceStartSec = resource.startSec
            resourceEnd = resource.end
            resourceEndSec = resource.endSec
        }
    }

    // MARK: - 请求构造

    private func buildRequest() -> AlertConfigUpdateRequest {
        var cfg = original
        var range = cfg.alertSendTimeRange ?? AlertSendTimeRange()
        range.noticeAlert = AlertTimeRangeItem(
            sendTimeRange: "\(timeString(noticeStart, seconds: noticeStartSec)) - \(timeString(noticeEnd, seconds: noticeEndSec))",
            type: range.noticeAlert?.type
        )
        range.resourceAlert = AlertTimeRangeItem(
            sendTimeRange: "\(timeString(resourceStart, seconds: resourceStartSec)) - \(timeString(resourceEnd, seconds: resourceEndSec))",
            type: range.resourceAlert?.type
        )
        cfg.alertSendTimeRange = range

        let json = (try? JSONEncoder().encode(cfg)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return AlertConfigUpdateRequest(
            id: item.id,
            type: "common",
            title: item.title ?? "xpack.alert.commonConfig",
            status: item.status ?? "Enable",
            config: json,
            displayName: "全局配置"
        )
    }

    // MARK: - 时间解析（"07:00:00 - 23:59:59"）

    private func parseRange(_ raw: String?) -> (start: Date, startSec: Int, end: Date, endSec: Int)? {
        guard let raw else { return nil }
        let parts = raw.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let start = parseTime(parts[0]),
              let end = parseTime(parts[1]) else { return nil }
        return (start.0, start.1, end.0, end.1)
    }

    private func parseTime(_ raw: String) -> (Date, Int)? {
        let comps = raw.split(separator: ":").compactMap { Int($0) }
        guard comps.count >= 2 else { return nil }
        var dc = DateComponents()
        dc.hour = comps[0]
        dc.minute = comps[1]
        guard let date = Calendar.current.date(from: dc) else { return nil }
        return (date, comps.count >= 3 ? comps[2] : 0)
    }

    private func timeString(_ date: Date, seconds: Int) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, seconds)
    }
}
