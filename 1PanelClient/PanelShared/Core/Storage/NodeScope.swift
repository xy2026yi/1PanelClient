//
//  NodeScope.swift
//  1PanelClient
//
//  多机管理：当前操作节点的全局状态（按服务器隔离）。
//  1Panel v2 的节点路由由请求头 CurrentNode（或 ?operateNode= 查询参数，优先级更高）决定，
//  APIClient 在每次请求时读取此处的值注入请求头；不设置或 "local" 即操作主节点本机。
//  参考网页端实现：frontend/src/api/index.ts 的 axios 拦截器 + core/init/router/proxy.go
//

import Foundation

enum NodeScope {
    /// 节点切换通知：object 为 serverID（UUID），UI 据此刷新「当前节点」标记
    static let changeNotification = Notification.Name("1PanelClient.nodeScopeDidChange")

    private static let keyPrefix = "nodeScope.v1."

    /// 当前操作节点名；nil / 空 / "local" 均表示主节点本机
    static func current(for serverID: UUID) -> String? {
        let key = keyPrefix + serverID.uuidString
        let store = AppGroup.defaults ?? .standard
        let value = store.string(forKey: key) ?? UserDefaults.standard.string(forKey: key)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func setCurrent(_ node: String?, for serverID: UUID) {
        let key = keyPrefix + serverID.uuidString
        let store = AppGroup.defaults ?? .standard
        if let node, !node.isEmpty, node != "local" {
            store.set(node, forKey: key)
        } else {
            store.removeObject(forKey: key)
            // 兼容仅主进程可用的旧存储位置
            UserDefaults.standard.removeObject(forKey: key)
        }
        // 异步派发：允许在视图构建期间调用（切换节点的导航包装视图），
        // 避免观察者同步修改 @State 触发 SwiftUI 警告
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: changeNotification, object: serverID)
        }
    }

    /// 请求头用的节点名（与网页端 encodeURIComponent 等价：仅保留字母数字）
    static func headerValue(for serverID: UUID) -> String? {
        guard let node = current(for: serverID) else { return nil }
        return node.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
    }
}
