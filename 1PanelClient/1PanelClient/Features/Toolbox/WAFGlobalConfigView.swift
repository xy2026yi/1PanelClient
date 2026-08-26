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

                // 默认规则：内置规则集（scope 与面板 Web 端一致），
                // 可点入查看/开关/应用（rule/common/*）
                Section {
                    NavigationLink {
                        WAFCommonRulesView(server: server, scope: "args", title: L10n.t("参数规则"), builtin: true)
                    } label: {
                        toggleRow(title: L10n.t("参数规则"), item: config.args, scope: "Args")
                    }
                    NavigationLink {
                        WAFCommonRulesView(server: server, scope: "defaultUrlBlack", title: L10n.t("URL规则"), builtin: true)
                    } label: {
                        toggleRow(title: L10n.t("URL规则"), item: config.defaultUrlBlack, scope: "DefaultUrlBlack")
                    }
                    NavigationLink {
                        WAFCommonRulesView(server: server, scope: "methodWhite", title: L10n.t("HTTP规则"), builtin: true)
                    } label: {
                        toggleRow(title: L10n.t("HTTP规则"), item: config.methodWhite, scope: "MethodWhite")
                    }
                    NavigationLink {
                        WAFCommonRulesView(server: server, scope: "cookie", title: L10n.t("Cookie规则"), builtin: true)
                    } label: {
                        toggleRow(title: L10n.t("Cookie规则"), item: config.cookie, scope: "Cookie")
                    }
                    NavigationLink {
                        WAFCommonRulesView(server: server, scope: "header", title: L10n.t("Header规则"), builtin: true)
                    } label: {
                        toggleRow(title: L10n.t("Header规则"), item: config.header, scope: "Header")
                    }
                    NavigationLink {
                        WAFCommonRulesView(server: server, scope: "defaultUaBlack", title: L10n.t("User-Agent规则"), builtin: true)
                    } label: {
                        toggleRow(title: L10n.t("User-Agent规则"), item: config.defaultUaBlack, scope: "DefaultUaBlack")
                    }
                } header: {
                    SectionLabel(title: L10n.t("默认规则"), systemImage: "checkmark.shield")
                }

                // 其他：SQL/XSS/严格模式为全局开关（无规则列表）
                Section {
                    toggleRow(title: L10n.t("SQL注入防御"), item: config.sql, scope: "Sql")
                    toggleRow(title: L10n.t("XSS防御"), item: config.xss, scope: "Xss")
                    toggleRow(title: L10n.t("严格模式"), item: config.strict, scope: "Strict")
                } header: {
                    SectionLabel(title: L10n.t("其他"), systemImage: "ellipsis.circle")
                } footer: {
                    Text(L10n.t("严格模式开启后，各网站才能在检测强度中选择严格模式。"))
                }

                // 自定义规则
                Section {
                    NavigationLink {
                        WAFCommonRulesView(server: server, scope: "fileExt", title: L10n.t("文件上传限制"))
                    } label: {
                        toggleRow(title: L10n.t("文件上传限制"), item: config.fileExt, scope: "FileExt")
                    }
                    NavigationLink {
                        WAFCdnSettingsView(vm: vm, server: server, config: config.cdn)
                    } label: {
                        HStack {
                            Text("CDN")
                            Spacer()
                            if config.cdn?.state == "on" {
                                Text(config.cdn?.type?.uppercased() ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    SectionLabel(title: L10n.t("自定义规则"), systemImage: "slider.horizontal.3")
                }
            }
        }
        .navigationTitle(L10n.t("全局配置"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.loadAll() }
        .localToast(message: $vm.successMessage)
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
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
        .localToast(message: $successMessage)
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
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
