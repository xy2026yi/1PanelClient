//
//  PanelPasswordCrypto.swift
//  1PanelClient
//
//  面板登录密码混合加密（1Panel v2.4.x 网页端 encryptPassword 同款，抓包三段结构实证）：
//    段1 = RSA-2048/PKCS1v1.5( AES key )，公钥取自 panel_public_key cookie
//    段2 = 随机 16B IV 的 base64
//    段3 = AES-256-CBC/PKCS7( password, key = 32 字节 ASCII hex 串, iv ) 的 base64
//    最终 = 段1:段2:段3（冒号分隔）
//  panel_public_key cookie 不存在时回落明文（对齐网页端行为）。
//  注意：current/update 通道的密码是纯 Base64，另一编码，勿混用。
//

import Foundation
import CommonCrypto
import Security

nonisolated enum PanelPasswordCrypto {

    enum CryptoError: LocalizedError {
        case badPublicKey
        case rsaEncryptFailed(String)
        case aesFailed(OSStatus)
        case randomFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .badPublicKey:
                return L10n.t("面板公钥无效，无法加密登录密码")
            case .rsaEncryptFailed(let detail):
                return L10n.f("登录密码加密失败（RSA）：%@", detail)
            case .aesFailed(let status):
                return L10n.f("登录密码加密失败（AES：%ld）", Int(status))
            case .randomFailed(let status):
                return L10n.f("随机数生成失败（%ld）", Int(status))
            }
        }
    }

    // MARK: - 入口

    /// 明文密码 → 三段混合加密串；公钥缺失/不可解析时回落明文（网页端同款行为）
    static func encrypt(password: String, publicKeyPEM: String?) throws -> String {
        guard let pem = publicKeyPEM, !pem.isEmpty else {
            return password
        }
        // AES key = 32 字节 ASCII hex 串（原样字节参与运算，不做 hex 解码）
        let key = randomHex(characterCount: 32)
        let iv = randomBytes(count: 16)
        let cipher = try aesCBCEncrypt(
            data: Data(password.utf8),
            key: Data(key.utf8),
            iv: Data(iv)
        )
        let keyCipher = try rsaEncryptPKCS1(data: Data(key.utf8), pem: pem)
        return [keyCipher, Data(iv).base64EncodedString(), cipher].joined(separator: ":")
    }

    // MARK: - 公钥 cookie 解码

    /// panel_public_key cookie 值 → PEM 公钥。
    /// 服务端下发的是 URL 编码的 base64（整段 PEM 文本再 base64）：
    /// 百分号解码（还原 %3D 等）→ 容错把空格还原为 '+'（部分链路会把 + 空格化）→
    /// base64 解码 → 必须含 PEM 头才算有效，否则返回 nil（调用方回落明文）
    static func publicKeyPEM(fromCookieValue raw: String) -> String? {
        var value = raw.removingPercentEncoding ?? raw
        value = value.replacingOccurrences(of: " ", with: "+")
        guard let data = Data(base64Encoded: value),
              let pem = String(data: data, encoding: .utf8),
              pem.contains("BEGIN PUBLIC KEY") else {
            return nil
        }
        return pem
    }

    // MARK: - RSA（Security 框架，CryptoKit 无 RSA）

    private static func rsaEncryptPKCS1(data: Data, pem: String) throws -> String {
        guard let key = secPublicKey(fromPEM: pem) else {
            throw CryptoError.badPublicKey
        }
        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(
            key, .rsaEncryptionPKCS1, data as CFData, &error
        ) as Data? else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "unknown"
            throw CryptoError.rsaEncryptFailed(detail)
        }
        return encrypted.base64EncodedString()
    }

    /// PEM → SecKey。面板下发的 panel_public_key 是 SPKI（"BEGIN PUBLIC KEY"，
    /// 实捕 DER 294B：24B 头 + PKCS#1 270B）；Apple SecKeyCreateWithData 期望
    /// PKCS#1，故先按 ASN.1 剥出 BIT STRING 内层；剥不出时按原始 DER 兜底
    /// （兼容 "BEGIN RSA PUBLIC KEY" 直发 PKCS#1 的形态）
    private static func secPublicKey(fromPEM pem: String) -> SecKey? {
        // 剥掉 BEGIN/END 行与其余杂项，拼接 base64 体
        let body = pem
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: body) else { return nil }
        let candidates = [rsaPublicKeyDER(fromSPKI: der), der].compactMap { $0 }
        var lastError: Unmanaged<CFError>?
        for candidate in candidates {
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic
            ]
            lastError = nil
            if let key = SecKeyCreateWithData(candidate as CFData, attributes as CFDictionary, &lastError) {
                return key
            }
        }
        _ = lastError
        return nil
    }

    /// SPKI DER → 内嵌的 PKCS#1 RSA 公钥 DER（最小 ASN.1 走读：
    /// SEQUENCE { SEQUENCE(算法) BIT STRING(0x00 unused-bits + RSAPublicKey) }
    private static func rsaPublicKeyDER(fromSPKI der: Data) -> Data? {
        guard let spki = asn1Node(in: der), spki.tag == 0x30 else { return nil }
        guard let algID = asn1Node(in: spki.content), algID.tag == 0x30 else { return nil }
        let remainder = spki.content.dropFirst(algID.totalLength)
        guard let bitString = asn1Node(in: Data(remainder)), bitString.tag == 0x03,
              bitString.content.count > 1 else { return nil }
        // 首字节为 unused-bits（0），其后即 PKCS#1
        return bitString.content.dropFirst()
    }

    private struct ASN1Node {
        let tag: UInt8
        let content: Data
        let totalLength: Int
    }

    /// 解析单个顶层 ASN.1 节点（content 覆盖其声明长度）
    private static func asn1Node(in data: Data) -> ASN1Node? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        let tag = bytes[0]
        let first = bytes[1]
        var offset = 2
        var length = 0
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            guard count >= 1, count <= 4, bytes.count >= offset + count else { return nil }
            for i in 0..<count {
                length = (length << 8) | Int(bytes[offset + i])
            }
            offset += count
        }
        guard bytes.count >= offset + length else { return nil }
        return ASN1Node(tag: tag, content: Data(bytes[offset..<(offset + length)]), totalLength: offset + length)
    }

    // MARK: - AES-256-CBC/PKCS7（CommonCrypto，CryptoKit 无 CBC）

    /// internal 供单测固定向量对拍（PanelPasswordCryptoTests）
    static func aesCBCEncrypt(data: Data, key: Data, iv: Data) throws -> String {
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else {
            throw CryptoError.aesFailed(OSStatus(kCCParamError))
        }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                iv.withUnsafeBytes { ivPtr in
                    key.withUnsafeBytes { keyPtr in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, data.count,
                            outPtr.baseAddress, outPtr.count,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw CryptoError.aesFailed(status)
        }
        output.removeSubrange(outputLength..<output.count)
        return output.base64EncodedString()
    }

    // MARK: - 随机源（SecRandom，加密强度）

    static func randomBytes(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            // SecRandomCopyBytes 理论上不失败（读 /dev/urandom）；兜底 arc4random_buf
            arc4random_buf(&bytes, count)
            return bytes
        }
        return bytes
    }

    /// 随机十六进制串：characterCount 个 [0-9a-f] 字符
    static func randomHex(characterCount: Int) -> String {
        let byteCount = (characterCount + 1) / 2
        let bytes = randomBytes(count: byteCount)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(characterCount))
    }
}
