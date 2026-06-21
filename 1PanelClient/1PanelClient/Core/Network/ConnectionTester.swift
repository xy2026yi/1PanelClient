//
//  ConnectionTester.swift
//  1PanelClient
//

import Foundation

/// 测试服务器连接是否正常
enum ConnectionTester {
    /// 返回 (success, message)
    static func test(_ server: ServerConfig) async -> (Bool, String) {
        let client = APIClient(server: server)
        do {
            let info: DeviceInfo = try await client.send(
                path: APIEndpoint.deviceBase.path,
                as: DeviceInfo.self
            )
            return (true, "连接成功：\(info.hostname) · \(info.timeZone)")
        } catch let err as APIError {
            return (false, err.errorDescription ?? "未知错误")
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
