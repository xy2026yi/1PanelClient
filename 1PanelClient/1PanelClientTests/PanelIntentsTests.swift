//
//  PanelIntentsTests.swift
//  1PanelClientTests
//
//  App Intents 纯逻辑：实体映射、操作枚举 → API 值、文案组装的语言联动
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("App Intents 实体与枚举")
struct PanelIntentsTests {
    private func makeContainer(name: String = "nginx", state: String = "running",
                               image: String? = "nginx:latest") -> Container {
        let json = """
        {"containerID":"abc123","name":"\(name)","imageName":"\(image ?? "")","state":"\(state)"}
        """
        return try! JSONDecoder().decode(Container.self, from: Data(json.utf8))
    }

    private func makeWebsite() -> Website {
        let json = #"{"id":7,"primaryDomain":"example.com","status":"Running"}"#
        return try! JSONDecoder().decode(Website.self, from: Data(json.utf8))
    }

    private func makeCronjob() -> Cronjob {
        let json = #"{"id":3,"name":"daily-backup","spec":"0 3 * * *"}"#
        return try! JSONDecoder().decode(Cronjob.self, from: Data(json.utf8))
    }

    @Test("Container 映射：名称/状态/镜像与 serverID 保留")
    func containerMapping() {
        let serverID = UUID()
        let e = ContainerEntity(container: makeContainer(), serverID: serverID)
        #expect(e.name == "nginx")
        #expect(e.state == "running")
        #expect(e.imageName == "nginx:latest")
        #expect(e.serverID == serverID)
        #expect(e.id == "nginx")
    }

    @Test("Website 映射：id/域名/状态")
    func websiteMapping() {
        let e = WebsiteEntity(website: makeWebsite(), serverID: UUID())
        #expect(e.id == 7)
        #expect(e.domain == "example.com")
        #expect(e.status == "Running")
    }

    @Test("Cronjob 映射：name 缺失时回退 #id")
    func cronjobMappingAndFallback() {
        let e = CronjobEntity(job: makeCronjob(), serverID: UUID())
        #expect(e.id == 3)
        #expect(e.name == "daily-backup")
        #expect(e.spec == "0 3 * * *")

        let json = #"{"id":9}"#
        let job = try! JSONDecoder().decode(Cronjob.self, from: Data(json.utf8))
        let fallback = CronjobEntity(job: job, serverID: UUID())
        #expect(fallback.name == "#9")
    }

    @Test("容器操作枚举 → API 值")
    func containerOperationAPIValues() {
        #expect(ContainerOperationAppEnum.start.apiValue == "start")
        #expect(ContainerOperationAppEnum.stop.apiValue == "stop")
        #expect(ContainerOperationAppEnum.restart.apiValue == "restart")
        #expect(ContainerOperationAppEnum.kill.apiValue == "kill")
    }

    @Test("操作名 displayName 随语言联动")
    func operationDisplayNameLocalized() {
        let original = L10n.shared.language
        defer { L10n.shared.setLanguage(original) }

        L10n.shared.setLanguage(.english)
        #expect(ContainerOperationAppEnum.restart.displayName == "Restart")
        #expect(WebsiteToggleAppEnum.stop.displayName == "Stop")

        L10n.shared.setLanguage(.zhHans)
        #expect(ContainerOperationAppEnum.restart.displayName == "重启")
    }

    @Test("任务提交文案随语言联动")
    func dialogTextLocalized() {
        let original = L10n.shared.language
        defer { L10n.shared.setLanguage(original) }

        L10n.shared.setLanguage(.english)
        #expect(L10n.f("%@容器「%@」任务已提交", "Restart", "nginx")
                == "Restart container \"nginx\" task submitted")

        L10n.shared.setLanguage(.zhHans)
        #expect(L10n.f("%@容器「%@」任务已提交", "重启", "nginx")
                == "重启容器「nginx」任务已提交")
    }
}
