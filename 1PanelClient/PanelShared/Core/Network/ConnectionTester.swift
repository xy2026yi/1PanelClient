//
//  ConnectionTester.swift
//  1PanelClient
//

import Foundation

/// 测试服务器连接是否正常
enum ConnectionTester {
    /// 返回 (success, message)
    /// 只校验鉴权与接口可达性，不依赖具体业务模型解码，避免字段差异导致误报
    static func test(_ server: ServerConfig) async -> (Bool, String) {
        let client = APIClient(server: server)
        do {
            let raw = try await client.sendRaw(
                path: APIEndpoint.deviceBase.path,
                method: "POST"
            )
            // 解析外层 code/message，code==200 即视为连接成功
            if let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
               let code = obj["code"] as? Int {
                if code == 200 {
                    let host = (obj["data"] as? [String: Any])?["hostname"] as? String
                    let label = host.map { L10n.f("：%@", $0) } ?? ""
                    return (true, L10n.f("连接成功%@", label))
                }
                let msg = (obj["message"] as? String) ?? ""
                return (false, msg.isEmpty ? L10n.f("业务错误（%ld）", code) : msg)
            }
            // 非标准 JSON 包装，但 HTTP 200 也算通
            return (true, L10n.t("连接成功"))
        } catch let err as APIError {
            return (false, err.errorDescription ?? L10n.t("未知错误"))
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
