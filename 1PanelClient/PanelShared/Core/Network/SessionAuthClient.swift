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
        static let setting = "/api/v2/core/auth/setting"        // GET 匿名；jar 自动收 panel_public_key
        static let login = "/api/v2/core/auth/login"            // POST 匿名
        static let mfaLogin = "/api/v2/core/auth/mfalogin"      // POST 匿名
        static let captcha = "/api/v2/core/auth/captcha"        // GET 匿名
        static let current = "/api/v2/core/auth/current"        // GET session
        static let apiUpdate = "/api/v2/core/auth/api/update"   // POST session + CSRF
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

    /// 步骤 3b：接口功能 Disable 时的显式开启（session + CSRF 双提交）。
    /// 请求体回传 current 的现有配置、仅翻状态位，避免面板侧其余配置被改写。
    /// （v2.4 网页端对应 Legacy API Key 行启停，api/keys/status {id:"legacy"}——
    /// 依方案 §3.1 走 api/update；若新面板拒绝该端点，引导失败回落手动粘贴路径）
    func enableApiInterface(preserving info: CurrentUserInfo) async throws {
        let body = ApiConfigUpdateRequest(
            apiInterfaceStatus: "Enable",
            apiKey: info.apiKey ?? "",
            ipWhiteList: info.ipWhiteList ?? "",
            apiTrustedProxies: info.apiTrustedProxies ?? "",
            apiKeyValidityTime: info.apiKeyValidityTime ?? 120
        )
        let _: EmptyResponse = try await post(Path.apiUpdate, body: body, as: EmptyResponse.self)
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

    private func post<T: Decodable>(_ path: String, body: some Encodable, as type: T.Type) async throws -> T {
        let data = try JSONEncoder().encode(body)
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
            // code=200 且 data=null：EmptyResponse 兜底（api/update 等无数据端点）
            if T.self == EmptyResponse.self, let empty = EmptyResponse() as? T {
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

    /// current 响应后的取钥路径：Enable 直接用现有密钥（零副作用首选）；
    /// Disable 需 UI 确认后显式开启（面板侧会留痕）再重取
    enum KeyAcquisition: Equatable {
        /// 直接取 current.apiKey
        case useExisting(String)
        /// 需确认「将启用面板接口密钥功能」（confirmEnabled 后重取）
        case needsEnableConfirm
    }

    static func keyAcquisition(from info: CurrentUserInfo) -> KeyAcquisition {
        if info.apiInterfaceStatus == "Enable" {
            if let key = info.apiKey, !key.isEmpty {
                return .useExisting(key)
            }
        }
        return .needsEnableConfirm
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
    /// 登录响应标记密码已过期（一期指引改网页端修改，reset 表单后置）
    case passwordExpired
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
        case .passwordExpired:
            return L10n.t("面板密码已过期，请先在面板网页端修改密码后重试")
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

/// POST /core/auth/api/update 请求体：回传 current 的现有配置、仅翻状态位
nonisolated struct ApiConfigUpdateRequest: Encodable {
    let apiInterfaceStatus: String
    let apiKey: String
    let ipWhiteList: String
    let apiTrustedProxies: String
    let apiKeyValidityTime: Int
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

/// 登录成功响应（抓包 5 字段；passwordExpired 为过期面板版本的防御性可选字段，
/// 存在即停止引导并指引网页端改密——一期不做 reset 表单）
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
