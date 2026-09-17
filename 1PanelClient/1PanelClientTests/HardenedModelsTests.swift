//
//  HardenedModelsTests.swift
//  1PanelClientTests
//
//  M2 模型加固回归：decodeDefault 容错解码——字段缺失 / null / 类型漂移
//  不再让整页 decode 失败（覆盖数据库 / 容器 / 编排 / 快照 / 版本日志代表结构）。
//  上游 schema 真实漂移样本到达后追加夹具。
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("M2 模型加固：容错解码")
struct HardenedModelsTests {

    // MARK: Database

    @Test("DatabaseSystem：关键字段缺失/null/类型漂移回退默认值")
    func databaseSystemHardened() throws {
        let json = """
        {"id": null, "type": 7, "from": null, "database": null, "version": "8.0"}
        """
        let sys = try JSONDecoder().decode(DatabaseSystem.self, from: Data(json.utf8))
        #expect(sys.id == 0)
        #expect(sys.type == "")
        #expect(sys.from == "local")
        #expect(sys.database == "")
        #expect(sys.version == "8.0")
        // 全空对象也可解码（上游清空列表场景）
        let empty = try JSONDecoder().decode(DatabaseSystem.self, from: Data("{}".utf8))
        #expect(empty.id == 0 && empty.type.isEmpty && empty.from == "local")
    }

    @Test("FormatOption：collations 缺失回退空数组")
    func formatOptionHardened() throws {
        let opt = try JSONDecoder().decode(FormatOption.self, from: Data(#"{"format": "utf8mb4"}"#.utf8))
        #expect(opt.format == "utf8mb4")
        #expect(opt.collations.isEmpty)
    }

    // MARK: Container

    @Test("Container：containerID/name/state 缺失回退默认")
    func containerHardened() throws {
        let json = """
        {"containerID": null, "name": 42, "imageName": "nginx:alpine", "state": null}
        """
        let c = try JSONDecoder().decode(Container.self, from: Data(json.utf8))
        #expect(c.containerID == "")
        #expect(c.name == "")
        #expect(c.state == "unknown")
        #expect(c.imageName == "nginx:alpine")
    }

    @Test("ContainerInfo：name/image 缺失回退空串，可选字段保持")
    func containerInfoHardened() throws {
        let info = try JSONDecoder().decode(ContainerInfo.self, from: Data("{}".utf8))
        #expect(info.name == "")
        #expect(info.image == "")
        #expect(info.networks == nil && info.restartPolicy == nil)
    }

    @Test("ContainerPortInfo：协议缺失回退 tcp")
    func portInfoHardened() throws {
        let port = try JSONDecoder().decode(ContainerPortInfo.self,
                                            from: Data(#"{"hostPort":"80","containerPort":"8080"}"#.utf8))
        #expect(port.hostIP == "")
        #expect(port.hostPort == "80")
        #expect(port.protocolField == "tcp")
    }

    @Test("ContainerRepo/Image：id 类型漂移回退")
    func repoImageHardened() throws {
        let repo = try JSONDecoder().decode(ContainerRepo.self, from: Data(#"{"id": "abc"}"#.utf8))
        #expect(repo.id == 0)
        let image = try JSONDecoder().decode(ContainerImage.self, from: Data("{}".utf8))
        #expect(image.id == "")
    }

    // MARK: 容器资源

    @Test("ContainerNetwork/Volume/Compose：主键字段缺失回退")
    func resourceHardened() throws {
        let net = try JSONDecoder().decode(ContainerNetwork.self, from: Data("{}".utf8))
        #expect(net.id == "" && net.name == "")
        let vol = try JSONDecoder().decode(ContainerVolume.self, from: Data("{}".utf8))
        #expect(vol.name == "" && vol.id == "")
        let compose = try JSONDecoder().decode(ContainerCompose.self, from: Data("{}".utf8))
        #expect(compose.name == "" && compose.id == "")
    }

    // MARK: 快照 / 版本

    @Test("SnapshotItem：id 漂移回退 0，显示名回落 #0")
    func snapshotHardened() throws {
        let item = try JSONDecoder().decode(SnapshotItem.self, from: Data(#"{"id":"x"}"#.utf8))
        #expect(item.id == 0)
        #expect(item.displayName == "#0")
    }

    @Test("SwapDetail：path/size 缺失回退")
    func swapHardened() throws {
        let swap = try JSONDecoder().decode(SwapDetail.self, from: Data("{}".utf8))
        #expect(swap.path == "")
        #expect(swap.size == 0)
        #expect(swap.sizeGB == 0)
    }

    @Test("PanelRelease：version 缺失回退空串（版本日志页不整页崩）")
    func releaseHardened() throws {
        let release = try JSONDecoder().decode(PanelRelease.self, from: Data("{}".utf8))
        #expect(release.version == "")
        #expect(release.id == "")
    }

    // MARK: 信封联动（回归）

    @Test("PageEnvelope + Container 联动：漂移字段不拖垮整页")
    func envelopeWithHardenedModel() throws {
        let json = """
        {"total": 2, "items": [
          {"containerID": "a1", "name": "web", "state": "running"},
          {"containerID": null, "name": null, "state": null, "ports": ["80/tcp"]}
        ]}
        """
        let page = try JSONDecoder().decode(PageEnvelope<Container>.self, from: Data(json.utf8))
        #expect(page.total == 2)
        #expect(page.items?.count == 2)
        #expect(page.items?[1].state == "unknown")
        #expect(page.items?[1].ports == ["80/tcp"])
    }
}

// MARK: - M2 收尾：长尾结构加固回归

@Suite("M2 长尾加固回归")
struct HardenedLongTailTests {

    @Test("AIAgent：id/name 缺失回退，可选字段保持")
    func aiAgentHardened() throws {
        let agent = try JSONDecoder().decode(AIAgent.self, from: Data("{}".utf8))
        #expect(agent.id == 0)
        #expect(agent.name == "")
        #expect(agent.status == nil)
    }

    @Test("Cronjob：id 类型漂移回退 0（列表不整页失败）")
    func cronjobHardened() throws {
        let job = try JSONDecoder().decode(Cronjob.self, from: Data(#"{"id": "abc", "name": "备份"}"#.utf8))
        #expect(job.id == 0)
        #expect(job.name == "备份")
    }

    @Test("Website/WebsiteSSL/WebsiteFull：id 缺失回退")
    func websiteIdsHardened() throws {
        let w = try JSONDecoder().decode(Website.self, from: Data("{}".utf8))
        #expect(w.id == 0)
        let ssl = try JSONDecoder().decode(WebsiteSSL.self, from: Data("{}".utf8))
        #expect(ssl.id == 0)
        let full = try JSONDecoder().decode(WebsiteFull.self, from: Data("{}".utf8))
        #expect(full.id == 0)
    }

    @Test("OpenRestyStatus：七数值字段全缺失回退 0（键映射保持）")
    func openRestyStatusHardened() throws {
        let st = try JSONDecoder().decode(OpenRestyStatus.self, from: Data("{}".utf8))
        #expect(st.active == 0 && st.accepts == 0 && st.handled == 0)
        #expect(st.requests == 0 && st.reading == 0 && st.writing == 0 && st.waiting == 0)
        // 自定义键名（protocol/IPV6/ID）不因加固丢失
        let w = try JSONDecoder().decode(Website.self, from: Data(#"{"protocol":"https"}"#.utf8))
        #expect(w.protocolStr == "https")
        let ig = try JSONDecoder().decode(AppIgnoreUpgrade.self, from: Data(#"{"ID":7}"#.utf8))
        #expect(ig.id == 7)
    }

    @Test("AppSearchResponse：PageEnvelope 化（total null 回退 0）")
    func appSearchEnvelope() throws {
        let json = #"{"items": [{"id": 1, "key": "wordpress"}]}"#
        let resp = try JSONDecoder().decode(AppSearchResponse.self, from: Data(json.utf8))
        #expect(resp.total == 0)
        #expect(resp.items?.first?.key == "wordpress")
    }
}

// MARK: - wget 进度模型（抓包 2026-09-17：key/status 字段与完成态判定）

@Suite("wget 下载进度模型")
struct FileWgetProgressTests {

    @Test("抓包样本解码：Downloading / Canceled 双态")
    func decodeCaptured() throws {
        let json = """
        [{"key":"file-wget-f313a4ec","total":23983183,"written":7490304,
          "percent":31.23,"name":"PiliPlus_ios_2.1.4+5348.ipa","status":"Downloading"},
         {"key":"file-wget-a1b2","total":23983183,"written":12369408,
          "percent":51.57,"name":"app.ipa","status":"Canceled"}]
        """
        let items = try JSONDecoder().decode([FileWgetProgress].self, from: Data(json.utf8))
        #expect(items.count == 2)
        #expect(items[0].id == "file-wget-f313a4ec")
        #expect(items[0].isFinished == false)
        #expect(items[1].status == "Canceled")
        #expect(items[1].isFinished == true)
    }

    @Test("key/status 缺失时可解码（旧面板兼容），行键回落 name")
    func legacyShapeFallback() throws {
        let items = try JSONDecoder().decode([FileWgetProgress].self,
                                             from: Data(#"[{"name":"a.zip","percent":50}]"#.utf8))
        #expect(items[0].id == "a.zip")
        #expect(items[0].isFinished == false)
    }

    @Test("停止与清理请求编码")
    func requestEncoding() throws {
        let stop = try JSONEncoder().encode(FileWgetStopRequest(key: "file-wget-1"))
        #expect(String(decoding: stop, as: UTF8.self) == #"{"key":"file-wget-1"}"#)
        let rm = try JSONEncoder().encode(FileWgetRecordRemoveRequest(keys: ["k1", "k2"]))
        let obj = try JSONSerialization.jsonObject(with: rm) as? [String: Any]
        #expect((obj?["keys"] as? [String]) == ["k1", "k2"])
    }
}

// MARK: - 告警启停与面板会话模型（抓包 2026-09-17 / 上游 DTO）

@Suite("告警启停与面板终端会话")
struct AlertStatusAndPanelSessionTests {

    @Test("告警启停请求编码（/alert/status 与 /alert/config/status 同形）")
    func alertStatusEncode() throws {
        let req = AlertStatusRequest(id: 1, status: "Disable")
        let data = try JSONEncoder().encode(req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["id"] as? Int == 1)
        #expect(obj?["status"] as? String == "Disable")
    }

    @Test("面板会话解码（ssh 在线 + local 已断开，前端接口形状）")
    func panelSessionDecode() throws {
        let json = """
        [{"id":"s-1","kind":"ssh","title":"root@web-1","hostId":2,
          "attached":true,"createdAt":"2026-09-17T09:00:00Z","detachedAt":""},
         {"id":"s-2","kind":"local","title":"local","hostId":0,
          "attached":false,"createdAt":"2026-09-17T08:00:00Z","detachedAt":"2026-09-17T08:30:00Z"}]
        """
        let sessions = try JSONDecoder().decode([PanelTerminalSession].self, from: Data(json.utf8))
        #expect(sessions.count == 2)
        #expect(sessions[0].id == "s-1")
        #expect(sessions[0].attached == true)
        #expect(sessions[1].kind == "local")
        #expect(sessions[1].attached == false)
    }

    @Test("关闭面板会话请求编码")
    func closeRequestEncode() throws {
        let data = try JSONEncoder().encode(PanelTerminalSessionCloseRequest(id: "s-1"))
        #expect(String(decoding: data, as: UTF8.self) == #"{"id":"s-1"}"#)
    }
}
