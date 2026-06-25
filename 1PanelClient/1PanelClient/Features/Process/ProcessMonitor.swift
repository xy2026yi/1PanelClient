//
//  ProcessMonitor.swift
//  1PanelClient
//
//  系统进程监控：通过 WebSocket 连接 1Panel 进程接口
//  ws://host/api/v2/process/ws?operateNode=local
//  发送 {"type":"ps","username":"","name":""} → 接收进程列表 JSON
//

import Foundation
import CryptoKit
import Combine

// MARK: - 进程数据模型

struct ProcessItem: Decodable, Identifiable, Hashable {
    let pid: Int
    let name: String
    let ppid: Int
    let username: String
    let status: String
    let startTime: String?
    let numThreads: Int?
    let numConnections: Int?
    let cpuPercent: String?
    let cpuValue: Double?
    let rss: String?
    let rssValue: Int?
    let cmdLine: String?
    let diskRead: String?
    let diskWrite: String?

    enum CodingKeys: String, CodingKey {
        case pid = "PID"
        case name, ppid = "PPID", username, status
        case startTime, numThreads, numConnections
        case cpuPercent, cpuValue, rss, rssValue
        case cmdLine, diskRead, diskWrite
    }

    var id: Int { pid }

    var statusColor: String {
        switch status.lowercased() {
        case "running": return "green"
        case "sleep", "sleeping": return "blue"
        case "idle": return "secondary"
        case "zombie": return "red"
        case "stop", "stopped": return "orange"
        default: return "secondary"
        }
    }
}

// MARK: - WebSocket 请求

private struct PSRequest: Encodable {
    let type: String
    let username: String
    let name: String
}

// MARK: - 进程监控会话

@MainActor
final class ProcessMonitor: ObservableObject {
    @Published private(set) var processes: [ProcessItem] = []
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published var isAutoRefresh = true
    @Published var errorMessage: String?

    private let server: ServerConfig
    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private var receiveTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    /// 刷新间隔（秒）
    private let refreshInterval: UInt64 = 3

    init(server: ServerConfig) {
        self.server = server
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    deinit {
        receiveTask?.cancel()
        refreshTask?.cancel()
        pingTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - 认证 header

    private func authHeaders() -> [String: String] {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let raw = "1panel" + server.apiKey + timestamp
        let digest = Insecure.MD5.hash(data: Data(raw.utf8))
        let token = digest.map { String(format: "%02x", $0) }.joined()
        return [
            "1Panel-Token": token,
            "1Panel-Timestamp": timestamp
        ]
    }

    // MARK: - 构造 ws URL

    private func makeWebSocketURL() -> URL? {
        let base = server.normalizedBaseURL
        guard var comp = URLComponents(string: base) else { return nil }
        if comp.scheme == "https" { comp.scheme = "wss" }
        else { comp.scheme = "ws" }
        comp.path = "/api/v2/process/ws"
        comp.queryItems = [URLQueryItem(name: "operateNode", value: "local")]
        return comp.url
    }

    // MARK: - 连接 / 断开

    func connect() {
        guard !isConnecting, !isConnected else { return }
        guard let url = makeWebSocketURL() else {
            errorMessage = "无法构造进程监控连接地址"
            return
        }
        var request = URLRequest(url: url)
        for (k, v) in authHeaders() {
            request.setValue(v, forHTTPHeaderField: k)
        }

        isConnecting = true
        errorMessage = nil

        let ws = session.webSocketTask(with: request)
        ws.resume()
        task = ws

        // 用 ping 探测连接是否就绪，就绪后立即发送 ps 请求
        ws.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.handleDisconnect(error: error)
                    return
                }
                self.isConnecting = false
                self.isConnected = true
                self.requestProcesses()
                self.startAutoRefresh()
            }
        }

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        pingTask = Task { [weak self] in
            await self?.pingLoop()
        }
    }

    func disconnect() {
        refreshTask?.cancel()
        receiveTask?.cancel()
        pingTask?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        isConnected = false
        isConnecting = false
        processes = []
    }

    // MARK: - 发送 ps 请求

    func requestProcesses(username: String = "", name: String = "") {
        guard let task else { return }
        let req = PSRequest(type: "ps", username: username, name: name)
        guard let data = try? JSONEncoder().encode(req),
              let str = String(data: data, encoding: .utf8) else { return }
        Task {
            do { try await task.send(.string(str)) }
            catch { /* 静默 */ }
        }
    }

    // MARK: - 接收循环

    private func receiveLoop() async {
        guard let task else { return }
        var firstPacket = true
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
                if firstPacket {
                    firstPacket = false
                    isConnecting = false
                    isConnected = true
                    requestProcesses()
                    startAutoRefresh()
                }
                handleMessage(msg)
            } catch {
                if !Task.isCancelled {
                    handleDisconnect(error: error)
                }
                break
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseProcesses(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseProcesses(text)
            }
        @unknown default:
            break
        }
    }

    private func parseProcesses(_ text: String) {
        guard let jsonData = text.data(using: .utf8) else { return }
        do {
            let decoded = try JSONDecoder().decode([ProcessItem].self, from: jsonData)
            processes = decoded.sorted { ($0.cpuValue ?? 0) > ($1.cpuValue ?? 0) }
        } catch {
            // 非 JSON 数组帧（如心跳），忽略
        }
    }

    private func handleDisconnect(error: Error) {
        isConnected = false
        isConnecting = false
        refreshTask?.cancel()
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .cannotConnectToHost:
                errorMessage = "无法连接到主机"
            case .timedOut:
                errorMessage = "连接超时"
            case .networkConnectionLost:
                errorMessage = "网络连接已断开"
            default:
                errorMessage = "连接已断开：\(urlErr.localizedDescription)"
            }
        } else {
            errorMessage = "连接已断开：\(error.localizedDescription)"
        }
    }

    // MARK: - 自动刷新

    private func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.refreshInterval ?? 3))
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self?.requestProcesses()
                }
            }
        }
    }

    // MARK: - 心跳

    private func pingLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled, let task else { break }
            task.sendPing { _ in }
        }
    }
}
