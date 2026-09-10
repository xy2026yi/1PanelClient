//
//  SSHSessionModelsTests.swift
//  1PanelClientTests
//
//  SSH 在线会话与授权密钥请求的编解码验证：
//  向量取自网页端抓包（logs/SSH服务管理.md）
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("SSH 会话模型")
struct SSHSessionModelsTests {
    @Test("SSHSessionItem：process/ws (type=ssh) 响应项解码")
    func decodeSession() throws {
        let json = """
        [{"username":"root","PID":118393,"terminal":"","host":"192.168.50.200","loginTime":"2026-9-10 13:24:19"}]
        """
        let sessions = try JSONDecoder().decode([SSHSessionItem].self, from: Data(json.utf8))
        #expect(sessions.count == 1)
        let s = sessions[0]
        #expect(s.username == "root")
        #expect(s.pid == 118393)
        #expect(s.host == "192.168.50.200")
        #expect(s.loginTime == "2026-9-10 13:24:19")
        #expect(s.id == 118393)
        #expect(s.displayTitle == "root@192.168.50.200")
    }

    @Test("SSHSessionItem：host 缺失时 displayTitle 只显示用户")
    func displayTitleWithoutHost() throws {
        let json = """
        {"username":"root","PID":1,"terminal":"","host":"","loginTime":""}
        """
        let s = try JSONDecoder().decode(SSHSessionItem.self, from: Data(json.utf8))
        #expect(s.displayTitle == "root")
    }

    @Test("SSHFileUpdateRequest：授权密钥保存带空 path（对齐抓包）")
    func encodeAuthKeysUpdate() throws {
        let req = SSHFileUpdateRequest(key: "authKeys", path: "", value: "ssh-ed25519 AAAA root@1Panel")
        let data = try JSONEncoder().encode(req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["key"] as? String == "authKeys")
        #expect(obj?["path"] as? String == "")
        #expect(obj?["value"] as? String == "ssh-ed25519 AAAA root@1Panel")
    }

    @Test("SSHFileUpdateRequest：sshdConf 保存默认 path 也为空串")
    func encodeSSHConfUpdate() throws {
        let req = SSHFileUpdateRequest(key: "sshdConf", value: "Port 22")
        let data = try JSONEncoder().encode(req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["path"] as? String == "")
    }

    @Test("SSHFileRequest：读取授权密钥 name=authKeys")
    func encodeFileRequest() throws {
        let data = try JSONEncoder().encode(SSHFileRequest(name: "authKeys"))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["name"] as? String == "authKeys")
    }

    @Test("StopProcessRequest：断开会话与结束进程共用 PID 大写键")
    func encodeStopRequest() throws {
        let data = try JSONEncoder().encode(StopProcessRequest(pid: 118393))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["PID"] as? Int == 118393)
    }
}
