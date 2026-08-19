//
//  ServerHealthMonitor.swift
//  1PanelClient
//
//  服务器健康监测：定期对全部面板实例做轻量连通性探测（deviceBase 接口），
//  服务器列表以彩色徽标展示 在线/离线/未知，支持下拉手动刷新
//

import Foundation
import SwiftUI
import Combine

@MainActor
enum ServerHealth: Equatable {
    case unknown
    case checking
    /// message 含主机名（「连接成功：xxx」）
    case online(String)
    case offline(String)

    var label: String {
        switch self {
        case .unknown: return L10n.t("未检测")
        case .checking: return L10n.t("检测中")
        case .online: return L10n.t("在线")
        case .offline: return L10n.t("离线")
        }
    }
}

@MainActor
final class ServerHealthMonitor: ObservableObject {
    static let shared = ServerHealthMonitor()

    @Published private(set) var states: [UUID: ServerHealth] = [:]

    /// 自动轮询任务（60s 一轮，服务器页可见时启动）
    private var timerTask: Task<Void, Never>?

    private var servers: [ServerConfig] { ServerManager.shared.servers }

    func start() {
        guard timerTask == nil else { return }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkAll()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    /// 并发探测全部服务器；服务器增删后状态随之清理
    func checkAll() async {
        let targets = servers
        for id in states.keys where !targets.contains(where: { $0.id == id }) {
            states.removeValue(forKey: id)
        }
        guard !targets.isEmpty else { return }

        for s in targets { states[s.id] = .checking }

        await withTaskGroup(of: (UUID, ServerHealth).self) { [weak self] group in
            for s in targets {
                group.addTask {
                    // ConnectionTester 仅做一次轻量请求，不动业务模型
                    let (ok, msg) = await ConnectionTester.test(s)
                    return (s.id, ok ? .online(msg) : .offline(msg))
                }
            }
            for await (id, state) in group {
                self?.states[id] = state
            }
        }
    }

    func state(for id: UUID) -> ServerHealth {
        states[id] ?? .unknown
    }
}
