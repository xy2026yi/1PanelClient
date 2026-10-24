//
//  ServerEditView.swift
//  1PanelClient
//
//  添加/编辑服务器：账号密码「快速开始」引导流（登录一次 → session 代取接口密钥 →
//  即弃）+ 折叠高级区手动粘贴密钥（现行路径原样保留，引导失败全程可回落）。
//  引导流基于「登录与会话认证方案.md」：独立 cookie jar、登录请求不重试、
//  session 分钟级即弃，日常流量仍走 token 模式。
//

import SwiftUI

struct ServerEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: ServerManager

    var editing: ServerConfig?
    /// true = 以 sheet 弹出（自带 NavigationStack + 取消按钮）；false = 页面推入（返回即取消）
    var presentedAsSheet: Bool = true

    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var testing = false
    @State private var testResult: TestResult?
    @State private var showHTTPSBlockAlert = false
    @State private var httpsBlockMessage: String?
    @State private var showPlainHTTPWarning = false
    @AppStorage(SecurityGate.httpsOnlyKey) private var httpsOnly = false

    // MARK: 快速开始（账号密码引导）

    /// 引导流状态机：idle → working → (awaitingCaptcha | awaitingMFA | resetPassword |
    /// confirmEnable) → succeeded
    enum BootstrapPhase: Equatable {
        case idle
        case working
        /// 面板要求图形验证码（setting.needCaptcha 预取 / ErrAuth 后无条件拉取——网页端同款）
        case awaitingCaptcha
        /// MFA 动态口令输入（login 返回 mfaSession，尚非会话）
        case awaitingMFA
        /// 面板密码已过期：改密表单（受限会话仅可访问 reset 端点，改完自动重登录续跑）
        case resetPassword
        /// 接口功能未开启：等待用户确认「将启用面板接口密钥功能」（面板侧留痕）
        case confirmEnable
        /// 已取得密钥（session 即弃）
        case succeeded
    }

    @State private var username = ""
    @State private var password = ""
    @State private var entranceCode = ""
    @State private var showAdvanced = false
    @State private var bootstrapPhase: BootstrapPhase = .idle
    /// 行内结果/错误文案（错误另见 bootstrapErrorAlert）
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
    @State private var showPlainHTTPBootstrapWarning = false
    /// 明文 HTTP 引导确认后本次表单内不再重复弹（每次重新进入引导仍会警告）
    @State private var bootstrapHTTPAllowed = false

    struct TestResult {
        let success: Bool
        let message: String
    }

    /// 输入中的地址是否为 http:// 明文（含协议省略时的默认行为见 normalizedBaseURL）
    private var draftIsPlainHTTP: Bool {
        ServerConfig(id: UUID(), name: name, baseURL: baseURL, apiKey: apiKey).isPlainHTTP
    }

    private var isBootstrapBusy: Bool {
        bootstrapPhase == .working
    }

    /// 引导按钮可用性（地址/账号/密码齐备；验证码/OTP/改密确认显示时要求有效）
    private var bootstrapReady: Bool {
        guard !baseURL.trimmingCharacters(in: .whitespaces).isEmpty,
              !username.trimmingCharacters(in: .whitespaces).isEmpty,
              !password.isEmpty else { return false }
        if bootstrapPhase == .awaitingCaptcha { return !captchaInput.isEmpty }
        if bootstrapPhase == .awaitingMFA { return !otpInput.isEmpty }
        if bootstrapPhase == .resetPassword {
            return !newPassword.isEmpty && newPassword == confirmNewPassword
        }
        return true
    }

    var body: some View {
        if presentedAsSheet {
            NavigationStack {
                form
            }
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            Section(L10n.t("服务器信息")) {
                OutlinedTextField(label: L10n.t("显示名称"), text: $name)
                OutlinedTextField(label: L10n.t("面板地址"), prompt: "http://10.0.0.1:36130",
                              text: $baseURL, keyboardType: .URL)
                if draftIsPlainHTTP {
                    Label(L10n.t("HTTP 明文连接：API Key 与数据可能被链路窃听，建议改用 https://"), systemImage: "lock.open")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            quickStartSection

            advancedSection

            Section {
                Button {
                    runTest()
                } label: {
                    HStack {
                        if testing {
                            ProgressView()
                        }
                        Text(L10n.t("测试连接"))
                    }
                }
                .disabled(testing || baseURL.isEmpty || apiKey.isEmpty)

                if let r = testResult {
                    Label(r.message, systemImage: r.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(r.success ? .green : .red)
                        .font(.footnote)
                }
            }

            Section(L10n.t("提示")) {
                Text(L10n.t("快速开始会登录一次面板并自动获取接口密钥，日常使用仍以密钥连接。引导失败时可在高级选项中手动粘贴密钥。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(editing == nil ? L10n.t("添加服务器") : L10n.t("编辑服务器"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .toolbar {
            if presentedAsSheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.t("保存")) { save() }
                    .disabled(name.isEmpty || baseURL.isEmpty || apiKey.isEmpty)
            }
        }
        .onAppear { loadIfEditing() }
        .onDisappear {
            // 离开表单即弃：引导 session 销毁，密码随视图状态释放
            bootstrapClient?.invalidate()
            bootstrapClient = nil
        }
        .alert(L10n.t("无法保存"), isPresented: $showHTTPSBlockAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(httpsBlockMessage ?? "")
        }
        .alert(L10n.t("该面板使用 HTTP 明文连接"), isPresented: $showPlainHTTPWarning) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("仍然保存"), role: .destructive) { Haptic.warning(); performSave() }
        } message: {
            Text(L10n.t("HTTP 明文连接下，API Key 与服务器数据可能被同一网络内的攻击者窃听或篡改。建议为面板配置 HTTPS 后再用 https:// 地址连接。"))
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
        // 接口功能未开启的显式确认（方案 §3.4：开启 + 新密钥 + 登录日志均属面板侧正常留痕）
        .confirmationDialog(
            L10n.t("将启用面板接口密钥功能"),
            isPresented: .init(
                get: { bootstrapPhase == .confirmEnable },
                set: { if !$0 && bootstrapPhase == .confirmEnable { bootstrapPhase = .idle } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.t("启用并获取密钥")) {
                Task { await confirmEnableAndFetch() }
            }
            Button(L10n.t("取消"), role: .cancel) {
                bootstrapPhase = .idle
            }
        } message: {
            Text(L10n.t("面板尚未开启 API 接口。引导将在面板上开启该功能并使用/生成接口密钥（面板会留下一条登录记录）。稍后可在面板网页端撤销。"))
        }
    }

    // MARK: - 快速开始分区

    private var quickStartSection: some View {
        Section {
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
            Text(L10n.t("快速开始（账号密码）"))
        } footer: {
            Text(L10n.t("登录一次面板即可自动填入接口密钥，无需到网页端手动复制。开启了两步验证的面板会要求输入动态口令。"))
        }
    }

    /// 验证码行：图片 + 输入框 + 换一张
    private func captchaRow(_ captcha: CaptchaResponse) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            OutlinedTextField(label: L10n.t("图形验证码"),
                              text: $captchaInput, machineValue: true)
                .textInputAutocapitalization(.never)
            HStack(spacing: 12) {
                if let data = captcha.imageData,
                   let image = platformImage(data) {
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

    /// 高级区：可选安全入口码 + 手动粘贴密钥（现行路径）
    private var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showAdvanced) {
                OutlinedTextField(label: L10n.t("安全入口码"), prompt: L10n.t("面板未设置则留空"),
                                  text: $entranceCode, machineValue: true)
                    .textInputAutocapitalization(.never)
                OutlinedPasswordField(label: "API Key", text: $apiKey)
            } label: {
                Label(
                    apiKey.isEmpty
                        ? L10n.t("已有接口密钥？手动粘贴")
                        : L10n.t("接口密钥（已填入）"),
                    systemImage: "key.horizontal"
                )
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
        default:
            return L10n.t("登录并获取密钥")
        }
    }

    // MARK: - 引导流

    private func bootstrapTapped() {
        // 明文 HTTP 上先发高级别警告（账号密码 vs 密钥粘贴，前者更敏感）
        if draftIsPlainHTTP && !bootstrapHTTPAllowed {
            if httpsOnly {
                httpsBlockMessage = L10n.t("已开启「仅允许 HTTPS 连接」：请在 设置 → 安全 关闭该限制，或改用 https:// 地址")
                showHTTPSBlockAlert = true
                return
            }
            showPlainHTTPBootstrapWarning = true
            return
        }
        if bootstrapPhase == .awaitingMFA {
            Task { await submitMFA() }
            return
        }
        if bootstrapPhase == .resetPassword {
            Task { await submitPasswordReset() }
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

    /// 步骤 3：current 取钥（Enable 直接用现有密钥——零新建、零开关改动、零副作用）
    private func acquireKey(_ client: SessionAuthClient) async {
        bootstrapPhase = .working
        do {
            let info = try await client.currentUser()
            switch BootstrapDecision.keyAcquisition(from: info) {
            case .useExisting(let key):
                finishBootstrap(key: key)
            case .needsEnableConfirm:
                bootstrapPhase = .confirmEnable
            }
        } catch {
            handleBootstrapError(error)
        }
    }

    /// Disable → 显式开启（keys/status 翻 Legacy 行 Enable，v2.3.2+ 端点）
    /// → 重取 current 的 key
    private func confirmEnableAndFetch() async {
        guard let client = bootstrapClient else { return }
        bootstrapPhase = .working
        do {
            try await client.enableApiInterface()
            let refreshed = try await client.currentUser()
            guard let key = refreshed.apiKey, !key.isEmpty else {
                throw SessionAuthError.business(200, L10n.t("面板未返回接口密钥，请改用手动粘贴"))
            }
            finishBootstrap(key: key)
        } catch {
            handleBootstrapError(error)
        }
    }

    private func finishBootstrap(key: String) {
        apiKey = key
        bootstrapPhase = .succeeded
        bootstrapMessage = L10n.t("已获取接口密钥，保存后即可以密钥连接")
        Haptic.success()
        // session 即弃：jar 销毁、密码即清（不长期保留）
        teardownBootstrapClient()
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
            // 展开高级区引导补填安全入口码
            showAdvanced = true
            bootstrapPhase = .idle
        default:
            bootstrapPhase = .idle
        }
        // 其余失败不重试登录（IPTracker 锁定纪律）；jar 保留供同表单内重试，
        // 离开表单时 onDisappear 统一销毁
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
        didFetchSetting = false
    }

    // MARK: - 保存 / 测试（现行路径不变）

    private func loadIfEditing() {
        guard let s = editing else { return }
        name = s.name
        baseURL = s.baseURL
        apiKey = s.apiKey
        entranceCode = s.entranceCode ?? ""
    }

    private func save() {
        if draftIsPlainHTTP {
            if httpsOnly {
                // 显式弹窗提示（行内结果行小字在键盘弹起/滚动时易被忽略）
                httpsBlockMessage = L10n.t("已开启「仅允许 HTTPS 连接」：请在 设置 → 安全 关闭该限制，或改用 https:// 地址")
                showHTTPSBlockAlert = true
                testResult = TestResult(success: false, message: httpsBlockMessage ?? "")
                return
            }
            showPlainHTTPWarning = true
            return
        }
        performSave()
    }

    private func performSave() {
        let s = ServerConfig(
            id: editing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            // username 用完即清不落盘；安全入口码留档供下次引导免重填
            username: nil,
            entranceCode: entranceCode.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ? nil : entranceCode.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if editing != nil { manager.update(s) } else { manager.add(s) }
        manager.select(s)
        dismiss()
    }

    private func runTest() {
        if draftIsPlainHTTP && httpsOnly {
            testResult = TestResult(
                success: false,
                message: L10n.t("已开启「仅允许 HTTPS 连接」：请在 设置 → 安全 关闭该限制，或改用 https:// 地址")
            )
            return
        }
        testing = true
        testResult = nil
        let server = ServerConfig(
            id: editing?.id ?? UUID(),
            name: name,
            baseURL: baseURL,
            apiKey: apiKey
        )
        Task {
            // 草稿配置一次性探测，不进共享缓存（见 useSharedCache 参数注释）
            let (ok, msg) = await ConnectionTester.test(server, useSharedCache: false)
            await MainActor.run {
                self.testResult = TestResult(success: ok, message: msg)
                self.testing = false
            }
        }
    }

    // MARK: - 小工具

    /// 验证码 data URL → UIImage（iOS 专属类型收敛于此，便于测试目标共用）
    private func platformImage(_ data: Data) -> UIImage? {
        UIImage(data: data)
    }
}
