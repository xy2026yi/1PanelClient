//
//  AppLock.swift
//  1PanelClient
//
//  应用锁：自定义 4 位数字密码（Keychain 存加盐迭代摘要，不镜像 UserDefaults）
//  + FaceID/TouchID 可选。锁屏为 iPhone 解锁样式（「输入密码」+ 圆点 + 0-9 键盘）；
//  开启时进入后台即锁。连续输错递增锁定。
//

import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI

@MainActor
final class AppLockManager: ObservableObject {
    static let enabledKey = "applock.enabled"
    /// Keychain 里的密码摘要 key
    private static let pinKey = "applock.pin.sha256"
    /// 密码位数
    static let pinLength = 4

    @Published var isLocked: Bool

    private let defaults = UserDefaults.standard

    init() {
        // 冷启动：开关开启则先上锁，界面就绪后走解锁流程
        isLocked = defaults.bool(forKey: Self.enabledKey)
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    // MARK: - 密码（存摘要不存明文；静态操作，任何实例/设置页均可调用）

    static var hasPasscode: Bool {
        !(KeychainStore.read(for: pinKey) ?? "").isEmpty
    }

    static func setPasscode(_ pin: String) {
        KeychainStore.save(digestV2(pin), for: pinKey, mirror: false)
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

    /// 清除已存密码（关闭应用锁时调用，避免 Keychain/镜像残留）
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

    /// 进入后台时调用：开关开启则上锁。
    /// （历史遗留的 lockedByDeactivation 标记已删：熄屏回弹由 LockScreenView 的
    /// 延时复核 + canPresentBiometrics 双信号拦截，该标记重构后无任何读取方）
    func lockIfEnabled() {
        if isEnabled {
            isLocked = true
        }
    }

    /// 设备是否有可用的生物识别（FaceID/TouchID；仅用于优先快捷解锁，非必需）
    static var biometryAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// 当前设备的生物识别类型（锁屏图标用）
    static var biometryType: LABiometryType {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return ctx.biometryType
    }

    /// 弹生物识别（仅生物识别，失败/取消回落到密码键盘）；无生物识别直接返回
    func tryBiometricUnlock() async {
        guard isLocked, Self.biometryAvailable else { return }
        let ctx = LAContext()
        do {
            let ok = try await ctx.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: L10n.t("解锁 1PanelClient")
            )
            if ok { isLocked = false }
        } catch {
            // 用户取消 / 验证失败：保持锁定，锁屏自动切到密码键盘
        }
    }

    /// 密码验证通过
    func unlockWithPasscode() {
        isLocked = false
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

// MARK: - 锁屏遮罩

struct LockScreenView: View {
    @EnvironmentObject private var lock: AppLockManager
    @Environment(\.scenePhase) private var scenePhase
    /// true=显示密码键盘（生物识别取消/失败/不可用时自动或手动切换）
    @State private var showKeypad = false
    @State private var unlockFailed = false
    /// 本轮锁定期内累计输错次数；每满 5 次递增锁定（30s→60s→120s…封顶 5 分钟）
    @State private var failedAttempts = 0
    @State private var lockoutUntil: Date?
    /// 生物识别进行中标记：防验证回调与 scenePhase 回 active 竞争触发两次弹窗
    @State private var biometricInFlight = false
    /// 本轮前台是否已自动弹过一次生物识别。FaceID 系统弹窗本身会让 app 走一轮
    /// inactive→active（取消/失败关闭弹窗即回 active），若每次回 active 都补弹会
    /// 陷入「取消→再弹」死循环：一轮前台只自动弹一次，之后仅用户点「解锁」触发；
    /// 真正进过后台再回前台视为新一轮（见 onChange 的 .background 分支）
    @State private var biometricAutoPresented = false

    private var biometryIcon: String {
        switch AppLockManager.biometryType {
        case .faceID:               return "faceid"
        case .touchID:              return "touchid"
        case .opticID:              return "eye.square"
        default:                    return "lock.fill"
        }
    }

    /// 连续输错每满 5 次锁定一段时间，逐级翻倍封顶 5 分钟
    private func registerWrongAttempt() {
        failedAttempts += 1
        if failedAttempts % 5 == 0 {
            let block = failedAttempts / 5
            let seconds = min(30.0 * pow(2, Double(block - 1)), 300)
            lockoutUntil = Date().addingTimeInterval(seconds)
        }
    }

    /// 密码锁定等待视图：秒级倒计时，到点自动恢复键盘
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
                    Color.clear.onAppear { lockoutUntil = nil }
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            if showKeypad {
                if let until = lockoutUntil, Date() < until {
                    lockoutView(until: until)
                } else {
                    PasscodeKeypad(
                        title: L10n.t("输入密码"),
                        message: unlockFailed ? L10n.t("密码错误，请重试") : nil
                    ) { pin in
                        if AppLockManager.verifyPasscode(pin) {
                            Haptic.success()
                            lock.unlockWithPasscode()
                            return true
                        }
                        unlockFailed = true
                        registerWrongAttempt()
                        return false
                    }
                }
            } else {
                Image(systemName: biometryIcon)
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
            if AppLockManager.biometryAvailable {
                Button {
                    unlockFailed = false
                    showKeypad.toggle()
                } label: {
                    Text(showKeypad ? L10n.t("使用面容 ID 解锁") : L10n.t("使用密码解锁"))
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
            // 初次出现，或用户主动切回生物识别面板（「使用面容 ID 解锁」）：
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
    /// 被系统临时锁定（连续失败过多不可用）时才自动回落密码键盘，避免解锁按钮
    /// 点击无效
    private func autoBiometricUnlock() async {
        guard !showKeypad, !biometricInFlight, !biometricAutoPresented,
              canPresentBiometrics else { return }
        biometricInFlight = true
        defer { biometricInFlight = false }
        // 延时复核：拦下熄屏瞬间的 active 回弹（手机放着不碰才叫熄屏，多等 0.8s
        // 不影响真实交互；回弹场景此时已落回 inactive/background）
        try? await Task.sleep(for: .seconds(0.8))
        guard !showKeypad, !biometricAutoPresented, lock.isLocked, canPresentBiometrics else { return }
        biometricAutoPresented = true
        await lock.tryBiometricUnlock()
        if lock.isLocked, !AppLockManager.biometryAvailable {
            showKeypad = true
        }
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
        await lock.tryBiometricUnlock()
        if lock.isLocked, !AppLockManager.biometryAvailable {
            showKeypad = true
        }
    }
}

// MARK: - 设置密码（两次输入确认）

struct SetPasscodeSheet: View {
    /// 设置成功回调（已写入 Keychain）
    var onSuccess: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var firstPin: String? = nil
    @State private var mismatch = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            PasscodeKeypad(
                title: firstPin == nil ? L10n.t("输入新密码") : L10n.t("再次输入新密码"),
                message: mismatch ? L10n.t("两次输入不一致，请重新设置") : L10n.t("设置 4 位数字密码")
            ) { pin in
                if firstPin == nil {
                    firstPin = pin
                    mismatch = false
                    return true
                }
                if pin == firstPin {
                    AppLockManager.setPasscode(pin)
                    onSuccess()
                    dismiss()
                    return true
                }
                firstPin = nil
                mismatch = true
                return false
            }
            Spacer()
        }
        .bottomSheetDetents([.large])
        .interactiveDismissDisabled()
        // 显式取消：开启流程中放弃（开关由 get 取值自动弹回）、修改密码中保留旧密码
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.t("取消")) { dismiss() }
            }
        }
    }
}
