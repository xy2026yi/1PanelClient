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
            // DEBUG 直达调试页（Release 无此分支）：
            //   -chartDemo  图表示例页
            //   -wafDemo    WAF 监控页（指向本机 mock 面板，复现封锁记录空数据等问题）
            rootContent
                .preferredColorScheme(AppTheme(rawValue: themeRaw)?.colorScheme)
                // 注入呈现方尺寸类：sheet 内环境恒为 compact，bottomSheetDetents
                // 依赖它区分 iPad（见 Adaptive.swift PresenterSizeClassKey）
                .hostingPresenterSizeClass()
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

    @ViewBuilder
    private var rootContent: some View {
        #if DEBUG
        if CommandLine.arguments.contains("-chartDemo") {
            DebugChartDemoView()
        } else if CommandLine.arguments.contains("-wafDemo") {
            WAFMonitorView(server: ServerConfig(
                id: UUID(),
                name: "MockPanel",
                baseURL: "http://127.0.0.1:18899",
                apiKey: "mock-key"
            ))
        } else {
            ContentView()
        }
        #else
        ContentView()
        #endif
    }
}
