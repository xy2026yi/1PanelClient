//
//  PageResponse.swift
//  1PanelClient
//

import Foundation

/// 通用分页响应（当 data 直接是对象时使用）
struct PageResponse<T: Decodable>: Decodable {
    let total: Int?
    let items: [T]?
}
