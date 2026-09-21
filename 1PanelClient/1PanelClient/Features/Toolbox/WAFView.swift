//
//  WAFView.swift
//  1PanelClient
//
//  WAF 模块（方案二）：状态 / 监控（许可证管控） / 黑白名单 / 网站设置 / 全局配置；
//  与原「WAF 监控」合并——监控三板块（概览/拦截/封锁）作为「监控」子入口进入
//

import SwiftUI
import Combine

// MARK: - WAF 主视图

struct WAFView: View {
    @StateObject private var vm: WAFViewModel
    let server: ServerConfig
    @State private var pendingAction: String?
    /// 许可证门禁：无许可证时隐藏「监控」子入口（状态/黑白名单/网站设置/全局设置常显）
    @ObservedObject private var gate = AdvancedFeatureGate.shared
    /// 应用商店 VM（OpenResty 未安装时的安装入口，安装流程复用应用商店页面）
    @StateObject private var installStoreVM: AppStoreViewModel

    init(server: ServerConfig) {
        self.server = server
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(key: ManageItem.waf.storeKey(server: server)) {
            WAFViewModel(server: server)
        })
        _installStoreVM = StateObject(wrappedValue: AppStoreViewModel(server: server))
    }

    var body: some View {
        Group {
            if vm.openRestyNotInstalled {
                openRestyInstallPrompt
            } else if vm.isLoading && vm.config == nil {
                LoadingStateView()
            } else if vm.config != nil {
                content
            } else if let err = vm.errorMessage {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button(L10n.t("重试")) { Task { await vm.loadAll() } }
                }
            }
        }
        .navigationTitle("WAF")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.loadAll() }
        .task {
            await PageVMStore.shared.autoRefresh(vm: vm) { await vm.loadAll() }
            await gate.refresh(server: server)
        }
        // 从安装入口装完 OpenResty 后自动重查，返回本页即见 WAF 内容
        .onReceive(NotificationCenter.default.publisher(for: .installCompleted)) { _ in
            Task { await vm.loadAll() }
        }
        .alert(L10n.t("提示"), isPresented: Binding(
            // OpenResty 未安装时 WAF 接口必然报「global.json 不存在」类错误，
            // 属预期内：只抑制 errorMessage（页面显示安装引导），成功提示不受影响
            get: {
                vm.successMessage != nil || (vm.errorMessage != nil && !vm.openRestyNotInstalled)
            },
            set: { _ in vm.successMessage = nil; vm.errorMessage = nil }
        )) {
            Button(L10n.t("好的"), role: .cancel) { vm.successMessage = nil; vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? vm.successMessage ?? "")
        }
        .alert(
            pendingAction == "on" ? L10n.t("启动") : L10n.t("停止"),
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            )
        ) {
            Button(L10n.t("取消"), role: .cancel) { pendingAction = nil }
            Button(L10n.t("确认"), role: .destructive) {
                Haptic.warning()
                let action = pendingAction
                pendingAction = nil
                if let action = action {
                    Task { await vm.toggleRule(scope: "Waf", state: action) }
                }
            }
        } message: {
            Text(L10n.f("将对 WAF 进行 %@ 操作，是否继续？", pendingAction == "on" ? L10n.t("启动") : L10n.t("停止")))
        }
    }

    // MARK: OpenResty 未安装引导

    /// WAF 依赖 OpenResty：未安装时整页安装引导（与网站页共用组件）
    private var openRestyInstallPrompt: some View {
        OpenRestyInstallPrompt(
            storeVM: installStoreVM,
            message: L10n.t("WAF 功能依赖 OpenResty，请先安装后再使用")
        )
    }

    private var content: some View {
        List {
            // 状态
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WAF").font(.headline)
                        if let v = vm.status?.openrestyVersion {
                            Text("OpenResty \(v)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { vm.status?.open ?? false },
                        set: { newVal in
                            pendingAction = newVal ? "on" : "off"
                        }
                    ))
                    .labelsHidden()
                    .disabled(vm.isOperating)
                }
            }

            // 子入口（方案二顺序）：监控（许可证管控）→ 黑白名单 → 网站设置 → 全局配置
            Section {
                if gate.gatedAllowed {
                    NavigationLink {
                        WAFMonitorView(server: server)
                    } label: {
                        entryRow(icon: "chart.bar.xaxis", color: .purple, title: L10n.t("监控"))
                    }
                }
                NavigationLink {
                    WAFBlackWhiteView(vm: vm, server: server)
                } label: {
                    entryRow(icon: "shield.lefthalf.filled", color: .red, title: L10n.t("黑白名单"))
                }
                NavigationLink {
                    WAFWebsiteSettingsView(server: server)
                } label: {
                    entryRow(icon: "at", color: .teal, title: L10n.t("网站设置"))
                }
                NavigationLink {
                    WAFGlobalConfigView(vm: vm, server: server)
                } label: {
                    entryRow(icon: "globe", color: .blue, title: L10n.t("全局配置"))
                }
            }
        }
    }

    private func entryRow(icon: String, color: Color, title: String) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemName: icon, color: color, size: 34, cornerRadius: Radius.small)
            Text(title)
        }
    }
}
