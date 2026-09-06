//
//  AdaptivePolling.swift
//  1PanelClient
//
//  感知前后台的页面级轮询（审计 D1/D3），由 MonitorView/ContainerMonitorView 的
//  页面级暂停先例推广为可复用组件：
//  - scenePhase 非 active（后台/切换器）或 isActive 条件不满足时整轮暂停，不发请求；
//  - 恢复运行态（回前台、切回 Tab、返回根页面）当秒立即补拉一次，再回到固定周期；
//  - 页面消失时随 .task 生命周期自动取消。
//

import SwiftUI

extension View {
    /// 页面级自适应轮询。
    /// - Parameters:
    ///   - interval: 正常轮询周期（秒，内部按 1 秒粒度计时）
    ///   - fireImmediately: 挂载即执行一次；页面自身 `.task` 已有首拉时传 false 避免重复请求
    ///   - isActive: 附加运行条件（如 Tab 选中、处于根页面），不满足时暂停、重新满足时补拉
    ///   - action: 每轮执行的请求
    func adaptivePolling(
        interval: TimeInterval = 5,
        fireImmediately: Bool = false,
        isActive: @escaping () -> Bool = { true },
        action: @escaping () async -> Void
    ) -> some View {
        modifier(AdaptivePollingModifier(
            interval: interval,
            fireImmediately: fireImmediately,
            isActive: isActive,
            action: action
        ))
    }
}

private struct AdaptivePollingModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    /// 前后台活跃标记：@State 承载使 .task 循环读到的是实时值（闭包捕获的 struct 拷贝会过期）
    @State private var isSceneActive = true

    let interval: TimeInterval
    let fireImmediately: Bool
    let isActive: () -> Bool
    let action: () async -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in
                isSceneActive = phase == .active
            }
            .task { await runLoop() }
    }

    private func runLoop() async {
        let intervalTicks = max(1, Int(interval.rounded()))
        var ticksSinceFire = 0
        var wasPaused = false
        var attached = false

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }

            if !attached {
                attached = true
                if fireImmediately {
                    ticksSinceFire = 0
                    await action()
                    continue
                }
            }

            // 后台 / 条件不满足：暂停计时，标记待补拉
            guard isSceneActive && isActive() else {
                wasPaused = true
                continue
            }

            ticksSinceFire += 1
            // 恢复运行态（回前台/条件重新满足）立即补拉，否则到周期才触发
            if wasPaused || ticksSinceFire >= intervalTicks {
                wasPaused = false
                ticksSinceFire = 0
                await action()
            }
        }
    }
}
