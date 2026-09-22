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
    /// 0 = 全局（config 块 + config/global/state 开关）；
    /// 非 0 = 网站级（POST /cdn {websiteID} 读取 + config/website/state 开关，
    /// 含源站保护配置），抓包 2026-09-22
    var websiteID: Int = 0
    /// 网站级状态变更（开关/保存）后回调，父页重拉网站配置刷新 CDN 行
    var onStateChanged: (() -> Void)? = nil

    @State private var type = "header"
    @State private var header = "x-real-ip"
    /// 网站级：当前站 CDN 开关（config 块/全局仍走 vm）
    @State private var siteCdnOn = false
    /// 源站保护（网站级）
    @State private var originProtection = WAFOriginProtection()
    @State private var ipGroups: [WAFIPGroupItem] = []
    @State private var showIPGroupPicker = false
    @State private var didLoadSite = false
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

    init(vm: WAFViewModel, server: ServerConfig, config: WAFCdnConfig?,
         websiteID: Int = 0, onStateChanged: (() -> Void)? = nil) {
        self.vm = vm
        self.server = server
        self.config = config
        self.websiteID = websiteID
        self.onStateChanged = onStateChanged
        self.client = APIClient.shared(for: server)
        _siteCdnOn = State(initialValue: config?.state == "on")
    }

    private var isOn: Bool { websiteID != 0 ? siteCdnOn : (vm.config?.cdn?.state == "on") }

    var body: some View {
        Form {
            Section {
                Toggle("CDN", isOn: Binding(
                    get: { isOn },
                    set: { newVal in
                        Task { await toggleCDN(on: newVal) }
                    }
                ))
                .disabled(vm.isOperating || (websiteID != 0 && !didLoadSite))
            }

            Section {
                OutlinedPicker(label: L10n.t("IP 来源"),
                               options: ["header", "headers", "xff1", "xff2", "xff3"],
                               selection: $type,
                               optionLabels: [
                                   "header": L10n.t("从HTTP Header中获取"),
                                   "headers": L10n.t("从Header列表中获取"),
                                   "xff1": L10n.t("获取X-Forwarded-For的上一级代理地址"),
                                   "xff2": L10n.t("获取X-Forwarded-For的上上一级代理地址"),
                                   "xff3": L10n.t("获取X-Forwarded-For的上上上一级代理地址"),
                               ])

                // 从HTTP Header中获取：可填写的 Header 名（其余方式回传当前值）
                if type == "header" {
                    OutlinedTextField(label: L10n.t("HTTP Header"), prompt: "x-real-ip",
                                      text: $header)
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
                            .font(.dataMonospacedCaption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 源站保护（网站级）：开关 + 回源 IP 组多选
            if websiteID != 0 {
                Section {
                    Toggle(L10n.t("源站保护"), isOn: Binding(
                        get: { originProtection.state == "on" },
                        set: { originProtection.state = $0 ? "on" : "off" }
                    ))
                    Button {
                        showIPGroupPicker = true
                    } label: {
                        HStack {
                            Text(L10n.t("CDN回源IP组"))
                            Spacer()
                            Text(ipGroupSummary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text(L10n.t("源站保护"))
                } footer: {
                    Text(L10n.t("仅允许所选 IP 组内的回源请求访问源站；未选择时保存不生效"))
                }
            }
        }
        .navigationTitle("CDN")
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .onAppear { loadConfig() }
        .task { if websiteID != 0 { await loadSiteCDN() } }
        .sheet(isPresented: $showIPGroupPicker) {
            IPGroupMultiPickerView(groups: ipGroups, selection: $originProtection.ipGroups)
        }
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

    /// CDN回源IP组 已选摘要（组名顿号连接 / 未选择）
    private var ipGroupSummary: String {
        originProtection.ipGroups.isEmpty
            ? L10n.t("未选择") : originProtection.ipGroups.joined(separator: "、")
    }

    /// 网站级：POST /cdn {websiteID} 读当前站配置（含源站保护），并拉 IP 组列表
    private func loadSiteCDN() async {
        do {
            let cfg: WAFCdnConfig = try await client.send(
                path: APIEndpoint.wafCdn.path,
                body: WAFWebsiteConfigRequest(id: websiteID),
                as: WAFCdnConfig.self)
            siteCdnOn = cfg.state == "on"
            type = cfg.type ?? "header"
            let h = cfg.header ?? ""
            header = h.isEmpty ? "x-real-ip" : h
            originProtection = cfg.originProtection ?? WAFOriginProtection()
            didLoadSite = true
        } catch {
            // 读取失败保持传入 config 的初值，页面仍可保存
            didLoadSite = true
        }
        // 回源 IP 组候选（all:true 返回裸数组，抓包 2026-09-22）
        if let groups: [WAFIPGroupItem] = try? await client.send(
            path: APIEndpoint.wafIPGroupSearch.path,
            body: WAFIPGroupSearchRequest(page: 1, pageSize: 100, type: "", name: "", all: true),
            as: [WAFIPGroupItem].self) {
            ipGroups = groups
        }
    }

    /// 开关：全局走 config/global/state；网站级走 config/website/state {scope:Cdn}
    private func toggleCDN(on: Bool) async {
        guard websiteID != 0 else {
            await vm.toggleRule(scope: "Cdn", state: on ? "on" : "off")
            return
        }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.wafWebsiteState.path,
                body: WAFWebsiteStateRequest(websiteID: websiteID, scope: "Cdn",
                                             state: on ? "on" : "off", mode: nil),
                as: EmptyResponse.self)
            siteCdnOn = on
            onStateChanged?()
        } catch {
            errorMessage = error.localizedDescription
        }
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
            websiteID: websiteID,
            originProtection: websiteID != 0 ? originProtection : nil
        )
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.wafCdnUpdate.path, body: req, as: EmptyResponse.self
            )
            successMessage = L10n.t("已保存")
            if websiteID != 0 {
                // 父页重拉网站配置：返回时 CDN 行的开关/类型徽章显示新值
                onStateChanged?()
            } else {
                // 刷新全局配置：返回上级时 CDN 行的类型徽章显示新值
                await vm.loadAll()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}


// MARK: - CDN 回源 IP 组多选（勾选即回写，关闭即确认）

private struct IPGroupMultiPickerView: View {
    let groups: [WAFIPGroupItem]
    @Binding var selection: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if groups.isEmpty {
                    Section {
                        ContentUnavailableView(
                            L10n.t("暂无 IP 组"),
                            systemImage: "shield.slash",
                            description: Text(L10n.t("请先在 WAF 的 IP 组管理中创建"))
                        )
                        .padding(.vertical, 20)
                    }
                } else {
                    Section {
                        ForEach(groups) { group in
                            Button {
                                toggle(group.name)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selection.contains(group.name)
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selection.contains(group.name)
                                                         ? Color.accentColor : .secondary)
                                        .font(.title3)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(group.name)
                                            .foregroundStyle(.primary)
                                        if let source = group.source, !source.isEmpty {
                                            Text(source)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } footer: {
                        Text(L10n.t("可多选；所选 IP 组内的回源请求将被放行"))
                    }
                }
            }
            .navigationTitle(L10n.t("CDN回源IP组"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("完成")) { dismiss() }
                        .bold()
                }
            }
        }
    }

    private func toggle(_ name: String) {
        if let idx = selection.firstIndex(of: name) {
            selection.remove(at: idx)
        } else {
            selection.append(name)
        }
    }
}
