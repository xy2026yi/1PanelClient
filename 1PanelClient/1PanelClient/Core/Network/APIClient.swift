//
//  APIClient.swift
//  1PanelClient
//

import Foundation
import CryptoKit
import os

final class APIClient {
    let server: ServerConfig
    private let session: URLSession
    /// SSE 流式专用 session（无超时，用于日志查看等长连接）
    private let streamSession: URLSession
    /// 上传/下载专用 session（长超时，用于大文件传输）
    private let transferSession: URLSession

    init(server: ServerConfig) {
        self.server = server
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)

        let streamConfig = URLSessionConfiguration.default
        streamConfig.timeoutIntervalForRequest = .infinity
        streamConfig.timeoutIntervalForResource = .infinity
        streamConfig.httpCookieAcceptPolicy = .always
        self.streamSession = URLSession(configuration: streamConfig)

        // 上传/下载专用：大文件传输不受 15s/30s 超时限制
        let transferConfig = URLSessionConfiguration.default
        transferConfig.timeoutIntervalForRequest = 60          // 单个分片/请求超时
        transferConfig.timeoutIntervalForResource = .infinity  // 整体传输不限时
        transferConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        transferConfig.urlCache = nil
        transferConfig.httpCookieAcceptPolicy = .always
        self.transferSession = URLSession(configuration: transferConfig)
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
        request.cachePolicy = .reloadIgnoringLocalCacheData
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
            if wrapped.code == 200 {
                // code=200 但 data=null：集合类型回退为空集合
                // （服务端空列表会序列化为 null，如 /backups/record/size 无记录时）
                if let empty = (T.self as? EmptyInitializable.Type)?.emptyInstance() as? T {
                    return empty
                }
                if T.self == EmptyResponse.self {
                    return EmptyResponse() as! T
                }
                // 非集合类型的 data:null 无法回退空值：给出明确提示而不是空 message 的「业务错误200」
                throw APIError.businessError(200, "接口未返回数据")
            }
            #if DEBUG
            Logger(subsystem: "com.xy.1PanelClient.debug", category: "api")
                .warning("[API-DEBUG] \(path, privacy: .public) -> \(String(data: data, encoding: .utf8) ?? "", privacy: .public)")
            #endif
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
        request.cachePolicy = .reloadIgnoringLocalCacheData
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
        request.cachePolicy = .reloadIgnoringLocalCacheData
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

    // MARK: - 文件上传/下载

    /// multipart/form-data 上传。
    /// - Parameters:
    ///   - path: 接口路径（filesUpload 或 filesChunkUpload）
    ///   - fields: 普通表单字段（如 path/overwrite/filename/chunkIndex/chunkCount）
    ///   - fileFieldName: 文件字段名（直传为 "file"，分片为 "chunk"）
    ///   - fileName: 文件名
    ///   - mimeType: MIME 类型
    ///   - fileData: 文件（分片）二进制数据
    func uploadMultipart(
        path: String,
        fields: [String: String],
        fileFieldName: String,
        fileName: String,
        mimeType: String,
        fileData: Data
    ) async throws {
        guard let url = URL(string: server.normalizedBaseURL + path) else {
            throw APIError.invalidURL
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        // 普通字段
        for (name, value) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        // 文件字段
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        // 结束边界
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in generateHeaders() {
            request.setValue(v, forHTTPHeaderField: k)
        }
        // 覆盖默认的 JSON Content-Type
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await transferSession.data(for: request)
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
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(http.statusCode, msg)
        }
        // 解析业务信封（如 {code:200, message:"1 files upload success"}）
        if let wrapped = try? JSONDecoder().decode(APIResponse<EmptyResponse>.self, from: data) {
            if !wrapped.isSuccess {
                throw APIError.businessError(wrapped.code, wrapped.message ?? "上传失败")
            }
        }
    }

    /// 流式下载文件到临时目录，实时回报进度。
    /// - Parameters:
    ///   - path: 接口路径（filesDownload）
    ///   - queryItems: 查询参数（operateNode + path）
    ///   - fileName: 保存的文件名
    ///   - progress: 进度回调（0...1，-1 表示总大小未知）
    /// - Returns: 下载完成的本地文件 URL
    func downloadFile(
        path: String,
        queryItems: [URLQueryItem],
        fileName: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard var components = URLComponents(string: server.normalizedBaseURL + path) else {
            throw APIError.invalidURL
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "GET"
        for (k, v) in generateHeaders() {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await transferSession.bytes(for: request)
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
            throw APIError.httpError(http.statusCode, "下载失败")
        }

        let totalSize = http.expectedContentLength
        // 只取最后一段文件名（防服务端异常数据拼出目录穿越路径），并加 UUID 前缀：
        // 同名文件的并行下载不再写同一个临时文件互相覆盖
        let safeName = (fileName as NSString).lastPathComponent
        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(safeName)")
        // 覆盖旧的同名临时文件
        try? FileManager.default.removeItem(at: destURL)
        FileManager.default.createFile(atPath: destURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destURL)
        defer { try? handle.close() }

        var received: Int64 = 0
        var buffer = Data()
        // 用 AsyncBytes 逐块读取并落盘，避免大文件整体载入内存
        do {
            for try await byte in bytes {
                buffer.append(byte)
                received += 1
                if buffer.count >= 64 * 1024 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
                if received % (256 * 1024) == 0 {
                    // 主动响应取消：AsyncBytes 只在缓冲耗尽后才会察觉 Task 取消，
                    // 不主动检查的话取消后还会继续消费已缓冲的数据（进度条多走几秒）
                    if Task.isCancelled { throw CancellationError() }
                    if totalSize > 0 {
                        progress?(Double(received) / Double(totalSize))
                    }
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
            }
        } catch {
            try? FileManager.default.removeItem(at: destURL)
            throw APIError.networkError(error)
        }
        progress?(totalSize > 0 ? 1 : -1)
        return destURL
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
        request.cachePolicy = .reloadIgnoringLocalCacheData
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

/// code=200 且 data=null 时可回退为空值的集合类型
nonisolated protocol EmptyInitializable {
    static func emptyInstance() -> Self
}

extension Array: EmptyInitializable {
    static func emptyInstance() -> Self { [] }
}

extension Set: EmptyInitializable {
    static func emptyInstance() -> Self { [] }
}

extension Dictionary: EmptyInitializable {
    static func emptyInstance() -> Self { [:] }
}

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
