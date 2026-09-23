//
//  FilesModels.swift
//  1PanelClient
//
//  文件模块请求/收藏模型（自 FilesView.swift 拆出，内容未改动）
//

import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - 请求模型

struct FileCreateRequest: Encodable {
    let path: String
    let name: String
    let isDir: Bool
    let isLink: Bool
    let isSymlink: Bool
    let linkPath: String
}

struct FileDeleteRequest: Encodable {
    let path: String
    let isDir: Bool
    let forceDelete: Bool
}

struct FileRenameRequest: Encodable {
    let newName: String
    let path: String
    let oldName: String
}

/// 上传文件夹前检查目标路径已存在文件（POST /files/batch/check）
struct FileBatchCheckRequest: Encodable {
    let paths: [String]
}

/// 待上传的本地文件（文件夹上传用）：本地 URL + 含顶层文件夹名的相对路径
struct FolderUploadFile {
    let url: URL
    let relativePath: String
    let size: Int64
}

// MARK: - 收藏（files/favorite/*，可选增加-2 抓包 2026-09-16）

/// 收藏项（favorite/search 返回；favorite 添加响应同构单条）
struct FileFavorite: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let path: String?
    let isDir: Bool?
    let isTxt: Bool?
}

struct FileFavoriteAddRequest: Encodable {
    let path: String
}

struct FileFavoriteSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
}

struct FileFavoriteDeleteRequest: Encodable {
    let id: Int
}

