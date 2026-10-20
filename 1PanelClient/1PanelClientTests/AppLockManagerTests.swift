//
//  AppLockManagerTests.swift
//  1PanelClientTests
//
//  应用锁双开关：旧键迁移 / 开启判定与冷启动上锁 / 上锁判定（含前台验证豁免）/
//  系统验证策略 / 连续输错递增锁定 / 密码摘要往返（Keychain，模拟器环境）
//

import Testing
import Foundation
import LocalAuthentication
import SwiftUI
@testable import _PanelClient

@MainActor
// 密码往返用例读写固定的 Keychain 条目，用例间必须串行
@Suite("应用锁", .serialized)
struct AppLockManagerTests {
    /// 每个用例独立的 UserDefaults 域，结束后整域清除
    private func makeDefaults() -> (UserDefaults, () -> Void) {
        let suite = "applock.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    // MARK: - 旧版单开关迁移

    @Test("旧开关开 + 有生物识别硬件 → 密码开、面容开，旧键删除")
    func migrateLegacyOnWithBiometry() {
        let (d, cleanup) = makeDefaults()
        defer { cleanup() }
        d.set(true, forKey: AppLockManager.legacyEnabledKey)

        AppLockManager.migrateLegacyEnabledFlag(in: d, biometryPresent: true)

        #expect(d.bool(forKey: AppLockManager.passcodeEnabledKey))
        #expect(d.bool(forKey: AppLockManager.biometricsEnabledKey))
        #expect(d.object(forKey: AppLockManager.legacyEnabledKey) == nil)
    }

    @Test("旧开关开 + 无生物识别硬件 → 仅密码开")
    func migrateLegacyOnWithoutBiometry() {
        let (d, cleanup) = makeDefaults()
        defer { cleanup() }
        d.set(true, forKey: AppLockManager.legacyEnabledKey)

        AppLockManager.migrateLegacyEnabledFlag(in: d, biometryPresent: false)

        #expect(d.bool(forKey: AppLockManager.passcodeEnabledKey))
        #expect(!d.bool(forKey: AppLockManager.biometricsEnabledKey))
        #expect(d.object(forKey: AppLockManager.legacyEnabledKey) == nil)
    }

    @Test("旧开关关 → 两者都不开，旧键删除")
    func migrateLegacyOff() {
        let (d, cleanup) = makeDefaults()
        defer { cleanup() }
        d.set(false, forKey: AppLockManager.legacyEnabledKey)

        AppLockManager.migrateLegacyEnabledFlag(in: d, biometryPresent: true)

        #expect(!d.bool(forKey: AppLockManager.passcodeEnabledKey))
        #expect(!d.bool(forKey: AppLockManager.biometricsEnabledKey))
        #expect(d.object(forKey: AppLockManager.legacyEnabledKey) == nil)
    }

    @Test("无旧键 → 不触碰现有双开关，也不求值生物识别探测")
    func migrateWithoutLegacyKeyIsNoop() {
        let (d, cleanup) = makeDefaults()
        defer { cleanup() }
        d.set(true, forKey: AppLockManager.biometricsEnabledKey)

        var probed = false
        AppLockManager.migrateLegacyEnabledFlag(in: d, biometryPresent: { probed = true; return true }())

        #expect(!probed)
        #expect(d.bool(forKey: AppLockManager.biometricsEnabledKey))
        #expect(!d.bool(forKey: AppLockManager.passcodeEnabledKey))
    }

    @Test("迁移一次性：用户随后关掉的开关不会在下次启动被重新打开")
    func migrateIsOneShot() {
        let (d, cleanup) = makeDefaults()
        defer { cleanup() }
        d.set(true, forKey: AppLockManager.legacyEnabledKey)
        AppLockManager.migrateLegacyEnabledFlag(in: d, biometryPresent: true)

        d.set(false, forKey: AppLockManager.biometricsEnabledKey)
        AppLockManager.migrateLegacyEnabledFlag(in: d, biometryPresent: true)

        #expect(!d.bool(forKey: AppLockManager.biometricsEnabledKey))
        #expect(d.bool(forKey: AppLockManager.passcodeEnabledKey))
    }

    // MARK: - 开启判定 / 冷启动

    @Test("任一开关开即视为应用锁开启；冷启动据此决定初始是否上锁")
    func isEnabledWhenEitherFlagOn() {
        let (d, cleanup) = makeDefaults()
        defer { cleanup() }

        #expect(!AppLockManager.isEnabled(in: d))
        #expect(!AppLockManager(defaults: d).isLocked)

        d.set(true, forKey: AppLockManager.passcodeEnabledKey)
        #expect(AppLockManager.isEnabled(in: d))
        #expect(AppLockManager(defaults: d).isLocked)

        d.set(false, forKey: AppLockManager.passcodeEnabledKey)
        d.set(true, forKey: AppLockManager.biometricsEnabledKey)
        #expect(AppLockManager.isEnabled(in: d))
        #expect(AppLockManager(defaults: d).isLocked)
    }

    @Test("开关属性读写落到注入的 UserDefaults")
    func flagAccessorsRoundTrip() {
        let (d, cleanup) = makeDefaults()
        defer { cleanup() }
        let manager = AppLockManager(defaults: d)

        manager.biometricsEnabled = true
        #expect(d.bool(forKey: AppLockManager.biometricsEnabledKey))
        #expect(manager.isEnabled)

        manager.biometricsEnabled = false
        manager.passcodeEnabled = true
        #expect(!d.bool(forKey: AppLockManager.biometricsEnabledKey))
        #expect(d.bool(forKey: AppLockManager.passcodeEnabledKey))
        #expect(manager.isEnabled)

        manager.passcodeEnabled = false
        #expect(!manager.isEnabled)
    }

    // MARK: - 上锁判定

    @Test("上锁判定矩阵：未开启不锁；开启后 inactive/background 都锁；仅前台验证中的 inactive 豁免")
    func shouldLockMatrix() {
        #expect(!AppLockManager.shouldLock(isEnabled: false, leavingTo: .background, foregroundAuthInFlight: false))
        #expect(!AppLockManager.shouldLock(isEnabled: false, leavingTo: .inactive, foregroundAuthInFlight: false))

        #expect(AppLockManager.shouldLock(isEnabled: true, leavingTo: .background, foregroundAuthInFlight: false))
        #expect(AppLockManager.shouldLock(isEnabled: true, leavingTo: .inactive, foregroundAuthInFlight: false))

        // 设置页面容验证弹窗造成的 inactive 不锁；真正进后台仍锁
        #expect(!AppLockManager.shouldLock(isEnabled: true, leavingTo: .inactive, foregroundAuthInFlight: true))
        #expect(AppLockManager.shouldLock(isEnabled: true, leavingTo: .background, foregroundAuthInFlight: true))
    }

    @Test("lockIfEnabled / unlockWithPasscode 实例行为")
    func lockIfEnabledInstance() {
        let (d, cleanup) = makeDefaults()
        defer { cleanup() }
        let manager = AppLockManager(defaults: d)

        manager.lockIfEnabled(leavingTo: .background)
        #expect(!manager.isLocked)

        manager.biometricsEnabled = true
        manager.lockIfEnabled(leavingTo: .inactive)
        #expect(manager.isLocked)

        manager.unlockWithPasscode()
        #expect(!manager.isLocked)

        manager.lockIfEnabled(leavingTo: .background)
        #expect(manager.isLocked)
    }

    // MARK: - 系统验证策略

    @Test("开了密码仅生物识别（App 密码兜底）；仅面容带设备密码回退（防软锁死）")
    func authPolicySelection() {
        #expect(AppLockManager.authPolicy(passcodeEnabled: true) == .deviceOwnerAuthenticationWithBiometrics)
        #expect(AppLockManager.authPolicy(passcodeEnabled: false) == .deviceOwnerAuthentication)
    }

    // MARK: - 连续输错递增锁定

    @Test("每满 5 次锁定，时长 30s→60s→120s→240s→封顶 300s")
    func attemptGuardEscalation() {
        var guardState = PasscodeAttemptGuard()
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        for _ in 0..<4 { guardState.registerFailure(now: t0) }
        #expect(guardState.activeLockout(now: t0) == nil)

        guardState.registerFailure(now: t0)
        #expect(guardState.activeLockout(now: t0) == t0.addingTimeInterval(30))

        for _ in 0..<5 { guardState.registerFailure(now: t0) }
        #expect(guardState.lockoutUntil == t0.addingTimeInterval(60))

        for _ in 0..<5 { guardState.registerFailure(now: t0) }
        #expect(guardState.lockoutUntil == t0.addingTimeInterval(120))

        for _ in 0..<5 { guardState.registerFailure(now: t0) }
        #expect(guardState.lockoutUntil == t0.addingTimeInterval(240))

        for _ in 0..<5 { guardState.registerFailure(now: t0) }
        #expect(guardState.lockoutUntil == t0.addingTimeInterval(300))

        for _ in 0..<5 { guardState.registerFailure(now: t0) }
        #expect(guardState.lockoutUntil == t0.addingTimeInterval(300))
    }

    @Test("锁定到期：activeLockout 为 nil、clearExpiredLockout 清空；未到期不清；计数不随到期重置")
    func attemptGuardExpiry() {
        var guardState = PasscodeAttemptGuard()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for _ in 0..<5 { guardState.registerFailure(now: t0) }

        #expect(guardState.activeLockout(now: t0.addingTimeInterval(29)) != nil)
        #expect(guardState.activeLockout(now: t0.addingTimeInterval(30)) == nil)

        guardState.clearExpiredLockout(now: t0.addingTimeInterval(10))
        #expect(guardState.lockoutUntil != nil)
        guardState.clearExpiredLockout(now: t0.addingTimeInterval(30))
        #expect(guardState.lockoutUntil == nil)

        for _ in 0..<5 { guardState.registerFailure(now: t0) }
        #expect(guardState.lockoutUntil == t0.addingTimeInterval(60))
    }

    // MARK: - 密码（Keychain，模拟器）

    @Test("设置/验证/清除密码往返；setPasscode 写后回读确认")
    func passcodeRoundTrip() {
        // 备份开发机模拟器上可能存在的真实密码，用例结束还原，避免把 App 置于「开关开而无密码」态
        let saved = KeychainStore.read(for: AppLockManager.pinKey)
        defer {
            if let saved {
                KeychainStore.save(saved, for: AppLockManager.pinKey, mirror: false)
            } else {
                AppLockManager.clearPasscode()
            }
        }

        AppLockManager.clearPasscode()
        #expect(!AppLockManager.hasPasscode)
        #expect(!AppLockManager.verifyPasscode("1234"))

        #expect(AppLockManager.setPasscode("1234"))
        #expect(AppLockManager.hasPasscode)
        #expect(AppLockManager.verifyPasscode("1234"))
        #expect(!AppLockManager.verifyPasscode("4321"))

        // 覆盖写：旧密码失效
        #expect(AppLockManager.setPasscode("0000"))
        #expect(!AppLockManager.verifyPasscode("1234"))
        #expect(AppLockManager.verifyPasscode("0000"))

        AppLockManager.clearPasscode()
        #expect(!AppLockManager.hasPasscode)
        #expect(!AppLockManager.verifyPasscode("0000"))
    }
}
