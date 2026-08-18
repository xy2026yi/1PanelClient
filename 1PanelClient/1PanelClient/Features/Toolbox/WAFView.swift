//
//  WAFView.swift
//  1PanelClient
//
//  WAF 管理：状态 / 全局规则开关 / IP黑白名单 / IP组
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
                ProgressView("加载中…")
            } else if let config = vm.config {
                content(config: config)
            } else if let err = vm.errorMessage {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button("重试") { Task { await vm.loadAll() } }
                }
            }
        }
        .navigationTitle("WAF")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.loadAll() }
        .task { await vm.loadAll() }
        .alert("提示", isPresented: Binding(
            get: { vm.successMessage != nil || vm.errorMessage != nil },
            set: { _ in vm.successMessage = nil; vm.errorMessage = nil }
        )) {
            Button("好的") { vm.successMessage = nil; vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? vm.successMessage ?? "")
        }
        .alert(
            pendingAction == "on" ? "启动" : "停止",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingAction = nil }
            Button("确认", role: .destructive) {
                let action = pendingAction
                pendingAction = nil
                if let action = action {
                    Task { await vm.toggleRule(scope: "Waf", state: action) }
                }
            }
        } message: {
            Text("将对 WAF 进行 \(pendingAction == "on" ? "启动" : "停止") 操作，是否继续？")
        }
    }

    @ViewBuilder
    private func content(config: WAFConfig) -> some View {
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

            // 黑名单
            Section {
                NavigationLink {
                    WAFIPRulesView(server: server, scope: "ipBlack", title: "IP")
                } label: {
                    ruleRow(icon: "hand.raised", color: .red, title: "IP", item: config.ipBlack, scope: "IPBlack")
                }
                NavigationLink {
                    WAFCommonRulesView(server: server, scope: "urlBlack", title: "URL")
                } label: {
                    ruleRow(icon: "link.badge.plus", color: .orange, title: "URL", item: config.urlBlack, scope: "UrlBlack")
                }
                NavigationLink {
                    WAFCommonRulesView(server: server, scope: "uaBlack", title: "User-Agent")
                } label: {
                    ruleRow(icon: "person.crop.square", color: .pink, title: "User-Agent", item: config.uaBlack, scope: "UaBlack")
                }
            } header: {
                SectionLabel(title: "黑名单", systemImage: "hand.raised")
            }

            // 白名单
            Section {
                NavigationLink {
                    WAFIPRulesView(server: server, scope: "ipWhite", title: "IP")
                } label: {
                    ruleRow(icon: "checkmark.shield", color: .green, title: "IP", item: config.ipWhite, scope: "IPWhite")
                }
                NavigationLink {
                    WAFCommonRulesView(server: server, scope: "urlWhite", title: "URL")
                } label: {
                    ruleRow(icon: "link.badge.plus", color: .teal, title: "URL", item: config.urlWhite, scope: "UrlWhite")
                }
                NavigationLink {
                    WAFCommonRulesView(server: server, scope: "uaWhite", title: "User-Agent")
                } label: {
                    ruleRow(icon: "person.crop.square", color: .mint, title: "User-Agent", item: config.uaWhite, scope: "UaWhite")
                }
            } header: {
                SectionLabel(title: "白名单", systemImage: "checkmark.shield")
            }

            // IP 组
            Section {
                NavigationLink {
                    WAFIPGroupsView(server: server)
                } label: {
                    Text("IP 组")
                }
            }

            // 频率限制
            Section {
                NavigationLink {
                    WAFCcSettingsView(server: server, config: config.cc, scope: "Cc", title: "访问频率限制")
                } label: {
                    ccToggleRow(title: "访问频率限制", item: config.cc, scope: "Cc")
                }
                NavigationLink {
                    WAFAttackCountSettingsView(server: server, config: config.attackCount, scope: "AttackCount", title: "攻击频率限制")
                } label: {
                    ccToggleRow(title: "攻击频率限制", item: config.attackCount, scope: "AttackCount")
                }
                NavigationLink {
                    WAFAttackCountSettingsView(server: server, config: config.notFoundCount, scope: "NotFoundCount", title: "404 频率限制")
                } label: {
                    ccToggleRow(title: "404 频率限制", item: config.notFoundCount, scope: "NotFoundCount")
                }
            } header: {
                SectionLabel(title: "频率限制", systemImage: "gauge.with.dots.needle.67percent")
            }

            // 配置
            Section {
                NavigationLink {
                    WAFConfigItemView(server: server, title: "恶意 IP 组", scope: "DefaultIpBlack", updateType: "blackIP", item: config.defaultIpBlack)
                } label: {
                    toggleRow(title: "恶意 IP 组", item: config.defaultIpBlack, scope: "DefaultIpBlack")
                }
                NavigationLink {
                    WAFConfigItemView(server: server, title: "蜘蛛 IP 池", scope: "AllowSpider", updateType: "spiderIP", item: config.allowSpider)
                } label: {
                    toggleRow(title: "蜘蛛 IP 池", item: config.allowSpider, scope: "AllowSpider")
                }
                NavigationLink {
                    WAFLocationUpdateView(server: server)
                } label: {
                    Text("IP 地址库")
                }
            } header: {
                SectionLabel(title: "配置", systemImage: "gearshape")
            }
        }
    }

    private func ruleRow(icon: String, color: Color, title: String, item: WAFRuleItem?, scope: String) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemName: icon, color: color, size: 34, cornerRadius: 8)
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
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { item?.isOn ?? false },
                    set: { newVal in
                        Task { await toggle(newVal) }
                    }
                )) {
                    Text("启用")
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
                        Text("更新")
                        Spacer()
                        if isUpdating { ProgressView() }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .alert("提示", isPresented: Binding(
            get: { successMessage != nil || errorMessage != nil },
            set: { _ in successMessage = nil; errorMessage = nil }
        )) {
            Button("好的") { successMessage = nil; errorMessage = nil }
        } message: {
            Text(errorMessage ?? successMessage ?? "")
        }
    }

    private func toggle(_ on: Bool) async {
        let req = WAFGlobalStateRequest(scope: scope, state: on ? "on" : "off")
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafConfigGlobalState.path, body: req, as: EmptyResponse.self)
            successMessage = on ? "已启用" : "已禁用"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func update() async {
        isUpdating = true
        let req = WAFLocationUpdateRequest(type: updateType)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafLocationUpdate.path, body: req, as: EmptyResponse.self)
            successMessage = "更新成功"
        } catch {
            errorMessage = error.localizedDescription
        }
        isUpdating = false
    }
}
