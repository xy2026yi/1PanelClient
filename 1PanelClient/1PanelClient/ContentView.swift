//
//  ContentView.swift
//  1PanelClient
//

import SwiftUI

struct ContentView: View {
    /// 语言切换时 +1，经 .id() 强制重建整棵视图树以即时生效
    /// （服务器数据在 ServerManager 单例中，不受重建影响）
    @State private var languageVersion = 0

    @StateObject private var appLock = AppLockManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        MainTabView()
            .id(languageVersion)
            .onReceive(NotificationCenter.default.publisher(for: L10n.languageDidChangeNotification)) { _ in
                languageVersion += 1
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
                }
            }
    }
}

#Preview {
    ContentView()
}
