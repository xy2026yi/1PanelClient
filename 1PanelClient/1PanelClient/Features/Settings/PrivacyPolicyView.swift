//
//  PrivacyPolicyView.swift
//  1PanelClient
//
//  App 内隐私政策本地页（E5）：离线可读、不跳网页。内容与 git 跟踪的
// `doc/privacy-policy.md`（在线版/源头）同步维护；页底保留在线版入口。
// 页面用 L10n 词条构建，随应用内语言切换。
//

import SwiftUI

struct PrivacyPolicyView: View {
    /// 数据条目：标题 / 存放位置 · 用途 / 是否离开设备
    private struct DataItem {
        let title: String
        let detail: String
        let leaves: String
        let leavesIcon: String
    }

    private static let updated = "2026-09-06"

    private static let dataItems: [DataItem] = [
        .init(
            title: "面板地址、名称与 API 密钥",
            detail: "iOS 钥匙串 · 连接你自己的 1Panel 面板",
            leaves: "不离开设备（仅发往你配置的面板地址）",
            leavesIcon: "checkmark.circle"
        ),
        .init(
            title: "应用偏好设置",
            detail: "本机 UserDefaults · 记住你的设置",
            leaves: "不离开设备",
            leavesIcon: "checkmark.circle"
        ),
        .init(
            title: "应用锁密码",
            detail: "系统钥匙串 · 本机解锁校验",
            leaves: "不离开设备",
            leavesIcon: "checkmark.circle"
        ),
        .init(
            title: "面板数据本地缓存",
            detail: "本机 App 沙盒 · 离线展示最近一次快照",
            leaves: "不离开设备",
            leavesIcon: "checkmark.circle"
        ),
        .init(
            title: "诊断数据（MetricKit）",
            detail: "本机 Application Support · 崩溃与性能自诊断，保留 30 天",
            leaves: "仅当你主动分享导出时离开设备",
            leavesIcon: "checkmark.circle"
        ),
    ]

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("总则"))
                        .font(.headline)
                    Text(L10n.t("1PanelClient 是开源服务器管理面板 1Panel 的 iOS 客户端。"))
                    Text(L10n.t("本应用不收集、不上传任何用户数据——无内嵌分析 SDK、无广告、无追踪、无账号体系。"))
                }
                .font(.subheadline)
                .padding(.vertical, 4)
            } footer: {
                Text(L10n.f("最后更新：%@", Self.updated))
            }

            Section(L10n.t("数据存储与使用范围")) {
                ForEach(Array(Self.dataItems.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.t(item.title))
                            .font(.subheadline.weight(.medium))
                        Text(L10n.t(item.detail))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Label(L10n.t(item.leaves), systemImage: item.leavesIcon)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section(L10n.t("网络请求")) {
                Text(L10n.t("所有请求仅发往你本人添加的面板地址；应用不连接任何开发者或第三方服务器。"))
                    .font(.subheadline)
                Text(L10n.t("若你配置了 http:// 明文地址，界面会明示风险，并可在设置中开启「仅允许 HTTPS 连接」。"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.t("权限使用")) {
                Label(L10n.t("本地网络：用于连接局域网内的面板，仅在你主动测试连接时触发系统弹窗。"), systemImage: "wifi")
                    .font(.subheadline)
                Label(L10n.t("面容 ID / 触控 ID：仅用于应用锁解锁（可选功能），不上传任何生物信息。"), systemImage: "faceid")
                    .font(.subheadline)
            }

            Section(L10n.t("删除数据")) {
                Text(L10n.t("卸载应用即删除本机所有数据（Keychain 条目随卸载清除）；面板侧的 API 密钥可随时在 1Panel 面板「面板设置 → API 接口」中禁用或重新生成。"))
                    .font(.subheadline)
            }

            Section {
                if let url = URL(string: "https://github.com/xy2026yi/1PanelClient/issues") {
                    Link(destination: url) {
                        Label(L10n.t("通过 GitHub Issue 反馈"), systemImage: "ladybug")
                    }
                }
            } header: {
                Text(L10n.t("联系方式"))
            } footer: {
                if let url = URL(string: "https://github.com/xy2026yi/1PanelClient/blob/main/doc/privacy-policy.md") {
                    Link(L10n.t("查看在线版本"), destination: url)
                }
            }
        }
        .navigationTitle(L10n.t("隐私政策"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
