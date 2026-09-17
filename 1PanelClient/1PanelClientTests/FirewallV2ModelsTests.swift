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
