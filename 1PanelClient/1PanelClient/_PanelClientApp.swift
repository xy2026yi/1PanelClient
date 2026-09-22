//
//  _PanelClientApp.swift
//  1PanelClient
//

import SwiftUI

@main
struct _PanelClientApp: App {
    /// 全局外观主题（设置页可改），nil = 跟随系统
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue

    init() {
        // ADR-0002：MetricKit 本地诊断（仅落盘，零上报）
        MetricKitSubscriber.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            // DEBUG 直达调试页（Release 无此分支）：
            //   -chartDemo        图表示例页
            //   -wafDemo          WAF 监控页（指向本机 mock 面板，复现封锁记录空数据等问题）
            //   （-installFormDemo/-pendingFormsDemo 原型页已归档至 archive/debug-prototypes/）
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
        } else if CommandLine.arguments.contains("-editorDemo") {
            // CodeEditorArea 视觉回归入口：双态切换 + 真实长行样本，无网络依赖
            NavigationStack {
                EditorDemoHost()
            }
        } else {
            ContentView()
        }
        #else
        ContentView()
        #endif
    }
}

// MARK: - CodeEditorArea 视觉回归宿主（DEBUG -editorDemo 直达）
#if DEBUG
struct EditorDemoHost: View {
    @State private var text = """
location / {
    proxy_pass http://127.0.0.1:80;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header REMOTE-HOST $remote_addr;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $http_connection;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Port $server_port;
    proxy_http_version 1.1;
    add_header X-Cache $upstream_cache_status;
    proxy_ssl_server_name off;
    proxy_ssl_name $proxy_host;
}
# 行 16
# 行 17
# 行 18
# 行 19
# 行 20
# 行 21
# 行 22
# 行 23
# 行 24
# 行 25
# 行 26
# 行 27
# 行 28
# 行 29
# 行 30
# 行 31
# 行 32
# 行 33
# 行 34
# 行 35
# 行 36
# 行 37
# 行 38
# 行 39
# 行 40
# 行 41
# 行 42
# 行 43
# 行 44
# 行 45
# 行 46
# 行 47
# 行 48
# 行 49
# 行 50
"""
    @State private var readOnly = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("mode", selection: $readOnly) {
                Text("编辑").tag(false)
                Text("只读").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if readOnly {
                // 只读态：页面级 ScrollView 包裹（与站点 nginx 配置页同构）
                ScrollView {
                    CodeEditorArea(text: $text, readOnly: true)
                }
                .background(Color(.systemGroupedBackground))
            } else {
                // 编辑态：自滚动 TextEditor 独占
                CodeEditorArea(text: $text)
            }
        }
        .navigationTitle("editor-demo")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
