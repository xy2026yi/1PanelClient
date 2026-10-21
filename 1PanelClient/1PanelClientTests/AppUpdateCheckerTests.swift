//
//  AppUpdateCheckerTests.swift
//  1PanelClientTests
//
//  App 更新检查逻辑测试：版本比较 / releases 响应解析 / 静默检查节流 /
//  缓存冷启动恢复。网络请求为外部交互，不在单测覆盖范围
//  （同 AdvancedFeatureGateTests 对 license 检测的处理）。
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("App 更新检查")
struct AppUpdateCheckerTests {

    // MARK: - 版本比较（点分数值比较，CI 强制 tag 纯数字）

    @Test("数值比较避免字典序陷阱：0.10.0 > 0.9.0")
    func numericCompare() {
        #expect(AppUpdateChecker.isVersion("0.10.0", newerThan: "0.9.0"))
        #expect(!AppUpdateChecker.isVersion("0.9.0", newerThan: "0.10.0"))
        #expect(AppUpdateChecker.isVersion("1.0.0", newerThan: "0.99.99"))
    }

    @Test("段数不齐补零：0.3 ≡ 0.3.0，0.3.1 > 0.3")
    func paddedSegments() {
        #expect(!AppUpdateChecker.isVersion("0.3", newerThan: "0.3.0"))
        #expect(!AppUpdateChecker.isVersion("0.3.0", newerThan: "0.3"))
        #expect(AppUpdateChecker.isVersion("0.3.1", newerThan: "0.3"))
        #expect(!AppUpdateChecker.isVersion("0.3", newerThan: "0.3.1"))
    }

    @Test("相等与非数字段兜底（按 0 计）不判新")
    func equalAndGarbage() {
        #expect(!AppUpdateChecker.isVersion("1.2.3", newerThan: "1.2.3"))
        #expect(!AppUpdateChecker.isVersion("", newerThan: ""))
        #expect(!AppUpdateChecker.isVersion("abc", newerThan: "0.0.0"))
        // 前导零不影响数值：01 ≡ 1
        #expect(!AppUpdateChecker.isVersion("1.0", newerThan: "01.0.0"))
    }

    // MARK: - releases/latest 响应解析（纯函数直测）

    @Test("字段映射：tag 去 v 前缀、日期取前缀、说明保留、多余字段忽略")
    func parseFullResponse() throws {
        let json = """
        {
          "url": "https://api.github.com/repos/xy2026yi/1PanelClient/releases/1",
          "tag_name": "v0.3.0",
          "name": "v0.3.0",
          "body": "\\n* fix: 某某修复\\n* feat: 某某功能\\n",
          "published_at": "2026-10-01T08:30:00Z",
          "html_url": "https://github.com/xy2026yi/1PanelClient/releases/tag/v0.3.0",
          "assets": [{"name": "1PanelClient-v0.3.0.ipa", "size": 123}]
        }
        """
        let info = try AppUpdateChecker.parse(Data(json.utf8))
        #expect(info.version == "0.3.0")
        #expect(info.publishedDate == "2026-10-01")
        #expect(info.notes == "* fix: 某某修复\n* feat: 某某功能")
        #expect(info.releaseURL.hasSuffix("tag/v0.3.0"))
    }

    @Test("缺省字段兜底：body 空白归 nil；缺 tag_name / html_url 抛错")
    func parseMissingFields() throws {
        let minimal = #"{"tag_name":"0.4.0","html_url":"https://x/y","body":"  "}"#
        let info = try AppUpdateChecker.parse(Data(minimal.utf8))
        #expect(info.version == "0.4.0")
        #expect(info.notes == nil)
        #expect(info.publishedDate == nil)

        #expect(throws: URLError.self) {
            _ = try AppUpdateChecker.parse(Data(#"{"html_url":"https://x/y"}"#.utf8))
        }
        #expect(throws: URLError.self) {
            _ = try AppUpdateChecker.parse(Data(#"{"tag_name":"v1.0.0"}"#.utf8))
        }
    }

    @Test("适配声明：首行「适配面板版本：vX」解析入 panelBaseline；全角/半角冒号与空格均容")
    func parsePanelBaselineFirstLine() throws {
        let json = #"{"tag_name":"v0.3.0","html_url":"https://x/y","body":"适配面板版本：v2.3.1（面板版本不一致时，App 内总览页会有提示）\n## What's Changed\n* feat: x"}"#
        let info = try AppUpdateChecker.parse(Data(json.utf8))
        #expect(info.panelBaseline == "v2.3.1")
        #expect(AppUpdateChecker.parsePanelBaseline("适配面板版本: v2.4.0") == "v2.4.0")
        #expect(AppUpdateChecker.parsePanelBaseline("适配面板版本：  v2.3.10\n其他") == "v2.3.10")
    }

    @Test("适配声明：无 body / 无声明行 / 声明不在首行 / 无 v 前缀 → nil（历史 release 无此行）")
    func parsePanelBaselineAbsent() {
        #expect(AppUpdateChecker.parsePanelBaseline(nil) == nil)
        #expect(AppUpdateChecker.parsePanelBaseline("* fix: x\n* feat: y") == nil)
        #expect(AppUpdateChecker.parsePanelBaseline("## What's Changed\n适配面板版本：v2.3.1") == nil)
        #expect(AppUpdateChecker.parsePanelBaseline("适配面板版本：2.3.1") == nil)
    }

    @Test("旧缓存无 panelBaseline 键仍可解码（Optional 走 decodeIfPresent，角标不丢）")
    func decodeLegacyCache() throws {
        let legacy = #"{"version":"0.2.3","publishedDate":"2026-10-20","notes":"n","releaseURL":"https://x/y"}"#
        let info = try JSONDecoder().decode(AppUpdateInfo.self, from: Data(legacy.utf8))
        #expect(info.panelBaseline == nil)
        #expect(info.version == "0.2.3")
    }

    // MARK: - 节流与缓存（注入 defaults + 时钟，不触网）

    @MainActor
    private func makeChecker(suiteName: String, now: @escaping () -> Date) -> AppUpdateChecker {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppUpdateChecker(defaults: defaults, now: now)
    }

    @MainActor
    @Test("静默检查节流：从未检查 → 到期；24h 内 → 不到期；超 24h → 到期")
    func autoCheckThrottle() {
        let suiteName = "AppUpdateCheckerTests.throttle"
        let base = Date(timeIntervalSince1970: 1_760_000_000)
        var fakeNow = base
        let checker = makeChecker(suiteName: suiteName, now: { fakeNow })
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        #expect(checker.isAutoCheckDue)

        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(base, forKey: AppUpdateChecker.lastAutoCheckKey)
        #expect(!checker.isAutoCheckDue)

        fakeNow = base.addingTimeInterval(AppUpdateChecker.autoCheckInterval + 1)
        #expect(checker.isAutoCheckDue)
    }

    @MainActor
    @Test("缓存冷启动：缓存的版本比当前新 → 直接 available；不新 → 保持 idle")
    func cachedBootstrap() throws {
        let suiteName = "AppUpdateCheckerTests.cache"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 当前版本是定值（Bundle.main 注入值），分别用「更新/相同」两版本验证
        let current = AppUpdateChecker.currentVersion
        let newer = AppUpdateInfo(version: "\(current).1", publishedDate: nil,
                                  notes: nil, panelBaseline: nil, releaseURL: "https://x/y")
        defaults.set(try JSONEncoder().encode(newer), forKey: AppUpdateChecker.cachedLatestKey)
        let checker = AppUpdateChecker(defaults: defaults)
        #expect(checker.updateAvailable)
        #expect(checker.state == .available(newer))

        let same = AppUpdateInfo(version: current, publishedDate: nil,
                                 notes: nil, panelBaseline: nil, releaseURL: "https://x/y")
        defaults.set(try JSONEncoder().encode(same), forKey: AppUpdateChecker.cachedLatestKey)
        let fresh = AppUpdateChecker(defaults: defaults)
        #expect(!fresh.updateAvailable)
        #expect(fresh.state == .idle)
    }

    // MARK: - 冷启动提醒判定（纯函数）

    private static let sampleInfo = AppUpdateInfo(
        version: "9.9.9", publishedDate: "2026-10-20", notes: nil,
        panelBaseline: "v2.3.1", releaseURL: "https://x/y")

    @MainActor
    @Test("有新版 + 未上锁 + 本进程未提醒 → 返回待弹窗信息")
    func launchPromptWhenEligible() {
        let info = AppUpdateChecker.launchPromptInfo(
            state: .available(Self.sampleInfo), isLocked: false, alreadyShown: false)
        #expect(info == Self.sampleInfo)
    }

    @MainActor
    @Test("上锁期间不弹（alert 浮在锁屏之上），解锁后再判")
    func launchPromptBlockedWhileLocked() {
        #expect(AppUpdateChecker.launchPromptInfo(
            state: .available(Self.sampleInfo), isLocked: true, alreadyShown: false) == nil)
    }

    @MainActor
    @Test("本进程已提醒过 → 不再弹（取消后同一次启动内不复弹）")
    func launchPromptOncePerProcess() {
        #expect(AppUpdateChecker.launchPromptInfo(
            state: .available(Self.sampleInfo), isLocked: false, alreadyShown: true) == nil)
    }

    @MainActor
    @Test("非 available 状态一律不弹", arguments: [
        AppUpdateState.idle, .checking, .latest, .failed,
    ])
    func launchPromptRequiresAvailable(state: AppUpdateState) {
        #expect(AppUpdateChecker.launchPromptInfo(
            state: state, isLocked: false, alreadyShown: false) == nil)
    }

    @MainActor
    @Test("进程级标记：新实例默认未提醒，标记后为已提醒")
    func launchPromptShownFlag() {
        let suiteName = "AppUpdateCheckerTests.launchPrompt"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let checker = AppUpdateChecker(defaults: defaults)
        #expect(!checker.launchPromptShown)
        checker.markLaunchPromptShown()
        #expect(checker.launchPromptShown)
    }
}
