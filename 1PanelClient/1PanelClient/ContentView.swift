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
            .environmentObject(appLock)
            .overlay {
                if appLock.isLocked {
                    LockScreenView()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: appLock.isLocked)
            // 锁定时自动弹系统验证（冷启动/回前台/重试由 task(id:) 重新触发）
            .task(id: appLock.isLocked) {
                if appLock.isLocked {
                    // 稍等遮罩淡入完成再弹，避免验证框与转场重叠
                    try? await Task.sleep(for: .seconds(0.3))
                    guard appLock.isLocked else { return }
                    await appLock.unlock()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    appLock.lockIfEnabled()
                }
            }
    }
}

#Preview {
    ContentView()
}
