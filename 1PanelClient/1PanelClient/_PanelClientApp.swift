//
//  _PanelClientApp.swift
//  1PanelClient
//

import SwiftUI

@main
struct _PanelClientApp: App {
    /// 全局外观主题（设置页可改），nil = 跟随系统
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(AppTheme(rawValue: themeRaw)?.colorScheme)
        }
    }
}
