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
            // DEBUG 直达图表示例页：带启动参数 -chartDemo 拉起（Release 无此分支）
            #if DEBUG
            if CommandLine.arguments.contains("-chartDemo") {
                DebugChartDemoView()
                    .preferredColorScheme(AppTheme(rawValue: themeRaw)?.colorScheme)
            } else {
                ContentView()
                    .preferredColorScheme(AppTheme(rawValue: themeRaw)?.colorScheme)
            }
            #else
            ContentView()
                .preferredColorScheme(AppTheme(rawValue: themeRaw)?.colorScheme)
            #endif
        }
        // iPad 外接键盘：Cmd+1/2/3 切换三 Tab（MainTabView 监听 .selectAppTab 通知）
        .commands {
            CommandGroup(after: .toolbar) {
                Button(L10n.t("首页")) {
                    NotificationCenter.default.post(name: .selectAppTab, object: AppTab.overview)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button(L10n.t("管理")) {
                    NotificationCenter.default.post(name: .selectAppTab, object: AppTab.manage)
                }
                .keyboardShortcut("2", modifiers: .command)

                Button(L10n.t("设置")) {
                    NotificationCenter.default.post(name: .selectAppTab, object: AppTab.settings)
                }
                .keyboardShortcut("3", modifiers: .command)
            }
        }
    }
}
