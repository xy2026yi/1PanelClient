//
//  AppLock.swift
//  1PanelClient
//
//  应用锁：FaceID / TouchID（系统密码自动回退）。
//  开关存 UserDefaults；进入后台即锁，回前台/冷启动弹系统验证。
//  依据 doc/UI设计规范.md（服务器管理类 App 的安全底线）。
//

import Combine
import LocalAuthentication
import SwiftUI

@MainActor
final class AppLockManager: ObservableObject {
    static let enabledKey = "applock.enabled"

    @Published var isLocked: Bool

    private let defaults = UserDefaults.standard

    init() {
        // 冷启动：开关开启则先上锁，界面就绪后自动弹验证
        isLocked = defaults.bool(forKey: Self.enabledKey)
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    /// 设备是否设置了密码/生物识别（未设置则无法保护，设置页禁用开关）
    static var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// 当前设备的生物识别类型（锁屏图标用）
    static var biometryType: LABiometryType {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        return ctx.biometryType
    }

    /// 进入后台时调用：开关开启则上锁
    func lockIfEnabled() {
        if isEnabled { isLocked = true }
    }

    /// 弹系统验证（FaceID/TouchID，失败或无生物识别时自动回退设备密码）
    func unlock() async {
        guard isLocked else { return }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            // 设备未设密码：无法保护，直接放行（设置页已禁止在此设备开启）
            isLocked = false
            return
        }
        do {
            let ok = try await ctx.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: L10n.t("解锁 1PanelClient")
            )
            if ok { isLocked = false }
        } catch {
            // 用户取消/验证失败：保持锁定，等用户再试点「解锁」
        }
    }
}

// MARK: - 锁屏遮罩

struct LockScreenView: View {
    @EnvironmentObject private var lock: AppLockManager

    private var biometryIcon: String {
        switch AppLockManager.biometryType {
        case .faceID:               return "faceid"
        case .touchID:              return "touchid"
        case .opticID:              return "eye.square"
        default:                    return "lock.fill"
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: biometryIcon)
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(L10n.t("已锁定"))
                .font(.title3.bold())
            Text(L10n.t("验证以继续使用"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                Task { await lock.unlock() }
            } label: {
                Label(L10n.t("解锁"), systemImage: "lock.open")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .transition(.opacity)
    }
}
