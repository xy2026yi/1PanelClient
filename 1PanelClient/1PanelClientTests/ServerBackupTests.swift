//
//  ServerBackupTests.swift
//  1PanelClientTests
//
//  服务器配置备份编解码测试：roundtrip / 错密钥 / 篡改 / 格式头 / 密钥形态。
//  全部使用虚构服务器数据，不含任何真实凭据
//

import Foundation
import Testing
@testable import _PanelClient

@Suite("服务器备份编解码")
struct ServerBackupTests {

    /// 虚构服务器样本（无真实凭据）
    private func fakeServers(_ n: Int) -> [ServerConfig] {
        (0..<n).map { i in
            ServerConfig(name: "测试\(i)",
                         baseURL: "https://example-\(i).invalid",
                         apiKey: "fake-key-\(i)")
        }
    }

    @Test("roundtrip：加解密往返完整还原服务器列表")
    func roundtrip() throws {
        let key = ServerBackup.generateKey()
        let servers = fakeServers(3)
        let sealed = try ServerBackup.seal(servers, keyBase64: key)
        let opened = try ServerBackup.open(sealed, keyBase64: key)
        #expect(opened == servers)
    }

    @Test("空列表可导出可还原（导出侧 UI 另行拦截，编解码层不设限）")
    func emptyRoundtrip() throws {
        let key = ServerBackup.generateKey()
        let sealed = try ServerBackup.seal([], keyBase64: key)
        #expect(try ServerBackup.open(sealed, keyBase64: key).isEmpty)
    }

    @Test("错密钥：GCM 认证失败抛 corrupt")
    func wrongKeyThrows() throws {
        let sealed = try ServerBackup.seal(fakeServers(1), keyBase64: ServerBackup.generateKey())
        #expect(throws: ServerBackupError.corrupt) {
            _ = try ServerBackup.open(sealed, keyBase64: ServerBackup.generateKey())
        }
    }

    @Test("密文被篡改：认证失败抛 corrupt（含明文与密钥均未变的场景对照）")
    func tamperThrows() throws {
        let key = ServerBackup.generateKey()
        var sealed = try ServerBackup.seal(fakeServers(2), keyBase64: key)
        sealed[sealed.count - 1] ^= 0xFF
        #expect(throws: ServerBackupError.corrupt) {
            _ = try ServerBackup.open(sealed, keyBase64: key)
        }
    }

    @Test("非备份文件（magic/长度不符）抛 notBackupFile")
    func badMagicThrows() {
        #expect(throws: ServerBackupError.notBackupFile) {
            _ = try ServerBackup.open(Data("not a backup".utf8),
                                      keyBase64: ServerBackup.generateKey())
        }
    }

    @Test("密钥形态不符（非 32 字节 base64）抛 badKey")
    func badKeyThrows() {
        #expect(throws: ServerBackupError.badKey) {
            _ = try ServerBackup.seal(fakeServers(1), keyBase64: "short")
        }
        #expect(throws: ServerBackupError.badKey) {
            _ = try ServerBackup.seal(fakeServers(1), keyBase64: Data("16bytes".utf8).base64EncodedString())
        }
    }

    @Test("生成密钥：44 字符 base64、解码 32 字节、两次生成互异")
    func generatedKeyShape() throws {
        let a = ServerBackup.generateKey()
        let b = ServerBackup.generateKey()
        #expect(a.count == 44)
        #expect(try Data(base64Encoded: a)?.count == 32)
        #expect(a != b)
    }

    @Test("文件名：1Panel-servers- 前缀 + .enc 后缀")
    func fileNameShape() {
        let name = ServerBackup.backupFileName(at: Date(timeIntervalSince1970: 1_777_000_000))
        #expect(name.hasPrefix("1Panel-servers-"))
        #expect(name.hasSuffix(".enc"))
    }

    @Test("合并计划：与现有同址跳过、新址新增、文件内部同址重复只取首个、空址忽略")
    func mergePlanDedup() {
        let incoming = [
            ServerConfig(name: "已有", baseURL: "https://a.invalid/", apiKey: "k1"),
            ServerConfig(name: "新", baseURL: "https://b.invalid", apiKey: "k2"),
            ServerConfig(name: "新-重复", baseURL: "https://b.invalid/", apiKey: "k3"),
            ServerConfig(name: "空址", baseURL: "   ", apiKey: "k4"),
        ]
        let plan = ServerBackup.mergePlan(incoming, existingURLs: ["https://a.invalid"])
        #expect(plan.add.map(\.name) == ["新"])
        #expect(plan.skipped == 2)
    }

    @Test("合并计划：现有为空时全部新增（仍吸收文件内部重复）")
    func mergePlanFreshDevice() {
        let incoming = [
            ServerConfig(name: "x", baseURL: "https://x.invalid", apiKey: "k"),
            ServerConfig(name: "x-again", baseURL: "https://x.invalid", apiKey: "k"),
        ]
        let plan = ServerBackup.mergePlan(incoming, existingURLs: [])
        #expect(plan.add.count == 1)
        #expect(plan.skipped == 1)
    }
}
