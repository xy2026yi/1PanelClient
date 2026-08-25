//
//  OpenRestyManageModelsTests.swift
//  1PanelClientTests
//
//  OpenResty 管理增强模型解码测试（样本取自 doc/OpenResty增加功能.md 抓包）
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("OpenResty 管理模型")
struct OpenRestyManageModelsTests {

    @Test("模块列表响应解码（含 artifacts=null / 空字符串字段）")
    func decodeModulesResponse() throws {
        let json = """
        {"code":200,"message":"","data":{
          "mirror":"http://archive.ubuntu.com/ubuntu/",
          "dynamicSupported":true,
          "modules":[
            {"name":"ngx_brotli","custom":false,"script":"","packages":"libbrotli-dev",
             "params":"--add-module=/usr/local/openresty/modules/ngx_brotli","enable":false,
             "buildMode":"dynamic","provider":"local","loadOrder":10,"buildStatus":"pending",
             "loadStatus":"disabled","artifacts":null,"lastError":""},
            {"name":"web_dav","custom":false,
             "script":"unzip -o /tmp/nginx-dav-ext-module.zip -d /tmp","packages":"",
             "params":"--with-http_dav_module --add-module=/tmp/nginx-dav-ext-module","enable":true,
             "buildMode":"dynamic","provider":"local","loadOrder":30,"buildStatus":"ready",
             "loadStatus":"enabled","artifacts":null,"lastError":""}
          ]}}
        """
        let wrapped = try JSONDecoder().decode(APIResponse<OpenRestyModulesResponse>.self, from: Data(json.utf8))
        let resp = try #require(wrapped.data)

        #expect(resp.mirror == "http://archive.ubuntu.com/ubuntu/")
        #expect(resp.dynamicSupported == true)
        #expect(resp.modules?.count == 2)

        let brotli = try #require(resp.modules?.first { $0.name == "ngx_brotli" })
        #expect(brotli.isDynamic)
        #expect(brotli.enable == false)
        #expect(brotli.buildStatus == "pending")
        #expect(brotli.artifacts == nil)
        #expect(brotli.packages == "libbrotli-dev")

        let dav = try #require(resp.modules?.first { $0.name == "web_dav" })
        #expect(dav.enable == true)
        #expect(dav.buildStatus == "ready")
        #expect(dav.script?.isEmpty == false)
    }

    @Test("构建后 artifacts 为对象数组时仍可解码（服务端 []NginxModuleArtifact）")
    func decodeModulesWithArtifactsArray() throws {
        let json = """
        {"code":200,"message":"","data":{"mirror":"","dynamicSupported":true,"modules":[
          {"name":"ngx_brotli","enable":true,"buildMode":"dynamic","buildStatus":"ready",
           "loadOrder":10,"provider":"local","params":"--add-module=x","packages":"libbrotli-dev",
           "script":"","custom":false,"loadStatus":"enabled","lastError":"",
           "artifacts":[{"name":"mod.so","path":"modules/ngx_brotli/rev1/mod.so","checksum":"abc123"}]}
        ]}}
        """
        let wrapped = try JSONDecoder().decode(APIResponse<OpenRestyModulesResponse>.self, from: Data(json.utf8))
        let data = try #require(wrapped.data)
        let module = try #require(data.modules?.first)
        #expect(module.artifacts?.count == 1)
        #expect(module.artifacts?.first?.path == "modules/ngx_brotli/rev1/mod.so")
        #expect(module.buildStatus == "ready")
    }

    @Test("单字段类型异常不拖垮整个列表（宽松解码）")
    func lenientModuleDecode() throws {
        let json = """
        {"code":200,"message":"","data":{"mirror":"","dynamicSupported":false,"modules":[
          {"name":"rtmp","loadOrder":"20","enable":false,"buildMode":"dynamic"}
        ]}}
        """
        let wrapped = try JSONDecoder().decode(APIResponse<OpenRestyModulesResponse>.self, from: Data(json.utf8))
        let data = try #require(wrapped.data)
        let module = try #require(data.modules?.first)
        // loadOrder 类型不符（字符串）→ 宽松降级为 nil，其余字段照常
        #expect(module.name == "rtmp")
        #expect(module.loadOrder == nil)
        #expect(module.isDynamic)
    }

    @Test("性能参数 scope 列表解码")
    func decodeScopeItems() throws {
        let json = """
        {"code":200,"message":"","data":[
          {"name":"server_names_hash_bucket_size","params":["512"]},
          {"name":"client_header_buffer_size","params":["32k"]},
          {"name":"client_max_body_size","params":["50m"]},
          {"name":"gzip","params":["on"]}
        ]}
        """
        let wrapped = try JSONDecoder().decode(APIResponse<[OpenRestyScopeItem]>.self, from: Data(json.utf8))
        let items = try #require(wrapped.data)
        #expect(items.count == 4)
        #expect(items[1].params?.first == "32k")
        #expect(items[3].name == "gzip")
    }

    @Test("HTTPS 其他设置解码与请求编码")
    func httpsConfigRoundTrip() throws {
        let json = #"{"code":200,"message":"","data":{"https":true,"sslRejectHandshake":true}}"#
        let wrapped = try JSONDecoder().decode(APIResponse<OpenRestyHTTPSConfig>.self, from: Data(json.utf8))
        let config = try #require(wrapped.data)
        #expect(config.https == true)
        #expect(config.sslRejectHandshake == true)

        // 保存请求：operate 由 HTTPS 开关决定，握手开关作为字段回传
        let disableReq = OpenRestyHTTPSUpdateRequest(operate: "disable", sslRejectHandshake: true)
        let data = try JSONEncoder().encode(disableReq)
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["operate"] as? String == "disable")
        #expect(obj["sslRejectHandshake"] as? Bool == true)
    }

    @Test("模块开关请求编码（对齐服务端 NginxModuleUpdate 字段）")
    func encodeModuleUpdate() throws {
        let module = OpenRestyModule(
            name: "ngx_brotli", custom: false, script: "", packages: "libbrotli-dev",
            params: "--add-module=/usr/local/openresty/modules/ngx_brotli", enable: false,
            buildMode: "dynamic", provider: "local", loadOrder: 10, buildStatus: "pending",
            loadStatus: "disabled", artifacts: nil, lastError: ""
        )
        let req = OpenRestyModuleUpdateRequest(module: module, enable: true)
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
        #expect(obj["operate"] as? String == "update")
        #expect(obj["enable"] as? Bool == true)
        #expect(obj["name"] as? String == "ngx_brotli")
        #expect(obj["packages"] as? String == "libbrotli-dev")
        #expect(obj["loadOrder"] as? Int == 10)
        // 服务端不接收的字段（custom/artifacts 等）不出现在请求体
        #expect(obj["custom"] == nil)
        #expect(obj["artifacts"] == nil)
        #expect(obj["buildStatus"] == nil)
    }

    @Test("构建请求编码")
    func encodeBuildRequest() throws {
        let req = OpenRestyBuildRequest(
            taskID: "aeb601b6", mirror: "http://mirrors.aliyun.com/ubuntu/",
            modules: ["ngx_brotli", "rtmp"], force: true
        )
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
        #expect(obj["force"] as? Bool == true)
        #expect((obj["modules"] as? [String])?.count == 2)
        #expect(obj["mirror"] as? String == "http://mirrors.aliyun.com/ubuntu/")
    }
}
