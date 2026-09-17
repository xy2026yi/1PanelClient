//
//  APIResponse.swift
//  1PanelClient
//

import Foundation

nonisolated struct APIResponse<T: Decodable>: Decodable {
    let code: Int
    let message: String?
    let data: T?

    var isSuccess: Bool { code == 200 }
}

// MARK: - 通用分页信封

/// 1Panel 列表接口的 `{total, items}` 信封（dto.PageResult）。
/// L1 解码防御：上游把 total 置 null / 缺失时回退 0，不再让整页 decode 失败
/// （items 本就按可退空集合处理）。各模块列表响应以此 typealias 定义。
nonisolated struct PageEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    let total: Int
    let items: [T]?

    private enum CodingKeys: String, CodingKey {
        case total, items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        items = try c.decodeIfPresent([T].self, forKey: .items)
    }

    /// 测试/预览用便捷构造
    init(total: Int, items: [T]?) {
        self.total = total
        self.items = items
    }
}
