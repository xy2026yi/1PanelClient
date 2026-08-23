//
//  WAFCdnSettingsView.swift
//  1PanelClient
//
//  WAF 自定义规则 - CDN：开关走 config/global/state {scope:Cdn}；
//  真实 IP 获取方式（header / headers / xff1-3）与自定义 Header 名经
//  cdn/update 全量提交（rules 固定 Header 列表回传，websiteID=0 全局）。
//

import SwiftUI

struct WAFCdnSettingsView: View {
    @ObservedObject var vm: WAFViewModel
    let server: ServerConfig
    let config: WAFCdnConfig?

    @State private var type = "header"
    @State private var header = "x-real-ip"
    @State private var isSaving = false
    @State private var successMessage: String?
    @State private var errorMessage: String?

    private let client: APIClient

    /// 固定的 CDN Header 列表（提交与展示共用；服务端有值时优先回传其本值）
    private static let defaultHeaders = [
        "x-forwarded-for", "x-real-ip", "x-forwarded", "forwarded-for",
        "forwarded", "true-client-ip", "client-ip", "ali-cdn-real-ip",
        "cdn-src-ip", "cdn-real-ip", "cf-connecting-ip", "x-cluster-client-ip",
        "wl-proxy-client-ip", "proxy-client-ip",
    ]

    init(vm: WAFViewModel, server: ServerConfig, config: WAFCdnConfig?) {
        self.vm = vm
        self.server = server
        self.config = config
        self.client = APIClient(server: server)
    }

    private var isOn: Bool { vm.config?.cdn?.state == "on" }

    var body: some View {
        Form {
            Section {
                Toggle("CDN", isOn: Binding(
                    get: { isOn },
                    set: { newVal in
                        Task { await vm.toggleRule(scope: "Cdn", state: newVal ? "on" : "off") }
                    }
                ))
                .disabled(vm.isOperating)
            }

            Section {
                Picker(L10n.t("真实IP获取方式"), selection: $type) {
                    Text(L10n.t("从HTTP Header中获取")).tag("header")
                    Text(L10n.t("从Header列表中获取")).tag("headers")
                    Text(L10n.t("获取X-Forwarded-For的上一级代理地址")).tag("xff1")
                    Text(L10n.t("获取X-Forwarded-For的上上一级代理地址")).tag("xff2")
                    Text(L10n.t("获取X-Forwarded-For的上上上一级代理地址")).tag("xff3")
                }

                // 从HTTP Header中获取：可填写的 Header 名（其余方式回传当前值）
                if type == "header" {
                    TextField(L10n.t("HTTP Header"), text: $header)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            } footer: {
                // 对齐面板 Web 端：开关不限制编辑，保存时原样携带当前开关状态
                if type == "header" {
                    Text(L10n.t("CDN 将客户端真实 IP 写入该 Header，WAF 从中读取。"))
                }
            }

            // 从Header列表中获取：展示固定的 Header 列表
            if type == "headers" {
                Section(L10n.t("CDN Headers")) {
                    ForEach(Self.defaultHeaders, id: \.self) { h in
                        Text(h)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("CDN")
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .onAppear { loadConfig() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("保存")) {
                    Task { await save() }
                }
                .disabled(isSaving)
            }
        }
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { successMessage != nil || errorMessage != nil },
            set: { _ in successMessage = nil; errorMessage = nil }
        )) {
            Button(L10n.t("好的"), role: .cancel) { successMessage = nil; errorMessage = nil }
        } message: {
            Text(errorMessage ?? successMessage ?? "")
        }
    }

    private func loadConfig() {
        type = config?.type ?? "header"
        let h = config?.header ?? ""
        header = h.isEmpty ? "x-real-ip" : h
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let rules = (config?.rules?.isEmpty == false) ? config!.rules! : Self.defaultHeaders
        let h = header.trimmingCharacters(in: .whitespaces)
        let req = WAFCdnUpdateRequest(
            rules: rules,
            // 开关不限制编辑，保存时原样携带当前开关状态（对齐面板 Web 端）
            state: isOn ? "on" : "off",
            type: type,
            header: h.isEmpty ? "x-real-ip" : h,
            websiteID: 0
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.wafCdnUpdate.path, body: req, as: EmptyResponse.self
            )
            successMessage = L10n.t("已保存")
            // 刷新全局配置：返回上级时 CDN 行的类型徽章显示新值
            await vm.loadAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
