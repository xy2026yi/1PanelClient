//
//  FileInfo.swift
//  1PanelClient
//

import Foundation

/// 文件搜索请求
struct FileSearchRequest: Encodable {
    let path: String
    let page: Int
    let pageSize: Int
    let search: String
    let containSubdirs: Bool
    let showHidden: Bool
    let sort: String
    let order: String
}

/// 文件信息（基于 response.FileInfo，已通过 logs 验证字段）
struct FileInfo: Decodable {
    let path: String
    let name: String
    let user: String?
    let group: String?
    let uid: String?
    let gid: String?
    let `extension`: String?
    let content: String?
    let size: Int64?
    let isDir: Bool
    let isSymlink: Bool?
    let isHidden: Bool?
    let linkPath: String?
    let type: String?
    let mode: String?
    let mimeType: String?
    let updateTime: String?
    let modTime: String?
    let items: [FileInfo]?
    let itemTotal: Int?
    let favoriteID: Int?
    let isDetail: Bool?
}

extension FileInfo {
    var formattedSize: String {
        let bytes = size ?? 0
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
    }

    var formattedDate: String {
        guard let modTime, !modTime.isEmpty else { return "-" }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        if let date = isoFormatter.date(from: modTime) {
            return formatter.string(from: date)
        }
        return String(modTime.prefix(16))
    }
}
