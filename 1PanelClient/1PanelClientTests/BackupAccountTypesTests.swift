//
//  BackupAccountTypesTests.swift
//  1PanelClientTests
//
//  新增备份账号类型（COS/S3/Kodo/UPYUN/阿里云盘/OneDrive/GoogleDrive）
//  varsJson 键形状、OAuth 授权 URL、阿里云盘 token 解析的回归测试。
//  形状来源：1Panel v2 官方前端 operate/index.vue（dev-v2 取证 2026-09-21）
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("备份账号新类型 vars 形状")
struct BackupAccountVarsBuilderTests {

    private func jsonObject(_ vars: BackupVarsJSON) throws -> [String: Any] {
        let data = try JSONEncoder().encode(vars)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("COS：region + scType + endpointItem + endpoint")
    func cosShape() throws {
        let obj = try jsonObject(BackupAccountVarsBuilder.cos(
            proto: "https", host: "cos.ap-guangzhou.myqcloud.com",
            region: "ap-guangzhou", scType: "Standard"))
        #expect(obj["region"] as? String == "ap-guangzhou")
        #expect(obj["scType"] as? String == "Standard")
        #expect(obj["endpointItem"] as? String == "cos.ap-guangzhou.myqcloud.com")
        #expect(obj["endpoint"] as? String == "https://cos.ap-guangzhou.myqcloud.com")
    }

    @Test("S3：region + scType + mode + endpoint")
    func s3Shape() throws {
        let obj = try jsonObject(BackupAccountVarsBuilder.s3(
            proto: "https", host: "s3.amazonaws.com",
            region: "us-east-1", scType: "STANDARD_IA", mode: "path"))
        #expect(obj["region"] as? String == "us-east-1")
        #expect(obj["scType"] as? String == "STANDARD_IA")
        #expect(obj["mode"] as? String == "path")
        #expect(obj["endpoint"] as? String == "https://s3.amazonaws.com")
    }

    @Test("Kodo：domain（非 endpoint）+ timeout 整数")
    func kodoShape() throws {
        let obj = try jsonObject(BackupAccountVarsBuilder.kodo(
            proto: "https", host: "dl.example.com", timeoutHours: 2))
        #expect(obj["domain"] as? String == "https://dl.example.com")
        #expect(obj["endpoint"] == nil)
        #expect(obj["timeout"] as? Int == 2)
        #expect(obj["endpointItem"] as? String == "dl.example.com")
    }

    @Test("UPYUN 无 vars 键；阿里云盘 drive_id/refresh_token")
    func upyunAndAliyunShape() throws {
        let upyun = try jsonObject(BackupAccountVarsBuilder.upyun())
        #expect(upyun.isEmpty)

        let ali = try jsonObject(BackupAccountVarsBuilder.aliyun(
            driveID: "did", refreshToken: "rt"))
        #expect(ali["drive_id"] as? String == "did")
        #expect(ali["refresh_token"] as? String == "rt")
    }

    @Test("OAuth：OneDrive 带 isCN 布尔；GoogleDrive 无 isCN；code 可选携带")
    func oauthShape() throws {
        let one = try jsonObject(BackupAccountVarsBuilder.oauthClient(
            clientID: "cid", clientSecret: "cs", redirectURI: "https://r",
            isCN: true, code: "M.C54"))
        #expect(one["isCN"] as? Bool == true)
        #expect(one["client_id"] as? String == "cid")
        #expect(one["client_secret"] as? String == "cs")
        #expect(one["redirect_uri"] as? String == "https://r")
        #expect(one["code"] as? String == "M.C54")

        let google = try jsonObject(BackupAccountVarsBuilder.oauthClient(
            clientID: "cid", clientSecret: "cs", redirectURI: "https://r",
            isCN: nil, code: nil))
        #expect(google["isCN"] == nil)
        #expect(google["code"] == nil)
    }
}

@Suite("备份账号 OAuth 辅助")
struct BackupOAuthTests {

    @Test("OneDrive 授权 URL：国际/世纪互联与参数")
    func oneDriveURL() throws {
        let global = try #require(BackupOAuth.oneDriveAuthorizeURL(
            clientID: "cid", redirectURI: "https://r", isCN:false))
        #expect(global.absoluteString.hasPrefix(
            "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?"))
        let cn = try #require(BackupOAuth.oneDriveAuthorizeURL(
            clientID: "cid", redirectURI: "https://r", isCN: true))
        #expect(cn.absoluteString.hasPrefix(
            "https://login.chinacloudapi.cn/common/oauth2/v2.0/authorize?"))
        // 关键参数齐全（值按解码后断言：URLComponents 对 query 中 : / 不做百分号编码属合法）
        let comps = try #require(URLComponents(url: global, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["response_type"] == "code")
        #expect(items["client_id"] == "cid")
        #expect(items["redirect_uri"] == "https://r")
        #expect(items["scope"] == "offline_access Files.ReadWrite.All User.Read")
    }

    @Test("GoogleDrive 授权 URL：scope 与离线访问")
    func googleURL() throws {
        let url = try #require(BackupOAuth.googleDriveAuthorizeURL(
            clientID: "cid", redirectURI: "https://r"))
        #expect(url.absoluteString.hasPrefix(
            "https://accounts.google.com/o/oauth2/auth/oauthchooseaccount"))
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["client_id"] == "cid")
        #expect(items["access_type"] == "offline")
        #expect(items["prompt"] == "consent")
        #expect(items["scope"]?.contains("/auth/drive") == true)
        #expect(items["scope"]?.contains("/auth/photoslibrary") == true)
    }

    @Test("阿里云盘 token 解析：default_drive_id / refresh_token")
    func aliyunParse() throws {
        let parsed = try #require(BackupOAuth.parseAliyunToken(
            #"{"default_drive_id":"111","refresh_token":"abc","name":"x"}"#))
        #expect(parsed.driveID == "111")
        #expect(parsed.refreshToken == "abc")
        // 非法输入返回 nil（不崩溃）
        #expect(BackupOAuth.parseAliyunToken("not json") == nil)
        #expect(BackupOAuth.parseAliyunToken(#"{"default_drive_id":""}"#) == nil)
        #expect(BackupOAuth.parseAliyunToken(#"{"refresh_token":"r"}"#) == nil)
    }

    @Test("refresh_token Base64 解码（check 响应 token）")
    func decodeToken() {
        let b64 = Data("secret-rt".utf8).base64EncodedString()
        #expect(BackupOAuth.decodeRefreshToken(b64) == "secret-rt")
        #expect(BackupOAuth.decodeRefreshToken("!!!not-base64!!!") == "")
    }
}
