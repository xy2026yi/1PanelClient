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
// unlock 标记是全局 UserDefaults：用例间必须串行执行，否则
// unlockFlag 的「置 true→defer 清除」窗口会与读取该键的用例竞态
//（当前用例恰好都是 @MainActor 同步体不会交错，串行化是结构性保证，
//  任一用例改 async/解除 MainActor 后依然成立）
@Suite("高级功能门禁", .serialized)
struct AdvancedFeatureGateTests {

    @Test("门禁集合：高级功能分组整体 + AI 的 vLLM/模型下载")
    func gatedItems() {
        // WAF 已合并为常显模块（监控为其内部受控子入口），不再整体门禁
        let expected: Set<ManageItem> = [.gpuMonitor, .websiteMonitor, .nodeManage,
                                         .aiVllm, .aiDownloader]
        #expect(AdvancedFeatureGate.gatedItems == expected)
        // 非门禁项抽查
        #expect(!AdvancedFeatureGate.isGated(.apps))
        #expect(!AdvancedFeatureGate.isGated(.aiOllama))
        #expect(!AdvancedFeatureGate.isGated(.monitor))
    }

    @Test("可见性状态机：非门禁项只看偏好；门禁项需 license 或解锁再叠加偏好")
    func visibilityMatrix() {
        // unlock 标记是全局 UserDefaults，Swift Testing 用例并发执行时会与
        // unlockFlag 的「置 true→defer 清除」窗口竞态：本用例先显式清零并负责清理
        UserDefaults.standard.set(false, forKey: "manage.advancedUnlocked")
        defer { UserDefaults.standard.removeObject(forKey: "manage.advancedUnlocked") }

        let gate = AdvancedFeatureGate()

        // 未解锁
        gate.serverLicensed = nil    // 未知 → 隐藏
        #expect(!gate.shows(.aiVllm, prefsEnabled: true))
        #expect(!gate.shows(.gpuMonitor, prefsEnabled: true))
        gate.serverLicensed = false  // 无 license → 隐藏
        #expect(!gate.shows(.aiDownloader, prefsEnabled: true))
        gate.serverLicensed = true   // 有 license → 跟随偏好
        #expect(gate.shows(.aiVllm, prefsEnabled: true))
        #expect(!gate.shows(.aiVllm, prefsEnabled: false))
        gate.serverLicensed = false  // 无 license + 用户在编辑里关了 → 隐藏
        #expect(!gate.shows(.nodeManage, prefsEnabled: false))

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
