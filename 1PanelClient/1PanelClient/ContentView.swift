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
            .animation(.easeInOut(duration: 0.25), value: appLock.isLocked)
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
