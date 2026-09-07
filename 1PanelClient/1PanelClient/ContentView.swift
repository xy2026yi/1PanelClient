//
//  ContentView.swift
//  1PanelClient
//

import SwiftUI
import WidgetKit

struct ContentView: View {
    /// 语言切换时 +1，经 .id() 强制重建整棵视图树以即时生效
    /// （服务器数据在 ServerManager 单例中，不受重建影响）
    @State private var languageVersion = 0
    /// 回前台小组件 reload 的节流时间（≥5 分钟一次：reload 计入 WidgetKit
    /// 每日刷新预算，频繁切前台反复触发反而挤占系统自行刷新的份额；
    /// 服务器增删改经由 ServerManager 的 reload 不受此节流）
    @State private var lastWidgetReload: Date? = nil

    @StateObject private var appLock = AppLockManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        MainTabView()
            .id(languageVersion)
            .onReceive(NotificationCenter.default.publisher(for: L10n.languageDidChangeNotification)) { _ in
                languageVersion += 1
                // 小组件文案跟随语言，切换后重载时间线（否则要等系统预算自行刷新）
                WidgetCenter.shared.reloadAllTimelines()
            }
            .overlay {
                if appLock.isLocked {
                    LockScreenView()
                        .transition(.opacity)
                }
            }
            // environmentObject 必须包在 overlay 之外：overlay 内容不在内侧修饰器的
            // 环境作用域内，放 overlay 前会导致 LockScreenView 取不到 AppLockManager 而崩溃
            .environmentObject(appLock)
            .onChange(of: scenePhase) { _, phase in
                // 非 active 即锁（拉通知中心/进切换器会先 inactive，后台快照不露内容）；
                // 来电横幅等短暂失焦同样视为离开，与应用锁的隐私预期一致
                if phase != .active {
                    appLock.lockIfEnabled()
                } else if lastWidgetReload == nil || Date().timeIntervalSince(lastWidgetReload!) >= 300 {
                    // 回前台补一次小组件重载（节流 ≥5 分钟）：重装后系统可能丢弃
                    // 此前的 reload 请求导致小组件拖到分钟级不更新，每次回前台再
                    // 触发一次兜底；请求由系统合并调度
                    lastWidgetReload = Date()
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
    }
}

#Preview {
    ContentView()
}
