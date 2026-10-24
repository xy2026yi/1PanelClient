//
//  PageResponse.swift
//  1PanelClient
//

import Foundation

/// 通用分页响应（当 data 直接是对象时使用）
nonisolated struct PageResponse<T: Decodable>: Decodable {
    let total: Int?
    let items: [T]?
}

/// 条件 Sendable（元素 Sendable 时整页可跨隔离域——概览并发拉取等场景）
extension PageResponse: Sendable where T: Sendable {}

/// code=200 且 data=null（服务端空列表序列化为 null）时回退为空页，
/// 分页列表页据此显示「暂无数据」而不是报错
extension PageResponse: EmptyInitializable {
    static func emptyInstance() -> Self {
        PageResponse(total: 0, items: [])
    }
}
