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
            return "网络错误: \(err.localizedDescription)"
        case .notConfigured:
            return "请先添加服务器"
        case .htmlBlocked:
            return "请求被安全入口拦截，请检查服务器配置"
        }
    }
}
