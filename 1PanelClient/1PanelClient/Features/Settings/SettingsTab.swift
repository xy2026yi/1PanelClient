//
//  SettingsTab.swift
//  1PanelClient
//

import SwiftUI

/// 设置页导航路由（path 驱动；不用 isPresented 绑定——iOS 26 上 back 返回后
/// 绑定写回延迟甚至丢失，MainTabView 依路径计数推导底部栏可见性会失步）
enum SettingsRoute: Hashable {
    case about
    case privacyPolicy
    case diagnostics
}

struct SettingsTab: View {
    /// 导航路径由 MainTabView 持有（跨尺寸类重建不丢栈）；底部栏可见性由计数推导
    @Binding var navPath: NavigationPath
    /// regular（iPad 全屏）下不显示导航大标题，与首页/管理空标题一致——
    /// 独立 NavigationStack 的 large 标题会在页顶多出一行「设置」
    @Environment(\.horizontalSizeClass) private var hSize
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue
    @AppStorage(SecurityGate.httpsOnlyKey) private var httpsOnly = false
    @AppStorage(AppLockManager.enabledKey) private var appLockEnabled = false
    @State private var showSetPin = false
    @State private var setPinToast: String? = nil
    @State private var languageRaw = L10n.shared.language.rawValue

    init(navPath: Binding<NavigationPath> = .constant(NavigationPath())) {
        self._navPath = navPath
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            settingsRootContent
        }
    }

    /// 根内容（List 及其修饰符）
    var settingsRootContent: some View {
        List {
            // MARK: - 外观
            Section {
                Picker(L10n.t("主题"), selection: $themeRaw) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme.rawValue)
                    }
                }
            } header: {
                Text(L10n.t("外观"))
            } footer: {
                Text(L10n.t("跟随系统时随设备外观自动切换"))
            }

            // MARK: - 语言
            Section {
                Picker(L10n.t("语言"), selection: $languageRaw) {
                    ForEach(L10n.Language.allCases) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                }
            } header: {
                Text(L10n.t("语言"))
            } footer: {
                Text(L10n.t("切换后立即生效"))
            }

            // MARK: - 安全
            Section {
                Toggle(L10n.t("仅允许 HTTPS 连接"), isOn: $httpsOnly)
                Toggle(L10n.t("应用锁"), isOn: Binding(
                    get: { appLockEnabled && AppLockManager.hasPasscode },
                    set: { on in
                        if on {
                            // 未设过密码：先弹设置密码，成功后再真正开启
                            showSetPin = true
                        } else {
                            appLockEnabled = false
                            // 一并清除已存密码：重新开启时重设新密码，避免凭据残留
                            AppLockManager.clearPasscode()
                        }
                    }
                ))
                if AppLockManager.hasPasscode {
                    Button(L10n.t("修改密码")) {
                        showSetPin = true
                    }
                }
            } header: {
                Text(L10n.t("安全"))
            }

            // MARK: - 关于
            AboutSectionView(onOpen: { navPath.append(SettingsRoute.about) })
        }
        .navigationTitle(hSize == .regular ? "" : L10n.t("设置"))
        .navigationBarTitleDisplayMode(hSize == .regular ? .inline : .large)
        // navigationDestination 必须挂在 List 外，否则 lazy 容器内会被忽略
        .navigationDestination(for: SettingsRoute.self) { route in
            switch route {
            case .about:
                AboutDetailView { navPath.append($0) }
            case .privacyPolicy:
                PrivacyPolicyView()
            case .diagnostics:
                MetricDiagnosticsView()
            }
        }
        .sheet(isPresented: $showSetPin) {
            SetPasscodeSheet {
                appLockEnabled = true
                setPinToast = L10n.t("应用锁已开启")
            }
        }
        .toastOverlay(message: $setPinToast)
        // toast 2 秒自动消失（同各 ViewModel.showToast 惯例；比较新值防连续提示被旧任务清掉）
        .onChange(of: setPinToast) { _, newValue in
            guard newValue != nil else { return }
            Task {
                try? await Task.sleep(for: .seconds(2))
                if setPinToast == newValue { setPinToast = nil }
            }
        }
        .onChange(of: languageRaw) { _, new in
            L10n.shared.setLanguage(L10n.Language(rawValue: new) ?? .system)
        }
    }
}

// MARK: - 主题

/// 版本号唯一来源：工程 MARKETING_VERSION（构建时注入 CFBundleShortVersionString，审计 E7）。
/// 升级版本只改 pbxproj（或 `agvtool new-marketing-version <x.y.z>`），源码不再双写兜底版本号。

/// 全局外观主题（rawValue 持久化于 UserDefaults）
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "app.theme"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L10n.t("跟随系统")
        case .light:  return L10n.t("亮色")
        case .dark:   return L10n.t("暗色")
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
/// 注意：只负责展示，导航由宿主以 path 驱动挂载（避免 lazy 容器内 navigationDestination）
struct AboutSectionView: View {
    var onOpen: () -> Void

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var body: some View {
        Section {
            Button {
                onOpen()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                            .frame(width: 34, height: 34)
                        Image(systemName: "info")
                            .font(.panelScaled(14, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("关于APP"))
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

/// 关于详情：版本 / API 版本 / 1Panel 官网 / 隐私政策（本地页）/ 诊断数据（本地）
struct AboutDetailView: View {
    /// 二级推入（隐私政策/诊断）回写宿主导航路径
    var onOpen: (SettingsRoute) -> Void

    var body: some View {
        AboutDetailContent(onOpen: onOpen)
            .navigationTitle(L10n.t("关于APP"))
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AboutDetailContent: View {
    var onOpen: (SettingsRoute) -> Void

    var body: some View {
        List {
            Section(L10n.t("版本信息")) {
                LabeledContent(L10n.t("版本"), value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0")
                LabeledContent(L10n.t("API 版本"), value: "v2")
            }
            Section {
                if let url = URL(string: "https://1panel.cn") {
                    Link(destination: url) {
                        Label(L10n.t("1Panel 官网"), systemImage: "safari")
                    }
                }
                // E5：隐私政策为 App 内本地页（离线可读），页内附在线版链接
                Button {
                    onOpen(.privacyPolicy)
                } label: {
                    Label(L10n.t("隐私政策"), systemImage: "hand.raised")
                }
                Button {
                    onOpen(.diagnostics)
                } label: {
                    Label(L10n.t("诊断数据（本地）"), systemImage: "stethoscope")
                }
            }
        }
    }
}

/// ADR-0002：本地 MetricKit 诊断数据列表（仅落盘，不联网），支持系统分享导出
struct MetricDiagnosticsView: View {
    @State private var files: [URL] = []

    var body: some View {
        Group {
            if files.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无诊断数据"),
                    systemImage: "stethoscope",
                    description: Text(L10n.t("崩溃与性能诊断由系统每日聚合，产生后会自动出现在这里"))
                )
            } else {
                List {
                    Section {
                        ForEach(files, id: \.self) { url in
                            HStack {
                                Label(url.lastPathComponent,
                                      systemImage: url.lastPathComponent.hasPrefix("diagnostic")
                                          ? "exclamationmark.triangle" : "chart.bar")
                                    .font(.footnote)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                ShareLink(item: url) {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    } footer: {
                        Text(L10n.t("数据仅保存在本机（最近 30 天），不会自动上传；卸载 App 后即消失"))
                    }
                }
            }
        }
        .navigationTitle(L10n.t("诊断数据（本地）"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { files = MetricStore.listFiles() }
    }
}

