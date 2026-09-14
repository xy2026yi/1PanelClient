//
//  FileOperationsModelsTests.swift
//  1PanelClientTests
//
//  文件操作模型测试（样本取自 logs/推荐实现-文件.md 抓包 2026-09-14）：
//  权限九宫格换算 / 压缩·解压·移动·权限·wget 请求编码 / wget 进度解码
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("文件操作模型")
struct FileOperationsModelsTests {

    // MARK: 权限换算（抓包：0777→511、0755→493、0444→292）

    @Test("mode 数值与抓包一致", arguments: [
        ("0777", 511), ("0755", 493), ("0444", 292),
    ])
    func modeValues(octal: String, decimal: Int) {
        #expect(FileModeMath.decimal(fromOctalString: octal) == decimal)
        #expect(FileModeMath.octalString(decimal) == octal)
    }

    @Test("九宫格 ↔ mode 往返（rwxr-xr-x = 0755）")
    func tripleRoundtrip() {
        var owner = FileModeMath.Triple()
        owner.read = true; owner.write = true; owner.execute = true
        var group = FileModeMath.Triple()
        group.read = true; group.execute = true
        var other = FileModeMath.Triple()
        other.read = true; other.execute = true
        let mode = FileModeMath.mode(owner: owner, group: group, other: other)
        #expect(mode == 493)
        let back = FileModeMath.triples(fromMode: mode)
        #expect(back.owner == owner)
        #expect(back.group == group)
        #expect(back.other == other)
    }

    @Test("八进制字符串解析失败返回 nil")
    func invalidOctal() {
        #expect(FileModeMath.decimal(fromOctalString: nil) == nil)
        #expect(FileModeMath.decimal(fromOctalString: "") == nil)
        #expect(FileModeMath.decimal(fromOctalString: "09x") == nil)
    }

    // MARK: 请求编码（与抓包体逐字段对齐）

    private func encode(_ req: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
    }

    @Test("压缩请求编码（覆盖 + zip，抓包样本）")
    func encodeCompress() throws {
        let req = FileCompressRequest(
            files: ["/1G/ftp_test"], type: "zip", dst: "/1G",
            name: "ftp_test.zip", replace: true, secret: "",
            taskID: "4492e6c6-8508-4659-855d-25ebc1e62f93")
        let obj = try encode(req)
        #expect(obj["files"] as? [String] == ["/1G/ftp_test"])
        #expect(obj["type"] as? String == "zip")
        #expect(obj["dst"] as? String == "/1G")
        #expect(obj["name"] as? String == "ftp_test.zip")
        #expect(obj["replace"] as? Bool == true)
        #expect(obj["secret"] as? String == "")
    }

    @Test("解压请求编码（gz + 指定目录，抓包样本）")
    func encodeDecompress() throws {
        let req = FileDecompressRequest(
            type: "gz", dst: "/1G/123", path: "/1G/ftp_test1.gz",
            secret: "", taskID: "5a3f5c17-0f7f-4b8c-944c-c6f2a1792ffa")
        let obj = try encode(req)
        #expect(obj["type"] as? String == "gz")
        #expect(obj["dst"] as? String == "/1G/123")
        #expect(obj["path"] as? String == "/1G/ftp_test1.gz")
    }

    @Test("移动请求编码（type=cut 固定值，覆盖字段恒关）")
    func encodeMove() throws {
        let req = FileMoveRequest(oldPaths: ["/1G/123/ftp_test1"], newPath: "/1G", isDir: true)
        let obj = try encode(req)
        #expect(obj["oldPaths"] as? [String] == ["/1G/123/ftp_test1"])
        #expect(obj["newPath"] as? String == "/1G")
        #expect(obj["type"] as? String == "cut")
        #expect(obj["isDir"] as? Bool == true)
        #expect(obj["cover"] as? Bool == false)
        #expect(obj["allNames"] as? [String] == [])
    }

    @Test("权限请求编码（0777→mode 511 + sub，抓包样本）")
    func encodeBatchRole() throws {
        let req = FileBatchRoleRequest(
            paths: ["/1G/ftp_test1/1/1.txt"], mode: 511,
            user: "1panel-ftp", group: "root", sub: true)
        let obj = try encode(req)
        #expect(obj["paths"] as? [String] == ["/1G/ftp_test1/1/1.txt"])
        #expect(obj["mode"] as? Int == 511)
        #expect(obj["user"] as? String == "1panel-ftp")
        #expect(obj["group"] as? String == "root")
        #expect(obj["sub"] as? Bool == true)
    }

    @Test("多选权限编码（多路径 0644→0744=484，抓包样本）")
    func encodeBatchRoleMulti() throws {
        let req = FileBatchRoleRequest(
            paths: ["/1G/ftp_test/1.sh", "/1G/ftp_test/1.txt"], mode: 484,
            user: "root", group: "root", sub: true)
        let obj = try encode(req)
        #expect(obj["paths"] as? [String] == ["/1G/ftp_test/1.sh", "/1G/ftp_test/1.txt"])
        #expect(obj["mode"] as? Int == 484)
    }

    @Test("多选移动编码（allNames 含全部名称，跳过冲突时 oldPaths 仅未冲突项）")
    func encodeBatchMove() throws {
        var req = FileMoveRequest(
            oldPaths: ["/1G/ftp_test/1.sh"],
            newPath: "/1G/ftp_test/1", isDir: false)
        req.allNames = ["1.sh", "1.txt"]
        let obj = try encode(req)
        #expect(obj["oldPaths"] as? [String] == ["/1G/ftp_test/1.sh"])
        #expect(obj["allNames"] as? [String] == ["1.sh", "1.txt"])
        #expect(obj["type"] as? String == "cut")
        #expect(obj["cover"] as? Bool == false)
    }

    @Test("wget 请求编码与 key 响应解码")
    func wgetRequestResponse() throws {
        let req = FileWgetRequest(
            url: "https://github.com/bggRGjQaUbCoE/PiliPlus/releases/download/2.1.4/PiliPlus_ios_2.1.4+5348.ipa",
            path: "/1G/ftp_test", name: "PiliPlus_ios_2.1.4+5348.ipa",
            ignoreCertificate: true, useProxy: false)
        let obj = try encode(req)
        #expect(obj["ignoreCertificate"] as? Bool == true)
        #expect(obj["useProxy"] as? Bool == false)
        #expect(obj["name"] as? String == "PiliPlus_ios_2.1.4+5348.ipa")

        let keyResp = try JSONDecoder().decode(
            FileWgetKeyResponse.self,
            from: Data(#"{"key":"file-wget-0db18bc4-eccb-4583-a3e9-6241451a5a94"}"#.utf8))
        #expect(keyResp.key == "file-wget-0db18bc4-eccb-4583-a3e9-6241451a5a94")
    }

    @Test("wget 进度与 keys 响应解码（抓包 WS 帧）")
    func decodeWgetProgress() throws {
        let list = try JSONDecoder().decode([FileWgetProgress].self, from: Data(
            #"[{"total":23983183,"written":21309248,"percent":88.85,"name":"PiliPlus_ios_2.1.4+5348.ipa"}]"#.utf8))
        let p = try #require(list.first)
        #expect(p.total == 23983183)
        #expect(p.percent ?? 0 > 88)
        #expect(p.id == "PiliPlus_ios_2.1.4+5348.ipa")

        let keys = try JSONDecoder().decode(
            FileWgetKeysResponse.self, from: Data(#"{"keys":null}"#.utf8))
        #expect(keys.keys == nil)
    }
}
