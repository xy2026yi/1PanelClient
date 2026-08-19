//
//  AppStoreSettingsView.swift
//  1PanelClient
//
//  应用商店设置：卸载/升级/安装时的默认勾选项。
//  设置持久化到服务器（POST /api/v2/core/settings/apps/store/update），
//  安装/升级/卸载弹窗会读取这些值作为初始勾选状态。
//

import SwiftUI

struct AppStoreSettingsView: View {
    @ObservedObject var vm: AppsViewModel

    var body: some View {
        Group {
            if vm.isLoadingAppStoreConfig && vm.appStoreConfig == nil {
                ProgressView(L10n.t("加载中…"))
            } else {
                Form {
                    Section {
                        Text(L10n.t("以下选项将作为 升级 / 卸载 / 安装 应用时的默认勾选项，可在操作时手动修改。"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Section(L10n.t("卸载应用")) {
                        settingToggle(
                            title: L10n.t("删除备份"),
                            scope: .uninstallDeleteBackup,
                            isOn: vm.appStoreConfig?.isUninstallDeleteBackup ?? false
                        )
                        settingToggle(
                            title: L10n.t("删除镜像"),
                            scope: .uninstallDeleteImage,
                            isOn: vm.appStoreConfig?.isUninstallDeleteImage ?? false
                        )
                    }

                    Section(L10n.t("升级应用")) {
                        settingToggle(
                            title: L10n.t("升级前备份应用"),
                            scope: .upgradeBackup,
                            isOn: vm.appStoreConfig?.isUpgradeBackup ?? true
                        )
                        settingToggle(
                            title: L10n.t("升级后删除旧镜像"),
                            scope: .upgradeDeleteImage,
                            isOn: vm.appStoreConfig?.isUpgradeDeleteImage ?? false
                        )
                    }

                    Section(L10n.t("安装应用")) {
                        settingToggle(
                            title: L10n.t("默认打开端口外部访问"),
                            scope: .installAllowPort,
                            isOn: vm.appStoreConfig?.isInstallAllowPort ?? false
                        )
                    }
                }
            }
        }
        .navigationTitle(L10n.t("应用设置"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if vm.appStoreConfig == nil {
                await vm.loadAppStoreConfig()
            }
        }
    }

    /// 单个设置开关：get 读 VM 配置值，set 时立即 POST 更新并本地同步。
    @ViewBuilder
    private func settingToggle(title: String, scope: AppStoreSettingScope, isOn: Bool) -> some View {
        Toggle(isOn: Binding(
            get: { isOn },
            set: { newValue in
                Task { await vm.updateAppStoreSetting(scope: scope, enabled: newValue) }
            }
        )) {
            Text(title)
        }
    }
}
