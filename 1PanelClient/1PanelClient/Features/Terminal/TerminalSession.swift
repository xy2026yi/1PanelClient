//
//  TerminalSession.swift
//  1PanelClient
//
//  通过 WebSocket 连接 1Panel 终端（主机 SSH / 容器 Exec）
//  协议参考：1Panel 后端 /api/v2/hosts/terminal、/api/v2/containers/exec
//  兼容两种帧格式：原始文本字节 / JSON {type:"cmd",data:base64}
//

import Foundation
import CryptoKit
import Combine

// MARK: - 连接目标

enum TerminalTarget {
    /// 主机本地终端（操作面板所在服务器的 shell）
    case host(cols: Int, rows: Int)
    /// 容器内终端
    case container(containerID: String, user: String, command: String, cols: Int, rows: Int)
    /// 执行脚本库脚本（后端按 script_id 启动 PTY 运行脚本）
    case scriptRun(scriptID: Int, cols: Int, rows: Int)
    /// Redis CLI 终端
    case redis(name: String, cols: Int, rows: Int)
    /// 数据库终端（MySQL / PostgreSQL CLI）
    case database(databaseType: String, database: String, cols: Int, rows: Int)

    var cols: Int {
        switch self {
        case .host(let c, _): return c
        case .container(_, _, _, let c, _): return c
        case .scriptRun(_, let c, _): return c
        case .redis(_, let c, _): return c
        case .database(_, _, let c, _): return c
        }
    }

    var rows: Int {
        switch self {
        case .host(_, let r): return r
        case .container(_, _, _, _, let r): return r
        case .scriptRun(_, _, let r): return r
        case .redis(_, _, let r): return r
        case .database(_, _, _, let r): return r
        }
    }

    /// WebSocket 接口路径
    var path: String {
        switch self {
        case .host: return "/api/v2/hosts/terminal"
        case .container: return "/api/v2/containers/exec"
        case .scriptRun: return "/api/v2/core/script/run"
        case .redis: return "/api/v2/containers/exec"
        case .database: return "/api/v2/hosts/terminal/container"
        }
    }

    /// 查询参数
    var queryItems: [URLQueryItem] {
        switch self {
        case .host(let cols, let rows):
            return [
                URLQueryItem(name: "cols", value: "\(cols)"),
                URLQueryItem(name: "rows", value: "\(rows)"),
                URLQueryItem(name: "operateNode", value: "local")
            ]
        case .container(let id, let user, let command, let cols, let rows):
            return [
                URLQueryItem(name: "cols", value: "\(cols)"),
                URLQueryItem(name: "rows", value: "\(rows)"),
                URLQueryItem(name: "source", value: "container"),
                URLQueryItem(name: "containerid", value: id),
                URLQueryItem(name: "user", value: user),
                URLQueryItem(name: "command", value: command),
                URLQueryItem(name: "operateNode", value: "local")
            ]
        case .scriptRun(let scriptID, let cols, let rows):
            return [
                URLQueryItem(name: "cols", value: "\(cols)"),
                URLQueryItem(name: "rows", value: "\(rows)"),
                URLQueryItem(name: "script_id", value: "\(scriptID)"),
                URLQueryItem(name: "current_node", value: "local"),
                URLQueryItem(name: "operateNode", value: "local")
            ]
        case .redis(let name, let cols, let rows):
            return [
                URLQueryItem(name: "cols", value: "\(cols)"),
                URLQueryItem(name: "rows", value: "\(rows)"),
                URLQueryItem(name: "source", value: "redis"),
                URLQueryItem(name: "name", value: name),
                URLQueryItem(name: "from", value: "local"),
                URLQueryItem(name: "operateNode", value: "local")
            ]
        case .database(let dbType, let database, let cols, let rows):
            return [
                URLQueryItem(name: "cols", value: "\(cols)"),
                URLQueryItem(name: "rows", value: "\(rows)"),
                URLQueryItem(name: "source", value: "database"),
                URLQueryItem(name: "databaseType", value: dbType),
                URLQueryItem(name: "database", value: database),
                URLQueryItem(name: "operateNode", value: "local")
            ]
        }
    }
}

// MARK: - WebSocket 消息（JSON 包装，发送时用）

private struct WSPayload: Encodable {
    let type: String
    let data: String
}

private struct WSResize: Encodable {
    let type: String
    let cols: Int
    let rows: Int
}

// MARK: - 终端会话

@MainActor
final class TerminalSession: ObservableObject {
    let emulator = TerminalEmulator()

    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published var errorMessage: String?

    private let server: ServerConfig
    private let target: TerminalTarget
    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var emulatorCancellable: AnyCancellable?

    /// 收到原始字节时是否直接当文本喂入（true）；否则解析 JSON+base64
    private var rawFrameMode = false

    init(server: ServerConfig, target: TerminalTarget) {
        self.server = server
        self.target = target
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        emulator.resize(cols: target.cols, rows: target.rows)
        emulatorCancellable = emulator.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
    }

    deinit {
        receiveTask?.cancel()
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

    // MARK: - 构造 ws/wss URL

    private func makeWebSocketURL() -> URL? {
        let base = server.normalizedBaseURL
        let components = URLComponents(string: base)
        guard var comp = components else { return nil }
        // http -> ws，https -> wss
        if comp.scheme == "https" { comp.scheme = "wss" }
        else { comp.scheme = "ws" }
        comp.path = target.path
        comp.queryItems = target.queryItems
        return comp.url
    }

    // MARK: - 连接

    func connect() {
        guard !isConnecting, !isConnected else { return }
        guard let url = makeWebSocketURL() else {
            errorMessage = "无法构造终端连接地址"
            emulator.feed("\u{1B}[31m无法构造终端连接地址\u{1B}[0m\r\n")
            return
        }
        var request = URLRequest(url: url)
        for (k, v) in authHeaders() {
            request.setValue(v, forHTTPHeaderField: k)
        }

        isConnecting = true
        errorMessage = nil
        emulator.feed("正在连接 \(server.name)…\r\n")
        emulator.feed("\u{1B}[90m\(url.absoluteString)\u{1B}[0m\r\n")

        let ws = session.webSocketTask(with: request)
        ws.resume()
        task = ws

        // 诊断：3 秒后检查连接状态
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run {
                guard let self else { return }
                if self.isConnecting && !self.isConnected {
                    let state = self.task?.state.rawValue ?? -1
                    let closeCode = self.task?.closeCode.rawValue ?? -1
                    self.emulator.feed("\r\n\u{1B}[33m[诊断] 3秒未收到数据\r\nWS状态: \(state) (0=running 3=completed)\r\n关闭码: \(closeCode)\u{1B}[0m\r\n")
                }
            }
        }

        // 发送初始 resize（触发服务端 PTY 启动并推送数据）
        sendResize(cols: target.cols, rows: target.rows)

        // 启动接收与心跳循环
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        pingTask = Task { [weak self] in
            await self?.pingLoop()
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        pingTask?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        isConnected = false
        isConnecting = false
    }

    // MARK: - 发送输入

    /// 发送用户输入（JSON + base64 包装，匹配 1Panel 终端协议）
    /// 1Panel 终端后端要求客户端输入用 {"type":"cmd","data":"<base64>"} 格式
    func send(_ text: String) {
        guard let task else { return }
        let b64 = Data(text.utf8).base64EncodedString()
        guard let data = try? JSONEncoder().encode(WSPayload(type: "cmd", data: b64)),
              let str = String(data: data, encoding: .utf8) else { return }
        Task {
            do { try await task.send(.string(str)) }
            catch { /* 发送失败静默 */ }
        }
    }

    /// 通知后端终端尺寸变更
    func sendResize(cols: Int, rows: Int) {
        guard let task else { return }
        emulator.resize(cols: cols, rows: rows)
        guard let data = try? JSONEncoder().encode(WSResize(type: "resize", cols: cols, rows: rows)),
              let str = String(data: data, encoding: .utf8) else { return }
        Task {
            try? await task.send(.string(str))
        }
    }

    // MARK: - 接收循环

    private func receiveLoop() async {
        guard let task else { return }
        // 首次成功接收即判定连接成功
        var firstPacket = true
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
                if firstPacket {
                    firstPacket = false
                    isConnecting = false
                    isConnected = true
                }
                handleIncoming(msg)
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.handleDisconnect(error: error)
                    }
                }
                break
            }
        }
    }

    private func handleIncoming(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            ingest(text)
        case .data(let data):
            // 二进制帧直接当字节流
            rawFrameMode = true
            emulator.feed(data)
        @unknown default:
            break
        }
    }

    /// 解析接收到的文本：优先尝试 JSON+base64，失败则当原始文本
    private func ingest(_ text: String) {
        // 快速判断：JSON 以 { 开头才尝试解析
        let trimmed = text.unicodeScalars.first.map { Character($0) }
        if trimmed == "{" {
            if let jsonData = text.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let type = obj["type"] as? String {
                switch type {
                case "cmd":
                    if let b64 = obj["data"] as? String,
                       let decoded = Data(base64Encoded: b64) {
                        emulator.feed(decoded)
                    } else if let raw = obj["data"] as? String {
                        emulator.feed(raw)
                    }
                    return
                case "resize", "ping", "pong":
                    return
                default:
                    return
                }
            }
        }
        // 原始文本帧：切到 raw 模式，后续发送也用原始帧
        rawFrameMode = true
        emulator.feed(text)
    }

    private func handleDisconnect(error: Error) {
        isConnected = false
        isConnecting = false
        var msg: String
        if let urlErr = error as? URLError {
            msg = "连接已断开 [code: \(urlErr.code.rawValue)]\n\(urlErr.localizedDescription)"
        } else {
            msg = "连接已断开：\(error.localizedDescription)"
        }
        errorMessage = msg
        emulator.feed("\r\n\u{1B}[31m\(msg)\u{1B}[0m\r\n")
    }

    // MARK: - 心跳

    private func pingLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let task else { break }
            let ts = String(Int(Date().timeIntervalSince1970 * 1000))
            let heartbeat = "{\"type\":\"heartbeat\",\"timestamp\":\"\(ts)\"}"
            try? await task.send(.string(heartbeat))
            task.sendPing { [weak self] err in
                if let err {
                    Task { @MainActor in
                        self?.emulator.feed("\r\n\u{1B}[33mping 失败：\(err.localizedDescription)\u{1B}[0m\r\n")
                    }
                }
            }
        }
    }
}
