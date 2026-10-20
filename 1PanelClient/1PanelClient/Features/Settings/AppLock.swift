//
//  AppLock.swift
//  1PanelClient
//
//  应用锁：「面容/触控 ID」与「密码」两个独立开关，任一开启即离开前台上锁。
//  密码为自定义 4 位数字（Keychain 存加盐迭代摘要，不镜像 UserDefaults），不可修改——
//  只能关闭后重新开启设新密码；关闭任一方式须先以当前已开启的任一方式验证身份。
//  锁屏为 iPhone 解锁样式（「输入密码」+ 圆点 + 0-9 键盘）；连续输错递增锁定。
//

import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI

/// 应用锁的两种验证方式（设置页开关 / 关闭前验证 sheet 的 item）
enum AppLockMethod: String, Identifiable {
    case biometrics
    case passcode

    var id: String { rawValue }
}

@MainActor
final class AppLockManager: ObservableObject {
    /// 「面容/触控 ID」开关
    static let biometricsEnabledKey = "applock.biometrics.enabled"
    /// 「密码」开关。密码摘要本体在 Keychain，开关位单独放 UserDefaults：上锁判定只读
    /// 开关位不碰 Keychain——设备刚锁屏时受保护数据不可读，Keychain 读失败会被误判为
    /// 「未开启」而漏锁
    static let passcodeEnabledKey = "applock.passcode.enabled"
    /// 旧版单开关键（≤ v0.2.2）：首次启动迁移为密码开 + 面容开（有生物识别硬件时），随后删除
    static let legacyEnabledKey = "applock.enabled"
    /// Keychain 里的密码摘要 key（internal 供测试备份/还原模拟器上的既有密码）
    static let pinKey = "applock.pin.sha256"
    /// 密码位数
    static let pinLength = 4

    @Published var isLocked: Bool

    /// 设置页发起的系统验证进行中（开/关面容、关密码）：系统弹窗会让场景短暂 inactive，
    /// 该窗口内不上锁（见 lockIfEnabled）
    private var foregroundAuthInFlight = false
    private var foregroundAuthGeneration = 0

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateLegacyEnabledFlag(in: defaults, biometryPresent: Self.hasBiometryHardware)
        // 冷启动：任一方式开启则先上锁，界面就绪后走解锁流程
        isLocked = Self.isEnabled(in: defaults)
    }

    // MARK: - 开关

    var biometricsEnabled: Bool {
        get { defaults.bool(forKey: Self.biometricsEnabledKey) }
        set { defaults.set(newValue, forKey: Self.biometricsEnabledKey) }
    }

    var passcodeEnabled: Bool {
        get { defaults.bool(forKey: Self.passcodeEnabledKey) }
        set { defaults.set(newValue, forKey: Self.passcodeEnabledKey) }
    }

    /// 任一方式开启即为「应用锁开启」
    var isEnabled: Bool { Self.isEnabled(in: defaults) }

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: biometricsEnabledKey) || defaults.bool(forKey: passcodeEnabledKey)
    }

    /// 旧版单开关 → 双开关迁移（一次性；旧键不存在则无事发生）。旧版面容只要设备支持
    /// 就隐式可用，故有生物识别硬件时面容开关迁为开，保持用户既有的解锁体验
    static func migrateLegacyEnabledFlag(in defaults: UserDefaults, biometryPresent: @autoclosure () -> Bool) {
        guard defaults.object(forKey: legacyEnabledKey) != nil else { return }
        if defaults.bool(forKey: legacyEnabledKey) {
            defaults.set(true, forKey: passcodeEnabledKey)
            if biometryPresent() {
                defaults.set(true, forKey: biometricsEnabledKey)
            }
        }
        defaults.removeObject(forKey: legacyEnabledKey)
    }

    // MARK: - 密码（存摘要不存明文；静态操作，任何实例/设置页均可调用）

    static var hasPasscode: Bool {
        !(KeychainStore.read(for: pinKey) ?? "").isEmpty
    }

    /// 写入新密码摘要；返回写后回读是否成功（Keychain 写失败是静默的，回读兜底，
    /// 避免开关已开却无密码可验）
    @discardableResult
    static func setPasscode(_ pin: String) -> Bool {
        KeychainStore.save(digestV2(pin), for: pinKey, mirror: false)
        return hasPasscode
    }

    static func verifyPasscode(_ pin: String) -> Bool {
        guard let stored = KeychainStore.read(for: pinKey), !stored.isEmpty else { return false }
        if stored.hasPrefix(v2Prefix) {
            let body = stored.dropFirst(v2Prefix.count)
            guard let sep = body.firstIndex(of: ":"),
                  let salt = data(fromHex: String(body[body.startIndex..<sep])) else { return false }
            return digestV2(pin, salt: salt) == stored
        }
        // 旧格式（无盐 SHA256）：验证通过后原位升级为 v2
        if legacyDigest(pin) == stored {
            KeychainStore.save(digestV2(pin), for: pinKey, mirror: false)
            return true
        }
        return false
    }

    /// 清除已存密码（关闭密码开关时调用，避免 Keychain/镜像残留）
    static func clearPasscode() {
        KeychainStore.delete(for: pinKey)
    }

    // MARK: 摘要算法
    // v2 = "v2:" + 盐(16字节hex) + ":" + 摘要hex；摘要 = 10 万轮迭代 SHA256(盐+密码)。
    // 4 位数字密码空间仅 1 万，无盐单轮哈希可瞬间穷举；加盐 + 迭代显著抬高离线
    // 穷举成本（真正的边界仍是 Keychain 本身，此处是纵深防御）。

    private static let v2Prefix = "v2:"
    private static let digestRounds = 100_000

    private static func digestV2(_ pin: String, salt: Data? = nil) -> String {
        let s = salt ?? SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        var acc = s
        acc.append(contentsOf: pin.utf8)
        for _ in 0..<digestRounds {
            acc = Data(SHA256.hash(data: acc))
        }
        let hex: (Data) -> String = { $0.map { String(format: "%02x", $0) }.joined() }
        return v2Prefix + hex(s) + ":" + hex(acc)
    }

    private static func legacyDigest(_ pin: String) -> String {
        SHA256.hash(data: Data(pin.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func data(fromHex hex: String) -> Data? {
        var bytes: [UInt8] = []
        var iter = hex.makeIterator()
        while let h = iter.next(), let l = iter.next() {
            guard let hi = h.hexDigitValue, let lo = l.hexDigitValue else { return nil }
            bytes.append(UInt8(hi << 4 | lo))
        }
        return bytes.isEmpty ? nil : Data(bytes)
    }

    // MARK: - 生命周期

    /// 场景离开活跃态时调用：任一方式开启则上锁。设置页发起的系统验证会让场景短暂
    /// inactive（系统弹窗抢焦点），该窗口内不上锁，否则验证刚完成就被锁屏盖住；
    /// 真正进入后台不受此豁免
    func lockIfEnabled(leavingTo phase: ScenePhase) {
        if Self.shouldLock(isEnabled: isEnabled, leavingTo: phase, foregroundAuthInFlight: foregroundAuthInFlight) {
            isLocked = true
        }
    }

    static func shouldLock(isEnabled: Bool, leavingTo phase: ScenePhase, foregroundAuthInFlight: Bool) -> Bool {
        guard isEnabled else { return false }
        if phase == .inactive, foregroundAuthInFlight { return false }
        return true
    }

    /// 密码验证通过
    func unlockWithPasscode() {
        isLocked = false
    }

    // MARK: - 生物识别

    /// 设备当前能否做生物识别（已录入且未被系统临时锁定；设置页开启面容时以此验一次）
    static var biometryAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// 设备的生物识别硬件类型（无硬件为 .none；未录入时仍返回硬件类型）
    static var biometryType: LABiometryType {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return ctx.biometryType
    }

    /// 设备是否有生物识别硬件（设置页据此决定是否显示面容开关行）
    static var hasBiometryHardware: Bool {
        biometryType != .none
    }

    /// 面向用户的生物识别名称（设置页开关标题 / 提示文案）
    static var biometryDisplayName: String {
        switch biometryType {
        case .faceID:  return L10n.t("面容 ID")
        case .touchID: return L10n.t("触控 ID")
        default:       return L10n.t("生物识别")
        }
    }

    /// 生物识别图标（锁屏 / 验证页 / 设置行共用）
    static var biometryIcon: String {
        switch biometryType {
        case .faceID:  return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "eye.square"
        default:       return "lock.fill"
        }
    }

    /// 系统验证策略：开了密码 → 仅生物识别（失败/取消由 App 密码键盘兜底）；仅面容 →
    /// 带设备密码回退的策略（否则生物识别被系统锁定/录入失效时无任何解锁途径，App 被软锁死）
    static func authPolicy(passcodeEnabled: Bool) -> LAPolicy {
        passcodeEnabled ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
    }

    /// 锁屏的生物识别路径当前能否走通（面容开关开 + 对应策略可评估）
    var biometricUnlockAvailable: Bool {
        biometricsEnabled
            && LAContext().canEvaluatePolicy(Self.authPolicy(passcodeEnabled: passcodeEnabled), error: nil)
    }

    enum AuthOutcome: Equatable {
        case success
        /// 用户取消或系统中断（如进后台）
        case cancelled
        /// 用户在系统弹窗里点了回退按钮（仅 WithBiometrics 策略会出现，语义为「改用 App 密码」）
        case fallbackRequested
        /// 不可评估或验证失败；code 为 LAError 码（canEvaluatePolicy 失败亦归此）
        case failed(LAError.Code?)
    }

    private static func laCode(_ error: Error?) -> LAError.Code? {
        (error as? LAError)?.code
    }

    /// 跑一次系统验证。fallbackTitle：nil 用系统默认回退按钮文案，"" 隐藏回退按钮
    private static func evaluate(policy: LAPolicy, reason: String, fallbackTitle: String?) async -> AuthOutcome {
        let ctx = LAContext()
        if let fallbackTitle {
            ctx.localizedFallbackTitle = fallbackTitle
        }
        var evalError: NSError?
        guard ctx.canEvaluatePolicy(policy, error: &evalError) else {
            return .failed(laCode(evalError))
        }
        do {
            return try await ctx.evaluatePolicy(policy, localizedReason: reason) ? .success : .failed(nil)
        } catch {
            switch laCode(error) {
            case .userCancel, .appCancel, .systemCancel: return .cancelled
            case .userFallback:                           return .fallbackRequested
            case let code:                                return .failed(code)
            }
        }
    }

    /// 锁屏弹系统验证；面容开关未开直接返回不弹
    @discardableResult
    func tryBiometricUnlock() async -> AuthOutcome {
        guard isLocked, biometricsEnabled else { return .cancelled }
        let outcome = await Self.evaluate(
            policy: Self.authPolicy(passcodeEnabled: passcodeEnabled),
            reason: L10n.t("解锁 1PanelClient"),
            fallbackTitle: passcodeEnabled ? L10n.t("使用密码") : nil
        )
        switch outcome {
        case .success:
            isLocked = false
        case .failed(.passcodeNotSet?) where !passcodeEnabled:
            // 仅面容模式且设备已移除锁屏密码（移除需先验证原密码，只能是机主所为）：面容随之
            // 失效、又无 App 密码可退，上锁已无任何可验证途径——放行，避免软锁死
            isLocked = false
        default:
            break
        }
        return outcome
    }

    /// 设置页发起的系统验证（开/关面容、关密码）：期间豁免 inactive 上锁
    func authenticateInForeground(policy: LAPolicy, reason: String, fallbackTitle: String? = nil) async -> AuthOutcome {
        foregroundAuthGeneration += 1
        let generation = foregroundAuthGeneration
        foregroundAuthInFlight = true
        let outcome = await Self.evaluate(policy: policy, reason: reason, fallbackTitle: fallbackTitle)
        // 弹窗关闭后场景 inactive→active 的 scenePhase 传播可能略滞后于本回调，留余量再解除豁免
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            guard let self, self.foregroundAuthGeneration == generation else { return }
            self.foregroundAuthInFlight = false
        }
        return outcome
    }
}

// MARK: - 数字键盘（iPhone 解锁样式）

/// 0-9 圆形键盘 + 圆点指示：输入满位回调 onEntered，返回 true=通过并清空，
/// false=错误（抖动提示后清空）
struct PasscodeKeypad: View {
    let title: String
    var message: String? = nil
    let onEntered: (String) -> Bool

    @State private var input = ""
    @State private var wrongAttempt = 0

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

            // 圆点指示
            HStack(spacing: 22) {
                ForEach(0..<AppLockManager.pinLength, id: \.self) { i in
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.6), lineWidth: 1)
                        .background(Circle().fill(i < input.count ? Color.primary : .clear))
                        .frame(width: 13, height: 13)
                }
            }
            .padding(.top, 24)
            .offset(x: wrongAttempt % 2 == 0 ? -12 : 12)
            .opacity(wrongAttempt == 0 ? 1 : 0.6)
            .animation(wrongAttempt == 0 ? nil : .easeInOut(duration: 0.06), value: wrongAttempt)

            // 键盘
            VStack(spacing: 18) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 30) {
                        ForEach(1...3, id: \.self) { col in
                            key("\(row * 3 + col)")
                        }
                    }
                }
                HStack(spacing: 30) {
                    Color.clear.frame(width: 74, height: 74)
                    key("0")
                    Button {
                        if !input.isEmpty {
                            input.removeLast()
                        }
                    } label: {
                        Image(systemName: "delete.left")
                            .font(.title3)
                            .foregroundStyle(.primary)
                            .frame(width: 74, height: 74)
                            // B5：审计器会读到 Image 节点的符号名 delete.left（不可读），
                            // 图标层补可读标签（按钮层已有）
                            .accessibilityLabel(L10n.t("删除"))
                    }
                    .accessibilityLabel(L10n.t("删除"))
                }
            }
            .padding(.top, 36)
        }
        // iPad 全屏画布上限宽居中，避免 74pt 圆键在整幅宽度上比例失调
        .frame(maxWidth: 360)
        .onChange(of: input) { _, newValue in
            guard newValue.count == AppLockManager.pinLength else { return }
            // 等圆点填充渲染完再校验，抖动/清空与视觉同步
            Task {
                try? await Task.sleep(for: .seconds(0.1))
                if !onEntered(newValue) {
                    Haptic.error()
                    wrongAttempt += 1
                    try? await Task.sleep(for: .seconds(0.35))
                    input = ""
                    wrongAttempt = 0
                } else {
                    input = ""
                }
            }
        }
    }

    private func key(_ digit: String) -> some View {
        Button {
            guard input.count < AppLockManager.pinLength else { return }
            input.append(digit)
        } label: {
            Text(digit)
                .font(.panelScaled(28, weight: .regular, design: .rounded))
                // 固定 74pt 圆形键位，字号随动态类型放大到 xxxLarge 为止
                .dynamicTypeSize(...(.xxxLarge))
                .foregroundStyle(.primary)
                .frame(width: 74, height: 74)
                .background(Circle().fill(Color(uiColor: .secondarySystemFill)))
        }
    }
}

// MARK: - 密码校验面板（键盘 + 连续输错递增锁定）

/// 连续输错递增锁定：每满 5 次锁定一段时间（30s→60s→120s…封顶 5 分钟）
struct PasscodeAttemptGuard: Equatable {
    private(set) var failedAttempts = 0
    private(set) var lockoutUntil: Date?

    static let attemptsPerLockout = 5
    static let baseLockoutSeconds: TimeInterval = 30
    static let maxLockoutSeconds: TimeInterval = 300

    mutating func registerFailure(now: Date = Date()) {
        failedAttempts += 1
        if failedAttempts % Self.attemptsPerLockout == 0 {
            let block = failedAttempts / Self.attemptsPerLockout
            let seconds = min(Self.baseLockoutSeconds * pow(2, Double(block - 1)), Self.maxLockoutSeconds)
            lockoutUntil = now.addingTimeInterval(seconds)
        }
    }

    /// 仍在锁定期内时返回截止时间，否则 nil
    func activeLockout(now: Date = Date()) -> Date? {
        guard let until = lockoutUntil, now < until else { return nil }
        return until
    }

    mutating func clearExpiredLockout(now: Date = Date()) {
        if let until = lockoutUntil, now >= until {
            lockoutUntil = nil
        }
    }
}

/// 密码校验面板：锁定期显示秒级倒计时，否则显示键盘。锁定状态由宿主持有——切到生物识别
/// 面板再切回时本面板会重建，若状态放在面板内，来回切换即可绕过锁定
struct PasscodeVerifyPanel: View {
    @Binding var attemptGuard: PasscodeAttemptGuard
    /// 校验通过回调（已触发成功触感）
    let onVerified: () -> Void

    @State private var lastAttemptFailed = false

    var body: some View {
        if let until = attemptGuard.activeLockout() {
            lockoutView(until: until)
        } else {
            PasscodeKeypad(
                title: L10n.t("输入密码"),
                message: lastAttemptFailed ? L10n.t("密码错误，请重试") : nil
            ) { pin in
                if AppLockManager.verifyPasscode(pin) {
                    Haptic.success()
                    onVerified()
                    return true
                }
                lastAttemptFailed = true
                attemptGuard.registerFailure()
                return false
            }
        }
    }

    /// 锁定等待视图：秒级倒计时，到点自动恢复键盘
    private func lockoutView(until: Date) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.panelScaled(40))
                .foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remain = Int(max(0, until.timeIntervalSince(context.date)).rounded(.up))
                if remain > 0 {
                    Text(L10n.f("密码尝试次数过多，请在 %ld 秒后重试", remain))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                } else {
                    Color.clear.onAppear { attemptGuard.clearExpiredLockout() }
                }
            }
        }
    }
}

// MARK: - 锁屏遮罩

struct LockScreenView: View {
    @EnvironmentObject private var lock: AppLockManager
    @Environment(\.scenePhase) private var scenePhase
    /// 用户主动切到密码键盘（两种方式都开时可来回切；面容路径走不通时自动置位）
    @State private var preferKeypad = false
    /// 连续输错递增锁定（见 PasscodeVerifyPanel 说明，持有在宿主）
    @State private var attemptGuard = PasscodeAttemptGuard()
    /// 生物识别进行中标记：防验证回调与 scenePhase 回 active 竞争触发两次弹窗
    @State private var biometricInFlight = false
    /// 本轮前台是否已自动弹过一次生物识别。FaceID 系统弹窗本身会让 app 走一轮
    /// inactive→active（取消/失败关闭弹窗即回 active），若每次回 active 都补弹会
    /// 陷入「取消→再弹」死循环：一轮前台只自动弹一次，之后仅用户点「解锁」触发；
    /// 真正进过后台再回前台视为新一轮（见 onChange 的 .background 分支）
    @State private var biometricAutoPresented = false

    /// 当前是否显示密码键盘：仅开密码 → 恒键盘；仅开面容 → 恒面容面板；都开 → 随用户切换
    private var showKeypad: Bool {
        guard lock.passcodeEnabled else { return false }
        guard lock.biometricsEnabled else { return true }
        return preferKeypad
    }

    /// 底部「切换方式」按钮：两种方式都开且面容路径可走时才有意义
    private var canSwitchMethod: Bool {
        lock.passcodeEnabled && lock.biometricsEnabled && lock.biometricUnlockAvailable
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            if showKeypad {
                PasscodeVerifyPanel(attemptGuard: $attemptGuard) {
                    lock.unlockWithPasscode()
                }
            } else {
                Image(systemName: AppLockManager.biometryIcon)
                    .font(.panelScaled(56))
                    .foregroundStyle(.secondary)
                    // B5：纯装饰图标，状态由下方「已锁定」文本朗读，无需独立成焦点
                    .accessibilityHidden(true)
                Text(L10n.t("已锁定"))
                    .font(.title3.bold())
                    .padding(.top, 16)
                Text(L10n.t("验证以继续使用"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                Button {
                    Task { await manualBiometricUnlock() }
                } label: {
                    Label(L10n.t("解锁"), systemImage: "lock.open")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 24)
            }

            Spacer()
            Spacer()

            // 生物识别与密码键盘互相切换
            if canSwitchMethod {
                Button {
                    preferKeypad.toggle()
                } label: {
                    Text(showKeypad ? L10n.f("使用%@", AppLockManager.biometryDisplayName) : L10n.t("使用密码"))
                        .font(.subheadline)
                        // B5：纯文字按钮实测命中高仅 18pt，扩到 44（视觉不变）
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .transition(.opacity)
        .task(id: showKeypad) {
            // 初次出现，或用户主动切回生物识别面板（「使用面容 ID」）：
            // 视为新一轮，允许自动弹一次
            if !showKeypad { biometricAutoPresented = false }
            await autoBiometricUnlock()
        }
        // 上锁可能发生在 inactive（进切换器/通知中心）：系统验证在非 active 时无法
        // 正常展示，回 active 时再补弹。熄屏瞬间的 active 回弹由 autoBiometricUnlock
        // 的延时 0.8s 复核 + canPresentBiometrics 拦截（见下方函数注释）；FaceID 弹窗
        // 自身造成的 inactive→active 往返（取消即触发）由 biometricAutoPresented 挡住：
        // 一轮前台只自动弹一次，不随弹窗关闭重弹
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // 真正进过后台：回前台算新一轮，重新允许自动弹一次
                biometricAutoPresented = false
            case .active:
                Task { await autoBiometricUnlock() }
            default:
                break
            }
        }
    }

    /// 是否适合弹系统验证：applicationState 为 UIKit 即时值（SwiftUI scenePhase
    /// 环境传播滞后）；isProtectedDataAvailable 为设备级锁屏信号（熄屏即锁后变
    /// false，解锁系统锁屏后才回 true）——LiveContainer 下 applicationState 可能
    /// 滞后，双信号一起兜底，确保设备锁屏/熄屏状态绝不弹 FaceID
    private var canPresentBiometrics: Bool {
        UIApplication.shared.applicationState == .active
            && UIApplication.shared.isProtectedDataAvailable
    }

    /// 前台活跃时自动弹生物识别（每轮前台至多一次，见 biometricAutoPresented）。
    /// 熄屏瞬间的 active 回弹不弹——判定方式为**延时 0.8s 复核**：回弹会在复核前
    /// 落回非活跃态被 canPresentBiometrics 拦下（自动弹次数不消耗，设备解锁后
    /// 照常自动弹）；通知中心收起/切换器返回/设备解锁则持续活跃，复核通过后弹窗。
    /// 失败/取消不自动切密码键盘：非用户主动的失败不应占用掉生物识别路径，留在
    /// 验证界面由用户选择重试或切密码（对齐 iOS 系统锁屏的交互习惯）；仅生物识别
    /// 路径走不通（未录入/被系统临时锁定）或用户在系统弹窗点了「使用密码」时才切键盘
    private func autoBiometricUnlock() async {
        guard !showKeypad, !biometricInFlight, !biometricAutoPresented,
              canPresentBiometrics else { return }
        biometricInFlight = true
        defer { biometricInFlight = false }
        // 延时复核：拦下熄屏瞬间的 active 回弹（手机放着不碰才叫熄屏，多等 0.8s
        // 不影响真实交互；回弹场景此时已落回 inactive/background）
        try? await Task.sleep(for: .seconds(0.8))
        guard !Task.isCancelled, !showKeypad, !biometricAutoPresented, lock.isLocked,
              canPresentBiometrics else { return }
        biometricAutoPresented = true
        let outcome = await lock.tryBiometricUnlock()
        fallBackToKeypadIfNeeded(after: outcome)
    }

    /// 用户点「解锁」手动弹生物识别：与自动弹共用 biometricInFlight 互斥（手动与
    /// 0.8s 复核中的自动弹不并发），并消耗 biometricAutoPresented——FaceID 弹窗
    /// 关闭会造成 inactive→active 往返，不消耗的话取消后会再被自动补弹一次
    /// （用户要取消两次才停，违背「取消后仅点解锁触发」的交互约定）
    private func manualBiometricUnlock() async {
        guard !showKeypad, !biometricInFlight, lock.isLocked, canPresentBiometrics else { return }
        biometricInFlight = true
        defer { biometricInFlight = false }
        biometricAutoPresented = true
        let outcome = await lock.tryBiometricUnlock()
        fallBackToKeypadIfNeeded(after: outcome)
    }

    /// 面容路径走不通或用户在系统弹窗点了「使用密码」：开了密码则切键盘；仅面容模式
    /// 无键盘可切（走不通的终极兜底在 tryBiometricUnlock 的设备密码回退/放行）
    private func fallBackToKeypadIfNeeded(after outcome: AppLockManager.AuthOutcome) {
        guard lock.isLocked, lock.passcodeEnabled else { return }
        if outcome == .fallbackRequested || !lock.biometricUnlockAvailable {
            preferKeypad = true
        }
    }
}

// MARK: - 关闭前验证

/// 关闭某种锁定方式前的身份验证。可用方式 = 当前已开启的方式：仅面容 → 面容；
/// 仅密码 → 密码；都开 → 任一。通过后回调 onVerified 并关闭；取消不作任何更改
/// （设置页开关由 get 取值自动弹回）
struct AppLockVerifySheet: View {
    let allowBiometrics: Bool
    let allowPasscode: Bool
    var onVerified: () -> Void

    @EnvironmentObject private var lock: AppLockManager
    @Environment(\.dismiss) private var dismiss
    @State private var preferKeypad = false
    @State private var attemptGuard = PasscodeAttemptGuard()
    @State private var biometricInFlight = false

    private var showKeypad: Bool {
        guard allowPasscode else { return false }
        guard allowBiometrics else { return true }
        return preferKeypad
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()

                if showKeypad {
                    PasscodeVerifyPanel(attemptGuard: $attemptGuard) {
                        finish()
                    }
                } else {
                    Image(systemName: AppLockManager.biometryIcon)
                        .font(.panelScaled(56))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(L10n.t("验证以继续使用"))
                        .font(.title3.bold())
                        .padding(.top, 16)
                    Button {
                        Task { await runBiometrics() }
                    } label: {
                        Label(L10n.t("验证"), systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 24)
                }

                Spacer()
                Spacer()

                if allowBiometrics && allowPasscode {
                    Button {
                        preferKeypad.toggle()
                    } label: {
                        Text(showKeypad ? L10n.f("使用%@", AppLockManager.biometryDisplayName) : L10n.t("使用密码"))
                            .font(.subheadline)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .padding(.bottom, 32)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
            }
        }
        .bottomSheetDetents([.large])
        .interactiveDismissDisabled()
        .task(id: showKeypad) {
            // 初次出现或切回生物识别面板：等 sheet 呈现动画落定后自动弹一次
            guard !showKeypad else { return }
            try? await Task.sleep(for: .seconds(0.4))
            guard !Task.isCancelled else { return }
            await runBiometrics()
        }
    }

    private func runBiometrics() async {
        guard allowBiometrics, !showKeypad, !biometricInFlight else { return }
        biometricInFlight = true
        defer { biometricInFlight = false }
        let outcome = await lock.authenticateInForeground(
            policy: AppLockManager.authPolicy(passcodeEnabled: allowPasscode),
            reason: L10n.t("验证以更改应用锁设置"),
            fallbackTitle: allowPasscode ? L10n.t("使用密码") : nil
        )
        switch outcome {
        case .success:
            Haptic.success()
            finish()
        case .fallbackRequested:
            if allowPasscode { preferKeypad = true }
        case .failed(.passcodeNotSet?) where !allowPasscode:
            // 仅面容且设备已移除锁屏密码：与锁屏放行逻辑一致（见 tryBiometricUnlock），无可验证途径
            finish()
        case .failed:
            // 面容路径走不通（未录入/被系统锁定）：有密码则切键盘，否则留在面板由用户重试或取消
            if allowPasscode, !AppLockManager.biometryAvailable { preferKeypad = true }
        case .cancelled:
            break
        }
    }

    private func finish() {
        onVerified()
        dismiss()
    }
}

// MARK: - 设置密码（两次输入确认）

struct SetPasscodeSheet: View {
    /// 设置成功回调（已写入 Keychain 并回读确认）
    var onSuccess: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var firstPin: String? = nil
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()
                PasscodeKeypad(
                    title: firstPin == nil ? L10n.t("输入新密码") : L10n.t("再次输入新密码"),
                    message: errorMessage ?? L10n.t("设置 4 位数字密码")
                ) { pin in
                    if firstPin == nil {
                        firstPin = pin
                        errorMessage = nil
                        return true
                    }
                    guard pin == firstPin else {
                        firstPin = nil
                        errorMessage = L10n.t("两次输入不一致，请重新设置")
                        return false
                    }
                    guard AppLockManager.setPasscode(pin) else {
                        firstPin = nil
                        errorMessage = L10n.t("密码保存失败，请重试")
                        return false
                    }
                    onSuccess()
                    dismiss()
                    return true
                }
                Spacer()
            }
            // 显式取消：开启流程中放弃，开关由 get 取值自动弹回
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
            }
        }
        .bottomSheetDetents([.large])
        .interactiveDismissDisabled()
    }
}
