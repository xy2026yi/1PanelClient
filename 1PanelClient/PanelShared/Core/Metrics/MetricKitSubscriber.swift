//
//  MetricKitSubscriber.swift
//  1PanelClient
//
//  ADR-0002：MetricKit 本地诊断——payload 仅落盘，绝不联网上报。
//

import Foundation
import MetricKit

/// 订阅 MXMetricManager 的每日指标与崩溃/卡顿诊断，JSON 原样写入
/// `Application Support/Metrics/`，保留最近 30 天。
/// 零上报立场：数据不出设备，导出只能由用户在设置-关于-诊断数据里手动分享。
///
/// nonisolated（整个类型）：MXMetricManager 从自己的内部队列回调 didReceive，
/// 并不承诺主线程。项目默认 MainActor 隔离下，隔离的 @objc witness 会生成
/// executor 断言——后台队列回调即崩溃（Xcode 直跑基本不交付 payload 所以本地
/// 不可见，TestFlight/Ad-Hoc 分发版每日指标交付必现）。落盘走全静态无共享
/// 可变状态的 MetricStore，线程安全；顺带把磁盘 IO 留在回调线程不占主线程。
/// @unchecked Sendable：无可变实例状态（static let shared 需要）
nonisolated final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitSubscriber()
    /// 本地保留窗口（ADR-0002）
    static let retentionDays = 30

    private override init() {
        super.init()
    }

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        MetricStore.save(payloads, prefix: "metric") { $0.timeStampEnd }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        MetricStore.save(payloads, prefix: "diagnostic") { $0.timeStampEnd }
    }
}

/// payload 落盘/清理/列目录。文件名 `<前缀>-<时间戳>.json`。
/// nonisolated：需被 nonisolated 的 MetricKit 回调同步调用（全静态无共享可变状态）
nonisolated enum MetricStore {
    /// 本地保留窗口（ADR-0002）
    static let retentionDays = MetricKitSubscriber.retentionDays

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Metrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 写入后顺带清理过期文件
    static func save<T: NSObject>(
        _ payloads: [T], prefix: String, timestamp: (T) -> Date
    ) {
        for (i, payload) in payloads.enumerated() {
            let json: Data
            if let mx = payload as? MXMetricPayload { json = mx.jsonRepresentation() }
            else if let dx = payload as? MXDiagnosticPayload { json = dx.jsonRepresentation() }
            else { continue }
            let name = "\(prefix)-\(Int(timestamp(payload).timeIntervalSince1970))-\(i).json"
            try? json.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
        prune()
    }

    /// 删除超过保留窗口的文件
    static func prune(olderThan days: Int = retentionDays) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for url in files where url.pathExtension == "json" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if date < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// 按修改时间倒序列出已存 payload
    static func listFiles() -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }
    }
}
