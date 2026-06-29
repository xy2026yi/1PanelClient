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
