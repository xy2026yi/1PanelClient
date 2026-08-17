//
//  SettingsTab.swift
//  1PanelClient
//

import SwiftUI

struct SettingsTab: View {
    /// 向 MainTabView 同步导航深度：true=根页面（显示底部 Tab 栏），false=子页面
    @Binding var atRoot: Bool
    @State private var showAbout = false
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue

    init(atRoot: Binding<Bool> = .constant(true)) {
        self._atRoot = atRoot
    }

    var body: some View {
        NavigationStack {
            settingsRootContent
        }
    }

    /// 根内容（List 及其修饰符）
    var settingsRootContent: some View {
        List {
            // MARK: - 外观
            Section {
                Picker("主题", selection: $themeRaw) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme.rawValue)
                    }
                }
            } header: {
                Text("外观")
            } footer: {
                Text("跟随系统时随设备外观自动切换")
            }

            // MARK: - 关于
            AboutSectionView(isPresented: $showAbout)
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.large)
        // navigationDestination 必须挂在 List 外，否则 lazy 容器内会被忽略
        .navigationDestination(isPresented: $showAbout) {
            AboutDetailView()
        }
        .onChange(of: showAbout) { _, show in
            atRoot = !show
        }
    }
}

// MARK: - 主题

/// 全局外观主题（rawValue 持久化于 UserDefaults）
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "app.theme"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "亮色"
        case .dark:   return "暗色"
        }
    }

    /// 传给 preferredColorScheme 的值，nil 表示跟随系统
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// MARK: - 关于（居中卡片入口）

/// 设置页底部的「关于APP」入口行：小号圆圈 i 图标 + 左对齐标题与版本号
/// 注意：只负责展示与置位，导航由宿主在 List 外挂载（避免 lazy 容器内 navigationDestination）
struct AboutSectionView: View {
    @Binding var isPresented: Bool

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.4"
    }

    var body: some View {
        Section {
            Button {
                isPresented = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                            .frame(width: 34, height: 34)
                        Image(systemName: "info")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("关于APP")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(appVersion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// 关于详情：版本 / API 版本 / 1Panel 官网
struct AboutDetailView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.4"
    }

    var body: some View {
        List {
            Section("版本信息") {
                LabeledContent("版本", value: appVersion)
                LabeledContent("API 版本", value: "v2")
            }
            Section {
                Link(destination: URL(string: "https://1panel.cn")!) {
                    Label("1Panel 官网", systemImage: "safari")
                }
            }
        }
        .navigationTitle("关于APP")
        .navigationBarTitleDisplayMode(.inline)
    }
}

