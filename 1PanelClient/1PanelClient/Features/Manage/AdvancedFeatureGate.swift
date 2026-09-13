//
//  AdvancedFeatureGate.swift
//  1PanelClient
//
//  高级功能门禁：管理「高级功能」分组（整体）与 AI 的 vLLM / 模型下载
//  默认按服务器许可证显隐——licenses/search 存在 status=Bound（已绑定专业版）
//  即显示；未绑定 / 检测失败则隐藏（含「管理 → 编辑」列表，无法经偏好开启）。
//  关于页连点版本号 7 次可一次性解锁（设备级持久化），解锁后纳入
//  「管理 → 编辑」正常管控。
//
//  边界说明：客户端门禁只影响 UI 可见性，不是访问控制——真正的边界在
//  面板认证与 xpack license（服务端执行）；未绑定服务器上这些 API 本就拒绝。
//

import SwiftUI
import Combine

@MainActor
final class AdvancedFeatureGate: ObservableObject {
    static let shared = AdvancedFeatureGate()

    private static let unlockKey = "manage.advancedUnlocked"
    /// 按服务器 id 缓存的许可证绑定状态（冷启动先用缓存，进管理页再异步刷新）
    private static func licenseKey(_ serverID: UUID) -> String { "license.\(serverID.uuidString)" }

    /// 当前服务器是否已绑定专业版；nil = 未知（按未绑定处理，避免闪现后消失）
    @Published var serverLicensed: Bool?

    /// 设备级一次性解锁（连点 7 次；"知道有这些功能"是使用者属性，与服务器无关）
    var isUnlocked: Bool {
        UserDefaults.standard.bool(forKey: Self.unlockKey)
    }

    /// 门禁项：高级功能分组整体 + AI 的 vLLM / 模型下载（确认整体隐藏，不拆分）
    static let gatedItems: Set<ManageItem> = [
        .gpuMonitor, .websiteMonitor, .nodeManage, .wafMonitor,
        .aiVllm, .aiDownloader,
    ]

    static func isGated(_ item: ManageItem) -> Bool {
        gatedItems.contains(item)
    }

    /// 可见性：非门禁项走用户偏好；门禁项需「服务器已绑定 或 设备已解锁」再叠加偏好。
    /// 编辑列表等需要排除锁定项的场景传 prefsEnabled: true 即得纯门禁判定
    func shows(_ item: ManageItem, prefsEnabled: Bool) -> Bool {
        guard Self.isGated(item) else { return prefsEnabled }
        return (serverLicensed == true || isUnlocked) && prefsEnabled
    }

    func unlock() {
        UserDefaults.standard.set(true, forKey: Self.unlockKey)
        objectWillChange.send()
    }

    /// 检测服务器许可证（任一条 status=Bound 即已绑定）；失败按未绑定处理，
    /// 不落缓存（下次进管理页自动重试）——连点解锁的逃生门始终存在
    func refresh(server: ServerConfig) async {
        let key = Self.licenseKey(server.id)
        if UserDefaults.standard.object(forKey: key) != nil {
            serverLicensed = UserDefaults.standard.bool(forKey: key)
        } else {
            serverLicensed = nil
        }

        let client = APIClient.shared(for: server)
        do {
            let resp: PageResponse<LicenseItem> = try await client.send(
                path: APIEndpoint.licensesSearch.path,
                body: LicenseSearchRequest(page: 1, pageSize: 20),
                as: PageResponse<LicenseItem>.self)
            let licensed = (resp.items ?? []).contains { $0.isBound }
            serverLicensed = licensed
            UserDefaults.standard.set(licensed, forKey: key)
        } catch {
            guard !APIError.isCancellation(error) else { return }
            // 检测失败：保持缓存值（若有），否则视为未绑定
            if UserDefaults.standard.object(forKey: key) == nil {
                serverLicensed = false
            }
        }
    }
}
