//
//  APIError.swift
//  1PanelClient
//

import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, String)
    case businessError(Int, String)
    case decodingError(String)
    case networkError(Error)
    case notConfigured
    case htmlBlocked

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "服务器地址格式错误"
        case .invalidResponse:
            return "服务器返回了无法解析的响应"
        case .httpError(let code, let msg):
            return "HTTP \(code): \(msg)"
        case .businessError(let code, let msg):
            return msg.isEmpty ? "业务错误（\(code)）" : msg
        case .decodingError(let msg):
            return "数据解析失败: \(msg)"
        case .networkError(let err):
            // 连接完全建立不起来时给出可操作的排查方向，而不只是系统错误文案
            if let urlErr = err as? URLError,
               [.cannotConnectToHost, .cannotFindHost, .timedOut, .notConnectedToInternet, .networkConnectionLost].contains(urlErr.code) {
                return """
                    无法连接到服务器。请检查：地址与端口是否正确、服务器防火墙是否放行；\
                    在模拟器中运行时，还需在 macOS「系统设置 → 隐私与安全性 → 本地网络」中允许 Simulator。
                    """
            }
            return "网络错误: \(err.localizedDescription)"
        case .notConfigured:
            return "请先添加服务器"
        case .htmlBlocked:
            return "请求被安全入口拦截，请检查服务器配置"
        }
    }
}
