//
//  ServerBootstrapView.swift
//  1PanelClient
//
//  账号密码引导流弹窗（服务器编辑页「登录并获取密钥」入口）：
//  安全入口（可选）/面板账号/面板密码 → 登录一次面板 → session 代取现有密钥或
//  创建专用密钥 → 明文回传主表单后 session 即弃。流程依据「登录与会话认证方案.md」；
//  日常流量仍走 token 模式，本弹窗不落地任何会话状态（密码/验证码/口令随视图销毁）。
//

import SwiftUI

struct ServerBootstrapView: View {
    /// 面板地址（打开弹窗时的主表单快照）
    let baseURL: String
    /// 预填安全入口码（编辑模式留档 / 本次会话内重复引导免重填）
    var initialEntranceCode: String = ""
    /// 取钥成功回调：apiKey 填入主表单；entranceCode 留档供下次引导免重填
    var onKeyObtained: (_ apiKey: String, _ entranceCode: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(SecurityGate.httpsOnlyKey) private var httpsOnly = false

    /// 引导流状态机：idle → working → (awaitingCaptcha | awaitingMFA | resetPassword |
    /// confirmEnable | confirmCreate) → succeeded
    enum BootstrapPhase: Equatable {
        case idle
        case working
        /// 面板要求图形验证码（setting.needCaptcha 预取 / ErrAuth 后无条件拉取——网页端同款）
        case awaitingCaptcha
        /// MFA 动态口令输入（login 返回 mfaSession，尚非会话）
        case awaitingMFA
        /// 面板密码已过期：改密表单（受限会话仅可访问 reset 端点，改完自动重登录续跑）
        case resetPassword
        /// 接口功能未开启但密钥材料在：等待确认「将启用面板接口密钥功能」（翻开关复用）
        case confirmEnable
        /// 需创建专用密钥（行 Revoked / 从未有 key / 行缺失）：创建参数表单（预填可改）
        case confirmCreate
        /// 已取得密钥（session 即弃）
        case succeeded
    }

    @State private var username = ""
    @State private var password = ""
    @State private var entranceCode = ""
    @State private var bootstrapPhase: BootstrapPhase = .idle
    /// 行内结果/错误文案
    @State private var bootstrapMessage: String?
    @State private var bootstrapClient: SessionAuthClient?
    /// 登录页设置已取（needCaptcha 判定与 jar 公钥收集只做一次）
    @State private var didFetchSetting = false
    @State private var captcha: CaptchaResponse?
    @State private var captchaInput = ""
    @State private var mfaSessionID = ""
    @State private var otpInput = ""
    // 密码过期改密表单（oldPassword 复用上方已输入的「面板密码」）
    @State private var newPassword = ""
    @State private var confirmNewPassword = ""
    // 创建密钥参数表单（预填 bootstrapDefaults，用户可定制——如反向代理的可信代理）
    @State private var createName = ""
    @State private var createDescription = ""
    @State private var createIPWhiteList = ""
    @State private var createTrustedProxies = ""
    @State private var createValidity = 120
    @State private var createNeverExpires = true
    @State private var createExpiresAt = Date()
    @State private var showPlainHTTPBootstrapWarning = false
    /// 明文 HTTP 引导确认后本弹窗内不再重复弹
    @State private var bootstrapHTTPAllowed = false
    @State private var showHTTPSBlockAlert = false
    @State private var httpsBlockMessage: String?
    /// 创建参数汇总的居中确认弹窗（与明文传输警告同款样式）
    @State private var showCreateConfirm = false

    /// 输入地址是否为 http:// 明文
    private var draftIsPlainHTTP: Bool {
        ServerConfig(id: UUID(), name: "", baseURL: baseURL, apiKey: "").isPlainHTTP
    }

    private var isBootstrapBusy: Bool {
        bootstrapPhase == .working
    }

    /// 引导按钮可用性（账号/密码齐备；验证码/OTP/改密/创建表单显示时要求有效）
    private var bootstrapReady: Bool {
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty,
              !password.isEmpty else { return false }
        if bootstrapPhase == .awaitingCaptcha { return !captchaInput.isEmpty }
        if bootstrapPhase == .awaitingMFA { return !otpInput.isEmpty }
        if bootstrapPhase == .resetPassword {
            return !newPassword.isEmpty && newPassword == confirmNewPassword
        }
        if bootstrapPhase == .confirmCreate {
            return !createName.trimmingCharacters(in: .whitespaces).isEmpty && createValidity > 0
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    OutlinedTextField(label: L10n.t("安全入口码"), prompt: L10n.t("面板未设置则留空"),
                                      text: $entranceCode, machineValue: true)
                        .textInputAutocapitalization(.never)
                    OutlinedTextField(label: L10n.t("面板账号"), prompt: "admin",
                                      text: $username, machineValue: true)
                        .textInputAutocapitalization(.never)
                    OutlinedPasswordField(label: L10n.t("面板密码"), text: $password)

                    if bootstrapPhase == .awaitingCaptcha, let captcha {
                        captchaRow(captcha)
                    }
                    if bootstrapPhase == .awaitingMFA {
                        OutlinedTextField(label: L10n.t("动态口令"), prompt: "123456",
                                          text: $otpInput, keyboardType: .numberPad)
                    }
                    if bootstrapPhase == .resetPassword {
                        OutlinedPasswordField(label: L10n.t("新密码"), text: $newPassword)
                        OutlinedPasswordField(label: L10n.t("确认新密码"), text: $confirmNewPassword)
                    }
                    if bootstrapPhase == .confirmCreate {
                        createFormFields
                    }

                    Button {
                        bootstrapTapped()
                    } label: {
                        HStack {
                            if isBootstrapBusy {
                                ProgressView()
                            }
                            Text(bootstrapButtonTitle)
                        }
                    }
                    .disabled(isBootstrapBusy || !bootstrapReady)

                    if let message = bootstrapMessage {
                        Label(message, systemImage: bootstrapPhase == .succeeded
                                              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(bootstrapPhase == .succeeded ? .green : .orange)
                            .font(.footnote)
                    }
                } header: {
                    Text(L10n.t("面板登录"))
                } footer: {
                    // 目标地址常驻展示：弹窗内改不了主表单，避免连错面板
                    Text(baseURL)
                }
            }
            .navigationTitle(L10n.t("登录并获取密钥"))
            .navigationBarTitleDisplayMode(.inline)
            .formWidthLimit()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
            }
            // 面板侧变更确认统一居中弹窗（与明文传输警告同款样式）
            .alert(L10n.t("将启用面板接口密钥功能"), isPresented: .init(
                get: { bootstrapPhase == .confirmEnable },
                set: { if !$0 && bootstrapPhase == .confirmEnable { bootstrapPhase = .idle } }
            )) {
                Button(L10n.t("启用并获取密钥")) {
                    Task { await performEnableMutation() }
                }
                Button(L10n.t("取消"), role: .cancel) {}
            } message: {
                Text(L10n.t("面板尚未开启 API 接口。引导将开启该功能并复用面板现有的接口密钥（面板会留下一条登录记录）。稍后可在面板网页端停用或撤销。"))
            }
            .alert(L10n.t("将创建新的接口密钥"), isPresented: $showCreateConfirm) {
                Button(L10n.t("创建密钥")) {
                    Task { await performCreate() }
                }
                Button(L10n.t("取消"), role: .cancel) {}
            } message: {
                Text(createConfirmMessage)
            }
            // 引导流专用明文警告：账号密码将明文传输，级别高于密钥粘贴的保存警告
            .alert(L10n.t("将以明文传输面板账号密码"), isPresented: $showPlainHTTPBootstrapWarning) {
                Button(L10n.t("取消"), role: .cancel) {}
                Button(L10n.t("仍要引导登录"), role: .destructive) {
                    bootstrapHTTPAllowed = true
                    Task { await runBootstrap() }
                }
            } message: {
                Text(L10n.t("当前为 HTTP 明文连接，账号与密码可被同一网络内的攻击者截获。建议为面板配置 HTTPS 后再引导；也可改用手动粘贴密钥。"))
            }
            .alert(L10n.t("无法引导"), isPresented: $showHTTPSBlockAlert) {
                Button(L10n.t("好的"), role: .cancel) {}
            } message: {
                Text(httpsBlockMessage ?? "")
            }
        }
        .onAppear {
            if entranceCode.isEmpty {
                entranceCode = initialEntranceCode
            }
        }
        .onDisappear {
            // 离开弹窗即弃：引导 session 销毁，密码/验证码/口令随视图状态释放
            teardownBootstrapClient()
        }
    }

    // MARK: - 分区子视图

    /// 创建密钥参数表单（预填 bootstrapDefaults，全部可改——反向代理的可信代理、
    /// 白名单收紧、签名窗口、到期时间）
    @ViewBuilder private var createFormFields: some View {
        OutlinedTextField(label: L10n.t("名称"), text: $createName)
        OutlinedTextField(label: L10n.t("描述"), prompt: L10n.t("可选"), text: $createDescription)
        OutlinedMultiLineField(label: L10n.t("IP 白名单"), prompt: "0.0.0.0/0",
                               lines: 3, fixedLines: 3, monospaced: true, text: $createIPWhiteList)
        Text(L10n.t("允许调用接口的来源网段（CIDR，每行一个）；默认不限制来源。"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 14)
        OutlinedMultiLineField(label: L10n.t("API 可信代理"), prompt: L10n.t("直连面板可留空"),
                               lines: 2, fixedLines: 2, monospaced: true, text: $createTrustedProxies)
        Text(L10n.t("经反向代理部署面板时填写代理网段（CIDR，每行一个）；直连可留空。"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 14)
        OutlinedUnitField(label: L10n.t("请求签名有效窗口"), unit: L10n.t("分钟"),
                          text: createValidityBinding, range: 1...10080)
        Toggle(L10n.t("永不过期"), isOn: $createNeverExpires)
        if !createNeverExpires {
            DatePicker(L10n.t("密钥到期时间"), selection: $createExpiresAt)
        }
    }

    /// OutlinedUnitField 的 String 绑定桥接（Int 模型）
    private var createValidityBinding: Binding<String> {
        Binding<String>(
            get: { String(createValidity) },
            set: { createValidity = Int($0) ?? createValidity }
        )
    }

    /// 表单当前值 → 创建参数（提交与汇总确认共用同一份）
    private var createParams: ApiKeyCreateParams {
        ApiKeyCreateParams(
            name: createName.trimmingCharacters(in: .whitespacesAndNewlines),
            description: createDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            ipWhiteList: createIPWhiteList.trimmingCharacters(in: .whitespacesAndNewlines),
            apiTrustedProxies: createTrustedProxies.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKeyValidityTime: createValidity,
            expiresAt: createNeverExpires ? nil : ApiKeyCreateParams.expiresAtString(from: createExpiresAt),
            allowAppBinding: false
        )
    }

    /// 创建确认弹窗的参数汇总（居中 alert 正文）
    private var createConfirmMessage: String {
        let params = createParams
        var lines = [L10n.f("名称：%@", params.name)]
        lines.append(L10n.f("IP 白名单：%@", params.ipWhiteList.replacingOccurrences(of: "\n", with: ", ")))
        if !params.apiTrustedProxies.isEmpty {
            lines.append(L10n.f("API 可信代理：%@", params.apiTrustedProxies.replacingOccurrences(of: "\n", with: ", ")))
        }
        lines.append(L10n.f("请求签名有效窗口：%ld 分钟", params.apiKeyValidityTime))
        lines.append(params.expiresAt == nil
                     ? L10n.t("有效期：永不过期")
                     : L10n.f("有效期至：%@", params.expiresAt ?? ""))
        lines.append(L10n.t("接口未开启时将一并开启；密钥稍后可在面板网页端停用或撤销。"))
        return lines.joined(separator: "\n")
    }

    /// 验证码行：图片 + 输入框 + 换一张
    private func captchaRow(_ captcha: CaptchaResponse) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            OutlinedTextField(label: L10n.t("图形验证码"),
                              text: $captchaInput, machineValue: true)
                .textInputAutocapitalization(.never)
            HStack(spacing: 12) {
                if let data = captcha.imageData,
                   let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .accessibilityLabel(L10n.t("图形验证码"))
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                        .frame(height: 36)
                }
                Spacer()
                Button(L10n.t("换一张")) {
                    Task { await reloadCaptcha() }
                }
                .font(.footnote)
                .disabled(isBootstrapBusy)
            }
        }
    }

    private var bootstrapButtonTitle: String {
        switch bootstrapPhase {
        case .awaitingCaptcha:
            return L10n.t("登录（已填验证码）")
        case .awaitingMFA:
            return L10n.t("登录（已填动态口令）")
        case .resetPassword:
            return L10n.t("重置密码并继续")
        case .confirmCreate:
            return L10n.t("创建密钥")
        default:
            return L10n.t("登录并获取密钥")
        }
    }

    // MARK: - 引导流

    private func bootstrapTapped() {
        // 明文 HTTP 上先发高级别警告（账号密码 vs 密钥粘贴，前者更敏感）
        if draftIsPlainHTTP {
            if httpsOnly {
                httpsBlockMessage = L10n.t("已开启「仅允许 HTTPS 连接」：请在 设置 → 安全 关闭该限制，或改用 https:// 地址")
                showHTTPSBlockAlert = true
                return
            }
            if !bootstrapHTTPAllowed {
                showPlainHTTPBootstrapWarning = true
                return
            }
        }
        if bootstrapPhase == .awaitingMFA {
            Task { await submitMFA() }
            return
        }
        if bootstrapPhase == .resetPassword {
            Task { await submitPasswordReset() }
            return
        }
        if bootstrapPhase == .confirmCreate {
            // 创建参数表单 → 居中汇总确认
            showCreateConfirm = true
            return
        }
        Task { await runBootstrap() }
    }

    private func runBootstrap() async {
        guard let client = ensureBootstrapClient() else { return }
        bootstrapPhase = .working
        bootstrapMessage = nil
        do {
            if !didFetchSetting {
                // 步骤 1：登录页设置（jar 自动收 panel_public_key 公钥 cookie）
                let setting = try await client.fetchAuthSetting()
                didFetchSetting = true
                if setting.needCaptcha == true && captcha == nil {
                    captcha = try await client.fetchCaptcha()
                    captchaInput = ""
                    bootstrapPhase = .awaitingCaptcha
                    return
                }
            }
            // 步骤 2：登录（含验证码时随请求带上）
            let result = try await client.login(
                username: username.trimmingCharacters(in: .whitespaces),
                password: password,
                captcha: captchaInput,
                captchaID: captcha?.captchaID ?? ""
            )
            try await handleLoginResult(result, client: client)
        } catch {
            handleBootstrapError(error)
        }
    }

    private func handleLoginResult(_ result: LoginResult, client: SessionAuthClient) async throws {
        // 密码过期：转改密表单（受限会话仅可访问 reset 端点；改完自动重登录续跑）
        if result.passwordExpired == true {
            newPassword = ""
            confirmNewPassword = ""
            captcha = nil
            captchaInput = ""
            bootstrapMessage = L10n.t("面板密码已过期，请设置新密码后继续")
            bootstrapPhase = .resetPassword
            return
        }
        // MFA：展示 OTP 输入，等待下一步（不自动重试）
        if result.mfaRequired, let sessionID = result.mfaSession {
            mfaSessionID = sessionID
            otpInput = ""
            bootstrapPhase = .awaitingMFA
            return
        }
        await acquireKey(client)
    }

    /// MFA 第二步提交
    private func submitMFA() async {
        guard let client = bootstrapClient else { return }
        bootstrapPhase = .working
        do {
            let result = try await client.mfaLogin(sessionID: mfaSessionID, code: otpInput)
            try await handleLoginResult(result, client: client)
        } catch {
            handleBootstrapError(error)
        }
    }

    /// 密码过期改密提交：明文端点（§8）改密成功 → 受限会话即废 →
    /// 以新密码重新登录续跑引导（验证码不沿用——上一次已消费，失败分支会重新拉取）
    private func submitPasswordReset() async {
        guard let client = bootstrapClient else { return }
        bootstrapPhase = .working
        bootstrapMessage = nil
        do {
            try await client.resetPassword(old: password, new: newPassword)
            password = newPassword
            newPassword = ""
            confirmNewPassword = ""
            let result = try await client.login(
                username: username.trimmingCharacters(in: .whitespaces),
                password: password,
                captcha: "",
                captchaID: ""
            )
            try await handleLoginResult(result, client: client)
        } catch {
            handleBootstrapError(error)
            // 改密失败退回表单态（handleBootstrapError 的默认分支是 idle）
            if bootstrapPhase == .idle {
                bootstrapPhase = .resetPassword
            }
        }
    }

    /// 步骤 3：current + keys/search 取钥（legacy 行 Enable 且明文在手——零新建、
    /// 零开关改动、零副作用；Revoked/无 key 走创建，Disable 走开启确认）
    private func acquireKey(_ client: SessionAuthClient) async {
        bootstrapPhase = .working
        do {
            let info = try await client.currentUser()
            let legacyRow = try await client.searchApiKeys().first(where: { $0.id == "legacy" })
            switch BootstrapDecision.keyAcquisition(current: info, legacyRow: legacyRow) {
            case .useExisting(let key):
                finishBootstrap(key: key)
            case .needsEnableConfirm:
                bootstrapPhase = .confirmEnable
            case .needsCreateConfirm:
                enterCreateForm()
            }
        } catch {
            handleBootstrapError(error)
        }
    }

    /// 进入创建参数表单（预填默认值；再次进入保留上次编辑，便于改参重试）
    private func enterCreateForm() {
        if createName.isEmpty {
            let defaults = ApiKeyCreateParams.bootstrapDefaults()
            createName = defaults.name
            createDescription = defaults.description
            createIPWhiteList = defaults.ipWhiteList
            createTrustedProxies = defaults.apiTrustedProxies
            createValidity = defaults.apiKeyValidityTime
            createNeverExpires = true
            createExpiresAt = Date().addingTimeInterval(180 * 24 * 3600)
        }
        bootstrapMessage = nil
        bootstrapPhase = .confirmCreate
    }

    /// 确认后翻接口开关（legacy 行 = 全局开关）→ 复用现有密钥；key 意外为空转创建表单
    private func performEnableMutation() async {
        guard let client = bootstrapClient else { return }
        bootstrapPhase = .working
        do {
            try await client.enableApiInterface()
            let refreshed = try await client.currentUser()
            if let key = refreshed.apiKey, !key.isEmpty {
                finishBootstrap(key: key)
                return
            }
            enterCreateForm()
        } catch {
            handleBootstrapError(error)
        }
    }

    /// 创建专用密钥：接口开关尽力而为（Revoked 行可能拒绝再 Enable，不阻断创建）→
    /// keys/create（表单参数）
    private func performCreate() async {
        guard let client = bootstrapClient else { return }
        bootstrapPhase = .working
        bootstrapMessage = nil
        do {
            try? await client.enableApiInterface()
            finishBootstrap(key: try await client.createApiKey(params: createParams))
        } catch let error as SessionAuthError {
            // create 的 keys/* 404 = 面板低于 v2.3.2（enable 的 404 已在客户端内映射）
            if case .http(404, _) = error {
                handleBootstrapError(SessionAuthError.business(
                    404,
                    L10n.t("面板版本过低（接口密钥管理需 v2.3.2 及以上），请改用手动粘贴密钥")
                ))
                return
            }
            handleBootstrapError(error)
        } catch {
            handleBootstrapError(error)
        }
    }

    private func finishBootstrap(key: String) {
        let entrance = entranceCode.trimmingCharacters(in: .whitespacesAndNewlines)
        Haptic.success()
        // session 即弃：jar 销毁、密码即清（不长期保留）
        teardownBootstrapClient()
        // 明文回传主表单（填入 API Key 字段）并关闭弹窗
        onKeyObtained(key, entrance)
        dismiss()
    }

    private func handleBootstrapError(_ error: Error) {
        if APIError.isCancellation(error) {
            bootstrapPhase = .idle
            return
        }
        let sessionError = (error as? SessionAuthError) ?? SessionAuthError.network(error)
        bootstrapMessage = sessionError.localizedDescription
        Haptic.error()
        switch sessionError {
        case .badCredentials, .captchaInvalid:
            // 网页端同款：ErrAuth 后无条件拉验证码展示；ErrCaptchaCode 换新码
            bootstrapPhase = .working
            Task { await reloadCaptcha() }
        case .mfaFailed:
            otpInput = ""
            bootstrapPhase = .awaitingMFA
        case .wrongEntrance:
            // 安全入口字段就在本弹窗顶部，停留表单态即可
            bootstrapPhase = .idle
        default:
            bootstrapPhase = .idle
        }
        // 其余失败不重试登录（IPTracker 锁定纪律）；jar 保留供同弹窗内重试，
        // 离开弹窗时 onDisappear 统一销毁
    }

    /// 拉取/刷新验证码（ErrAuth 后无条件展示；失败则停回 idle，文案沿用认证错误）
    private func reloadCaptcha() async {
        guard let client = bootstrapClient else {
            bootstrapPhase = .idle
            return
        }
        do {
            captcha = try await client.fetchCaptcha()
            captchaInput = ""
            bootstrapPhase = .awaitingCaptcha
        } catch {
            bootstrapPhase = .idle
        }
    }

    /// 首次引导创建专用 client（独立 jar），复用同一实例贯穿整个引导
    private func ensureBootstrapClient() -> SessionAuthClient? {
        if let client = bootstrapClient {
            client.entranceCode = entranceCode
            return client
        }
        let client = SessionAuthClient(baseURL: baseURL)
        client.entranceCode = entranceCode
        bootstrapClient = client
        return client
    }

    private func teardownBootstrapClient() {
        bootstrapClient?.invalidate()
        bootstrapClient = nil
        password = ""
        captcha = nil
        captchaInput = ""
        otpInput = ""
        mfaSessionID = ""
        newPassword = ""
        confirmNewPassword = ""
        didFetchSetting = false
    }
}
