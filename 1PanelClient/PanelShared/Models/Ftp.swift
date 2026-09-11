//
//  Ftp.swift
//  1PanelClient
//
//  FTP 工具箱（/toolbox/ftp）：安装状态 / 账号管理 / 用户日志
//

import Foundation

/// GET /api/v2/toolbox/ftp/base：安装与运行状态
nonisolated struct FTPBase: Decodable {
    let isActive: Bool
    let isExist: Bool
}

/// 账号列表搜索请求
nonisolated struct FTPSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
}

/// FTP 账号（/toolbox/ftp/search 返回 items）
nonisolated struct FTPItem: Decodable, Identifiable, Hashable {
    let id: Int
    let createdAt: String?
    let user: String
    /// 服务端返回明文密码
    let password: String
    let path: String
    /// "Enable" / "Disable"
    let status: String?
    let description: String?

    var isEnabled: Bool { status?.lowercased() == "enable" }
}

/// 创建账号：密码 base64 编码；无描述时省略 description 字段
nonisolated struct FTPCreateRequest: Encodable {
    let user: String
    let password: String
    let path: String
    let description: String?
}

/// 更新账号：全字段回传（与网页端一致，密码 base64 编码）
nonisolated struct FTPUpdateRequest: Encodable {
    let id: Int
    let createdAt: String?
    let user: String
    let password: String
    let path: String
    let status: String?
    let description: String?
}

/// 服务操作 {operation: start | stop | restart}
nonisolated struct FTPOperateRequest: Encodable {
    let operation: String
}

/// 删除账号 {ids}
nonisolated struct FTPDeleteRequest: Encodable {
    let ids: [Int]
}

/// 用户日志搜索：operation 空串为全部，"PUT" 上传 / "GET" 下载
nonisolated struct FTPLogSearchRequest: Encodable {
    let user: String
    let operation: String
    let page: Int
    let pageSize: Int
}

/// FTP 用户日志行（/toolbox/ftp/log/search 返回 items）
nonisolated struct FTPLogItem: Decodable, Hashable {
    let ip: String?
    let user: String?
    let time: String?
    /// 原始操作串，如 "\"GET/tmp/test1/README.md\""
    let operation: String?
    let status: String?
    let size: String?
}
