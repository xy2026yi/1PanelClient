//
//  WAFView.swift
//  1PanelClient
//
//  WAF 管理：状态 / 黑白名单 / 全局配置
//

import SwiftUI
import Combine

// MARK: - WAF 主视图

struct WAFView: View {
    @StateObject private var vm: WAFViewModel
    let server: ServerConfig
    @State private var pendingAction: String?

    init(server: ServerConfig) {
        self.server = server
        _vm = StateObject(wrappedValue: WAFViewModel(server: server))
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.config == nil {
                ProgressView(L10n.t("加载中…"))
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
        .task { await vm.loadAll() }
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { vm.successMessage != nil || vm.errorMessage != nil },
            set: { _ in vm.successMessage = nil; vm.errorMessage = nil }
        )) {
            Button(L10n.t("好的")) { vm.successMessage = nil; vm.errorMessage = nil }
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

            // 监控
            Section {
                NavigationLink {
                    WAFOverviewView(server: server)
                } label: {
                    entryRow(icon: "chart.bar.xaxis", color: .blue, title: L10n.t("概览"))
                }
                NavigationLink {
                    WAFInterceptLogsView(server: server)
                } label: {
                    entryRow(icon: "exclamationmark.triangle", color: .orange, title: L10n.t("拦截记录"))
                }
                NavigationLink {
                    WAFBlockRecordsView(server: server)
                } label: {
                    entryRow(icon: "lock.shield", color: .red, title: L10n.t("封锁记录"))
                }
            } header: {
                SectionLabel(title: L10n.t("监控"), systemImage: "chart.pie")
            }

            Section {
                NavigationLink {
                    WAFBlackWhiteView(vm: vm, server: server)
                } label: {
                    entryRow(icon: "shield.lefthalf.filled", color: .red, title: L10n.t("黑白名单"))
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
            IconBadge(systemName: icon, color: color, size: 34, cornerRadius: 8)
            Text(title)
        }
    }
}
