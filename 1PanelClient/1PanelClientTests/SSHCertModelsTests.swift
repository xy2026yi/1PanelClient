//
//  SSHCertModelsTests.swift
//  1PanelClientTests
//
//  SSH 密钥模型与请求编解码验证：向量取自网页端抓包（logs/分组与类别.md）
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("SSH 密钥模型")
struct SSHCertModelsTests {
    // MARK: - 解码（抓包原始 JSON）

    @Test("SSHCertItem：cert/search 响应项解码")
    func decodeCert() throws {
        let json = """
        {"id":1,"createdAt":"2026-08-22T19:22:20.367093595+08:00",
         "name":"id_ed25519_1panel","encryptionMode":"ed25519","passPhrase":"",
         "publicKey":"c3NoLWVkMjU1MTkgQUFBQUMz","privateKey":"LS0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0K",
         "description":"1Panel Terminal"}
        """
        let cert = try JSONDecoder().decode(SSHCertItem.self, from: Data(json.utf8))
        #expect(cert.id == 1)
        #expect(cert.name == "id_ed25519_1panel")
        #expect(cert.encryptionMode == "ed25519")
        #expect(cert.passPhrase == "")
        #expect(cert.description == "1Panel Terminal")
    }

    // MARK: - 创建请求（三模式 + base64 传输）

    @Test("SSHCertCreateRequest：自动生成只需名称/加密方式")
    func encodeGenerate() throws {
        let req = SSHCertCreateRequest(mode: "generate", encryptionMode: "ed25519", name: "123")
        let dict = try encodeToDict(req)
        #expect(dict["mode"] as? String == "generate")
        #expect(dict["encryptionMode"] as? String == "ed25519")
        #expect(dict["name"] as? String == "123")
        #expect(dict["passPhrase"] as? String == "")
    }

    @Test("SSHCertCreateRequest：生成 + 随机密码 + 描述（密码 base64）")
    func encodeGenerateWithPassPhrase() throws {
        var req = SSHCertCreateRequest(mode: "generate", encryptionMode: "ed25519", name: "111111")
        req.description = "1111111"
        req.passPhrase = Data("hpxjNNnCEX".utf8).base64EncodedString()
        let dict = try encodeToDict(req)
        #expect(dict["passPhrase"] as? String == "aHB4ak5ObkNFWA==")
        #expect(dict["description"] as? String == "1111111")
    }

    @Test("SSHCertCreateRequest：手动输入 mode=input，私钥公钥 base64")
    func encodeInput() throws {
        var req = SSHCertCreateRequest(mode: "input", encryptionMode: "ed25519", name: "1234")
        // 与抓包样本一致：OpenSSH 私钥文本以换行结尾，base64 后首块为 LS0t…S0VZLS0tLS0K
        req.privateKey = Data("-----BEGIN OPENSSH PRIVATE KEY-----\n".utf8).base64EncodedString()
        req.publicKey = Data("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5".utf8).base64EncodedString()
        let dict = try encodeToDict(req)
        #expect(dict["mode"] as? String == "input")
        #expect(dict["privateKey"] as? String == "LS0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0K")
        #expect(dict["publicKey"] as? String == Data("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5".utf8).base64EncodedString())
    }

    @Test("SSHCertCreateRequest：文件上传 mode=import")
    func encodeImport() throws {
        let req = SSHCertCreateRequest(mode: "import", encryptionMode: "ed25519", name: "123456")
        #expect(req.mode == "import")
        let dict = try encodeToDict(req)
        #expect(dict["mode"] as? String == "import")
    }

    // MARK: - 更新/删除请求

    @Test("SSHCertUpdateRequest：编辑回传完整对象（含原样公私钥）")
    func encodeUpdate() throws {
        let req = SSHCertUpdateRequest(
            id: 2,
            createdAt: "2026-09-10T13:06:41.135324892+08:00",
            name: "123",
            encryptionMode: "ed25519",
            passPhrase: "",
            publicKey: "c3NoLWVkMjU1MTkgQUFBQUMz",
            privateKey: "LS0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0K",
            description: "111",
            mode: "input"
        )
        let dict = try encodeToDict(req)
        #expect(dict["id"] as? Int == 2)
        #expect(dict["isDefault"] == nil)  // 分组接口才有，密钥无此字段
        #expect(dict["publicKey"] as? String == "c3NoLWVkMjU1MTkgQUFBQUMz")
        #expect(dict["privateKey"] as? String == req.privateKey)
        #expect(dict["mode"] as? String == "input")
    }

    @Test("SSHCertDeleteRequest：ids 数组 + forceDelete 开关")
    func encodeDelete() throws {
        let req = SSHCertDeleteRequest(ids: [5], forceDelete: true)
        let dict = try encodeToDict(req)
        #expect(dict["ids"] as? [Int] == [5])
        #expect(dict["forceDelete"] as? Bool == true)
        // 默认不强制
        let def = try encodeToDict(SSHCertDeleteRequest(ids: [5]))
        #expect(def["forceDelete"] as? Bool == false)
    }

    // MARK: - 枚举

    @Test("SSHCertCreateMode：三种创建方式对应服务端 mode 值")
    func createModeRawValues() {
        #expect(SSHCertCreateMode.generate.rawValue == "generate")
        #expect(SSHCertCreateMode.input.rawValue == "input")
        #expect(SSHCertCreateMode.importFiles.rawValue == "import")
        #expect(SSHCertEncryption.allCases.map(\.rawValue) == ["ed25519", "ecdsa", "rsa", "dsa"])
    }

    // MARK: - 工具

    private func encodeToDict<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as? [String: Any] ?? [:]
    }
}
