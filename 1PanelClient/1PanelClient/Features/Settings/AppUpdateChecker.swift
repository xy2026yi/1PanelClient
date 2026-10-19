//
//  AppUpdateChecker.swift
//  1PanelClient
//
//  App 自身更新检查：直调 GitHub Releases API（releases/latest），单源无回落。
//  分发形态是未签名 IPA + AltStore/SideStore 源，无法自更新——本模块只负责
//  「发现 + 提示」，下载动作交给 release 页（openURL，页内含 IPA 与 sha256）。
//
//  数据源字段映射：tag_name（去 v 前缀）→ 版本；body → 更新说明；
//  html_url → release 页；published_at → 发布日期（取日期前缀）。
//  国内对 api.github.com 连通性时好时坏：静默检查失败即吞掉（角标下次
//  启动再试），手动检查失败仅 toast，不做镜像回落（定案）。
//
//  隐私：匿名请求，User-Agent 仅含 App 名与版本号，不携带任何用户标识
//  （隐私政策「网络请求」节已同步说明）。
//

import Foundation
import Combine

/// 一次检查得到的最新版本信息（Codable：UserDefaults 缓存冷启动先出角标）
struct AppUpdateInfo: Codable, Equatable {
    /// 已去 v 前缀，如 "0.3.0"
    let version: String
    /// YYYY-MM-DD（API 的 ISO8601 取日期前缀）
    let publishedDate: String?
    /// release body（GitHub 自动生成的更新说明）
    let notes: String?
    /// release 页地址（含 IPA 与 sha256，供「前往下载」跳转）
    let releaseURL: String
}

/// 检查状态机：idle → checking → latest / available / failed；
/// available 在冷启动时可由缓存直接恢复（不等网络）
enum AppUpdateState: Equatable {
    case idle
    case checking
    case latest
    case available(AppUpdateInfo)
    case failed
}

@MainActor
final class AppUpdateChecker: ObservableObject {
    static let shared = AppUpdateChecker()

    static let releasesURL = URL(string: "https://api.github.com/repos/xy2026yi/1PanelClient/releases/latest")!
    /// 启动静默检查节流窗口（手动检查不受限）
    static let autoCheckInterval: TimeInterval = 24 * 3600
    static let lastAutoCheckKey = "update.lastAutoCheckAt"
    static let cachedLatestKey = "update.cachedLatest"

    @Published private(set) var state: AppUpdateState = .idle

    /// 设置页「关于APP」入口行角标判定
    var updateAvailable: Bool {
        if case .available = state { return true }
        return false
    }

    private let url: URL
    private let session: URLSession
    private let defaults: UserDefaults
    private let now: () -> Date

    init(url: URL = AppUpdateChecker.releasesURL,
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init) {
        self.url = url
        self.session = Self.makeSession()
        self.defaults = defaults
        self.now = now
        // 冷启动先读缓存出角标（available），网络刷新由启动 .task 异步补
        if let data = defaults.data(forKey: Self.cachedLatestKey),
           let cached = try? JSONDecoder().decode(AppUpdateInfo.self, from: data),
           Self.isVersion(cached.version, newerThan: Self.currentVersion) {
            state = .available(cached)
        }
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }

    /// 当前版本唯一来源：CFBundleShortVersionString（tag 构建时注入）
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - 检查

    /// 手动/静默检查共用入口。失败落 .failed（手动检查据此 toast，静默检查
    /// 无 UI 呈现）；取消还原 .idle 不算失败（同 APIError.isCancellation 口径）
    func check() async {
        guard state != .checking else { return }
        state = .checking
        do {
            let info = try await fetchLatest()
            state = Self.isVersion(info.version, newerThan: Self.currentVersion)
                ? .available(info) : .latest
            if let data = try? JSONEncoder().encode(info) {
                // 无论新旧都缓存：角标判定在读取时比较版本，升级后缓存自然失效
                defaults.set(data, forKey: Self.cachedLatestKey)
            }
        } catch {
            if Self.isCancellation(error) {
                state = .idle
            } else {
                state = .failed
            }
        }
        // 成败都记时：手动检查同样推后静默检查窗口，避免紧接着的启动重复请求
        defaults.set(now(), forKey: Self.lastAutoCheckKey)
    }

    /// 启动静默检查：24h 内至多一次（节流判定可测，网络部分见 check）
    func autoCheckIfDue() async {
        guard isAutoCheckDue else { return }
        await check()
    }

    var isAutoCheckDue: Bool {
        guard let last = defaults.object(forKey: Self.lastAutoCheckKey) as? Date else {
            return true
        }
        return now().timeIntervalSince(last) >= Self.autoCheckInterval
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlErr = error as? URLError, urlErr.code == .cancelled { return true }
        return false
    }

    // MARK: - 数据源解析（纯函数，单测直测）

    /// releases/latest 响应裁剪解码：只取所需字段，多余字段忽略
    static func parse(_ data: Data) throws -> AppUpdateInfo {
        struct GHRelease: Decodable {
            let tagName: String?
            let htmlURL: String?
            let publishedAt: String?
            let body: String?
            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name", htmlURL = "html_url"
                case publishedAt = "published_at", body
            }
        }
        let release = try JSONDecoder().decode(GHRelease.self, from: data)
        guard let rawTag = release.tagName, !rawTag.isEmpty,
              let page = release.htmlURL, !page.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        let version = rawTag.hasPrefix("v") ? String(rawTag.dropFirst()) : rawTag
        let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppUpdateInfo(
            version: version,
            publishedDate: release.publishedAt.map { String($0.prefix(10)) },
            notes: (notes?.isEmpty == true) ? nil : notes,
            releaseURL: page)
    }

    private func fetchLatest() async throws -> AppUpdateInfo {
        var request = URLRequest(url: url)
        // GitHub API 硬性要求 User-Agent（缺省 403）；版本号便于区分来源
        request.setValue("1PanelClient/\(Self.currentVersion) (+https://github.com/xy2026yi/1PanelClient)",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            // 匿名限流 403 / 5xx 统归失败（单源无回落，静默场景吞掉、手动场景 toast）
            throw URLError(.badServerResponse)
        }
        return try Self.parse(data)
    }

    // MARK: - 版本比较

    /// 点分数字版本比较（CI 强制 tag 纯数字；非数字段按 0 兜底，段数不齐补零：
    /// 0.3 ≡ 0.3.0）。数值比较避免 "0.10.0" < "0.9.0" 的字典序陷阱
    static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let l = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let r = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(l.count, r.count) {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}
