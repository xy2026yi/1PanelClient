//
//  KeychainStore.swift
//  1PanelClient
//

import Foundation
import Security

/// App Group 常量：主 App 与小组件扩展共享配置/凭据镜像。
/// 未签名分发（LiveContainer）无 entitlements 时 UserDefaults(suiteName:) 退化为进程内实例，
/// 小组件读不到数据则显示引导空态。
enum AppGroup {
    static let id = "group.com.xy.panelclient"

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: id)
    }
}

enum KeychainStore {
    private static let service = "com.xy.1PanelClient"
    /// 共享 access group（正式签名时主 App 与 Widget 读写同一份凭据）
    private static let accessGroup = "9744G2RJJ4.group.com.xy.panelclient"
    private static let mirrorPrefix = "apikey.mirror."

    private static func query(for key: String, group: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        if group {
            q[kSecAttrAccessGroup as String] = accessGroup
        }
        return q
    }

    /// mirror=false：敏感值（应用锁密码摘要）不镜像到 UserDefaults（明文可读的
    /// 存储，会让「只存摘要」形同虚设），并清除历史版本可能残留的镜像
    static func save(_ value: String, for key: String, mirror: Bool = true) {
        guard let data = value.data(using: .utf8) else { return }
        // 无 access group 版（未签名环境的兼容路径）
        SecItemDelete(query(for: key, group: false) as CFDictionary)
        var attrs = query(for: key, group: false)
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
        // 共享 access group 版（Widget 扩展读取；无 entitlements 时静默失败）
        SecItemDelete(query(for: key, group: true) as CFDictionary)
        var shared = query(for: key, group: true)
        shared[kSecValueData as String] = data
        SecItemAdd(shared as CFDictionary, nil)
        // App Group UserDefaults 镜像（Widget 的第二读取路径）
        if mirror {
            AppGroup.defaults?.set(value, forKey: mirrorPrefix + key)
        } else {
            AppGroup.defaults?.removeObject(forKey: mirrorPrefix + key)
        }
    }

    /// 读取并返回底层状态码（诊断模拟器重装后 Keychain 不可读的问题）
    static func readWithStatus(for key: String) -> (value: String?, status: OSStatus) {
        var readQuery = query(for: key, group: false)
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return (nil, status)
        }
        return (value, status)
    }

    static func read(for key: String) -> String? {
        readWithStatus(for: key).value
    }

    /// Widget / App Intents 跨进程读取：共享 keychain → App Group 镜像 → 进程内
    static func readShared(for key: String) -> String? {
        var q = query(for: key, group: true)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8), !value.isEmpty {
            return value
        }
        if let mirror = AppGroup.defaults?.string(forKey: mirrorPrefix + key), !mirror.isEmpty {
            return mirror
        }
        return read(for: key)
    }

    static func delete(for key: String) {
        SecItemDelete(query(for: key, group: false) as CFDictionary)
        SecItemDelete(query(for: key, group: true) as CFDictionary)
        AppGroup.defaults?.removeObject(forKey: mirrorPrefix + key)
    }
}
