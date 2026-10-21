//
//  ServerBackup.swift
//  1PanelClient
//
//  服务器配置备份编解码：[ServerConfig]（含 Keychain 中的 API Key 合流）→
//  AES-256-GCM 加密。密钥为导出时随机生成的 32 字节、base64 形态展示与
//  粘贴——均匀随机的 256 位密钥无需口令拉伸派生；不落盘不进 UserDefaults，
//  仅导出成功页展示一次，保管责任在用户。
//  文件头 magic+版本先于密文，导入侧据此识别格式；GCM 认证标签使错密钥与
//  篡改都能被干净地检出。备份文件含 API Key 明文（加密后），文件与密钥
//  请分开存放。
//

import CryptoKit
import Foundation

enum ServerBackupError: LocalizedError {
    /// 密钥不是合法的 32 字节 base64
    case badKey
    /// 文件头不符（magic / 版本 / 长度）
    case notBackupFile
    /// GCM 认证失败：密钥错误或内容被篡改
    case corrupt

    var errorDescription: String? {
        switch self {
        case .badKey, .corrupt:
            return L10n.t("密钥错误或备份文件已损坏")
        case .notBackupFile:
            return L10n.t("不是有效的备份文件")
        }
    }
}

nonisolated enum ServerBackup {

    /// 文件头：magic 识别格式，版本字节留格式演进空间
    private static let magic = Data("1PCSRVBK".utf8)
    private static let version: UInt8 = 1

    /// 密文内的明文信封（版本化，未来可扩展偏好等字段）
    private struct Envelope: Codable {
        let v: Int
        let servers: [ServerConfig]
    }

    /// 随机生成备份密钥（32 字节 → 44 字符 base64）
    static func generateKey() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
    }

    /// 备份文件名：沿用 1Panel-servers-<ISO8601 时间戳>.enc 形态
    static func backupFileName(at date: Date = .now) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "1Panel-servers-\(formatter.string(from: date)).enc"
    }

    /// 加密打包服务器列表；keyBase64 须为 generateKey 同形态的 32 字节 base64
    static func seal(_ servers: [ServerConfig], keyBase64: String) throws -> Data {
        let key = try parseKey(keyBase64)
        let plaintext = try JSONEncoder().encode(Envelope(v: Int(version), servers: servers))
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw ServerBackupError.corrupt }
        var out = magic
        out.append(version)
        out.append(combined)
        return out
    }

    /// 解密还原服务器列表；密钥错误/篡改/格式不符均抛 ServerBackupError
    static func open(_ data: Data, keyBase64: String) throws -> [ServerConfig] {
        let key = try parseKey(keyBase64)
        guard data.count > magic.count + 1,
              data.prefix(magic.count) == magic,
              data[data.index(data.startIndex, offsetBy: magic.count)] == version
        else { throw ServerBackupError.notBackupFile }
        do {
            let box = try AES.GCM.SealedBox(combined: Data(data.dropFirst(magic.count + 1)))
            let plaintext = try AES.GCM.open(box, using: key)
            return try JSONDecoder().decode(Envelope.self, from: plaintext).servers
        } catch {
            throw ServerBackupError.corrupt
        }
    }

    private static func parseKey(_ raw: String) throws -> SymmetricKey {
        guard let data = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              data.count == 32 else { throw ServerBackupError.badKey }
        return SymmetricKey(data: data)
    }
}
