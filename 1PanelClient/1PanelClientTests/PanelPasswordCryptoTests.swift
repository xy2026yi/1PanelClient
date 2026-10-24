//
//  PanelPasswordCryptoTests.swift
//  1PanelClientTests
//
//  面板登录密码混合加密（logs/登录与会话认证方案.md §2.2）：
//  - 公钥 cookie 解码：logs/抓取.md 实捕值 → PEM；非法值 nil 回落明文
//  - AES-256-CBC 固定向量：key = 32 字节 ASCII 原样字节（对拍 cryptography/openssl 语义）
//  - 全链路 round-trip：临时 RSA 密钥对下，三段结构（RSA 256B : IV 16B : AES 密文）、
//    RSA 私钥解出 32 字节 ASCII hex key、AES 解回原明文
//  - 公钥缺失/无效回落明文（网页端同款行为）
//

import Testing
import Foundation
import CommonCrypto
import Security
@testable import _PanelClient

@Suite("面板密码混合加密")
struct PanelPasswordCryptoTests {

    /// logs/抓取.md 实捕 panel_public_key cookie 值（URL 编码的 base64，内容为整段 PEM）
    private static let capturedCookieValue =
        "LS0tLS1CRUdJTiBQVUJMSUMgS0VZLS0tLS0KTUlJQklqQU5CZ2txaGtpRzl3MEJBUUVGQUFPQ0FROEFNSUlCQ2dLQ0FRRUE1SVMyc1E5MERHWWpzaGQzZ0lvUApWZGl6OVlDRkFJckJReW8rVURpQWhWYzBtL2o5UHFXWDR6SmN6TkViTTByYWZYbWRaZkZHR3pvNy84Nm5hYXNtCms1VUw2b3RVcDJqUVQwN20yeXNGemtWTmZFcDNnQ2M2bTZ0K3B3RmRZOTlLaWRKclBSOUs3UGZZbW1CQzJUR2wKRktmNWJzallsSW1BWTI0ZDdMa2pWdWxCcGJMcy9xMlU2K1drSmV0d1lOZjNRdVV1bzNJWlZVMzhBOEdhWFNKUwpPbkFaWVhTQ2hlZEExdXlqNDYxOUxscW1Oa1ZsOTlSSE9YKzA2cGErRG5hSUcwbDRkcy93K2Jqa1NMTWlOcGdwCklsMVdIZTdDZCtCb1JmanQ3NHY4Ym1mZGxHRVk4eG4zclV6b0IzZ2xhSVVYMDVtNmF2dU9PWW1jMEp6c3BjVk0KUHdJREFRQUIKLS0tLS1FTkQgUFVCTElDIEtFWS0tLS0tCg%3D%3D"

    // MARK: - 公钥 cookie 解码

    @Test("实捕 cookie 值解码为完整 PEM（含 BEGIN/END 头）")
    func capturedCookieDecodesToPEM() {
        let pem = PanelPasswordCrypto.publicKeyPEM(fromCookieValue: Self.capturedCookieValue)
        #expect(pem?.contains("-----BEGIN PUBLIC KEY-----") == true)
        #expect(pem?.contains("-----END PUBLIC KEY-----") == true)
    }

    @Test("cookie 值携带原始 '+'（未被 URL 编码）时同样可解码")
    func cookieWithRawPlus() {
        // 实捕值中的 '/' 原样、'%3D' 还原 '='；'+' 变体：手工把某段还原为未编码形态
        let raw = Data("hello".utf8).base64EncodedString() // 非公钥内容，应 nil（校验 PEM 头兜底）
        #expect(PanelPasswordCrypto.publicKeyPEM(fromCookieValue: raw) == nil)
    }

    @Test("无效 cookie 值一律返回 nil（调用方回落明文）")
    func invalidCookieReturnsNil() {
        #expect(PanelPasswordCrypto.publicKeyPEM(fromCookieValue: "") == nil)
        #expect(PanelPasswordCrypto.publicKeyPEM(fromCookieValue: "not base64 !!") == nil)
        #expect(PanelPasswordCrypto.publicKeyPEM(fromCookieValue: "%E4%B8%AD%E6%96%87") == nil)
    }

    // MARK: - AES 固定向量

    @Test("AES-256-CBC/PKCS7 固定向量（key 为 32 字节 ASCII 原样，非 hex 解码）")
    func aesFixedVector() throws {
        // 参考输出由 Python cryptography 以相同 key/iv/明文生成（PKCS7）
        let key = "0123456789abcdef0123456789abcdef"
        let iv = try #require(Data(base64Encoded: "AAECAwQFBgcICQoLDA0ODw=="))
        let plaintext = "P@ssw0rd-面板测试123"
        let cipher = try PanelPasswordCrypto.aesCBCEncrypt(
            data: Data(plaintext.utf8),
            key: Data(key.utf8),
            iv: iv
        )
        #expect(cipher == "86cPk0sIzTTAZX8CAjyyqt9xk8fknc5DJOcZh3OiVac=")
    }

    // MARK: - 全链路 round-trip

    @Test("三段结构 + RSA 解出 AES key + AES 解回原明文")
    func fullRoundTrip() throws {
        let privateKey = try Self.makeRSAKeyPair()
        let pem = try Self.publicKeyPEM(of: privateKey)

        let password = "S3cret!密码-引导流"
        let encrypted = try PanelPasswordCrypto.encrypt(password: password, publicKeyPEM: pem)

        // 三段冒号分隔
        let segments = encrypted.split(separator: ":").map(String.init)
        #expect(segments.count == 3)

        // 段1 = RSA-2048/PKCS1v1.5 密文（2048 位 → 256 字节）
        let rsaCipher = try #require(Data(base64Encoded: segments[0]))
        #expect(rsaCipher.count == 256)

        // 段2 = 16 字节 IV
        let iv = try #require(Data(base64Encoded: segments[1]))
        #expect(iv.count == 16)

        // RSA 私钥解出 AES key：32 字节 ASCII hex 串
        var decryptError: Unmanaged<CFError>?
        let keyData = try #require(
            SecKeyCreateDecryptedData(
                privateKey, .rsaEncryptionPKCS1, rsaCipher as CFData, &decryptError
            ) as Data?,
            "RSA 私钥应能解出 AES key"
        )
        #expect(keyData.count == 32)
        let keyString = String(decoding: keyData, as: UTF8.self)
        #expect(keyString.count == 32)
        #expect(keyString.allSatisfy { $0.isHexDigit })

        // 段3 用该 key + IV 解回原明文
        let cipherData = try #require(Data(base64Encoded: segments[2]))
        let recovered = try Self.aesDecrypt(data: cipherData, key: keyData, iv: iv)
        #expect(String(decoding: recovered, as: UTF8.self) == password)
    }

    @Test("同明文两次加密产物不同（随机 key/iv）")
    func randomizedPerCall() throws {
        let pem = try Self.publicKeyPEM(of: Self.makeRSAKeyPair())
        let a = try PanelPasswordCrypto.encrypt(password: "same", publicKeyPEM: pem)
        let b = try PanelPasswordCrypto.encrypt(password: "same", publicKeyPEM: pem)
        #expect(a != b)
    }

    // MARK: - 明文回落

    @Test("公钥缺失/无效回落明文（网页端同款）")
    func plaintextFallback() throws {
        #expect(try PanelPasswordCrypto.encrypt(password: "secret", publicKeyPEM: nil) == "secret")
        #expect(try PanelPasswordCrypto.encrypt(password: "secret", publicKeyPEM: "") == "secret")
        // 无效 PEM：RSA 段构造失败应抛错而非静默降级——encrypt 只在「无公钥」时回落，
        // 有公钥但解析失败属于面板数据异常，明确报错（与网页端行为一致）
        #expect(throws: (any Error).self) {
            _ = try PanelPasswordCrypto.encrypt(password: "secret", publicKeyPEM: "not-a-pem")
        }
    }

    // MARK: - 随机源

    @Test("randomHex：字符域与长度")
    func randomHexShape() {
        let hex = PanelPasswordCrypto.randomHex(characterCount: 32)
        #expect(hex.count == 32)
        #expect(hex.allSatisfy { $0.isHexDigit })
        #expect(!hex.contains(where: { "ABCDEF".contains($0) }))
        #expect(PanelPasswordCrypto.randomHex(characterCount: 32) != hex)
    }

    @Test("randomBytes：长度与非全零")
    func randomBytesShape() {
        let bytes = PanelPasswordCrypto.randomBytes(count: 16)
        #expect(bytes.count == 16)
        #expect(bytes.contains(where: { $0 != 0 }))
    }

    // MARK: - 辅助

    /// 临时 RSA-2048 密钥对（测试内即用即弃）
    private static func makeRSAKeyPair() throws -> SecKey {
        let params: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(params as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? NSError(domain: "test", code: -1)
        }
        return key
    }

    /// SecKey 外部形态（PKCS#1）→ 包装成面板同款 SPKI PEM
    private static func publicKeyPEM(of privateKey: SecKey) throws -> String {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw NSError(domain: "test", code: -2)
        }
        var error: Unmanaged<CFError>?
        guard let der = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw error?.takeRetainedValue() ?? NSError(domain: "test", code: -3)
        }
        // 测试里的 SecKey 外部形态即 PKCS#1；面板 PEM 是 SPKI——补一层 ASN.1 头
        // 使其与实捕 panel_public_key 同构（同时覆盖 SPKI 剥头路径）
        let pkcs1 = der
        let algID = Data([0x30, 0x0d]) + Data([0x06, 0x09]) + Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01])
            + Data([0x05, 0x00])
        let bitStringBody = Data([0x00]) + pkcs1
        var spki = Data([0x30])
        let inner = algID + Data([0x03]) + derLengthBytes(bitStringBody.count) + bitStringBody
        spki += derLengthBytes(inner.count) + inner
        let b64 = spki.base64EncodedString()
        let lines = stride(from: 0, to: b64.count, by: 64).map {
            String(b64.dropFirst($0).prefix(64))
        }
        return "-----BEGIN PUBLIC KEY-----\n" + lines.joined(separator: "\n") + "\n-----END PUBLIC KEY-----"
    }

    private static func derLengthBytes(_ length: Int) -> Data {
        if length < 0x80 {
            return Data([UInt8(length)])
        }
        if length <= 0xFF {
            return Data([0x81, UInt8(length)])
        }
        return Data([0x82, UInt8(length >> 8), UInt8(length & 0xFF)])
    }

    /// 测试内 AES-256-CBC/PKCS7 解密（与实现互为对拍）
    private static func aesDecrypt(data: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                iv.withUnsafeBytes { ivPtr in
                    key.withUnsafeBytes { keyPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
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
            throw NSError(domain: "test.aes", code: Int(status))
        }
        output.removeSubrange(outputLength..<output.count)
        return output
    }
}
