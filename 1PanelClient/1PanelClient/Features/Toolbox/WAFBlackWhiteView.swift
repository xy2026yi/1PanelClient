//
//  WAFBlackWhiteView.swift
//  1PanelClient
//
//  WAF 黑白名单：黑名单 / 白名单 / IP 组
//

import SwiftUI

// MARK: - 黑白名单

struct WAFBlackWhiteView: View {
    @ObservedObject var vm: WAFViewModel
    let server: ServerConfig

    var body: some View {
        List {
            if let config = vm.config {
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
                    SectionLabel(title: L10n.t("黑名单"), systemImage: "hand.raised")
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
                    SectionLabel(title: L10n.t("白名单"), systemImage: "checkmark.shield")
                }

                // IP 组
                Section {
                    NavigationLink {
                        WAFIPGroupsView(server: server)
                    } label: {
                        Text(L10n.t("IP 组"))
                    }
                }
            }
        }
        .navigationTitle(L10n.t("黑白名单"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.loadAll() }
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { vm.successMessage != nil || vm.errorMessage != nil },
            set: { _ in vm.successMessage = nil; vm.errorMessage = nil }
        )) {
            Button(L10n.t("好的"), role: .cancel) { vm.successMessage = nil; vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? vm.successMessage ?? "")
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
}
