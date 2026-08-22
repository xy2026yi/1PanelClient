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

    /// 进入后台时调用：开关开启则上锁
    func lockIfEnabled() {
        if isEnabled { isLocked = true }
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
                    }
                    .accessibilityLabel(L10n.t("删除"))
                }
            }
            .padding(.top, 36)
        }
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
                .font(.system(size: 28, weight: .regular, design: .rounded))
                .foregroundStyle(.primary)
                .frame(width: 74, height: 74)
                .background(Circle().fill(Color(uiColor: .secondarySystemFill)))
        }
    }
}

// MARK: - 锁屏遮罩

struct LockScreenView: View {
    @EnvironmentObject private var lock: AppLockManager
    /// true=显示密码键盘（生物识别取消/失败/不可用时自动或手动切换）
    @State private var showKeypad = false
    @State private var unlockFailed = false
    /// 本轮锁定期内累计输错次数；每满 5 次递增锁定（30s→60s→120s…封顶 5 分钟）
    @State private var failedAttempts = 0
    @State private var lockoutUntil: Date?

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
                .font(.system(size: 40))
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
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text(L10n.t("已锁定"))
                    .font(.title3.bold())
                    .padding(.top, 16)
                Text(L10n.t("验证以继续使用"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                Button {
                    Task { await lock.tryBiometricUnlock() }
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
                }
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .transition(.opacity)
        .task(id: showKeypad) {
            // 首次进入尝试生物识别；取消/失败（仍锁定且未展示键盘）自动切密码键盘
            if !showKeypad {
                await lock.tryBiometricUnlock()
                if lock.isLocked { showKeypad = true }
            }
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
        .presentationDetents([.large])
        .interactiveDismissDisabled()
        // 显式取消：开启流程中放弃（开关由 get 取值自动弹回）、修改密码中保留旧密码
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.t("取消")) { dismiss() }
            }
        }
    }
}
