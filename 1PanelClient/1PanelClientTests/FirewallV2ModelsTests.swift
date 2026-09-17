//
//  FirewallV2ModelsTests.swift
//  1PanelClientTests
//
//  防火墙 v2.3.0 契约解码测试（M1）。夹具按上游 v2.3.0 Go DTO 的
//  json tag 合成（agent/app/dto/firewall.go + forwarding.go +
//  utils/firewall/filter/{model,inventory}.go），真机抓包验证后补真实样本。
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("防火墙 v2.3.0 模型解码")
struct FirewallV2ModelsTests {

    @Test("子系统状态（含冲突后端与双栈族状态）")
    func subsystemStatus() throws {
        let json = """
        {"name":"system","backend":"iptables","conflictBackend":"firewalld",
         "isExist":true,"isActive":true,"isInit":true,"isBind":false,
         "version":"1.8.7","pingStatus":"Enable","message":"","reason":"",
         "syncError":"","ipv4":{"available":true,"initialized":true,"bound":false,"reason":""},
         "ipv6":{"available":false,"initialized":false,"bound":false,"reason":"no ipv6"}}
        """
        let status = try JSONDecoder().decode(FirewallSubsystemStatus.self, from: Data(json.utf8))
        #expect(status.backend == "iptables")
        #expect(status.conflictBackend == "firewalld")
        #expect(status.isInit == true && status.isBind == false)
        #expect(status.pingBlocked == true)
        #expect(status.ipv4?.available == true)
        #expect(status.ipv6?.available == false)
    }

    @Test("规则清单响应（managed/external 混合 + 计数）")
    func inventoryResponse() throws {
        let json = """
        {"ipv4Range":{"min":1,"max":42},"ipv6Range":{"min":0,"max":0},
         "total":2,"allTotal":5,"managedTotal":2,
         "items":[
           {"rule":{"uuid":"u-1","scope":{"provider":"iptables","family":"ipv4",
              "table":"filter","chain":"1PANEL_BASIC","direction":"input"},
             "nativeKind":"rule","protocol":"tcp","sourceAddress":"192.168.1.0/24",
             "destinationPort":"443","action":"accept","description":"https"},
            "desired":{"uuid":"u-1","rule":{"uuid":"u-1"},"origin":"created","protected":false},
            "state":"managed","match":"exact"},
           {"rule":{"scope":{"provider":"iptables","family":"ipv4","table":"filter",
              "chain":"INPUT","direction":"input"},"nativeKind":"opaque",
             "protocol":"","action":"drop"},
            "observed":{"rule":{},"instanceKey":"k-9","parseStatus":"opaque",
             "raw":"-A INPUT -j DROP","protected":true},
            "state":"external","match":"opaque"}],
         "notices":[{"code":"default_scope_mismatch","values":["INPUT"]}]}
        """
        let resp = try JSONDecoder().decode(FirewallRuleInventoryResponse.self, from: Data(json.utf8))
        #expect(resp.allTotal == 5)
        #expect(resp.managedTotal == 2)
        #expect(resp.items?.count == 2)
        #expect(resp.items?[0].state == "managed")
        #expect(resp.items?[0].manageableUUID == "u-1")
        #expect(resp.items?[0].rule?.destinationPort == "443")
        #expect(resp.items?[1].state == "external")
        #expect(resp.items?[1].manageableUUID == nil)
        #expect(resp.items?[1].observed?.raw?.contains("DROP") == true)
        #expect(resp.notices?.first?.code == "default_scope_mismatch")
    }

    @Test("创建响应（任务式 + 部分失败明细）")
    func createResponse() throws {
        let json = """
        {"taskID":"task-77","queued":true,"succeeded":0,"failed":0,"skipped":0}
        """
        let resp = try JSONDecoder().decode(FirewallRuleCreateResponse.self, from: Data(json.utf8))
        #expect(resp.taskID == "task-77")
        #expect(resp.queued == true)

        let json2 = """
        {"succeeded":1,"failed":1,"skipped":0,
         "errors":[{"index":0,"status":"conflict","rule":{"protocol":"tcp"},
                    "error":"port already covered"}]}
        """
        let resp2 = try JSONDecoder().decode(FirewallRuleCreateResponse.self, from: Data(json2.utf8))
        #expect(resp2.failed == 1)
        #expect(resp2.errors?.first?.error?.contains("covered") == true)
    }

    @Test("转发规则（PageEnvelope 信封 + 目标字段）")
    func forwardRules() throws {
        let json = """
        {"total":1,"items":[{"id":12,"chain":"1PANEL_FORWARD","family":"ipv4",
          "address":"","port":"8080","protocol":"tcp","strategy":"accept",
          "num":"3","targetIP":"10.0.0.5","targetPort":"80","interface":"eth0",
          "usedStatus":"1PanelClient","description":"web","isDesired":true,
          "isRuntime":true,"syncStatus":"ok"}]}
        """
        let page = try JSONDecoder().decode(PageEnvelope<FirewallForwardRule>.self, from: Data(json.utf8))
        #expect(page.total == 1)
        let rule = page.items?.first
        #expect(rule?.port == "8080")
        #expect(rule?.targetIP == "10.0.0.5")
        #expect(rule?.num == "3")
        #expect(rule?.isDesired == true)
    }

    @Test("设置（三组后端 + ping + 白名单原始串）")
    func settings() throws {
        let json = """
        {"system":{"selected":"ufw","current":"ufw","options":[
            {"name":"ufw","installed":true,"active":true,"initialized":true,"bound":true,
             "supported":true,"message":"","ipv4":{"available":true,"initialized":true,"bound":true},"ipv6":{"available":true}},
            {"name":"firewalld","installed":false,"active":false,"initialized":false,
             "bound":false,"supported":true,"supportReason":"not installed"}]},
         "forwarding":{"selected":"iptables","options":[]},
         "docker":{"selected":"iptables","options":[]},
         "pingStatus":"Disable","portWhiteList":"80/tcp,443/tcp"}
        """
        let settings = try JSONDecoder().decode(FirewallSettings.self, from: Data(json.utf8))
        #expect(settings.system?.selected == "ufw")
        #expect(settings.system?.options?.count == 2)
        #expect(settings.system?.options?[1].installed == false)
        #expect(settings.pingBlocked == false)
        #expect(parseFirewallPortWhitelist(settings.portWhiteList) == ["80/tcp", "443/tcp"])
    }

    @Test("Docker 端口守护总览（容器/端口组/孤立策略）")
    func dockerGuardList() throws {
        let json = """
        {"base":{"name":"docker","version":"27.1","isExist":true,"initialized":true,
          "bound":true,"ipv4":{"state":"ok","initialized":true,"bound":true,"effective":true},
          "ipv6":{"state":"ok","initialized":true,"bound":true,"effective":true},
          "backend":"iptables","message":""},
         "containers":[
           {"key":"c1","name":"nginx-proxy","compose":"proxy","application":"",
            "endpoints":[],
            "portGroups":[
              {"key":"c1:80","label":"80/tcp",
               "endpoint":{"family":"ipv4","hostIP":"0.0.0.0","hostPort":80,"protocol":"tcp",
                 "containerID":"cid1","containerName":"nginx-proxy","containerState":"running",
                 "containerPort":80,"policyUUID":"p-1","mode":"allow_sources",
                 "sources":["1.2.3.4"],"effective":true,"trafficPath":"dnat"},
               "endpoints":[]}]}],
         "orphanPolicies":[
           {"family":"ipv4","hostIP":"0.0.0.0","hostPort":8081,"protocol":"tcp",
            "containerID":"","containerName":"","policyUUID":"p-9","mode":"deny_all",
            "sources":[],"effective":false,"trafficPath":""}]}
        """
        let list = try JSONDecoder().decode(DockerGuardList.self, from: Data(json.utf8))
        #expect(list.base?.initialized == true)
        #expect(list.containers?.count == 1)
        let group = list.containers?.first?.portGroups?.first
        #expect(group?.endpoint?.hostPort == 80)
        #expect(group?.endpoint?.mode == "allow_sources")
        #expect(group?.endpoint?.sources == ["1.2.3.4"])
        #expect(list.orphanPolicies?.first?.policyUUID == "p-9")
    }

    @Test("规则表单 scope 构造（对齐 Web 端 buildRule 三分支）")
    func scopeForCreate() {
        let ipt = FirewallViewModel.scopeForCreate(backend: "iptables", family: "ipv4")
        #expect(ipt.table == "filter" && ipt.chain == "1PANEL_BASIC" && ipt.direction == "input")
        let fw = FirewallViewModel.scopeForCreate(backend: "firewalld", family: "ipv4")
        #expect(fw.zone == "public" && fw.family == "inet")
        let ufw = FirewallViewModel.scopeForCreate(backend: "ufw", family: "ipv6")
        #expect(ufw.chain == "incoming" && ufw.family == "ipv6")
    }
}

// MARK: - 抓包核对回归（2026-09-17 logs/防火墙_v2.3.0.md + iptables.md）

@Suite("防火墙 v2.3.0 抓包核对回归")
struct FirewallV2CaptureRegressionTests {

    @Test("搜索作用域构造：iptables 六链 / ufw 单链 / firewalld zone（抓包+源码口径）")
    func searchScopes() {
        let ipt = FirewallViewModel.scopeForSearch(backend: "iptables") ?? []
        #expect(ipt.count == 6)
        #expect(ipt.allSatisfy { $0.table == "filter" && $0.direction == "input" })
        #expect(Set(ipt.compactMap(\.chain)) == ["1PANEL_BASIC_BEFORE", "1PANEL_BASIC", "1PANEL_BASIC_AFTER"])
        #expect(FirewallViewModel.excludeChainsForSearch(backend: "iptables") == ["1PANEL_BASIC_BEFORE", "1PANEL_BASIC_AFTER"])

        let ufw = FirewallViewModel.scopeForSearch(backend: "ufw") ?? []
        #expect(ufw.count == 1)
        #expect(ufw[0].family == "inet" && ufw[0].chain == "incoming")
        #expect(FirewallViewModel.excludeChainsForSearch(backend: "ufw") == [])

        let nft = FirewallViewModel.scopeForSearch(backend: "nftables") ?? []
        #expect(nft.count == 6 && nft[0].provider == "nftables")
    }

    @Test("转发 remove 整行回显（抓包：编辑/删除回传原始行 + operation）")
    func forwardRemoveEchoesFullRow() throws {
        let rule = FirewallForwardRule(
            id: 9, chain: "", family: "ipv4", address: "", port: "8080",
            protocolField: "tcp", strategy: "", num: "3",
            targetIP: "127.0.0.1", targetPort: "21", interface: "",
            usedStatus: "", descriptionText: nil,
            isDesired: true, isRuntime: true, syncStatus: "converged"
        )
        let op = FirewallForwardOperation.remove(rule)
        let data = try JSONEncoder().encode([op])
        let text = String(decoding: data, as: UTF8.self)
        // 抓包形态：id/num/isDesired/syncStatus 等运行时字段原样在场
        #expect(text.contains(#""operation":"remove""#))
        #expect(text.contains(#""id":9"#))
        #expect(text.contains(#""num":"3""#))
        #expect(text.contains(#""isDesired":true"#))
        #expect(text.contains(#""syncStatus":"converged""#))
        #expect(text.contains(#""targetPort":"21""#))
    }

    @Test("白名单双格式：逗号串与 JSON 数组串都可解析，编码为 JSON 数组（抓包形态）")
    func whitelistDualFormat() {
        // 初始形态（逗号串）
        let fromComma = parseFirewallWhitelistEntries("80/tcp,443/tcp,443/udp")
        #expect(fromComma.count == 3)
        #expect(fromComma[0] == FirewallPortWhitelistEntry(family: "ipv4", protocolField: "tcp", port: "80"))
        #expect(fromComma[2].protocolField == "udp")

        // 编辑后形态（JSON 数组字符串，抓包原文）
        let jsonForm = #"[{"family":"ipv4","port":"8444","protocol":"tcp"},{"family":"ipv4","port":"22","protocol":"tcp"},{"family":"ipv4","port":"443","protocol":"udp"}]"#
        let fromJSON = parseFirewallWhitelistEntries(jsonForm)
        #expect(fromJSON.count == 3)
        #expect(fromJSON[0].port == "8444")
        #expect(fromJSON[2].protocolField == "udp")

        // 提交编码：JSON 数组字符串（与 Web 端提交一致），往返稳定
        let encoded = encodeFirewallWhitelistEntries(fromJSON)
        #expect(encoded.hasPrefix("["))
        #expect(parseFirewallWhitelistEntries(encoded) == fromJSON)
        #expect(encoded.contains(#""family":"ipv4""#))
        #expect(encoded.contains(#""protocol":"tcp""#))
    }

    @Test("设置真实样本（三组后端 + guard_chain_missing reason）")
    func settingsCapturedSample() throws {
        let json = """
        {"system":{"selected":"iptables","current":"iptables","options":[
          {"name":"iptables","installed":true,"active":false,"initialized":true,"bound":true,
           "supported":true,"implementation":"iptables",
           "ipv4":{"available":true,"initialized":true,"bound":true},
           "ipv6":{"available":true,"initialized":true,"bound":true}}]},
         "forwarding":{"selected":"iptables","current":"iptables","options":[]},
         "docker":{"selected":"iptables","current":"iptables","options":[
          {"name":"iptables","installed":true,"active":true,"initialized":false,"bound":false,
           "supported":true,
           "ipv4":{"available":true,"initialized":false,"bound":false,"reason":"guard_chain_missing"},
           "ipv6":{"available":true,"initialized":false,"bound":false,"reason":"guard_chain_missing"}}]},
         "pingStatus":"Disable","portWhiteList":"80/tcp,443/tcp,443/udp"}
        """
        let settings = try JSONDecoder().decode(FirewallSettings.self, from: Data(json.utf8))
        #expect(settings.system?.selected == "iptables")
        #expect(settings.pingBlocked == false)
        #expect(settings.docker?.options?.first?.ipv4?.reason == "guard_chain_missing")
        #expect(parseFirewallWhitelistEntries(settings.portWhiteList).count == 3)
    }

    @Test("转发列表真实样本（iptables-forward，isActive=false 但 isInit=true）")
    func forwardCapturedSample() throws {
        let json = """
        {"total":3,"items":[
          {"id":2,"chain":"","family":"ipv4","address":"","port":"8080","protocol":"tcp",
           "strategy":"","num":"1","targetIP":"127.0.0.1","targetPort":"53","interface":"",
           "usedStatus":"","description":"","isDesired":true,"isRuntime":true,"syncStatus":"converged"},
          {"id":4,"chain":"","family":"ipv4","address":"","port":"8081","protocol":"udp",
           "strategy":"","num":"3","targetIP":"127.0.0.1","targetPort":"53","interface":"",
           "usedStatus":"","description":"","isDesired":true,"isRuntime":true,"syncStatus":"converged"}]}
        """
        let page = try JSONDecoder().decode(PageEnvelope<FirewallForwardRule>.self, from: Data(json.utf8))
        #expect(page.total == 3)
        #expect(page.items?.count == 2)
        #expect(page.items?[0].num == "1")
        #expect(page.items?[1].protocolField == "udp")
        #expect(page.items?[1].syncStatus == "converged")
    }

    @Test("Docker 总览真实样本（平铺 endpoints：ipv4+ipv6 各一条，trafficPath=forward）")
    func dockerCapturedSample() throws {
        let json = """
        {"base":{"name":"iptables-docker","version":"1.8.11","isExist":true,
          "initialized":true,"bound":true,
          "ipv4":{"state":"effective","initialized":true,"bound":true,"effective":true},
          "ipv6":{"state":"effective","initialized":true,"bound":true,"effective":true},
          "backend":"iptables"},
         "containers":[
          {"key":"6fad","name":"1Panel-mysql-nmJH","compose":"mysql","application":"mysql",
           "endpoints":[
            {"family":"ipv4","hostIP":"0.0.0.0","hostPort":3306,"protocol":"tcp",
             "containerID":"6fad","containerName":"1Panel-mysql-nmJH","containerState":"running",
             "containerPort":3306,"compose":"mysql","application":"mysql",
             "sources":[],"effective":false,"trafficPath":"forward","managementTarget":"container_guard"},
            {"family":"ipv6","hostIP":"::","hostPort":3306,"protocol":"tcp",
             "containerID":"6fad","containerName":"1Panel-mysql-nmJH","containerState":"running",
             "containerPort":3306,"compose":"mysql","application":"mysql",
             "sources":[],"effective":false,"trafficPath":"forward","managementTarget":"container_guard"}],
           "portGroups":[]}],
         "orphanPolicies":[]}
        """
        let list = try JSONDecoder().decode(DockerGuardList.self, from: Data(json.utf8))
        #expect(list.base?.initialized == true)
        let container = list.containers?.first
        #expect(container?.endpoints?.count == 2)
        #expect(container?.endpoints?[0].family == "ipv4")
        #expect(container?.endpoints?[0].trafficPath == "forward")
        #expect(container?.endpoints?[1].hostIP == "::")
        #expect(container?.portGroups?.isEmpty == true)
    }

    @Test("规则清单真实样本摘录（protected 白名单规则 + markers/locator）")
    func inventoryCapturedSample() throws {
        let json = """
        {"ipv4Range":{"min":1,"max":5},"ipv6Range":{"min":0,"max":0},
         "total":5,"allTotal":17,"managedTotal":1,
         "items":[
          {"rule":{"scope":{"provider":"iptables","family":"ipv4","table":"filter",
              "chain":"1PANEL_BASIC","direction":"input"},"nativeKind":"rule",
            "protocol":"tcp","destinationPort":"80","action":"accept"},
           "observed":{"rule":{},"locator":{"provider":"iptables",
              "scopeKey":"iptables:ipv4:filter:1PANEL_BASIC:input",
              "canonical":"-A 1PANEL_BASIC -p tcp -m tcp --dport 80 -j ACCEPT","position":1},
            "instanceKey":"sha256:3e93","marker":"1panel-rule:601917b0",
            "parseStatus":"supported","raw":"-A 1PANEL_BASIC -p tcp -j ACCEPT","protected":true},
           "desired":{"uuid":"601917b0","rule":{"uuid":"601917b0"},
              "origin":"adopted","protected":true,"marker":"1panel-rule:601917b0"},
           "state":"protected","match":"exact"}],
         "notices":[]}
        """
        let resp = try JSONDecoder().decode(FirewallRuleInventoryResponse.self, from: Data(json.utf8))
        #expect(resp.allTotal == 17 && resp.managedTotal == 1)
        let item = resp.items?.first
        #expect(item?.state == "protected")
        #expect(item?.manageableUUID == "601917b0")
        #expect(item?.observed?.marker?.hasPrefix("1panel-rule:") == true)
        #expect(item?.observed?.locator?.position == 1)
    }
}

// MARK: - 同步/重置/策略编码回归（抓包 2026-09-17）

@Suite("防火墙同步与守护策略回归")
struct FirewallSyncAndPolicyTests {

    @Test("同步预览真实样本（system/iptables：ready 1 + existing 4）")
    func syncPreviewCaptured() throws {
        let json = """
        {"subsystem":"system","targetProvider":"iptables",
         "total":5,"ready":1,"existing":4,"removed":0,"blocked":0,
         "items":[
          {"sourceUUID":"86a2cdb8","rule":{"uuid":"86a2cdb8",
             "scope":{"provider":"iptables","family":"ipv4","table":"filter","chain":"1PANEL_BASIC","direction":"input"},
             "nativeKind":"rule","protocol":"tcp","destinationPort":"8443","action":"accept"},
           "status":"ready","reason":"target rule differs from database policy"},
          {"sourceUUID":"601917b0","rule":{"uuid":"601917b0","protocol":"tcp","destinationPort":"80","action":"accept"},
           "status":"existing","reason":"rule already matches database policy"}]}
        """
        let p = try JSONDecoder().decode(FirewallRuleSyncPreview.self, from: Data(json.utf8))
        #expect(p.ready == 1 && p.existing == 4)
        #expect(p.items?.count == 2)
        #expect(p.items?[0].status == "ready")
        #expect(p.items?[0].displayToken == "8443")
    }

    @Test("转发同步预览（forwardRule 侧条目）")
    func forwardSyncPreview() throws {
        let json = """
        {"subsystem":"forwarding","targetProvider":"iptables",
         "total":3,"ready":1,"existing":2,"removed":0,"blocked":0,
         "items":[
          {"sourceUUID":"ipv4\\u0000tcp\\u00008080","forwardRule":{"port":"8080","protocol":"tcp",
             "targetIP":"127.0.0.1","targetPort":"53"},"status":"ready","reasonCode":"missing_in_target"}]}
        """
        let p = try JSONDecoder().decode(FirewallRuleSyncPreview.self, from: Data(json.utf8))
        #expect(p.subsystem == "forwarding")
        #expect(p.items?.first?.forwardRule?.port == "8080")
        #expect(p.items?.first?.displayToken == "8080")
    }

    @Test("Docker 策略编码（deny_sources + 来源列表，抓包提交形态）")
    func dockerPolicyEncode() throws {
        let policy = DockerGuardPolicy(
            family: "ipv4", hostIP: "0.0.0.0", hostPort: 3306,
            protocolField: "tcp", mode: "deny_sources",
            sources: ["172.29.0.1", "172.29.0.2"], descriptionText: ""
        )
        let data = try JSONEncoder().encode(DockerGuardPolicyBatchRequest(policies: [policy]))
        // JSONEncoder 键序不稳定（字典哈希序），按结构断言而非子串匹配
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let item = (root?["policies"] as? [[String: Any]])?.first
        #expect(item?["family"] as? String == "ipv4")
        #expect(item?["hostPort"] as? Int == 3306)
        #expect(item?["protocol"] as? String == "tcp")
        #expect(item?["mode"] as? String == "deny_sources")
        #expect((item?["sources"] as? [String]) == ["172.29.0.1", "172.29.0.2"])
        #expect(item?["description"] as? String == "")
    }

    @Test("重置响应（{removed, disabled}）")
    func resetResponse() throws {
        let resp = try JSONDecoder().decode(FirewallRuleResetResponse.self,
                                            from: Data(#"{"removed":5,"disabled":true}"#.utf8))
        #expect(resp.removed == 5 && resp.disabled == true)
    }
}

// MARK: - 低频操作回归（纳管/排序/原文/导入导出）

@Suite("防火墙低频操作回归")
struct FirewallLowFreqTests {

    @Test("纳管请求编码（scope + instanceKey）")
    func adoptRequestEncode() throws {
        let req = FirewallRuleAdoptRequest(
            scope: FirewallScope(provider: "iptables", family: "ipv4", table: "filter",
                                 chain: "INPUT", direction: "input"),
            instanceKey: "sha256:abc")
        let data = try JSONEncoder().encode(req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["instanceKey"] as? String == "sha256:abc")
        let scope = obj?["scope"] as? [String: Any]
        #expect(scope?["provider"] as? String == "iptables")
        #expect(scope?["chain"] as? String == "INPUT")
    }

    @Test("排序请求编码（uuid + targetPosition）")
    func reorderRequestEncode() throws {
        let req = FirewallRuleReorderRequest(uuid: "u-1", targetPosition: 3, priority: nil)
        let data = try JSONEncoder().encode(req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["uuid"] as? String == "u-1")
        #expect(obj?["targetPosition"] as? Int == 3)
    }

    @Test("导入解析：导出文件往返（去 uuid 的规则数组可直接解码）")
    func importRoundTrip() throws {
        let exported = """
        [{"scope":{"provider":"iptables","family":"ipv4","table":"filter","chain":"1PANEL_BASIC","direction":"input"},
          "nativeKind":"rule","protocol":"tcp","sourceAddress":"172.16.0.0/24",
          "destinationPort":"53,21-22","action":"accept","description":"ALL"}]
        """
        let rules = try JSONDecoder().decode([FirewallRule].self, from: Data(exported.utf8))
        #expect(rules.count == 1)
        #expect(rules[0].sourceAddress == "172.16.0.0/24")
        #expect(rules[0].destinationPort == "53,21-22")
        #expect(rules[0].uuid == nil)
    }

    @Test("原生详情请求编码（zone_service 形态）")
    func nativeDetailEncode() throws {
        let req = FirewallNativeDetailRequest(provider: "firewalld",
                                              nativeKind: "zone_service", name: "public")
        let data = try JSONEncoder().encode(req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["nativeKind"] as? String == "zone_service")
        #expect(obj?["permanent"] as? Bool == true)
    }
}
