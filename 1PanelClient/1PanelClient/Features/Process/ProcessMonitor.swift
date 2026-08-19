//
//  ProcessMonitor.swift
//  1PanelClient
//
//  系统进程监控：通过 WebSocket 连接 1Panel 进程接口
//  ws://host/api/v2/process/ws?operateNode=local
//  发送 {"type":"ps","username":"","name":""} → 接收进程列表 JSON
//  发送 {"type":"net","processName":""} → 接收网络连接列表 JSON
//  POST /api/v2/process/stop {"PID":123} → 结束进程
//

import Foundation
import CryptoKit
import Combine
import SwiftUI

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
}

// MARK: - 网络连接模型

struct NetworkConnection: Decodable, Identifiable, Hashable {
    let type: String       // tcp / tcp6 / udp / udp6
    let status: String     // LISTEN / ESTABLISHED / NONE
    let localaddr: Addr
    let remoteaddr: Addr
    let pid: Int
    let name: String

    struct Addr: Decodable, Hashable {
        let ip: String
        let port: Int
    }

    enum CodingKeys: String, CodingKey {
        case type, status, localaddr, remoteaddr
        case pid = "PID"
        case name
    }

    var id: String { "\(type)-\(pid)-\(localaddr.ip):\(localaddr.port)-\(remoteaddr.ip):\(remoteaddr.port)" }

    var typeColor: Color {
        switch type {
        case "tcp":  return .blue
        case "tcp6": return .indigo
        case "udp":  return .teal
        case "udp6": return .mint
        default:     return .secondary
        }
    }
}

// MARK: - WebSocket 请求

private struct WSRequest: Encodable {
    let type: String
    let username: String?
    let name: String?
    let processName: String?
}

// MARK: - 结束进程请求

struct StopProcessRequest: Encodable {
    let pid: Int
    enum CodingKeys: String, CodingKey {
        case pid = "PID"
    }
}

// MARK: - 进程监控会话

@MainActor
final class ProcessMonitor: ObservableObject {
    @Published private(set) var processes: [ProcessItem] = []
    @Published private(set) var connections: [NetworkConnection] = []
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isStopping = false
    @Published var mode: MonitorMode = .processes {
        didSet { requestCurrent() }
    }
    @Published var isAutoRefresh = true
    @Published var errorMessage: String?
    @Published var successMessage: String?

    enum MonitorMode: String, CaseIterable, Identifiable {
        case processes = "进程"
        case network = "网络"
        var id: String { rawValue }
    }

    private let server: ServerConfig
    private let apiClient: APIClient
    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private var receiveTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    private let refreshInterval: UInt64 = 3

    init(server: ServerConfig) {
        self.server = server
        self.apiClient = APIClient(server: server)
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
            errorMessage = L10n.t("无法构造进程监控连接地址")
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

        ws.sendPing { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    self.handleDisconnect(error: error)
                    return
                }
                self.isConnecting = false
                self.isConnected = true
                self.requestCurrent()
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
        connections = []
    }

    // MARK: - 发送请求

    func requestCurrent() {
        switch mode {
        case .processes: requestProcesses()
        case .network:   requestNetwork()
        }
    }

    func requestProcesses(username: String = "", name: String = "") {
        guard let task else { return }
        let req = WSRequest(type: "ps", username: username, name: name, processName: nil)
        sendWS(task, req)
    }

    func requestNetwork(processName: String = "") {
        guard let task else { return }
        let req = WSRequest(type: "net", username: nil, name: nil, processName: processName)
        sendWS(task, req)
    }

    private func sendWS(_ task: URLSessionWebSocketTask, _ req: WSRequest) {
        guard let data = try? JSONEncoder().encode(req),
              let str = String(data: data, encoding: .utf8) else { return }
        Task {
            do { try await task.send(.string(str)) }
            catch { /* 静默 */ }
        }
    }

    // MARK: - 结束进程

    func stopProcess(pid: Int) async {
        isStopping = true
        errorMessage = nil
        successMessage = nil
        defer { isStopping = false }
        let req = StopProcessRequest(pid: pid)
        do {
            let _: EmptyResponse = try await apiClient.send(
                path: APIEndpoint.processStop.path, body: req, as: EmptyResponse.self
            )
            successMessage = L10n.f("进程 %ld 已结束", pid)
            requestCurrent()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 接收循环

    private func receiveLoop() async {
        guard let task else { return }
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
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
            parseResponse(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseResponse(text)
            }
        @unknown default:
            break
        }
    }

    /// 区分进程列表 vs 网络连接：检查首元素是否含 "type" 键
    private func parseResponse(_ text: String) {
        guard let jsonData = text.data(using: .utf8) else { return }
        guard let array = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]],
              let first = array.first else { return }

        if first["type"] != nil {
            if let decoded = try? JSONDecoder().decode([NetworkConnection].self, from: jsonData) {
                connections = decoded.sorted { $0.name < $1.name }
            }
        } else {
            if let decoded = try? JSONDecoder().decode([ProcessItem].self, from: jsonData) {
                processes = decoded.sorted { ($0.cpuValue ?? 0) > ($1.cpuValue ?? 0) }
            }
        }
    }

    private func handleDisconnect(error: Error) {
        isConnected = false
        isConnecting = false
        refreshTask?.cancel()
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .cannotConnectToHost:
                errorMessage = L10n.t("无法连接到主机")
            case .timedOut:
                errorMessage = L10n.t("连接超时")
            case .networkConnectionLost:
                errorMessage = L10n.t("网络连接已断开")
            default:
                errorMessage = L10n.f("连接已断开：%@", urlErr.localizedDescription)
            }
        } else {
            errorMessage = L10n.f("连接已断开：%@", error.localizedDescription)
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
                    self?.requestCurrent()
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
