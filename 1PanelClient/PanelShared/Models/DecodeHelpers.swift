//
//  DecodeHelpers.swift
//  1PanelClient
//
//  L1 解码防御（M2 模型加固）：decodeDefault —— 字段缺失 / null / 类型漂移时
//  回退默认值，防止单字段口径变化导致整页 decode 失败。
//  适用：展示型字段与可安全回退的 id（回退 0 的误操作由服务端拒绝，
//  仍优于整页空白）。业务关键字段（密码、目标资源 id）仍用严格可选解码。
//

import Foundation

extension KeyedDecodingContainer {
    /// 容错解码：任何失败（缺失 / null / 类型不符）回退 fallback
    nonisolated func decodeDefault<T: Decodable>(_ type: T.Type, forKey key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}
