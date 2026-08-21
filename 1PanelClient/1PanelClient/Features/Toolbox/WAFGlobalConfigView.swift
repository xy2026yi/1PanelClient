//
//  WAFGlobalConfigView.swift
//  1PanelClient
//
//  WAF 全局配置：频率限制 / 配置
//

import SwiftUI

// MARK: - 全局配置

struct WAFGlobalConfigView: View {
    @ObservedObject var vm: WAFViewModel
    let server: ServerConfig

    var body: some View {
        List {
            if let config = vm.config {
                // 频率限制
                Section {
                    NavigationLink {
                        WAFCcSettingsView(server: server, config: config.cc, scope: "Cc", title: L10n.t("访问频率限制"))
                    } label: {
                        ccToggleRow(title: L10n.t("访问频率限制"), item: config.cc, scope: "Cc")
                    }
                    NavigationLink {
                        WAFAttackCountSettingsView(server: server, config: config.attackCount, scope: "AttackCount", title: L10n.t("攻击频率限制"))
                    } label: {
                        ccToggleRow(title: L10n.t("攻击频率限制"), item: config.attackCount, scope: "AttackCount")
                    }
                    NavigationLink {
                        WAFAttackCountSettingsView(server: server, config: config.notFoundCount, scope: "NotFoundCount", title: L10n.t("404 频率限制"))
                    } label: {
                        ccToggleRow(title: L10n.t("404 频率限制"), item: config.notFoundCount, scope: "NotFoundCount")
                    }
                } header: {
                    SectionLabel(title: L10n.t("频率限制"), systemImage: "gauge.with.dots.needle.67percent")
                }

                // 配置
                Section {
                    NavigationLink {
                        WAFConfigItemView(server: server, title: L10n.t("恶意 IP 组"), scope: "DefaultIpBlack", updateType: "blackIP", item: config.defaultIpBlack)
                    } label: {
                        toggleRow(title: L10n.t("恶意 IP 组"), item: config.defaultIpBlack, scope: "DefaultIpBlack")
                    }
                    NavigationLink {
                        WAFSpiderPoolView(server: server, item: config.allowSpider)
                    } label: {
                        toggleRow(title: L10n.t("蜘蛛 IP 池"), item: config.allowSpider, scope: "AllowSpider")
                    }
                    NavigationLink {
                        WAFLocationUpdateView(server: server)
                    } label: {
                        Text(L10n.t("IP 地址库"))
                    }
                } header: {
                    SectionLabel(title: L10n.t("配置"), systemImage: "gearshape")
                }
            }
        }
        .navigationTitle(L10n.t("全局配置"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.loadAll() }
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { vm.successMessage != nil || vm.errorMessage != nil },
            set: { _ in vm.successMessage = nil; vm.errorMessage = nil }
        )) {
            Button(L10n.t("好的")) { vm.successMessage = nil; vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? vm.successMessage ?? "")
        }
    }

    private func toggleRow(title: String, item: WAFRuleItem?, scope: String) -> some View {
        Toggle(isOn: Binding(
            get: { item?.isOn ?? false },
            set: { newVal in
                Task { await vm.toggleRule(scope: scope, state: newVal ? "on" : "off") }
            }
        )) {
            Text(title)
        }
        .disabled(vm.isOperating)
    }

    private func ccToggleRow(title: String, item: WAFCcRuleConfig?, scope: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle("", isOn: Binding(
                get: { item?.isOn ?? false },
                set: { newVal in
                    Task { await vm.toggleRule(scope: scope, state: newVal ? "on" : "off") }
                }
            ))
            .labelsHidden()
            .disabled(vm.isOperating)
        }
    }
}


// MARK: - 配置项（开关 + 更新）

struct WAFConfigItemView: View {
    let server: ServerConfig
    let title: String
    let scope: String
    let updateType: String
    let item: WAFRuleItem?

    @State private var isUpdating = false
    /// item 不可变，开关需本地镜像，成功保持、失败回滚，否则弹窗触发重绘时回跳
    @State private var isEnabled: Bool
    @State private var successMessage: String?
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig, title: String, scope: String, updateType: String, item: WAFRuleItem?) {
        self.server = server
        self.title = title
        self.scope = scope
        self.updateType = updateType
        self.item = item
        self.client = APIClient(server: server)
        _isEnabled = State(initialValue: item?.isOn ?? false)
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { isEnabled },
                    set: { newVal in
                        isEnabled = newVal
                        Task { await toggle(newVal) }
                    }
                )) {
                    Text(L10n.t("启用"))
                }
            } header: {
                Text(title)
            }

            Section {
                Button {
                    Task { await update() }
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(L10n.t("更新"))
                        Spacer()
                        if isUpdating { ProgressView() }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { successMessage != nil || errorMessage != nil },
            set: { _ in successMessage = nil; errorMessage = nil }
        )) {
            Button(L10n.t("好的")) { successMessage = nil; errorMessage = nil }
        } message: {
            Text(errorMessage ?? successMessage ?? "")
        }
    }

    private func toggle(_ on: Bool) async {
        let req = WAFGlobalStateRequest(scope: scope, state: on ? "on" : "off")
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafConfigGlobalState.path, body: req, as: EmptyResponse.self)
            successMessage = on ? L10n.t("已启用") : L10n.t("已禁用")
        } catch {
            isEnabled = !on
            errorMessage = error.localizedDescription
        }
    }

    private func update() async {
        isUpdating = true
        let req = WAFLocationUpdateRequest(type: updateType)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafLocationUpdate.path, body: req, as: EmptyResponse.self)
            successMessage = L10n.t("更新成功")
        } catch {
            errorMessage = error.localizedDescription
        }
        isUpdating = false
    }
}
