//
//  RuntimesModelsTests.swift
//  1PanelClientTests
//
//  运行环境模型测试：解码夹具取自 logs/runtimes.md 真实抓包（面板 v2.4.1），
//  覆盖列表/详情、params 混型、PHP 扩展/配置/FPM、supervisor、Node 模块，
//  以及四类型创建请求的编码形状（含大写键与四数组）。
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("运行环境模型")
struct RuntimesModelsTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func encode(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let obj = try JSONSerialization.jsonObject(with: data)
        return try #require(obj as? [String: Any])
    }

    // MARK: - 列表项解码（PHP 抓包样本）

    @Test("列表项：params 混型（字符串/数字）与展示属性")
    func listEntryDecode() throws {
        let json = """
        {
            "id": 3, "name": "123", "resource": "appstore", "appDetailID": 1206, "appID": 223,
            "source": "", "status": "Running", "type": "php", "image": "1panel-php-fpm:8.5.12",
            "params": {
                "CONTAINER_NAME": "123",
                "CONTAINER_PACKAGE_URL": "https://mirrors.ustc.edu.cn",
                "IMAGE_NAME": "1panel-php-fpm:8.5.12",
                "PANEL_APP_PORT_HTTP": "9000",
                "PANEL_WEBSITE_DIR": "/opt/1panel/www",
                "PHP_EXTENSIONS": "",
                "PHP_VERSION": "8.5.12",
                "TZ": "Asia/Shanghai"
            },
            "message": "", "version": "8",
            "createdAt": "2026-10-25T09:13:45.689559657+08:00",
            "codeDir": "", "appParams": null, "port": "9000",
            "path": "/opt/1panel/runtime/php/123",
            "exposedPorts": null, "environments": null, "volumes": null, "extraHosts": null,
            "containerStatus": "", "container": "123", "remark": ""
        }
        """
        let entry = try decode(RuntimeEntry.self, json)
        #expect(entry.id == 3)
        #expect(entry.runtimeType == .php)
        #expect(entry.isRunning)
        #expect(!entry.isTransitional)
        #expect(entry.containerName == "123")
        #expect(entry.params?["PHP_EXTENSIONS"]?.stringValue == "")
        #expect(entry.appParams == nil)
        // 容器名兜底：params 缺 CONTAINER_NAME 时取 container 字段
        #expect(entry.containerName == "123")
    }

    @Test("列表项：端口字段为数字时的容错（PANEL_APP_PORT_HTTP 回填为 9000 数字）")
    func listEntryNumericParam() throws {
        let json = """
        { "id": 9, "name": "123", "type": "php", "status": "Running",
          "params": { "PANEL_APP_PORT_HTTP": 9000, "CONTAINER_NAME": "123" },
          "port": "9000" }
        """
        let entry = try decode(RuntimeEntry.self, json)
        #expect(entry.params?["PANEL_APP_PORT_HTTP"]?.intValue == 9000)
        #expect(entry.params?["PANEL_APP_PORT_HTTP"]?.stringValue == "9000")
    }

    @Test("创建中状态：Creating/Building 为过渡态")
    func transitionalStatus() throws {
        let creating = try decode(RuntimeEntry.self, """
        { "id": 4, "name": "123", "type": "node", "status": "Creating" }
        """)
        let building = try decode(RuntimeEntry.self, """
        { "id": 2, "name": "x", "type": "php", "status": "Building" }
        """)
        let stopped = try decode(RuntimeEntry.self, """
        { "id": 5, "name": "y", "type": "go", "status": "Stopped" }
        """)
        #expect(creating.isTransitional && !creating.isRunning)
        #expect(building.isTransitional)
        #expect(!stopped.isTransitional && !stopped.isRunning)
    }

    @Test("分页信封解码")
    func pageEnvelope() throws {
        let json = """
        { "code": 200, "message": "", "data": { "total": 1,
          "items": [ { "id": 3, "name": "123", "type": "php", "status": "Running" } ] } }
        """
        let resp = try decode(APIResponse<RuntimeListResponse>.self, json)
        #expect(resp.data?.total == 1)
        #expect(resp.data?.items?.first?.name == "123")
    }

    // MARK: - RuntimeParamValue 混型

    @Test("RuntimeParamValue：字符串/数字/数组/null 编解码往返")
    func paramValueCodable() throws {
        let v1 = RuntimeParamValue.string("8.5.12")
        let v2 = RuntimeParamValue.int(9000)
        let v3 = RuntimeParamValue.array(["zip", "curl"])
        let v4 = RuntimeParamValue.null

        let enc = try encode(["a": v1, "b": v2, "c": v3, "d": v4] as [String: RuntimeParamValue])
        #expect(enc["a"] as? String == "8.5.12")
        #expect(enc["b"] as? Int == 9000)
        #expect((enc["c"] as? [String]) == ["zip", "curl"])
        #expect(enc["d"] is NSNull)

        // 解码端：数字优先按 Int、数组只认字符串数组、布尔单列
        let d = try decode([String: RuntimeParamValue].self, """
        { "s": "x", "i": 42, "d": 1.5, "b": true, "a": ["p","q"], "n": null }
        """)
        #expect(d["s"]?.stringValue == "x")
        #expect(d["i"]?.intValue == 42)
        #expect(d["d"]?.intValue == 1)
        #expect(d["b"]?.stringValue == "true")
        #expect(d["a"]?.arrayValue == ["p", "q"])
        #expect(d["n"]?.isNull == true)
    }

    // MARK: - 创建请求编码形状（四类型抓包样本）

    @Test("PHP 创建请求编码：params 四键 + taskID + source")
    func phpCreateEncode() throws {
        let req = RuntimeCreateRequest(
            name: "123",
            appDetailID: 1206,
            image: "1panel-php-fpm:8.5.12",
            params: [
                "PHP_EXTENSIONS": .array(["zip"]),
                "PHP_VERSION": .string("8.5.12"),
                "CONTAINER_PACKAGE_URL": .string("https://mirrors.tuna.tsinghua.edu.cn"),
                "PANEL_APP_PORT_HTTP": .int(9000),
                "CONTAINER_NAME": .string("123"),
            ],
            type: "php",
            codeDir: "",
            port: nil,
            source: "https://mirrors.ustc.edu.cn",
            exposedPorts: nil,
            environments: [],
            volumes: nil,
            extraHosts: nil,
            remark: "",
            appID: 223,
            version: "8",
            taskID: "819d584e-25d9-4bf7-b97e-ae937d6235d5"
        )
        let obj = try encode(req)
        #expect(obj["name"] as? String == "123")
        #expect(obj["appDetailID"] as? Int == 1206)
        #expect(obj["type"] as? String == "php")
        #expect(obj["resource"] as? String == "appstore")
        #expect(obj["rebuild"] as? Bool == false)
        #expect(obj["appID"] as? Int == 223)
        #expect(obj["version"] as? String == "8")
        #expect(obj["taskID"] as? String == "819d584e-25d9-4bf7-b97e-ae937d6235d5")
        // install 为 nil 不出现在 JSON（PHP 抓包无此键）
        #expect(obj["install"] == nil)
        let params = try #require(obj["params"] as? [String: Any])
        #expect((params["PHP_EXTENSIONS"] as? [String]) == ["zip"])
        #expect(params["PHP_VERSION"] as? String == "8.5.12")
        #expect(params["PANEL_APP_PORT_HTTP"] as? Int == 9000)
        // environments 传空数组（PHP 抓包带空数组）
        #expect((obj["environments"] as? [Any])?.isEmpty == true)
        // exposedPorts/volumes 为 nil 不出现
        #expect(obj["exposedPorts"] == nil && obj["volumes"] == nil)
    }

    @Test("Node 创建请求编码：install/codeDir/port/四数组与 scripts 参数")
    func nodeCreateEncode() throws {
        let req = RuntimeCreateRequest(
            name: "123",
            appDetailID: 1949,
            image: "",
            params: [
                "PACKAGE_MANAGER": .string("npm"),
                "HOST_IP": .string("0.0.0.0"),
                "CUSTOM_SCRIPT": .string("1"),
                "CONTAINER_NAME": .string("123"),
                "EXEC_SCRIPT": .string("npm run start"),
            ],
            type: "node",
            install: true,
            codeDir: "/",
            port: 4004,
            source: "https://registry.npmjs.org/",
            exposedPorts: [],
            environments: [],
            volumes: [],
            extraHosts: [],
            remark: "",
            appID: 201,
            version: "26.12.1",
            taskID: "08583628-b172-46ca-a44b-708b5884d75f"
        )
        let obj = try encode(req)
        #expect(obj["install"] as? Bool == true)
        #expect(obj["codeDir"] as? String == "/")
        #expect(obj["port"] as? Int == 4004)
        #expect(obj["image"] as? String == "")
        // 四数组空数组序列化（抓包口径：[] 而非 null）
        #expect((obj["exposedPorts"] as? [Any])?.isEmpty == true)
        #expect((obj["extraHosts"] as? [Any])?.isEmpty == true)
        #expect((obj["volumes"] as? [Any])?.isEmpty == true)
        let params = try #require(obj["params"] as? [String: Any])
        #expect(params["EXEC_SCRIPT"] as? String == "npm run start")
    }

    @Test("Python 创建请求编码：EXEC_SCRIPT/APP_PORT")
    func pythonCreateEncode() throws {
        let req = RuntimeCreateRequest(
            name: "test",
            appDetailID: 1884,
            image: "",
            params: [
                "HOST_IP": .string("0.0.0.0"),
                "CONTAINER_NAME": .string("test"),
                "EXEC_SCRIPT": .string("python server.py"),
            ],
            type: "python",
            codeDir: "/1G/test_python",
            port: 8080,
            source: "",
            exposedPorts: [],
            environments: [],
            volumes: [],
            extraHosts: [],
            remark: "",
            appID: 23,
            version: "3.15.0",
            taskID: "b3358494-3208-4d9b-a76f-ba73c52e3fa9"
        )
        let obj = try encode(req)
        #expect(obj["type"] as? String == "python")
        #expect(obj["codeDir"] as? String == "/1G/test_python")
        #expect(obj["port"] as? Int == 8080)
        let params = try #require(obj["params"] as? [String: Any])
        #expect(params["EXEC_SCRIPT"] as? String == "python server.py")
    }

    @Test("编辑请求：rebuild 恒 true 且带 id")
    func updateEncode() throws {
        let req = RuntimeUpdateRequest(
            id: 3,
            name: "123",
            appDetailID: 1206,
            image: "1panel-php-fpm:8.5.12",
            params: [
                "CONTAINER_NAME": .string("123"),
                "PHP_EXTENSIONS": .array(["curl"]),
            ],
            type: "php",
            codeDir: "",
            port: nil,
            source: "https://mirrors.ustc.edu.cn",
            environments: [],
            remark: "",
            appID: 223,
            version: "8"
        )
        let obj = try encode(req)
        #expect(obj["id"] as? Int == 3)
        #expect(obj["rebuild"] as? Bool == true)
        #expect(obj["taskID"] == nil)
    }

    // MARK: - 操作/删除/备注

    @Test("operate 大写 ID 键")
    func operateEncode() throws {
        let obj = try encode(RuntimeOperateRequest(operate: "down", ID: 3))
        #expect(obj["operate"] as? String == "down")
        #expect(obj["ID"] as? Int == 3)
    }

    @Test("删除请求带 taskID 与开关")
    func deleteEncode() throws {
        let obj = try encode(RuntimeDeleteRequest(
            id: 3, forceDelete: false, deleteImage: false,
            taskID: "be9a8dfd-9f3b-433a-98c6-ba7666310edb"
        ))
        #expect(obj["id"] as? Int == 3)
        #expect(obj["forceDelete"] as? Bool == false)
        #expect(obj["taskID"] as? String == "be9a8dfd-9f3b-433a-98c6-ba7666310edb")
    }

    @Test("删除前检查：null 与非空两种返回")
    func deleteCheckResponses() throws {
        let empty = try decode(APIResponse<EmptyResponse>.self,
                               #"{"code":200,"message":"","data":null}"#)
        #expect(empty.data == nil)
        let linked = try decode([AppDeleteCheckItem].self,
                                #"[{"type":"website","name":"abc.test.com:443"}]"#)
        #expect(linked.first?.type == "website")
        #expect(linked.first?.name == "abc.test.com:443")
    }

    // MARK: - PHP 扩展 / 模版

    @Test("PHP 扩展列表解码（已加载 + 可装）")
    func phpExtensionsDecode() throws {
        let json = """
        { "extensions": ["Core", "ctype", "curl"],
          "supportExtensions": [
            { "name": "amqp", "description": "", "installed": false, "check": "amqp",
              "versions": ["56", "70", "85"], "file": "amqp.so" },
            { "name": "zip", "description": "", "installed": true, "check": "zip",
              "versions": ["85"], "file": "zip.so" }
          ] }
        """
        let resp = try decode(RuntimePHPExtensionsResponse.self, json)
        #expect(resp.extensions == ["Core", "ctype", "curl"])
        #expect(resp.supportExtensions?.count == 2)
        #expect(resp.supportExtensions?[0].installed == false)
        #expect(resp.supportExtensions?[1].installed == true)
    }

    @Test("扩展安装带 taskID、卸载不带")
    func extensionOpsEncode() throws {
        let install = try encode(RuntimePHPExtensionInstallRequest(
            id: 3, name: "zip", taskID: "54d1bfcd-c2d5-4f75-bc2b-877f826f5b43"
        ))
        #expect(install["taskID"] as? String == "54d1bfcd-c2d5-4f75-bc2b-877f826f5b43")
        let uninstall = try encode(RuntimePHPExtensionUninstallRequest(id: 9, name: "zip"))
        #expect(uninstall["taskID"] == nil)
        #expect(uninstall["id"] as? Int == 9)
    }

    @Test("扩展模版解码与逗号串拆分")
    func templateDecode() throws {
        let tpl = try decode(RuntimePHPTemplate.self, """
        { "id": 2, "name": "WordPress",
          "extensions": "exif,igbinary,imagick,intl,zip" }
        """)
        #expect(tpl.displayName == "WordPress")
        #expect(tpl.extensionList == ["exif", "igbinary", "imagick", "intl", "zip"])
    }

    // MARK: - PHP 配置 / FPM

    @Test("php.ini 配置读取解码与四 scope 保存编码")
    func phpConfigCodable() throws {
        let cfg = try decode(RuntimePHPConfig.self, """
        { "params": { "max_execution_time": "30", "memory_limit": "128M" },
          "disableFunctions": null, "uploadMaxSize": "2M", "maxExecutionTime": "30" }
        """)
        #expect(cfg.params?["memory_limit"] == "128M")
        #expect(cfg.disableFunctions == nil)

        let paramsSave = try encode(RuntimePHPConfigUpdateRequest(
            id: 3, params: ["memory_limit": "128M"], scope: "params"
        ))
        #expect(paramsSave["scope"] as? String == "params")
        #expect(paramsSave["disableFunctions"] == nil)

        let fnSave = try encode(RuntimePHPConfigUpdateRequest(
            id: 3, scope: "disable_functions", disableFunctions: ["bash", "exec"]
        ))
        #expect((fnSave["disableFunctions"] as? [String]) == ["bash", "exec"])

        let uploadSave = try encode(RuntimePHPConfigUpdateRequest(
            id: 3, scope: "upload_max_filesize", uploadMaxSize: "3M"
        ))
        #expect(uploadSave["uploadMaxSize"] as? String == "3M")
    }

    @Test("配置参数 11 键固定口径")
    func phpParamKeys() {
        #expect(RuntimePHPParamKey.allCases.count == 11)
        #expect(RuntimePHPParamKey.maxExecutionTime.rawValue == "max_execution_time")
        // On/Off 开关型恰为 3 项
        #expect(RuntimePHPParamKey.allCases.filter(\.isToggle).count == 3)
    }

    @Test("FPM 配置读写（值可为字符串/数字）")
    func fpmConfigCodable() throws {
        let cfg = try decode(RuntimeFPMConfig.self, """
        { "id": 0, "params": { "pm": "dynamic", "pm.max_children": "10", "pm.start_servers": "2" } }
        """)
        #expect(cfg.params?["pm"]?.stringValue == "dynamic")
        #expect(cfg.params?["pm.max_children"]?.intValue == 10)

        let save = try encode(RuntimeFPMConfigUpdateRequest(
            id: 3,
            params: [
                "pm": .string("static"),
                "pm.max_children": .int(10),
                "pm.start_servers": .int(2),
                "pm.min_spare_servers": .int(1),
                "pm.max_spare_servers": .int(3),
            ]
        ))
        let params = try #require(save["params"] as? [String: Any])
        #expect(params["pm.max_children"] as? Int == 10)
    }

    @Test("负载状态 value 混型（字符串/数字）")
    func fpmStatusDecode() throws {
        let items = try decode([RuntimeFPMStatusItem].self, """
        [ { "key": "pool", "value": "www" },
          { "key": "start since", "value": 228 },
          { "key": "memory peak", "value": 2097152 } ]
        """)
        #expect(items[0].value?.stringValue == "www")
        #expect(items[1].value?.intValue == 228)
        #expect(items[2].value?.intValue == 2097152)
    }

    @Test("并发方案预设值（4GB 与 128GB 两端抽查）")
    func fpmPresets() {
        #expect(RuntimeFPMPreset.g4.values.maxChildren == 80)
        #expect(RuntimeFPMPreset.g4.values.maxSpare == 30)
        #expect(RuntimeFPMPreset.g128.values.maxChildren == 1000)
        #expect(RuntimeFPMPreset.g128.values.startServers == 50)
        #expect(RuntimeFPMPreset.allCases.count == 8)
    }

    // MARK: - 容器配置四数组编解码

    @Test("exposedPorts 编解码（hostIP/protocol 键名）")
    func exposedPortCodable() throws {
        let port = RuntimeExposedPort(hostPort: 9999, containerPort: 9999, hostIP: "", protocol: "tcp")
        let obj = try encode(port)
        #expect(obj["hostPort"] as? Int == 9999)
        #expect(obj["hostIP"] as? String == "")
        #expect(obj["protocol"] as? String == "tcp")

        let back = try decode(RuntimeExposedPort.self,
                              #"{"hostPort":9999,"containerPort":9999,"hostIP":"","protocol":"tcp"}"#)
        #expect(back == port)
    }

    // MARK: - Supervisor

    @Test("进程列表解码（含子进程状态与大写 PID）")
    func supervisorDecode() throws {
        let json = """
        [ { "name": "123", "command": "sleep 6000", "user": "www-data", "dir": "/",
            "numprocs": "1", "msg": "",
            "status": [ { "name": "123:123_00", "status": "RUNNING", "PID": "27",
                          "uptime": "0:00:22", "msg": "" } ],
            "autoRestart": "true", "autoStart": "true", "environment": "" },
          { "name": "php-fpm", "command": "php-fpm --nodaemonize", "user": "root", "dir": "",
            "numprocs": "1", "msg": "",
            "status": [ { "name": "php-fpm:php-fpm_00", "status": "RUNNING", "PID": "6",
                          "uptime": "0:01:46", "msg": "" } ],
            "autoRestart": "true", "autoStart": "true", "environment": "" } ]
        """
        let list = try decode([RuntimeSupervisorProcess].self, json)
        #expect(list.count == 2)
        #expect(list[0].autoRestartOn && list[0].autoStartOn)
        #expect(list[0].status?.first?.isRunning == true)
        #expect(list[0].status?.first?.PID == "27")
        #expect(list[1].user == "root")
    }

    @Test("进程创建请求形状（numprocsNum 数字 + numprocs/autoX 字符串）")
    func supervisorCreateEncode() throws {
        let obj = try encode(RuntimeSupervisorCreateRequest(
            name: "123", command: "sleep 6000", user: "www-data", dir: "/",
            numprocsNum: 1, numprocs: "1", id: 9,
            autoRestart: "true", autoStart: "true", environment: ""
        ))
        #expect(obj["operate"] as? String == "create")
        #expect(obj["numprocsNum"] as? Int == 1)
        #expect(obj["numprocs"] as? String == "1")
        #expect(obj["autoRestart"] as? String == "true")
        #expect(obj["id"] as? Int == 9)
    }

    @Test("进程配置文件请求（file=config，get/update）")
    func supervisorFileEncode() throws {
        let get = try encode(RuntimeSupervisorFileRequest(
            name: "123", file: "config", operate: "get", content: "", id: 9
        ))
        #expect(get["operate"] as? String == "get")
        #expect(get["file"] as? String == "config")
        let update = try encode(RuntimeSupervisorFileRequest(
            name: "123", file: "config", operate: "update",
            content: "[program:123]", id: 9
        ))
        #expect(update["content"] as? String == "[program:123]")
    }

    // MARK: - Node 专属

    @Test("package.json scripts 解析解码")
    func nodePackageDecode() throws {
        let scripts = try decode([RuntimeNodeScript].self,
                                 #"[{"name":"test","script":"node index.js"}]"#)
        #expect(scripts.count == 1)
        #expect(scripts[0].script == "node index.js")
    }

    @Test("Node 模块列表与操作（大写键）")
    func nodeModuleCodable() throws {
        let mods = try decode([RuntimeNodeModule].self, """
        [ { "name": "express", "version": "5.0.0", "license": "MIT", "description": "web framework" } ]
        """)
        #expect(mods[0].displayName == "express")

        let listReq = try encode(RuntimeNodeModulesRequest(ID: 4))
        #expect(listReq["ID"] as? Int == 4)

        let opReq = try encode(RuntimeNodeModuleOperateRequest(
            ID: 4, Operate: "install", Module: "curl", PkgManager: "npm"
        ))
        #expect(opReq["ID"] as? Int == 4)
        #expect(opReq["Operate"] as? String == "install")
        #expect(opReq["PkgManager"] as? String == "npm")
    }

    // MARK: - 类型枚举

    @Test("RuntimeType 解析与展示")
    func runtimeTypeParse() {
        #expect(RuntimeType.parse("php") == .php)
        #expect(RuntimeType.parse("Node") == .node)
        #expect(RuntimeType.parse("java") == nil)
        #expect(RuntimeType.parse(nil) == nil)
        #expect(RuntimeType.php.terminalUser == "www-data")
        #expect(RuntimeType.node.terminalUser == "root")
        #expect(RuntimeType.allCases.count == 4)
    }

    // MARK: - 日志读取

    @Test("构建日志请求/响应")
    func logReadCodable() throws {
        let req = try encode(RuntimeLogReadRequest(id: 3, type: "php", page: 1, pageSize: 500, latest: true))
        #expect(req["type"] as? String == "php")
        #expect(req["latest"] as? Bool == true)

        let resp = try decode(RuntimeLogReadResponse.self, """
        { "end": true, "path": "/opt/1panel/runtime/php/123/build.log", "total": 1,
          "taskStatus": "", "lines": ["#1 DONE 0.0s"], "totalLines": 28 }
        """)
        #expect(resp.end == true)
        #expect(resp.lines == ["#1 DONE 0.0s"])
        #expect(resp.totalLines == 28)
    }
}
