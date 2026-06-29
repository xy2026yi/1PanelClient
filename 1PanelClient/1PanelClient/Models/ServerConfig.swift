//
//  ServerConfig.swift
//  1PanelClient
//

import Foundation

nonisolated struct ServerConfig: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var baseURL: String
    var apiKey: String

    init(id: UUID = UUID(), name: String, baseURL: String, apiKey: String) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    var normalizedBaseURL: String {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }
}
