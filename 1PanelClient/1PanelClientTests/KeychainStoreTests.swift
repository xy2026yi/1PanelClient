//
//  KeychainStoreTests.swift
//  1PanelClientTests
//
//  API Key 的 Keychain 增删改查往返（模拟器环境）
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("KeychainStore")
struct KeychainStoreTests {
    @Test("保存/覆盖/读取/删除往返")
    func roundTrip() {
        let key = "test.\(UUID().uuidString)"
        defer { KeychainStore.delete(for: key) }

        // 未写入前读取为 nil
        #expect(KeychainStore.read(for: key) == nil)

        KeychainStore.save("secret-密钥-1", for: key)
        #expect(KeychainStore.read(for: key) == "secret-密钥-1")

        // 同名条目覆盖写
        KeychainStore.save("rotated-key-2", for: key)
        #expect(KeychainStore.read(for: key) == "rotated-key-2")

        KeychainStore.delete(for: key)
        #expect(KeychainStore.read(for: key) == nil)
    }

    @Test("readWithStatus：未写入时返回非成功状态码")
    func statusForMissingItem() {
        let key = "test.missing.\(UUID().uuidString)"
        let (value, status) = KeychainStore.readWithStatus(for: key)
        #expect(value == nil)
        #expect(status != errSecSuccess)
    }
}
