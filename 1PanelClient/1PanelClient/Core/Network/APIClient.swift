//
//  APIClient.swift
//  1PanelClient
//

import Foundation
import CryptoKit

final class APIClient {
    let server: ServerConfig
    private let session: URLSession
    /// SSE 流式专用 session（无超时，用于日志查看等长连接）
    private let streamSession: URLSession

    init(server: ServerConfig) {
        self.server = server
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)

        let streamConfig = URLSessionConfiguration.default
        streamConfig.timeoutIntervalForRequest = .infinity
        streamConfig.timeoutIntervalForResource = .infinity
        streamConfig.httpCookieAcceptPolicy = .always
        self.streamSession = URLSession(configuration: streamConfig)
    }

    // MARK: - Token 签名

    private func generateHeaders() -> [String: String] {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let raw = "1panel" + server.apiKey + timestamp
        let digest = Insecure.MD5.hash(data: Data(raw.utf8))
        let token = digest.map { String(format: "%02x", $0) }.joined()
        return [
            "1Panel-Token": token,
            "1Panel-Timestamp": timestamp,
            "Content-Type": "application/json"
        ]
    }

    // MARK: - 核心请求

    func send<T: Decodable>(
        path: String,
        method: String = "POST",
        body: (any Encodable)? = nil,
        queryItems: [URLQueryItem]? = nil,
        as type: T.Type
    ) async throws -> T {
        guard var components = URLComponents(string: server.normalizedBaseURL + path) else {
            throw APIError.invalidURL
        }
        if let queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        for (k, v) in generateHeaders() {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if let body {
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        } else if method == "POST" {
            request.httpBody = Data("{}".utf8)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        // 安全入口拦截检测
        if let ct = http.value(forHTTPHeaderField: "Content-Type"), ct.contains("text/html") {
            throw APIError.htmlBlocked
        }

        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(http.statusCode, msg)
        }

        // 优先走业务包装
        if let wrapped = try? JSONDecoder().decode(APIResponse<T>.self, from: data) {
            if wrapped.isSuccess, let value = wrapped.data {
                return value
            }
            if wrapped.code == 200 && T.self == EmptyResponse.self {
                return EmptyResponse() as! T
            }
            throw APIError.businessError(wrapped.code, wrapped.message ?? "")
        }

        // 裸 JSON
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error.localizedDescription)
        }
    }

    // 便捷方法：只要知道成功即可
    func sendRaw(
        path: String,
        method: String = "POST",
        body: (any Encodable)? = nil
    ) async throws -> Data {
        guard let url = URL(string: server.normalizedBaseURL + path) else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (k, v) in generateHeaders() {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if let body {
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        } else if method == "POST" {
            request.httpBody = Data("{}".utf8)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        if let ct = http.value(forHTTPHeaderField: "Content-Type"), ct.contains("text/html") {
            throw APIError.htmlBlocked
        }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// 获取二进制图片数据（如应用图标）
    /// 返回原始 Data，调用方需自行包装成 UIImage
    func fetchImage(path: String, queryItems: [URLQueryItem]? = nil) async throws -> Data {
        guard var components = URLComponents(string: server.normalizedBaseURL + path) else {
            throw APIError.invalidURL
        }
        if let queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in generateHeaders() {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        // 图标可能返回 html（被安全入口拦截）或 json 错误体
        if let ct = http.value(forHTTPHeaderField: "Content-Type"), ct.contains("text/html") {
            throw APIError.htmlBlocked
        }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.httpError(http.statusCode, "图标请求失败")
        }
        // 防御：若返回 JSON 错误体（业务错误），抛出
        if let ct = http.value(forHTTPHeaderField: "Content-Type"), ct.contains("application/json") {
            throw APIError.businessError(500, "图标接口返回 JSON")
        }
        return data
    }

    // MARK: - SSE 流式请求（日志查看）

    /// 发起 SSE 流式请求，逐行产出日志内容（已剥离 `data: ` 前缀）
    /// - Parameters:
    ///   - path: 接口路径
    ///   - queryItems: 查询参数
    /// - Returns: 异步日志行序列（遇到 `data: ` 开头则剥离前缀；空行跳过）
    func streamSSELines(
        path: String,
        queryItems: [URLQueryItem]
    ) -> AsyncThrowingStream<String, Error> {
        var components = URLComponents(string: server.normalizedBaseURL + path)
        components?.queryItems = queryItems
        guard let url = components?.url else {
            return AsyncThrowingStream { _ in }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in generateHeaders() {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")

        return AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                    do {
                        (bytes, response) = try await streamSession.bytes(for: request)
                    } catch {
                        continuation.finish(throwing: APIError.networkError(error))
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: APIError.invalidResponse)
                        return
                    }
                    if !(200...299).contains(http.statusCode) {
                        continuation.finish(throwing: APIError.httpError(http.statusCode, "日志流请求失败"))
                        return
                    }
                    // 逐行读取 SSE 数据
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.isEmpty { continue }
                        if line.hasPrefix("data:") {
                            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            if payload == "[DONE]" { break }
                            if !payload.isEmpty {
                                continuation.yield(payload)
                            }
                        } else if line.hasPrefix("{") {
                            // JSON API 响应信封（如 {"code":200,...}），跳过
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

// MARK: - 辅助类型

nonisolated struct EmptyResponse: Codable {}

nonisolated struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void
    init(_ wrapped: any Encodable) {
        self.encodeFunc = wrapped.encode
    }
    func encode(to encoder: Encoder) throws {
        try encodeFunc(encoder)
    }
}

// MARK: - MD5（备用，iOS 用 CryptoKit.Insecure.MD5）
