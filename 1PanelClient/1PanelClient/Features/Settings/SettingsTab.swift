//
//  SettingsTab.swift
//  1PanelClient
//

import LocalAuthentication
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
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue
    @AppStorage(SecurityGate.httpsOnlyKey) private var httpsOnly = false
    @AppStorage(AppLockManager.biometricsEnabledKey) private var biometricsEnabled = false
    @AppStorage(AppLockManager.passcodeEnabledKey) private var passcodeEnabled = false
    /// 开/关面容走系统验证时需豁免 inactive 上锁，经 manager 发起
    @EnvironmentObject private var appLock: AppLockManager
    @State private var showSetPin = false
    /// 正在关闭的方式（非 nil 时弹关闭前验证 sheet）
    @State private var pendingDisable: AppLockMethod? = nil
    @State private var biometricAuthInFlight = false
    @State private var securityToast: String? = nil
    @State private var biometricAlert: String? = nil
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
            // MARK: - 常规（主题 + 语言）
            Section {
                Picker(selection: $themeRaw) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme.rawValue)
                    }
                } label: {
                    settingsRowLabel(L10n.t("主题"), systemName: "paintpalette", color: .purple)
                }
                Picker(selection: $languageRaw) {
                    ForEach(L10n.Language.allCases) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                } label: {
                    settingsRowLabel(L10n.t("语言"), systemName: "globe", color: .teal)
                }
            } header: {
                Text(L10n.t("常规"))
            } footer: {
                Text(L10n.t("主题跟随系统时自动切换；语言切换后立即生效"))
            }

            // MARK: - 安全
            Section {
                Toggle(isOn: $httpsOnly) {
                    settingsRowLabel(L10n.t("仅允许 HTTPS 连接"), systemName: "lock.shield", color: .green)
                }
                // 应用锁两种方式各自独立开关；无生物识别硬件的机型不显示面容行
                if AppLockManager.hasBiometryHardware {
                    Toggle(isOn: Binding(
                        get: { biometricsEnabled },
                        set: { on in
                            if on {
                                enableBiometrics()
                            } else {
                                requestDisable(.biometrics)
                            }
                        }
                    )) {
                        settingsRowLabel(AppLockManager.biometryDisplayName,
                                         systemName: AppLockManager.biometryIcon, color: .indigo)
                    }
                }
                Toggle(isOn: Binding(
                    get: { passcodeEnabled && AppLockManager.hasPasscode },
                    set: { on in
                        if on {
                            // 先弹设置密码，成功后再真正开启
                            showSetPin = true
                        } else {
                            requestDisable(.passcode)
                        }
                    }
                )) {
                    settingsRowLabel(L10n.t("密码"), systemName: "lock", color: .orange)
                }
            } header: {
                Text(L10n.t("安全"))
            }

            // MARK: - 关于
            AboutSectionView(onOpen: { navPath.append(SettingsRoute.about) })
        }
        // 与管理页根部同款：无标题（原大标题「设置」已按需求移除）
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // TabBar 上方留白：与首页/管理页 contentMargins 同一机制、同一数值——
        // safeAreaInset 底栏不产生滚动内容避让，缺它时末行被 Tab 栏遮住
        //（行高变大后内容超出屏即暴露：可滚余量极小表现为拖动回弹）
        .contentMargins(.bottom, 60, for: .scrollContent)
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
                passcodeEnabled = true
                Haptic.success()
                securityToast = L10n.t("密码已开启")
            }
        }
        .sheet(item: $pendingDisable) { method in
            AppLockVerifySheet(
                allowBiometrics: canVerifyWithBiometrics,
                allowPasscode: canVerifyWithPasscode
            ) {
                disable(method)
            }
        }
        .alert(AppLockManager.biometryDisplayName, isPresented: Binding(
            get: { biometricAlert != nil },
            set: { if !$0 { biometricAlert = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(biometricAlert ?? "")
        }
        .toastOverlay(message: $securityToast)
        // toast 2 秒自动消失（同各 ViewModel.showToast 惯例；比较新值防连续提示被旧任务清掉）
        .onChange(of: securityToast) { _, newValue in
            guard newValue != nil else { return }
            Task {
                try? await Task.sleep(for: .seconds(2))
                if securityToast == newValue { securityToast = nil }
            }
        }
        .onChange(of: languageRaw) { _, new in
            L10n.shared.setLanguage(L10n.Language(rawValue: new) ?? .system)
        }
    }

    // MARK: - 应用锁开关流程

    /// 当前可用于「关闭前验证」的方式 = 已开启且确实可用的方式
    private var canVerifyWithBiometrics: Bool {
        biometricsEnabled && AppLockManager.hasBiometryHardware
    }

    private var canVerifyWithPasscode: Bool {
        passcodeEnabled && AppLockManager.hasPasscode
    }

    /// 开启面容/触控 ID：先验一次（确认确实可用，并在此刻触发系统权限弹窗），通过才置开
    private func enableBiometrics() {
        guard !biometricAuthInFlight else { return }
        biometricAuthInFlight = true
        Task {
            defer { biometricAuthInFlight = false }
            // 隐藏系统回退按钮：此处只为确认生物识别本身可用，没有「改用密码」的语义
            let outcome = await appLock.authenticateInForeground(
                policy: .deviceOwnerAuthenticationWithBiometrics,
                reason: L10n.t("验证以更改应用锁设置"),
                fallbackTitle: ""
            )
            let name = AppLockManager.biometryDisplayName
            switch outcome {
            case .success:
                biometricsEnabled = true
                Haptic.success()
                securityToast = L10n.f("%@ 已开启", name)
            case .cancelled, .fallbackRequested:
                break
            case .failed(let code):
                switch code {
                case .biometryNotEnrolled:
                    biometricAlert = L10n.f("设备尚未录入%@，请先在系统设置中录入", name)
                case .biometryNotAvailable:
                    biometricAlert = L10n.f("%@ 不可用，请在系统设置中检查权限", name)
                default:
                    biometricAlert = L10n.f("%@ 验证失败，未开启", name)
                }
            }
        }
    }

    /// 关闭某方式前先验证身份：可用方式 = 当前已开启的方式（仅面容→面容；仅密码→密码；
    /// 都开→任一）。若无任一可验证方式（如密码开关位残留但 Keychain 已无密码），无从验证，直接关闭
    private func requestDisable(_ method: AppLockMethod) {
        guard canVerifyWithBiometrics || canVerifyWithPasscode else {
            disable(method)
            return
        }
        pendingDisable = method
    }

    private func disable(_ method: AppLockMethod) {
        switch method {
        case .biometrics:
            biometricsEnabled = false
        case .passcode:
            passcodeEnabled = false
            // 一并清除已存密码：密码不可修改，重新开启时必须设新密码，也避免凭据残留
            AppLockManager.clearPasscode()
        }
    }

    /// 设置行统一图标样式：与「关于」入口行同款（34pt IconBadge + 左对齐标题），
    /// 供 Picker/Toggle/Button 行的 label 复用
    private func settingsRowLabel(_ title: String, systemName: String, color: Color) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemName: systemName, color: color,
                      size: 34, cornerRadius: Radius.small, backgroundOpacity: 0.08)
            Text(title)
        }
        .padding(.vertical, 4)
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

/// 设置页底部的「关于」入口行：小号圆圈 i 图标 + 左对齐标题与版本号
/// 注意：只负责展示，导航由宿主以 path 驱动挂载（避免 lazy 容器内 navigationDestination）
struct AboutSectionView: View {
    var onOpen: () -> Void

    /// 有新版时的标题角标（冷启动由缓存恢复，不等网络）
    @ObservedObject private var updater = AppUpdateChecker.shared

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var body: some View {
        Section {
            Button {
                onOpen()
            } label: {
                HStack(spacing: 12) {
                    IconBadge(systemName: "info", color: .accentColor,
                              size: 34, cornerRadius: Radius.small, backgroundOpacity: 0.08)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(L10n.t("关于"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            if updater.updateAvailable {
                                Text(L10n.t("新版本"))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(.red))
                            }
                        }
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

/// 关于详情：图标卡片（说明/版本）+ 功能组（问题反馈/官网/隐私政策/诊断/检查更新）
struct AboutDetailView: View {
    /// 二级推入（诊断）回写宿主导航路径
    var onOpen: (SettingsRoute) -> Void

    var body: some View {
        AboutDetailContent(onOpen: onOpen)
            .navigationTitle(L10n.t("关于"))
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AboutDetailContent: View {
    var onOpen: (SettingsRoute) -> Void

    @ObservedObject private var gate = AdvancedFeatureGate.shared
    @ObservedObject private var updater = AppUpdateChecker.shared
    @EnvironmentObject private var safari: InAppSafariPresenter
    /// 隐私政策在线可达性探测进行中（行尾转圈，防重复点击）
    @State private var isProbingPrivacy = false
    /// 连点版本号解锁计数（Android 开发者选项同款彩蛋）——挂在顶部卡片的
    /// 版本行上（整行热区），7 次渐进提示逻辑不变
    @State private var versionTaps = 0
    @State private var tapToast: String?
    private static let unlockTaps = 7

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var body: some View {
        List {
            headerCard
            actionSection
            if case .available(let info) = updater.state {
                updateSection(info)
            }
        }
        .localToast(message: $tapToast)
    }

    // MARK: 顶部卡片（图标 + 一句话说明 + 版本；版本行承载连点彩蛋）

    private var headerCard: some View {
        Section {
            VStack(spacing: 10) {
                appIcon
                Text(L10n.t("服务器运维管理面板 1Panel 的移动端 App"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(L10n.f("版本 %@", appVersion))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    // 整行热区：连点彩蛋的命中区不因居中文本变窄
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { handleVersionTap() }
            }
            .padding(.vertical, 8)
        }
    }

    /// 主 App 图标：经 CFBundleIcons 取实际图标文件（列表按尺寸升序，取末位）
    @ViewBuilder
    private var appIcon: some View {
        if let image = Self.loadAppIcon() {
            Image(uiImage: image)
                .resizable()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            // 兜底：图标资产缺失（如 CI 未签名包）不空占位
            IconBadge(systemName: "apps.iphone", color: .accentColor,
                      size: 88, cornerRadius: 20, backgroundOpacity: 0.12)
        }
    }

    private static func loadAppIcon() -> UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String] else { return nil }
        for name in files.reversed() {
            if let image = UIImage(named: name) { return image }
        }
        return nil
    }

    // MARK: 功能组（无标题）：问题反馈 / 官网 / 隐私政策（在线）/ 诊断数据 / 检查更新

    private var actionSection: some View {
        Section {
            Button {
                if let url = URL(string: "https://github.com/xy2026yi/1PanelClient/issues") {
                    safari.open(url)
                }
            } label: {
                Label(L10n.t("问题反馈"), systemImage: "ladybug")
            }
            Button {
                if let url = URL(string: "https://1panel.cn") {
                    safari.open(url)
                }
            } label: {
                Label(L10n.t("1Panel 官网"), systemImage: "safari")
            }
            // 隐私政策默认在线版（源头 docs/privacy-policy.md）：探测可达即跳
            // Safari；离线/网络阻断（如 GitHub 不可达）回退 App 内本地页兜底
            Button {
                Task { await openPrivacyPolicy() }
            } label: {
                HStack {
                    Label(L10n.t("隐私政策"), systemImage: "hand.raised")
                    Spacer()
                    if isProbingPrivacy { ProgressView() }
                }
            }
            .disabled(isProbingPrivacy)
            Button {
                onOpen(.diagnostics)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "stethoscope")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("诊断数据"))
                        Text(L10n.t("仅保存在本机"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            checkUpdateRow
        }
    }

    /// HEAD 探测在线版可达性（超时 4s）：任何 HTTP 响应都算可达——回退只服务
    /// 「打不开网络」的场景，页面级 4xx/5xx 交给 Safari 自行呈现
    private func openPrivacyPolicy() async {
        guard !isProbingPrivacy, let url = PrivacyPolicyView.onlineURL else { return }
        isProbingPrivacy = true
        defer { isProbingPrivacy = false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 4
        let reachable: Bool
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            reachable = response is HTTPURLResponse
        } catch {
            reachable = false
        }
        if reachable {
            safari.open(url)
        } else {
            onOpen(.privacyPolicy)
        }
    }

    // MARK: 检查更新（单源 GitHub Releases API，失败不回落）

    private var checkUpdateRow: some View {
        Button {
            Task { await runManualCheck() }
        } label: {
            HStack {
                Label(L10n.t("检查更新"), systemImage: "arrow.triangle.2.circlepath")
                Spacer()
                switch updater.state {
                case .checking:
                    ProgressView()
                case .available:
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.red)
                default:
                    EmptyView()
                }
            }
        }
        .disabled(updater.state == .checking)
    }

    /// 有新版时紧随功能组出现的展示块：日期 + 更新说明 + 前往下载
    private func updateSection(_ info: AppUpdateInfo) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                if let date = info.publishedDate {
                    Text(L10n.f("发布于 %@", date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let notes = info.notes {
                    // release body 是 GitHub 自动生成的 markdown：内联解析保留换行，
                    // 解析失败回落纯文本
                    Text((try? AttributedString(
                        markdown: notes,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                        ?? AttributedString(notes))
                        .font(.footnote)
                }
            }
            .padding(.vertical, 2)
            if let url = URL(string: info.releaseURL) {
                Link(destination: url) {
                    Label(L10n.t("前往下载"), systemImage: "safari")
                }
            }
        } header: {
            Text(L10n.f("发现新版本 %@", info.version))
        } footer: {
            Text(L10n.t("AltStore / SideStore 用户也可在源中直接刷新获取更新"))
        }
    }

    private func runManualCheck() async {
        await updater.check()
        switch updater.state {
        case .latest:
            tapToast = L10n.f("已是最新版本 %@", AppUpdateChecker.currentVersion)
        case .available:
            Haptic.success()
        case .failed:
            tapToast = L10n.t("检查更新失败，请稍后再试")
        default:
            break
        }
    }

    // MARK: 连点解锁（7 次，第 3 次起渐进提示；一次性解锁后交给「管理→编辑」管控）

    private func handleVersionTap() {
        if gate.isUnlocked {
            tapToast = L10n.t("高级功能入口已开启，可在「管理 → 编辑」中调整")
            return
        }
        versionTaps += 1
        let remaining = Self.unlockTaps - versionTaps
        if remaining <= 0 {
            gate.unlock()
            versionTaps = 0
            Haptic.success()
            tapToast = L10n.t("已开启高级功能入口，可在「管理 → 编辑」中调整")
        } else if remaining <= Self.unlockTaps - 3 {
            tapToast = L10n.f("再点 %d 次开启高级功能入口", remaining)
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
        .navigationTitle(L10n.t("诊断数据"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { files = MetricStore.listFiles() }
    }
}

