//
//  APIClientTokenTests.swift
//  1PanelClientTests
//
//  1Panel v2 签名算法的固定向量验证：Token = MD5("1panel" + apiKey + timestamp)
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("APIClient Token 签名")
struct APIClientTokenTests {
    @Test("固定向量：MD5(\"1panel\" + apiKey + timestamp)")
    func knownVectors() {
        #expect(APIClient.token(apiKey: "test-api-key", timestamp: "1710000000") == "50fd9a80beb43cf893a8885a328b61a0")
        #expect(APIClient.token(apiKey: "another-key", timestamp: "9999999999") == "ddcf9fc13d157824688b62073c534640")
        #expect(APIClient.token(apiKey: "", timestamp: "0000000000") == "fb3ea141e3c8aa4e0392c021f4698fca")
    }

    @Test("格式：32 位小写十六进制")
    func formatSanity() {
        let token = APIClient.token(apiKey: "k", timestamp: "1")
        #expect(token.count == 32)
        #expect(token.allSatisfy { $0.isHexDigit })
        #expect(token == token.lowercased())
    }
}
