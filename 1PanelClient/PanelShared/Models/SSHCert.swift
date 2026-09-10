//
//  SSHCert.swift
//  1PanelClient
//
//  SSH 密钥管理（面板主机的密钥对，/api/v2/hosts/ssh/cert/*）
//  通过 logs/分组与类别.md 抓包验证；私钥/公钥/密码均 base64 编码后传输
//

import Foundation

// MARK: - 模型

/// SSH 密钥（response 项，见 hosts/ssh/cert/search）
nonisolated struct SSHCertItem: Decodable, Identifiable, Hashable {
    let id: Int
    let createdAt: String?
    let name: String?
    /// ed25519 / ecdsa / rsa / dsa
    let encryptionMode: String?
    /// 密码（未设置为空串）
    let passPhrase: String?
    let publicKey: String?
    let privateKey: String?
    let description: String?
}

extension SSHCertItem {
    /// base64 解码展示用（服务端字段为 base64；解码失败回退原文，兼容明文返回；
    /// 空值返回 nil）
    static func decodeBase64(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        if let data = Data(base64Encoded: text), let decoded = String(data: data, encoding: .utf8) {
            return decoded
        }
        return text
    }
}

// MARK: - 创建/编辑

/// 创建方式（mode 字段）
enum SSHCertCreateMode: String, CaseIterable, Identifiable {
    /// 自动生成密钥对
    case generate = "generate"
    /// 手动输入私钥/公钥
    case input = "input"
    /// 从本地文件导入私钥/公钥
    case importFiles = "import"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .generate:    return L10n.t("自动生成")
        case .input:       return L10n.t("手动输入")
        case .importFiles: return L10n.t("文件上传")
        }
    }
}

/// 加密方式（encryptionMode 字段）
enum SSHCertEncryption: String, CaseIterable, Identifiable {
    case ed25519
    case ecdsa
    case rsa
    case dsa

    var id: String { rawValue }

    var displayName: String { rawValue.uppercased() }
}

/// 创建 SSH 密钥请求（POST /api/v2/hosts/ssh/cert）
/// generate 只需名称/加密方式（密码可选）；input/import 需 base64 后的私钥（公钥可选）
nonisolated struct SSHCertCreateRequest: Encodable {
    var mode: String
    var encryptionMode: String
    var name: String
    var description: String = ""
    var passPhrase: String = ""
    var privateKey: String = ""
    var publicKey: String = ""
}

/// 更新 SSH 密钥请求（POST /api/v2/hosts/ssh/cert/update）
/// 仅改名称/描述；公私钥/密码未修改时原样回传服务端值（同 SSH 主机编辑凭据的回传约定）
nonisolated struct SSHCertUpdateRequest: Encodable {
    let id: Int
    let createdAt: String?
    let name: String
    let encryptionMode: String
    let passPhrase: String
    let publicKey: String
    let privateKey: String
    let description: String
    /// 服务端要求回传的回显字段（抓包值为 input，创建方式本身不可改）
    let mode: String
}

// MARK: - 查询/删除

/// 密钥列表查询
nonisolated struct SSHCertSearchRequest: Encodable {
    var page: Int = 1
    var pageSize: Int = 100
}

/// 删除 SSH 密钥请求（POST /api/v2/hosts/ssh/cert/delete）
nonisolated struct SSHCertDeleteRequest: Encodable {
    let ids: [Int]
    var forceDelete: Bool = false
}
