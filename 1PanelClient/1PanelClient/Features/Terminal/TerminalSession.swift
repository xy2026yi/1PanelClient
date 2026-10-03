//
//  TerminalSession.swift
//  1PanelClient
//
//  通过 WebSocket 连接 1Panel 终端（主机 SSH / 容器 Exec）
//  协议参考：1Panel 后端 /api/v2/hosts/terminal、/api/v2/hosts/terminal/container
//  兼容两种帧格式：原始文本字节 / JSON {type:"cmd",data:base64}
//

import Foundation
import CryptoKit
import Combine

// MARK: - 连接目标

enum TerminalTarget {
    /// 主机本地终端（操作面板所在服务器的 shell）
    case host(cols: Int, rows: Int)
    /// SSH 连接已保存的远程主机（hosts 表中的 id）
    case sshHost(id: Int, cols: Int, rows: Int)
    /// 容器内终端
    case container(containerID: String, user: String, command: String, cols: Int, rows: Int)
    /// 执行脚本库脚本（后端按 script_id 启动 PTY 运行脚本）
    case scriptRun(scriptID: Int, cols: Int, rows: Int)
    /// Redis CLI 终端
    case redis(name: String, cols: Int, rows: Int)
    /// 数据库终端（MySQL / PostgreSQL CLI）
    case database(databaseType: String, database: String, cols: Int, rows: Int)
    /// Ollama 模型交互终端（source=ollama，AI 模块「运行」入口）
    case ollamaModel(name: String, cols: Int, rows: Int)

    var cols: Int {
        switch self {
        case .host(let c, _): return c
        case .sshHost(_, let c, _): return c
        case .container(_, _, _, let c, _): return c
        case .scriptRun(_, let c, _): return c
        case .redis(_, let c, _): return c
        case .database(_, _, let c, _): return c
        case .ollamaModel(_, let c, _): return c
        }
    }

    var rows: Int {
        switch self {
        case .host(_, let r): return r
        case .sshHost(_, _, let r): return r
        case .container(_, _, _, _, let r): return r
        case .scriptRun(_, _, let r): return r
        case .redis(_, _, let r): return r
        case .database(_, _, _, let r): return r
        case .ollamaModel(_, _, let r): return r
        }
    }

    /// WebSocket 接口路径
    var path: String {
        switch self {
        case .host: return "/api/v2/hosts/terminal/local"
        case .sshHost: return "/api/v2/hosts/terminal/ssh"
        case .container: return "/api/v2/hosts/terminal/container"
        case .scriptRun: return "/api/v2/core/script/run"
        case .redis: return "/api/v2/hosts/terminal/container"
        case .database: return "/api/v2/hosts/terminal/container"
        case .ollamaModel: return "/api/v2/hosts/terminal/container"
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
        case .sshHost(let id, let cols, let rows):
            return [
                URLQueryItem(name: "cols", value: "\(cols)"),
                URLQueryItem(name: "rows", value: "\(rows)"),
                URLQueryItem(name: "id", value: "\(id)"),
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
        case .ollamaModel(let name, let cols, let rows):
            return [
                URLQueryItem(name: "cols", value: "\(cols)"),
                URLQueryItem(name: "rows", value: "\(rows)"),
                URLQueryItem(name: "source", value: "ollama"),
                URLQueryItem(name: "name", value: name),
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
    /// 终端输出回调：SwiftTerm 渲染面注入，收到服务端字节流后喂入其 VT 引擎
    var onOutput: ((Data) -> Void)?

    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published var errorMessage: String?

    private let server: ServerConfig
    private let target: TerminalTarget
    /// 连接就绪后自动执行的初始命令（如 MongoDB 容器内启动 mongosh）
    private let initialCommand: String?
    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    /// 服务端下发的会话 id（连接建立时 {"type":"session","id":...}）：
    /// 终端 PTY 会话跨连接保留，带 session 参数重连即恢复同一会话
    /// （网页端同款机制：WS 约 60s 一换，靠 session 重挂 + terminalRevalidate 保活）
    private var sessionID: String?
    /// 用户主动断开（手动断开/离开页面）不再自动重连
    private var isUserClosed = false
    /// 初始命令只执行一次：重连恢复同一 PTY 后再次执行会嵌套（如 hermes 套 hermes）
    private var hasSentInitialCommand = false
    /// 连续自动重连失败计数（成功首包清零；超限转为手动重连提示）
    private var reconnectFailures = 0
    /// 连接代次：旧连接的 receive/ping 回调不得触碰新连接的状态
    private var generation = 0

    /// 收到原始字节时是否直接当文本喂入（true）；否则解析 JSON+base64
    private var rawFrameMode = false

    init(server: ServerConfig, target: TerminalTarget, initialCommand: String? = nil) {
        self.server = server
        self.target = target
        self.initialCommand = initialCommand
        let config = URLSessionConfiguration.default
        // 请求级空闲超时按「等待新数据」计时：终端可能长时间无输出（CLI 等待
        // AI 生成回复、长任务无回显），30s 静默即被 URLSession 掐断 WebSocket，
        // 表现为生成完成前夕「连接已断开: Socket未连接」+ ping 失败。
        // 超时放开为不限（与 APIClient 流式会话同款），断线检测交给 pingLoop
        // 的心跳（sendPing 失败即连接已死）
        config.timeoutIntervalForRequest = .infinity
        config.timeoutIntervalForResource = .infinity
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
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
        // 跟随多机管理切换的当前节点：operateNode 查询参数优先级高于请求头，
        // 枚举里写死的 local 会被替换，否则远程节点终端永远连到本机
        var items = target.queryItems.map {
            $0.name == "operateNode" ? URLQueryItem(name: "operateNode", value: NodeScope.current(for: server.id) ?? "local") : $0
        }
        // 会话恢复重连（网页端同款参数）：session 挂回保留的 PTY，
        // terminalRevalidate 让服务端顺带校验/续期该会话
        if let sessionID {
            items.append(URLQueryItem(name: "session", value: sessionID))
            items.append(URLQueryItem(name: "terminalRevalidate", value: "1"))
        }
        comp.queryItems = items
        return comp.url
    }

    // MARK: - 连接

    func connect() {
        guard !isConnecting, !isConnected else { return }
        isUserClosed = false
        openSocket()
    }

    /// 建立一条 WS 连接（首连与自动重连共用；重连时 URL 携带 session 参数恢复会话）
    private func openSocket() {
        observeNodeScope()
        guard let url = makeWebSocketURL() else {
            errorMessage = L10n.t("无法构造终端连接地址")
            emit("\u{1B}[31m" + L10n.t("无法构造终端连接地址") + "\u{1B}[0m\r\n")
            return
        }
        var request = URLRequest(url: url)
        for (k, v) in authHeaders() {
            request.setValue(v, forHTTPHeaderField: k)
        }

        isConnecting = true
        errorMessage = nil

        // 旧连接的收包/心跳回调作废（代次 +1），任务收尾
        generation += 1
        receiveTask?.cancel()
        pingTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)

        let gen = generation
        let ws = session.webSocketTask(with: request)
        ws.resume()
        task = ws

        // 发送初始 resize（触发服务端 PTY 启动并推送数据）
        sendResize(cols: target.cols, rows: target.rows)

        // 启动接收与心跳循环
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(gen: gen)
        }
        pingTask = Task { [weak self] in
            await self?.pingLoop(gen: gen)
        }
    }

    func disconnect() {
        isUserClosed = true
        generation += 1
        receiveTask?.cancel()
        pingTask?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        isConnected = false
        isConnecting = false
    }

    // MARK: - 节点切换防护

    /// 连接建立时所处的节点；多机管理切换到其他节点后本连接路由已失效，主动断开
    private var nodeScopeCancellable: AnyCancellable?
    private var connectedNode: String = "local"

    private func observeNodeScope() {
        connectedNode = NodeScope.current(for: server.id) ?? "local"
        nodeScopeCancellable = NotificationCenter.default.publisher(for: NodeScope.changeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isConnected || self.isConnecting else { return }
                let now = NodeScope.current(for: self.server.id) ?? "local"
                guard now != self.connectedNode else { return }
                self.disconnect()
                self.emit("\u{1B}[33m" + L10n.f("当前节点已切换为 %@，连接已断开，请重新进入本页面", now) + "\u{1B}[0m\r\n")
            }
    }

    // MARK: - 发送输入

    /// 发送用户输入（JSON + base64 包装，匹配 1Panel 终端协议）
    /// 1Panel 终端后端要求客户端输入用 {"type":"cmd","data":"<base64>"} 格式
    func send(_ text: String) {
        send(data: Data(text.utf8))
    }

    /// 字节级发送（SwiftTerm 键盘输入/快捷键走这里），协议包装同上
    func send(data: Data) {
        guard let task else { return }
        let b64 = data.base64EncodedString()
        guard let payload = try? JSONEncoder().encode(WSPayload(type: "cmd", data: b64)),
              let str = String(data: payload, encoding: .utf8) else { return }
        Task {
            do { try await task.send(.string(str)) }
            catch { /* 发送失败静默 */ }
        }
    }

    /// 首包收到（服务端 PTY 已就绪）后自动执行初始命令，仅需一次
    private func sendInitialCommandIfNeeded() {
        guard let cmd = initialCommand else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.send(cmd)
        }
    }

    /// 通知后端终端尺寸变更
    func sendResize(cols: Int, rows: Int) {
        guard let task else { return }
        guard let data = try? JSONEncoder().encode(WSResize(type: "resize", cols: cols, rows: rows)),
              let str = String(data: data, encoding: .utf8) else { return }
        Task {
            try? await task.send(.string(str))
        }
    }

    // MARK: - 接收循环

    private func receiveLoop(gen: Int) async {
        guard let task else { return }
        // 首次成功接收即判定连接成功
        var firstPacket = true
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
                // 过期连接的回调：新连接已建立（自动重连）或已断开，静默退出
                guard gen == self.generation else { return }
                if firstPacket {
                    firstPacket = false
                    isConnecting = false
                    isConnected = true
                    reconnectFailures = 0
                    if !hasSentInitialCommand {
                        hasSentInitialCommand = true
                        sendInitialCommandIfNeeded()
                    }
                }
                handleIncoming(msg)
            } catch {
                guard gen == self.generation, !Task.isCancelled else { return }
                handleDisconnect(error: error)
                return
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
            emit(data)
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
                        emit(decoded)
                    } else if let raw = obj["data"] as? String {
                        emit(Data(raw.utf8))
                    }
                    return
                case "session":
                    // 服务端下发的会话 id：记录用于断线后恢复重连
                    if let id = obj["id"] as? String, !id.isEmpty { sessionID = id }
                    return
                case "resize", "ping", "pong", "heartbeat":
                    return
                default:
                    return
                }
            }
        }
        // 原始文本帧：切到 raw 模式，后续发送也用原始帧
        rawFrameMode = true
        emit(Data(text.utf8))
    }

    /// 把服务端/本地产生的终端字节流交给渲染面
    private func emit(_ text: String) {
        emit(Data(text.utf8))
    }

    private func emit(_ data: Data) {
        onOutput?(data)
    }

    /// 连接断开（服务端关闭/网络中断）。非用户主动断开且服务端支持会话保留
    /// （已下发 session id）时自动重连恢复，对用户透明；否则提示手动重连
    private func handleDisconnect(error: Error) {
        // 已有新连接在建立（自动重连竞态）或已按用户意愿关闭：不重复处理
        guard isConnected || isConnecting else { return }
        generation += 1
        receiveTask?.cancel()
        pingTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false

        guard !isUserClosed, sessionID != nil else {
            isConnecting = false
            var msg: String
            if let urlErr = error as? URLError {
                msg = L10n.f("连接已断开 [code: %ld]\n%@", urlErr.code.rawValue, urlErr.localizedDescription)
            } else {
                msg = L10n.f("连接已断开：%@", error.localizedDescription)
            }
            errorMessage = msg
            emit("\r\n\u{1B}[31m\(msg)\u{1B}[0m\r\n")
            return
        }
        scheduleReconnect()
    }

    /// 自动重连：短暂退避后重做会话校验并携带 session 参数重挂（网页端同款）。
    /// 首次（多为服务端例行换链）完全静默；连续失败从第 2 次起打灰色提示，
    /// 弱网用户能看出在自愈而非卡死
    private func scheduleReconnect() {
        reconnectFailures += 1
        guard reconnectFailures <= 3 else {
            isConnecting = false
            let msg = L10n.f("连接已断开：%@", L10n.t("自动重连失败，请手动重连"))
            errorMessage = msg
            emit("\r\n\u{1B}[31m\(msg)\u{1B}[0m\r\n")
            return
        }
        if reconnectFailures >= 2 {
            emit("\r\n\u{1B}[90m" + L10n.f("连接中断，正在恢复会话（第 %ld 次）…", reconnectFailures) + "\u{1B}[0m\r\n")
        }
        isConnecting = true
        let delayMs = UInt64(300 * reconnectFailures)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard let self, !self.isUserClosed, self.sessionID != nil,
                  !self.isConnected else { return }
            self.revalidateSession()
            self.openSocket()
        }
    }

    /// 会话校验/保活（对齐网页端周期性 terminalRevalidate GET；结果不消费）
    private func revalidateSession() {
        guard sessionID != nil, let url = makeWebSocketURL() else { return }
        guard var comp = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        comp.scheme = comp.scheme == "wss" ? "https" : "http"
        guard let httpURL = comp.url else { return }
        var request = URLRequest(url: httpURL)
        request.timeoutInterval = 10
        for (k, v) in authHeaders() {
            request.setValue(v, forHTTPHeaderField: k)
        }
        session.dataTask(with: request) { _, _, _ in }.resume()
    }

    // MARK: - 心跳

    /// 每 10s 应用层心跳 + WebSocket ping（服务端会回显 heartbeat，维持数据流）。
    /// 空闲超时已放开为不限，连接存活的检测职责在本循环：sendPing 本地发送
    /// 失败即连接已死（服务端不回 pong 不会报错，无需担心误判）。
    /// 每第 5 轮（约 50s）做一次会话校验，对齐网页端 ~60s 的 terminalRevalidate
    /// 保活周期（服务端 PTY 会话静默超时的保活信号）
    private func pingLoop(gen: Int) async {
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            guard gen == self.generation, !Task.isCancelled, let task else { break }
            tick += 1
            let ts = String(Int(Date().timeIntervalSince1970 * 1000))
            let heartbeat = "{\"type\":\"heartbeat\",\"timestamp\":\"\(ts)\"}"
            try? await task.send(.string(heartbeat))
            if tick % 5 == 0 { revalidateSession() }
            task.sendPing { [weak self] err in
                guard let self, let err else { return }
                Task { @MainActor in
                    // 过期连接的回调不得触发新连接的断开/重连
                    guard gen == self.generation else { return }
                    self.handleDisconnect(error: err)
                }
            }
        }
    }
}


// MARK: - 面板保留终端会话（v2.3.0 会话保留；POST /hosts/terminal/sessions/*）

/// 面板上保活/保留的终端会话（Web 终端创建，断线可恢复；kind = local/ssh/container）
struct PanelTerminalSession: Decodable, Identifiable, Hashable {
    let sessionID: String?
    let kind: String?
    let title: String?
    let hostId: Int?
    let attached: Bool?
    let createdAt: String?
    let detachedAt: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "id"
        case kind, title, hostId, attached, createdAt, detachedAt
    }

    var id: String { sessionID ?? UUID().uuidString }
}

/// POST /hosts/terminal/sessions/close {id}
struct PanelTerminalSessionCloseRequest: Encodable {
    let id: String
}
