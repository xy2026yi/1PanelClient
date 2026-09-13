//
//  AdvancedFeatureGateTests.swift
//  1PanelClientTests
//
//  高级功能门禁逻辑测试：门禁集合 / 可见性状态机
//  （license 检测为网络交互，不在单测覆盖范围）
//

import Testing
import Foundation
@testable import _PanelClient

@MainActor
@Suite("高级功能门禁")
struct AdvancedFeatureGateTests {

    @Test("门禁集合：高级功能分组整体 + AI 的 vLLM/模型下载")
    func gatedItems() {
        let expected: Set<ManageItem> = [.gpuMonitor, .websiteMonitor, .nodeManage, .wafMonitor,
                                         .aiVllm, .aiDownloader]
        #expect(AdvancedFeatureGate.gatedItems == expected)
        // 非门禁项抽查
        #expect(!AdvancedFeatureGate.isGated(.apps))
        #expect(!AdvancedFeatureGate.isGated(.aiOllama))
        #expect(!AdvancedFeatureGate.isGated(.monitor))
    }

    @Test("可见性状态机：非门禁项只看偏好；门禁项需 license 或解锁再叠加偏好")
    func visibilityMatrix() {
        let gate = AdvancedFeatureGate()

        // 未解锁（UserDefaults 默认 false）
        gate.serverLicensed = nil    // 未知 → 隐藏
        #expect(!gate.shows(.aiVllm, prefsEnabled: true))
        #expect(!gate.shows(.gpuMonitor, prefsEnabled: true))
        gate.serverLicensed = false  // 无 license → 隐藏
        #expect(!gate.shows(.aiDownloader, prefsEnabled: true))
        gate.serverLicensed = true   // 有 license → 跟随偏好
        #expect(gate.shows(.aiVllm, prefsEnabled: true))
        #expect(!gate.shows(.aiVllm, prefsEnabled: false))
        gate.serverLicensed = false  // 无 license + 用户在编辑里关了 → 隐藏
        #expect(!gate.shows(.wafMonitor, prefsEnabled: false))

        // 非门禁项不受 license 影响
        gate.serverLicensed = nil
        #expect(gate.shows(.apps, prefsEnabled: true))
        #expect(!gate.shows(.apps, prefsEnabled: false))
    }

    @Test("解锁标记：unlock 后无 license 也可见（一次性、设备级）")
    func unlockFlag() {
        let key = "manage.advancedUnlocked"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let gate = AdvancedFeatureGate()
        gate.serverLicensed = false
        #expect(!gate.shows(.aiVllm, prefsEnabled: true))

        gate.unlock()
        #expect(gate.isUnlocked)
        #expect(gate.shows(.aiVllm, prefsEnabled: true))
        #expect(!gate.shows(.aiVllm, prefsEnabled: false))
    }
}
