//
//  ContentView.swift
//  1PanelClient
//

import SwiftUI
import WidgetKit

struct ContentView: View {
    /// 语言切换时 +1，经 .id() 强制重建整棵视图树以即时生效
    /// （服务器数据在 ServerManager 单例中，不受重建影响）
    @State private var languageVersion = 0
    /// 回前台小组件 reload 的节流时间（≥5 分钟一次：reload 计入 WidgetKit
    /// 每日刷新预算，频繁切前台反复触发反而挤占系统自行刷新的份额；
    /// 服务器增删改经由 ServerManager 的 reload 不受此节流）
    @State private var lastWidgetReload: Date? = nil

    @StateObject private var appLock = AppLockManager()
    @StateObject private var safari = InAppSafariPresenter()
    /// 冷启动「发现新版本」弹窗：每进程至多一次，判定见 AppUpdateChecker.launchPromptInfo。
    /// 挂在这里而非 MainTabView：要避开锁屏（alert 浮在 overlay 之上）、不受
    /// 语言切换 .id 重建影响，且欢迎页（无服务器）同样覆盖
    @ObservedObject private var updater = AppUpdateChecker.shared
    @State private var launchUpdatePrompt: AppUpdateInfo?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        MainTabView()
            .id(languageVersion)
            .onReceive(NotificationCenter.default.publisher(for: L10n.languageDidChangeNotification)) { _ in
                languageVersion += 1
                // 小组件文案跟随语言，切换后重载时间线（否则要等系统预算自行刷新）
                WidgetCenter.shared.reloadAllTimelines()
            }
            .overlay {
                if appLock.isLocked {
                    LockScreenView()
                        .transition(.opacity)
                }
            }
            // 应用内浏览器 sheet：sheet 浮在窗口最上层（overlay 锁屏遮不住），上锁时
            // 主动关掉，避免外链页面露在锁屏之上（其余编辑类 sheet 的同类问题遗留中）
            .sheet(item: $safari.target) { target in
                InAppSafariSheet(target: target)
            }
            .alert(
                L10n.f("发现新版本 %@", launchUpdatePrompt?.version ?? ""),
                isPresented: Binding(
                    get: { launchUpdatePrompt != nil },
                    set: { if !$0 { launchUpdatePrompt = nil } }
                ),
                presenting: launchUpdatePrompt
            ) { info in
                Button(L10n.t("下载")) { openReleasePage(info) }
                Button(L10n.t("取消"), role: .cancel) {}
            } message: { info in
                if let date = info.publishedDate {
                    Text(L10n.f("发布于 %@", date))
                }
            }
            .onChange(of: appLock.isLocked) { _, locked in
                if locked {
                    safari.close()
                    // 更新弹窗同样浮在锁屏之上：上锁即收，解锁后按需再弹
                    launchUpdatePrompt = nil
                } else {
                    presentLaunchPromptIfNeeded()
                }
            }
            // 冷启动由缓存恢复的 .available 经 initial 立即命中；无缓存时网络检查
            // 晚到的 .available 由状态变更命中
            .onChange(of: updater.state, initial: true) { _, _ in
                presentLaunchPromptIfNeeded()
            }
            // environmentObject 必须包在 overlay 之外：overlay 内容不在内侧修饰器的
            // 环境作用域内，放 overlay 前会导致 LockScreenView 取不到 AppLockManager 而崩溃
            .environmentObject(appLock)
            .environmentObject(safari)
            .onChange(of: scenePhase) { _, phase in
                // 非 active 即锁（拉通知中心/进切换器会先 inactive，后台快照不露内容）；
                // 来电横幅等短暂失焦同样视为离开，与应用锁的隐私预期一致。
                // 设置页发起的面容验证造成的 inactive 由 manager 内部豁免
                if phase != .active {
                    appLock.lockIfEnabled(leavingTo: phase)
                    if phase == .background {
                        // 回后台补写页面快照：覆盖手动下拉刷新等不经 autoRefresh
                        // 的更新路径，冷启动恢复不落后于用户最后所见
                        PageVMStore.shared.persistAllSnapshots()
                    }
                } else if lastWidgetReload == nil || Date().timeIntervalSince(lastWidgetReload!) >= 300 {
                    // 回前台补一次小组件重载（节流 ≥5 分钟）：重装后系统可能丢弃
                    // 此前的 reload 请求导致小组件拖到分钟级不更新，每次回前台再
                    // 触发一次兜底；请求由系统合并调度
                    lastWidgetReload = Date()
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
    }

    private func presentLaunchPromptIfNeeded() {
        guard let info = AppUpdateChecker.launchPromptInfo(
            state: updater.state, isLocked: appLock.isLocked,
            alreadyShown: updater.launchPromptShown) else { return }
        updater.markLaunchPromptShown()
        launchUpdatePrompt = info
    }

    /// 「下载」与关于页「前往下载」同一出口：系统 Safari（IPA 下载与 AltStore 接力
    /// 依赖真实 Safari，见 InAppSafari 文件头）。releaseURL 来自远端响应，只放行 http/https
    private func openReleasePage(_ info: AppUpdateInfo) {
        guard let url = URL(string: info.releaseURL),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return }
        openURL(url)
    }
}

#Preview {
    ContentView()
}
