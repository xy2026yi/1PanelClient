//
//  FirewallV2ModelsTests.swift
//  1PanelClientTests
//
//  防火墙 v2.4.0 契约解码测试。夹具按上游 v2.4.0 Go DTO 的
//  json tag 合成（agent/app/dto/firewall.go + forwarding.go +
//  utils/firewall/filter/{model,inventory}.go），真机抓包验证后补真实样本。
//  v2.4.0 移除 sync/adopt 与 state/match/desired 对账模型：增删改操作键
//  换成 (scope, instanceKey, observed) 三元组。
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("防火墙 v2.4.0 模型解码")
struct FirewallV2ModelsTests {

    @Test("子系统状态（含冲突后端、双栈族状态与 ipv6Enabled/partial）")
    func subsystemStatus() throws {
        let json = """
        {"name":"system","backend":"iptables","conflictBackend":"firewalld",
         "isExist":true,"isActive":true,"isInit":true,"isBind":false,
         "version":"1.8.7","pingStatus":"Enable","message":"","reason":"",
         "ipv6Enabled":true,
         "ipv4":{"available":true,"initialized":true,"bound":false,"reason":"","partial":false},
         "ipv6":{"available":false,"initialized":true,"bound":false,"reason":"no ipv6","partial":true}}
        """
        let status = try JSONDecoder().decode(FirewallSubsystemStatus.self, from: Data(json.utf8))
        #expect(status.backend == "iptables")
        #expect(status.conflictBackend == "firewalld")
        #expect(status.isInit == true && status.isBind == false)
        #expect(status.pingBlocked == true)
        #expect(status.ipv6Enabled == true)
        #expect(status.ipv4?.available == true)
        #expect(status.ipv6?.partial == true)
    }

    @Test("规则清单响应（v2.4.0：无 state/desired，isWhitelist 表达保护）")
    func inventoryResponse() throws {
        let json = """
        {"ipv4Range":{"min":1,"max":42},"ipv6Range":{"min":0,"max":0},
         "total":2,"allTotal":5,
         "items":[
           {"rule":{"uuid":"u-1","scope":{"provider":"iptables","family":"ipv4",
              "table":"filter","chain":"1PANEL_BASIC","direction":"input"},
             "nativeKind":"rule","protocol":"tcp","sourceAddress":"192.168.1.0/24",
             "destinationPort":"443","action":"accept","description":"https"},
            "observed":{"rule":{},"instanceKey":"sha256:aa","parseStatus":"supported"},
            "isWhitelist":false},
           {"rule":{"scope":{"provider":"iptables","family":"ipv4","table":"filter",
              "chain":"INPUT","direction":"input"},"nativeKind":"opaque",
             "protocol":"","action":"drop"},
            "observed":{"rule":{},"instanceKey":"k-9","parseStatus":"opaque",
             "raw":"-A INPUT -j DROP","protected":true},
            "isWhitelist":true,"descriptionID":"dw-3"}],
         "notices":[{"code":"managed_scope_inactive","values":["INPUT"]}]}
        """
        let resp = try JSONDecoder().decode(FirewallRuleInventoryResponse.self, from: Data(json.utf8))
        #expect(resp.allTotal == 5)
        #expect(resp.items?.count == 2)
        let first = resp.items?[0]
        #expect(first?.rule?.destinationPort == "443")
        #expect(first?.operationTarget?.instanceKey == "sha256:aa")
        #expect(first?.operationTarget?.scope.chain == "1PANEL_BASIC")
        #expect(first?.isProtected == false)
        let second = resp.items?[1]
        #expect(second?.isProtected == true)
        #expect(second?.observed?.raw?.contains("DROP") == true)
        #expect(resp.notices?.first?.code == "managed_scope_inactive")
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

    @Test("转发规则（PageEnvelope 信封 + 目标字段；v2.4.0 无同步字段）")
    func forwardRules() throws {
        let json = """
        {"total":1,"items":[{"id":12,"chain":"1PANEL_FORWARD","family":"ipv4",
          "address":"","port":"8080","protocol":"tcp","strategy":"accept",
          "num":"3","targetIP":"10.0.0.5","targetPort":"80","interface":"eth0",
          "usedStatus":"1PanelClient","description":"web"}]}
        """
        let page = try JSONDecoder().decode(PageEnvelope<FirewallForwardRule>.self, from: Data(json.utf8))
        #expect(page.total == 1)
        let rule = page.items?.first
        #expect(rule?.port == "8080")
        #expect(rule?.targetIP == "10.0.0.5")
        #expect(rule?.num == "3")
    }

    @Test("设置（三组后端 + ping + 白名单 v2.3.1 数组）")
    func settings() throws {
        let json = """
        {"system":{"selected":"ufw","current":"ufw","options":[
            {"name":"ufw","installed":true,"active":true,"initialized":true,"bound":true,
             "supported":true,"message":"","ipv4":{"available":true,"initialized":true,"bound":true},"ipv6":{"available":true}},
            {"name":"firewalld","installed":false,"active":false,"initialized":false,
             "bound":false,"supported":true,"supportReason":"not installed"}]},
         "forwarding":{"selected":"iptables","options":[]},
         "docker":{"selected":"iptables","options":[]},
         "pingStatus":"Disable","portWhiteList":[{"port":"80","protocol":"tcp"},{"port":"443","protocol":"tcp"}]}
        """
        let settings = try JSONDecoder().decode(FirewallSettings.self, from: Data(json.utf8))
        #expect(settings.system?.selected == "ufw")
        #expect(settings.system?.options?.count == 2)
        #expect(settings.system?.options?[1].installed == false)
        #expect(settings.pingBlocked == false)
        #expect(settings.portWhiteList?.count == 2)
        #expect(settings.portWhiteList?.map(\.display) == ["80/tcp", "443/tcp"])
    }

    @Test("设置 v2.4.0：顶层 ipv6Enabled 解码 + 开关请求编码（抓包 2026-10-21）")
    func settingsIPv6() throws {
        let json = """
        {"ipv6Enabled":true,
         "system":{"selected":"iptables","current":"iptables","options":[
            {"name":"iptables","installed":true,"active":false,"initialized":true,"bound":true,
             "supported":true,"implementation":"iptables",
             "ipv4":{"partial":false,"available":true,"initialized":true,"bound":true},
             "ipv6":{"partial":false,"available":true,"initialized":true,"bound":true}}]},
         "forwarding":{"selected":"iptables","options":[]},
         "docker":{"selected":"iptables","options":[]},
         "pingStatus":"Disable","portWhiteList":[],"panelPort":"17331","sshPort":"22"}
        """
        let settings = try JSONDecoder().decode(FirewallSettings.self, from: Data(json.utf8))
        #expect(settings.ipv6Enabled == true)
        // 开关请求体与抓包一致：{"status":"Enable"|"Disable"}（任务式）
        let off = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            FirewallIPv6StatusRequest(status: "Disable"))) as? [String: Any]
        #expect(off?["status"] as? String == "Disable")
        let on = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            FirewallIPv6StatusRequest(status: "Enable"))) as? [String: Any]
        #expect(on?["status"] as? String == "Enable")
        // 开关乐观更新通道：ipv6Enabled 可变（副本修改不影响原值）
        var mutable = settings
        mutable.ipv6Enabled = false
        #expect(mutable.ipv6Enabled == false && settings.ipv6Enabled == true)
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

// MARK: - 抓包核对回归（2026-09-17 logs/防火墙_v2.3.0.md + iptables.md；
// 未标注 v2.4.0 的样本字段在两版间无变化）

@Suite("防火墙抓包核对回归")
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

    @Test("转发 remove 整行回显（编辑/删除回传原始行 + operation）")
    func forwardRemoveEchoesFullRow() throws {
        let rule = FirewallForwardRule(
            id: 9, chain: "", family: "ipv4", address: "", port: "8080",
            protocolField: "tcp", strategy: "", num: "3",
            targetIP: "127.0.0.1", targetPort: "21", interface: "",
            usedStatus: "", descriptionText: nil
        )
        let op = FirewallForwardOperation.remove(rule)
        let data = try JSONEncoder().encode([op])
        let text = String(decoding: data, as: UTF8.self)
        // 回显形态：id/num 等运行时字段原样在场；v2.4.0 无同步字段
        #expect(text.contains(#""operation":"remove""#))
        #expect(text.contains(#""id":9"#))
        #expect(text.contains(#""num":"3""#))
        #expect(text.contains(#""targetPort":"21""#))
        #expect(!text.contains("isDesired"))
        #expect(!text.contains("syncStatus"))
    }

    @Test("白名单 v2.3.1 数组形态：解码缺省 protocol，提交编码不含本地扩展字段")
    func whitelistArrayFormat() throws {
        // v2.3.1 线上形态：对象数组（无地址族维度，v4/v6 由 sources 覆盖）
        let json = #"[{"port":"8444","protocol":"tcp","type":"port","sources":[]},{"port":"22"},{"port":"443","protocol":"udp"}]"#
        let entries = try JSONDecoder().decode([FirewallPortWhitelistEntry].self, from: Data(json.utf8))
        #expect(entries.count == 3)
        #expect(entries[0].port == "8444")
        #expect(entries[0].type == "port")
        #expect(entries[0].sources == [])
        #expect(entries[1].protocolField == "tcp")   // 缺省 tcp
        #expect(entries[2].protocolField == "udp")
        // 同端口同协议不同类型的条目 id 不冲突（列表 ForEach 唯一键）
        let ssh = FirewallPortWhitelistEntry(protocolField: "tcp", port: "22", type: "ssh")
        #expect(entries[1].id != ssh.id)
        #expect(ssh.typeLabel == "SSH")
        // 同端口同协议不同来源是合法数据（上游匹配键含 sources）：
        // id 不并入 sources 会 ForEach 重号（串显/编辑错行/删一条实际删两条）
        let srcA = FirewallPortWhitelistEntry(protocolField: "tcp", port: "80",
                                              type: nil, sources: ["1.2.3.4"])
        let srcB = FirewallPortWhitelistEntry(protocolField: "tcp", port: "80",
                                              type: nil, sources: ["5.6.7.8"])
        #expect(srcA.id != srcB.id)
        #expect(srcA != srcB)
        // 来源一致的同一规则 id 稳定（跨次解码不闪行）
        let srcACopy = FirewallPortWhitelistEntry(protocolField: "tcp", port: "80",
                                                  type: nil, sources: ["1.2.3.4"])
        #expect(srcA.id == srcACopy.id)

        // 提交编码（create/update 请求体里的 rule）：不带本地扩展，与上游一致
        let data = try JSONEncoder().encode(FirewallWhitelistRuleRequest(rule: entries[0]))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""port":"8444""#))
        #expect(text.contains(#""protocol":"tcp""#))
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
         "pingStatus":"Disable","panelPort":"17331","sshPort":"22",
         "portWhiteList":[{"port":"80","protocol":"tcp"},{"port":"443","protocol":"tcp"},{"port":"443","protocol":"udp"}]}
        """
        let settings = try JSONDecoder().decode(FirewallSettings.self, from: Data(json.utf8))
        #expect(settings.system?.selected == "iptables")
        #expect(settings.pingBlocked == false)
        #expect(settings.docker?.options?.first?.ipv4?.reason == "guard_chain_missing")
        #expect(settings.portWhiteList?.count == 3)
        #expect(settings.portWhiteList?[2].protocolField == "udp")
        #expect(settings.panelPort == "17331")
    }

    @Test("转发列表真实样本（v2.3.2 抓包；多余同步字段被宽松解码忽略）")
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

    @Test("规则清单真实样本摘录（v2.4.0 形态：isWhitelist 白名单保护 + locator）")
    func inventoryCapturedSample() throws {
        let json = """
        {"ipv4Range":{"min":1,"max":5},"ipv6Range":{"min":0,"max":0},
         "total":5,"allTotal":17,
         "items":[
          {"rule":{"scope":{"provider":"iptables","family":"ipv4","table":"filter",
              "chain":"1PANEL_BASIC","direction":"input"},"nativeKind":"rule",
            "protocol":"tcp","destinationPort":"80","action":"accept"},
           "observed":{"rule":{},"locator":{"provider":"iptables",
              "scopeKey":"iptables:ipv4:filter:1PANEL_BASIC:input",
              "canonical":"-A 1PANEL_BASIC -p tcp -m tcp --dport 80 -j ACCEPT","position":1},
            "instanceKey":"sha256:3e93","marker":"1panel-rule:601917b0",
            "parseStatus":"supported","raw":"-A 1PANEL_BASIC -p tcp -j ACCEPT","protected":true,
            "persistence":"converged"},
           "isWhitelist":true,"descriptionID":"dw-1"}],
         "notices":[]}
        """
        let resp = try JSONDecoder().decode(FirewallRuleInventoryResponse.self, from: Data(json.utf8))
        #expect(resp.allTotal == 17)
        let item = resp.items?.first
        #expect(item?.isProtected == true)
        #expect(item?.operationTarget?.instanceKey == "sha256:3e93")
        #expect(item?.observed?.marker?.hasPrefix("1panel-rule:") == true)
        #expect(item?.observed?.locator?.position == 1)
        #expect(item?.observed?.persistence == "converged")
    }
}

// MARK: - 删除/重置/策略编码回归

@Suite("防火墙删除与守护策略回归")
struct FirewallDeleteAndPolicyTests {

    @Test("删除请求编码（v2.4.0：targets[{scope,instanceKey,observed}] 回传）")
    func deleteRequestEncode() throws {
        let observed = FirewallObservedRule(
            locator: FirewallLocator(provider: "iptables", scopeKey: "sk",
                                     nativeId: nil, canonical: "-A INPUT -j X", position: 3),
            instanceKey: "sha256:3e93", marker: "1panel-rule:601917b0",
            parseStatus: "supported", protected: true, persistence: "converged")
        let req = FirewallRuleDeleteRequest(targets: [
            FirewallRuleDeleteItem(
                scope: FirewallScope(provider: "iptables", family: "ipv4",
                                     table: "filter", chain: "1PANEL_BASIC", direction: "input"),
                instanceKey: "sha256:3e93", observed: observed)
        ])
        let data = try JSONEncoder().encode(req)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let target = (root?["targets"] as? [[String: Any]])?.first
        #expect(target?["instanceKey"] as? String == "sha256:3e93")
        #expect((target?["scope"] as? [String: Any])?["chain"] as? String == "1PANEL_BASIC")
        // observed 原样回传：服务端按它匹配活规则
        let obs = target?["observed"] as? [String: Any]
        #expect(obs?["parseStatus"] as? String == "supported")
        #expect((obs?["locator"] as? [String: Any])?["position"] as? Int == 3)
        #expect(obs?["persistence"] as? String == "converged")
    }

    @Test("Docker 策略编码（deny_sources + 来源列表；v2.4.0 无 description）")
    func dockerPolicyEncode() throws {
        let policy = DockerGuardPolicy(
            family: "ipv4", hostIP: "0.0.0.0", hostPort: 3306,
            protocolField: "tcp", mode: "deny_sources",
            sources: ["172.29.0.1", "172.29.0.2"]
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
        #expect(item?["description"] == nil)
    }

    @Test("重置响应（v2.4.0：backupPath + removed/disabled；抓包 2026-10-21 真实样本）")
    func resetResponse() throws {
        let resp = try JSONDecoder().decode(FirewallRuleResetResponse.self,
                                            from: Data(#"{"backupPath":"/opt/1panel/backup/firewall/host/iptables-20261021-200545-9ba43503-e6c3-4827-82fb-597172fd7715.json","removed":18,"disabled":true}"#.utf8))
        #expect(resp.backupPath?.hasPrefix("/opt/1panel/backup/firewall/host/") == true)
        #expect(resp.removed == 18 && resp.disabled == true)
    }

    @Test("重置请求编码（抓包 2026-10-21：backup + provider + withDockerRestart 三字段齐全）")
    func resetRequestEncode() throws {
        let data = try JSONEncoder().encode(
            FirewallRuleResetRequest(backup: false, provider: "iptables", withDockerRestart: false))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["backup"] as? Bool == false)
        #expect(obj?["provider"] as? String == "iptables")
        #expect(obj?["withDockerRestart"] as? Bool == false)
        // 缺省 backup=true（与上游 DTO default 一致）
        let defaulted = try JSONEncoder().encode(
            FirewallRuleResetRequest(provider: "iptables", withDockerRestart: false))
        let dobj = try JSONSerialization.jsonObject(with: defaulted) as? [String: Any]
        #expect(dobj?["backup"] as? Bool == true)
    }
}

// MARK: - 初始化 / 规则备份回归（v2.4.0 新增 rules/backups；抓包 2026-10-21）

@Suite("防火墙初始化与规则备份回归")
struct FirewallInitBackupTests {

    @Test("备份列表解码（directory + files[name/provider/ruleCount/modifiedAt 毫秒]）")
    func backupsDecode() throws {
        let json = """
        {"directory":"/opt/1panel/backup/firewall/host",
         "files":[{"name":"iptables-20261021-200545-9ba43503-e6c3-4827-82fb-597172fd7715.json",
                   "provider":"iptables","ruleCount":6,"modifiedAt":1792584345384}]}
        """
        let resp = try JSONDecoder().decode(FirewallRuleBackupsResponse.self, from: Data(json.utf8))
        #expect(resp.directory == "/opt/1panel/backup/firewall/host")
        let file = try #require(resp.files?.first)
        #expect(file.name?.hasPrefix("iptables-20261021-200545") == true)
        #expect(file.provider == "iptables")
        #expect(file.ruleCount == 6)
        #expect(file.modifiedAt == 1792584345384)
        // 行键取文件名（稳定，不随解码随机重建）
        #expect(file.id == file.name)
    }

    @Test("备份列表空态解码（无备份时 files 为空数组）")
    func backupsEmptyDecode() throws {
        let resp = try JSONDecoder().decode(
            FirewallRuleBackupsResponse.self,
            from: Data(#"{"directory":"/opt/1panel/backup/firewall/host","files":[]}"#.utf8))
        #expect(resp.directory?.isEmpty == false)
        #expect(resp.files?.isEmpty == true)
    }

    @Test("初始化并恢复规则请求编码（initialize:true + backupFile + items:[]）")
    func initializeRestoreEncode() throws {
        let req = FirewallRuleCreateRequest(
            items: [], initialize: true,
            backupFile: "iptables-20261021-200545-9ba43503-e6c3-4827-82fb-597172fd7715.json")
        let data = try JSONEncoder().encode(req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["initialize"] as? Bool == true)
        #expect((obj?["backupFile"] as? String)?.hasSuffix(".json") == true)
        #expect((obj?["items"] as? [Any])?.isEmpty == true)
    }

    @Test("普通建规则请求不带 initialize/backupFile（可选字段缺省不编码）")
    func createRequestOmitsInitializeFields() throws {
        let rule = FirewallRule(
            scope: FirewallScope(provider: "iptables", family: "ipv4",
                                 table: "filter", chain: "1PANEL_BASIC"),
            nativeKind: "rule", protocolField: "tcp",
            destinationPort: "443", action: "accept")
        let req = FirewallRuleCreateRequest(
            items: [FirewallRuleCreateItem(rule: rule, sourceKind: "user")])
        let data = try JSONEncoder().encode(req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["initialize"] == nil)
        #expect(obj?["backupFile"] == nil)
        #expect((obj?["items"] as? [Any])?.count == 1)
    }

    @Test("初始化并恢复响应解码（任务式 + 计数三元组）")
    func initializeRestoreResponse() throws {
        let resp = try JSONDecoder().decode(
            FirewallRuleCreateResponse.self,
            from: Data(#"{"taskID":"391553b6-9d66-4d8d-ae25-72bd6a52dc6b","queued":true,"succeeded":0,"failed":0,"skipped":0}"#.utf8))
        #expect(resp.taskID == "391553b6-9d66-4d8d-ae25-72bd6a52dc6b")
        #expect(resp.queued == true)
        #expect(resp.succeeded == 0 && resp.failed == 0 && resp.skipped == 0)
    }

    @Test("基础链操作请求编码（name/operate/taskID；taskID 由客户端生成随请求携带）")
    func filterOperateEncode() throws {
        let data = try JSONEncoder().encode(FirewallFilterOperateRequest(
            name: "1PANEL_BASIC", operate: "init-base",
            taskID: "cb9873c5-a21b-464c-b556-96df87e222cc"))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["name"] as? String == "1PANEL_BASIC")
        #expect(obj?["operate"] as? String == "init-base")
        #expect(obj?["taskID"] as? String == "cb9873c5-a21b-464c-b556-96df87e222cc")
    }
}

// MARK: - 低频操作回归（排序/原文/导入导出；v2.4.0 移除纳管）

@Suite("防火墙低频操作回归")
struct FirewallLowFreqTests {

    @Test("排序请求编码（v2.4.0：scope + instanceKey + targetPosition）")
    func reorderRequestEncode() throws {
        let req = FirewallRuleReorderRequest(
            scope: FirewallScope(provider: "iptables", family: "ipv4",
                                 table: "filter", chain: "1PANEL_BASIC", direction: "input"),
            instanceKey: "sha256:3e93", targetPosition: 3, priority: nil)
        let data = try JSONEncoder().encode(req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["instanceKey"] as? String == "sha256:3e93")
        #expect(obj?["targetPosition"] as? Int == 3)
        #expect((obj?["scope"] as? [String: Any])?["table"] as? String == "filter")
    }

    @Test("更新请求编码（仅改优先级通道：顶层 orderIndex、rule 为 nil）")
    func updateRequestEncode() throws {
        let req = FirewallRuleUpdateRequest(
            scope: FirewallScope(provider: "iptables", family: "ipv4",
                                 table: "filter", chain: "1PANEL_BASIC", direction: "input"),
            instanceKey: "sha256:3e93", rule: nil, descriptionText: nil, orderIndex: 5)
        let data = try JSONEncoder().encode(req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["orderIndex"] as? Int == 5)
        #expect(obj?["rule"] == nil)
        #expect(obj?["uuid"] == nil)
        #expect(obj?["instanceKey"] as? String == "sha256:3e93")
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
