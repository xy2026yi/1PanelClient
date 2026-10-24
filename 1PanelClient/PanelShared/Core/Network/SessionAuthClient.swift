//
//  SessionAuthClient.swift
//  1PanelClient
//
//  账号密码引导流专用客户端（「登录与会话认证方案.md」一期）：
//  ephemeral configuration + 独立 HTTPCookieStorage（与 .shared 及其他服务器完全隔离），
//  走 session 认证链：登录 → current 取 legacy apiKey（或显式开启接口功能后重取）→
//  用完即弃（invalidate 丢 jar，session 不落地任何存储）。
//  日常流量不走此客户端，现行 token 模式零改动。
//

import Foundation
import os

final class SessionAuthClient {

    // MARK: - 端点（/core/auth 前缀：APIAuth 整体排除 token，仅 session 可用）

    private enum Path {
        static let setting = "/api/v2/core/auth/setting"          // GET 匿名；jar 自动收 panel_public_key
        static let login = "/api/v2/core/auth/login"              // POST 匿名
        static let mfaLogin = "/api/v2/core/auth/mfalogin"        // POST 匿名
        static let captcha = "/api/v2/core/auth/captcha"          // GET 匿名
        static let current = "/api/v2/core/auth/current"          // GET session
        static let resetPassword = "/api/v2/core/auth/expired/reset"  // POST 受限会话（过期改密专用）
        static let apiKeysSearch = "/api/v2/core/auth/api/keys/search"  // POST session + CSRF
        static let apiKeysStatus = "/api/v2/core/auth/api/keys/status"  // POST session + CSRF
        static let apiKeysCreate = "/api/v2/core/auth/api/keys/create"  // POST session + CSRF
    }

    /// 引导基础地址（规范化：去尾部 /）
    private let baseURL: String
    /// 引导期专用 cookie jar（ephemeral session 持有；invalidate 后随 session 丢弃）
    private let cookieStorage: HTTPCookieStorage
    private let session: URLSession

    /// jar 只读访问（internal 供单测种子注入/观察断言；生产路径勿外部读写）
    var cookieJar: HTTPCookieStorage { cookieStorage }

    /// 用户填写的安全入口码（明文，如 "3f89948beb"）；非空时请求带 EntranceCode: base64(码)
    var entranceCode: String?

    /// - Parameters:
    ///   - baseURL: 面板基础地址
    ///   - protocolClasses: URLProtocol 注入（单测 mock 用，nil=正常网络栈）
    init(
        baseURL: String,
        protocolClasses: [AnyClass]? = nil
    ) {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        self.baseURL = url

        // 引导期专用 jar（方案 §3.2）：直接用 ephemeral 配置自带的 cookie 存储——
        // 每个配置实例一份、与 .shared 及其他会话互不可见，session 销毁即弃。
        // ⚠️ 勿改用手动 HTTPCookieStorage() 新实例：实测（Darwin 27）该实例不参与
        // URLSession 的 Set-Cookie 收发，等于无会话
        let config = URLSessionConfiguration.ephemeral
        let jar = config.httpCookieStorage ?? HTTPCookieStorage()
        config.httpCookieStorage = jar
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        if let protocolClasses {
            config.protocolClasses = protocolClasses
        }
        self.cookieStorage = jar
        self.session = URLSession(configuration: config)
    }

    /// 引导结束（成功/失败/中途取消）调用：session 不可再用，jar 随之销毁。
    /// deinit 亦兜底，但视图层显式调用语义更清晰（复用中的 client 不得提前 invalidate）
    func invalidate() {
        session.finishTasksAndInvalidate()
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    // MARK: - 引导步骤

    /// 步骤 1：登录页设置（needCaptcha 等）；jar 自动收 panel_public_key（加密密钥源）
    func fetchAuthSetting() async throws -> AuthSetting {
        try await get(Path.setting, as: AuthSetting.self)
    }

    /// 验证码图片（captchaID + data URL PNG）
    func fetchCaptcha() async throws -> CaptchaResponse {
        try await get(Path.captcha, as: CaptchaResponse.self)
    }

    /// 步骤 2：账号密码登录。密码按 §2.2 混合加密（公钥取自 jar 的 panel_public_key，
    /// 缺失回落明文对齐网页端）。成功后 jar 落 psession/pcsrftoken（HTTP 恒 200，
    /// 业务码在 body，失败也走 SessionAuthError 而非网络错误）
    func login(username: String, password: String, captcha: String, captchaID: String) async throws -> LoginResult {
        let encrypted = try PanelPasswordCrypto.encrypt(
            password: password,
            publicKeyPEM: Self.publicKeyPEM(from: cookieStorage, baseURL: baseURL)
        )
        let request = LoginRequest(
            name: username,
            password: encrypted,
            captcha: captcha,
            captchaID: captchaID,
            authMethod: "session",
            authSource: "local",
            language: L10n.shared.isEnglishEffective ? "en" : "zh"
        )
        return try await post(Path.login, body: request, as: LoginResult.self)
    }

    /// MFA 第二步：OTP 校验（登录验密成功但 MFA 开启时的续接，成功才落真会话）
    func mfaLogin(sessionID: String, code: String) async throws -> LoginResult {
        try await post(
            Path.mfaLogin,
            body: MfaLoginRequest(sessionId: sessionID, secret: "", code: code, authMethod: "session"),
            as: LoginResult.self
        )
    }

    /// 步骤 3：当前用户信息——apiInterfaceStatus + legacy apiKey 明文（取钥锚点）
    func currentUser() async throws -> CurrentUserInfo {
        try await get(Path.current, as: CurrentUserInfo.self)
    }

    /// 密码过期强制重置（§8 抓包实证：**明文直传**——既非 Base64 也非登录混合加密，
    /// 第三种编码通道，勿混用）。过期会话经 core 链 PasswordExpired 中间件仅可访问
    /// reset 类端点，改密成功后旧会话即废，调用方须以新密码重新登录续跑引导
    func resetPassword(old: String, new: String) async throws {
        let _: EmptyResponse = try await post(
            Path.resetPassword,
            body: PasswordResetRequest(oldPassword: old, newPassword: new),
            as: EmptyResponse.self
        )
    }

    /// 创建专用接口密钥（keys/create，v2.3.2+ 唯一的新 key 创建通道——
    /// v2.3.1 及更早的独立 api/generate 在新面板已不存在）。参数由引导表单提供
    /// （预填默认值、用户可定制，如反向代理场景的 apiTrustedProxies）；明文仅在
    /// 响应中出现一次，直接交引导流落 Keychain。创建的是多键体系命名行，用户
    /// 可在面板独立停用/撤销
    func createApiKey(params: ApiKeyCreateParams) async throws -> String {
        let resp = try await post(
            Path.apiKeysCreate,
            body: ApiKeyCreateRequest(
                name: params.name,
                description: params.description,
                ipWhiteList: params.ipWhiteList,
                apiTrustedProxies: params.apiTrustedProxies,
                apiKeyValidityTime: params.apiKeyValidityTime,
                expiresAt: params.expiresAt,
                allowAppBinding: params.allowAppBinding,
                requestID: UUID().uuidString.lowercased()
            ),
            as: ApiKeyCreateResponse.self
        )
        guard let key = resp.apiKey, !key.isEmpty else {
            throw SessionAuthError.business(200, L10n.t("面板未返回接口密钥，请改用手动粘贴"))
        }
        return key
    }

    /// API 密钥列表（POST keys/search {page,pageSize}）。legacy 行的 status 是接口
    /// 功能的权威口径（Enable/Disable/Revoked 三态抓包实证）——current 的
    /// apiInterfaceStatus 区分不出「停用」与「已撤销但残留旧 key 明文」
    func searchApiKeys() async throws -> [ApiKeyItem] {
        let page = try await post(
            Path.apiKeysSearch,
            body: ApiKeysSearchRequest(page: 1, pageSize: 20),
            as: PageEnvelope<ApiKeyItem>.self
        )
        return page.items ?? []
    }

    /// 步骤 3b：接口功能 Disable 时的显式开启（session + CSRF 双提交）。
    /// 接口功能开关即 API 密钥页 Legacy 行的启停（v2.3.2 起 keys/* 体系，2026-10-24
    /// v2.4.1 网页端实捕）：keys/search 取 legacy 行的 revision（乐观锁）→
    /// keys/status 翻 Enable。
    /// legacy 行缺失（全新面板从未有过任何 key 时不投影该行）= 没有开关可翻，
    /// **静默返回不视为错误**——创建路径依赖此语义不受阻。
    /// keys/* 404 即面板低于 v2.3.2（旧通道 api/update 属 v2.3.1 及更早、请求体从未
    /// 实证），明确报版本问题并回落手动粘贴路径。
    func enableApiInterface() async throws {
        do {
            let items = try await searchApiKeys()
            guard let legacy = items.first(where: { $0.id == "legacy" }) else {
                return
            }
            let _: EmptyResponse = try await post(
                Path.apiKeysStatus,
                body: ApiKeyStatusRequest(
                    id: "legacy",
                    revision: legacy.revision ?? 0,
                    status: "Enable"
                ),
                as: EmptyResponse.self
            )
        } catch let error as SessionAuthError {
            guard case .http(404, _) = error else { throw error }
            throw SessionAuthError.business(
                404,
                L10n.t("面板版本过低（接口密钥管理需 v2.3.2 及以上），请改用手动粘贴密钥")
            )
        }
    }

    // MARK: - 请求构造

    /// 独立构造（不走 APIClient）：无 1Panel-Token 头；EntranceCode 条件注入；
    /// jar 中存在 pcsrftoken 的非 GET 请求注入 X-CSRF-Token（双提交）
    private func makeRequest(path: String, method: String, body: Data?) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw SessionAuthError.invalidURL
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 后端按 Accept-Language 本地化 message（与 APIClient 同规则：发 "zh" 而非 "zh-CN"）
        request.setValue(
            L10n.shared.isEnglishEffective ? "en" : "zh",
            forHTTPHeaderField: "Accept-Language"
        )
        if let entrance = entranceCode?.trimmingCharacters(in: .whitespacesAndNewlines), !entrance.isEmpty {
            request.setValue(Data(entrance.utf8).base64EncodedString(), forHTTPHeaderField: "EntranceCode")
        }
        if method != "GET", let csrf = Self.csrfToken(from: cookieStorage, baseURL: baseURL) {
            request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
        }
        if let body {
            request.httpBody = body
        } else if method == "POST" {
            request.httpBody = Data("{}".utf8)
        }
        return request
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try await send(makeRequest(path: path, method: "GET", body: nil), as: type)
    }

    private func post<T: Decodable>(_ path: String, body: (any Encodable)? = nil, as type: T.Type) async throws -> T {
        let data = try body.map { try JSONEncoder().encode($0) }
        return try await send(makeRequest(path: path, method: "POST", body: data), as: type)
    }

    /// 发送 + 信封判定。HTTP 状态恒 200 的业务错误（code 401/4xx）在此转
    /// SessionAuthError（对齐方案「app 判定一律看 body code，勿看 HTTP 状态」）
    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SessionAuthError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SessionAuthError.invalidResponse
        }
        if let ct = http.value(forHTTPHeaderField: "Content-Type"), ct.contains("text/html") {
            // 安全入口拦截页面（HTML）：与 APIClient.htmlBlocked 同语义
            throw SessionAuthError.htmlBlocked
        }
        guard (200...299).contains(http.statusCode) else {
            throw SessionAuthError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let wrapped: APIResponse<T>
        do {
            wrapped = try JSONDecoder().decode(APIResponse<T>.self, from: data)
        } catch {
            throw SessionAuthError.decoding(error.localizedDescription)
        }
        if wrapped.isSuccess, let value = wrapped.data {
            return value
        }
        if wrapped.isSuccess {
            // code=200 且 data=null：EmptyResponse（api/update 等无数据端点）与
            // EmptyInitializable（列表信封空页，如零密钥面板的 keys/search）兜底
            if T.self == EmptyResponse.self, let empty = EmptyResponse() as? T {
                return empty
            }
            if let empty = (T.self as? EmptyInitializable.Type)?.emptyInstance() as? T {
                return empty
            }
        }
        throw SessionAuthError.from(
            businessCode: wrapped.code,
            message: wrapped.message ?? ""
        )
    }

    // MARK: - jar 读取（internal static 供单测）

    /// jar 内指定 cookie 的值（同名取末个）
    nonisolated static func cookieValue(
        named name: String,
        cookies: [HTTPCookie]
    ) -> String? {
        cookies.last(where: { $0.name == name })?.value
    }

    /// jar 中的 PEM 公钥（panel_public_key cookie 解码）
    nonisolated static func publicKeyPEM(
        from storage: HTTPCookieStorage,
        baseURL: String
    ) -> String? {
        guard let url = URL(string: baseURL) else { return nil }
        let raw = cookieValue(named: "panel_public_key", cookies: storage.cookies(for: url) ?? [])
        return PanelPasswordCrypto.publicKeyPEM(fromCookieValue: raw ?? "")
    }

    /// jar 中的 CSRF 令牌（pcsrftoken；非 GET 双提交用）
    nonisolated static func csrfToken(
        from storage: HTTPCookieStorage,
        baseURL: String
    ) -> String? {
        guard let url = URL(string: baseURL) else { return nil }
        let raw = cookieValue(named: "pcsrftoken", cookies: storage.cookies(for: url) ?? [])
        return (raw?.isEmpty == false) ? raw : nil
    }
}

// MARK: - 引导取钥决策（internal 供单测）

nonisolated enum BootstrapDecision {

    /// current 响应 + keys/search legacy 行后的取钥路径
    enum KeyAcquisition: Equatable {
        /// 直接取 current.apiKey（legacy 行 Enable 且明文在手——零副作用首选）
        case useExisting(String)
        /// 行 Disable 但密钥材料在（用户停过接口的升级面板）：确认翻开关后复用，不新建行
        case needsEnableConfirm
        /// 需确认「将创建新的接口密钥」（keys/create）：行 Revoked（残留旧明文不可信）、
        /// 行 Enable 但无 key（全新面板）、行缺失等其余形态
        case needsCreateConfirm
    }

    /// legacy 行 status 为权威口径：Revoked 时 current 仍可能返回旧 key 明文
    /// （settings 残留），直接使用会存进死 key；行缺失时回退 current 口径
    /// （升级面板投影异常时仍可复用现有密钥）
    static func keyAcquisition(
        current info: CurrentUserInfo,
        legacyRow: ApiKeyItem?
    ) -> KeyAcquisition {
        func decide(_ interfaceOn: Bool) -> KeyAcquisition {
            if let key = info.apiKey, !key.isEmpty {
                return interfaceOn ? .useExisting(key) : .needsEnableConfirm
            }
            return .needsCreateConfirm
        }
        guard let legacy = legacyRow else {
            return decide(info.apiInterfaceStatus == "Enable")
        }
        switch legacy.status {
        case "Enable":
            return decide(true)
        case "Disable":
            return decide(false)
        default:
            // Revoked 及未知状态：残留明文不可信，一律创建专用键
            return .needsCreateConfirm
        }
    }
}

// MARK: - 错误

/// 引导流错误：面板业务码（helper.BadAuth）逐项映射，与网络/解码错误区分。
/// 文案经 L10n；单测用 if-case 断言（locale 无关纪律）
enum SessionAuthError: LocalizedError {
    /// ErrAuth：账号或密码错误（网页端同款：此后无条件展示验证码）
    case badCredentials
    /// ErrEntrance：安全入口错误
    case wrongEntrance
    /// ErrLoginLocked：多次失败 IP 锁定（停止重试引导）
    case loginLocked
    /// ErrCaptchaCode：验证码错误
    case captchaInvalid
    /// ErrMFA：动态口令错误
    case mfaFailed
    /// ErrNotLogin：会话无效（current 等返回时）
    case notLogin
    /// 其他业务码
    case business(Int, String)
    case http(Int, String)
    case network(Error)
    case decoding(String)
    case invalidURL
    case invalidResponse
    case htmlBlocked

    /// 业务信封 → 错误：code/message 双源判定（HTTP 恒 200，业务码在 body）
    nonisolated static func from(businessCode code: Int, message: String) -> SessionAuthError {
        switch message {
        case "ErrAuth": return .badCredentials
        case "ErrEntrance": return .wrongEntrance
        case "ErrLoginLocked": return .loginLocked
        case "ErrCaptchaCode": return .captchaInvalid
        case "ErrMFA": return .mfaFailed
        case "ErrNotLogin": return .notLogin
        default: return .business(code, message)
        }
    }

    var errorDescription: String? {
        switch self {
        case .badCredentials:
            return L10n.t("账号或密码错误，请重新输入")
        case .wrongEntrance:
            return L10n.t("安全入口不正确，请在高级选项中填写面板的安全入口码")
        case .loginLocked:
            return L10n.t("失败次数过多，该 IP 已被临时锁定。请稍后在面板网页端重试，或改用手动粘贴密钥")
        case .captchaInvalid:
            return L10n.t("验证码错误，已刷新，请重新输入")
        case .mfaFailed:
            return L10n.t("动态口令不正确，请重新输入")
        case .notLogin:
            return L10n.t("登录会话已失效，请重新登录")
        case .business(let code, let message):
            return message.isEmpty ? L10n.f("业务错误（%ld）", code) : message
        case .http(let code, let message):
            return "HTTP \(code): \(message)"
        case .network(let error):
            return L10n.f("网络错误: %@", error.localizedDescription)
        case .decoding(let message):
            return L10n.f("数据解析失败: %@", message)
        case .invalidURL:
            return L10n.t("服务器地址格式错误")
        case .invalidResponse:
            return L10n.t("服务器返回了无法解析的响应")
        case .htmlBlocked:
            return L10n.t("请求被安全入口拦截，请检查安全入口码是否正确")
        }
    }
}

// MARK: - 模型

/// POST /core/auth/login 请求体（抓包逐字段对齐：captcha/captchaID 恒在，无验证码时为空串；
/// authMethod 固定 session）
nonisolated struct LoginRequest: Encodable {
    let name: String
    let password: String
    let captcha: String
    let captchaID: String
    let authMethod: String
    let authSource: String
    let language: String
}

/// POST /core/auth/mfalogin 请求体
nonisolated struct MfaLoginRequest: Encodable {
    let sessionId: String
    let secret: String
    let code: String
    let authMethod: String
}

/// POST /core/auth/expired/reset 请求体：**明文直传**（第三种编码通道，勿混用）
nonisolated struct PasswordResetRequest: Encodable {
    let oldPassword: String
    let newPassword: String
}

/// POST /core/auth/api/keys/search 请求体（v2.3.2+ 多键体系分页，抓包 {page:1,pageSize:20}）
nonisolated struct ApiKeysSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
}

/// api/keys 列表项子集。id=="legacy" 行即接口功能开关所在行；
/// revision 为乐观锁版本号（启停/更新/撤销请求须回传当前值，legacy 实测为巨大整数）
nonisolated struct ApiKeyItem: Decodable, Equatable, Sendable {
    let id: String?
    let kind: String?
    let name: String?
    let status: String?
    let revision: Int?
}

/// 创建密钥的可定制参数（引导表单预填默认值、用户可改；如反向代理场景的
/// apiTrustedProxies）。expiresAt 为面板网页端同款 ISO8601 UTC 串，nil=永不过期
nonisolated struct ApiKeyCreateParams: Equatable, Sendable {
    var name: String
    var description: String
    var ipWhiteList: String
    var apiTrustedProxies: String
    var apiKeyValidityTime: Int
    var expiresAt: String?
    var allowAppBinding: Bool

    /// 引导流默认值：全 IP 白名单（app 需任意网络可达，可在面板/表单收紧）、
    /// 签名窗口 120 分钟（面板默认）、永不过期
    static func bootstrapDefaults() -> Self {
        ApiKeyCreateParams(
            name: "1PanelClient",
            description: "",
            ipWhiteList: "0.0.0.0/0\n::/0",
            apiTrustedProxies: "",
            apiKeyValidityTime: 120,
            expiresAt: nil,
            allowAppBinding: false
        )
    }

    /// 到期时间 → 网页端同款 ISO8601 UTC（含毫秒，如 "2027-01-22T08:13:25.488Z"）。
    /// internal 供单测固定向量
    static func expiresAtString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

/// POST /core/auth/api/keys/status 请求体（启停，抓包三字段实证）
nonisolated struct ApiKeyStatusRequest: Encodable {
    let id: String
    let revision: Int
    let status: String
}

/// POST /core/auth/api/keys/create 请求体（字段与网页端抓包一致；expiresAt nil=永不过期）
nonisolated struct ApiKeyCreateRequest: Encodable {
    let name: String
    let description: String
    let ipWhiteList: String
    let apiTrustedProxies: String
    let apiKeyValidityTime: Int
    let expiresAt: String?
    let allowAppBinding: Bool
    let requestID: String
}

/// keys/create 响应 data：{item:{...}, apiKey:"明文"}——明文仅此一次
nonisolated struct ApiKeyCreateResponse: Decodable {
    let apiKey: String?
}

/// GET /core/auth/setting 响应（子集；抓包 needCaptcha/passkeySetting/panelName 实证）
nonisolated struct AuthSetting: Decodable, Equatable {
    let needCaptcha: Bool?
    let passkeySetting: Bool?
    let panelName: String?
    let language: String?
}

/// GET /core/auth/captcha 响应：captchaID + imagePath（data URL PNG）
nonisolated struct CaptchaResponse: Decodable, Equatable {
    let captchaID: String?
    let imagePath: String?

    /// data URL → PNG Data（"base64," 后段）
    var imageData: Data? {
        Self.imageData(fromDataURL: imagePath)
    }

    nonisolated static func imageData(fromDataURL path: String?) -> Data? {
        guard let path, let range = path.range(of: "base64,") else { return nil }
        return Data(base64Encoded: String(path[range.upperBound...]))
    }
}

/// 登录成功响应（抓包 5 字段；passwordExpired 为过期标记的可选防御字段——
/// 存在且为 true 时引导流转入改密表单：过期会话仅可访问 reset 端点，改完重登录）
nonisolated struct LoginResult: Decodable, Equatable {
    let name: String?
    let role: String?
    let mfaStatus: String?
    let mfaSession: String?
    let passwordExpired: Bool?

    /// 验密成功但 MFA 开启：mfaSession 令牌在手，等待 OTP 第二步（此响应无 Set-Cookie，尚非会话）
    var mfaRequired: Bool {
        mfaStatus == "Enable" && !(mfaSession ?? "").isEmpty
    }
}

/// GET /core/auth/current 响应子集（settings 表整体映射，Enable/Disable 均含全部字段；
/// 全可选用 decodeIfPresent 防版本差异整页失败）
nonisolated struct CurrentUserInfo: Decodable, Equatable {
    let name: String?
    let role: String?
    let mfaStatus: String?
    let apiInterfaceStatus: String?
    let apiKey: String?
    let ipWhiteList: String?
    let apiTrustedProxies: String?
    let apiKeyValidityTime: Int?
}
