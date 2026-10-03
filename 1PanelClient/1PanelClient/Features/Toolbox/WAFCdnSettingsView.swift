//
//  WAFCdnSettingsView.swift
//  1PanelClient
//
//  WAF 自定义规则 - CDN：开关走 config/global/state {scope:Cdn}；
//  真实 IP 获取方式（header / headers / xff1-3）与自定义 Header 名经
//  cdn/update 全量提交（rules 固定 Header 列表回传，websiteID=0 全局）。
//

import SwiftUI
import os

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
    /// CDN 开关（/cdn 读到的实际状态；加载前用快照/全局配置种子）
    @State private var cdnOn = false
    /// 源站保护（网站级）
    @State private var originProtection = WAFOriginProtection()
    @State private var ipGroups: [WAFIPGroupItem] = []
    /// 站级 /cdn 响应带回的 rules（保存时优先于传入 config，防止把全局 rules 写给单站）
    @State private var siteRules: [String]? = nil
    @State private var showIPGroupPicker = false
    /// /cdn 读取完成（含失败）；站级开关在完成前禁用
    @State private var didLoadCDN = false
    /// /cdn 读取代数令牌：开关切换成功后自增，读取期间发生过切换的慢返回
    /// 整体作废——防止用切换前的旧 state 覆盖本地 cdnOn（界面与服务器相反）
    @State private var cdnLoadToken = 0
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
        _cdnOn = State(initialValue: config?.state == "on")
        // 先用父页快照即时回填（不闪默认值），.task 再拉服务端最新覆盖
        _type = State(initialValue: config?.type ?? "header")
        let h = config?.header ?? ""
        _header = State(initialValue: h.isEmpty ? "x-real-ip" : h)
    }

    /// 开关以 /cdn 读到的实际状态为准（didLoadCDN 后恒用 cdnOn——config/global
    /// 的 cdn 块不随 cdn/update 更新，state 同样可能滞后）；加载完成前：
    /// 全局回落 vm.config，站级用快照种子（站级此时开关本就禁用）
    private var isOn: Bool {
        if didLoadCDN { return cdnOn }
        return websiteID != 0 ? cdnOn : (vm.config?.cdn?.state == "on")
    }

    var body: some View {
        Form {
            Section {
                Toggle("CDN", isOn: Binding(
                    get: { isOn },
                    set: { newVal in
                        Task { await toggleCDN(on: newVal) }
                    }
                ))
                .disabled(vm.isOperating || (websiteID != 0 && !didLoadCDN))
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
                        // plain 样式命中区只有文字部分，补全行矩形命中
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
                        .contentShape(Rectangle())
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
        // 父页快照不随保存/外部改动刷新，进入与下拉都以服务端最新为准
        .task { await refresh() }
        .refreshable { await refresh() }
        .sheet(isPresented: $showIPGroupPicker) {
            IPGroupMultiPickerView(groups: $ipGroups, selection: $originProtection.ipGroups)
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

    /// 进入 / 下拉刷新：读当前 CDN 配置。权威读取是 POST /cdn（websiteID=0
    /// 即全局，抓包 2026-09-26：config/global 的 cdn 块不随 cdn/update 更新，
    /// 网页端同样走此接口）；网站级另拉回源 IP 组候选
    private func refresh() async {
        await loadCDNConfig()
        if websiteID != 0 { await loadIPGroups() }
    }

    private func loadCDNConfig() async {
        cdnLoadToken += 1
        let token = cdnLoadToken
        do {
            let cfg: WAFCdnConfig = try await client.send(
                path: APIEndpoint.wafCdn.path,
                body: WAFCdnRequest(websiteID: websiteID),
                as: WAFCdnConfig.self)
            applyLoaded(cfg, token: token)
        } catch {
            // 读取失败保持传入 config 的初值，页面仍可保存
            applyLoaded(nil, token: token)
        }
    }

    /// /cdn 结果落地：读取期间发生过开关切换（令牌不一致）则整体作废，
    /// 仅解除加载禁用；未被用户编辑过的字段（仍等于 init 种子）才回填，
    /// 在途输入不被服务端旧值冲掉
    private func applyLoaded(_ cfg: WAFCdnConfig?, token: Int) {
        defer { didLoadCDN = true }
        guard token == cdnLoadToken else { return }
        cdnOn = cfg?.state == "on"
        if type == (config?.type ?? "header") {
            type = cfg?.type ?? "header"
        }
        let seedHeader: String = {
            let h = config?.header ?? ""
            return h.isEmpty ? "x-real-ip" : h
        }()
        if header == seedHeader {
            let h = cfg?.header ?? ""
            header = h.isEmpty ? "x-real-ip" : h
        }
        if originProtection == WAFOriginProtection() {
            originProtection = cfg?.originProtection ?? WAFOriginProtection()
        }
        siteRules = cfg?.rules
    }

    /// 回源 IP 组候选（all:true 返回裸数组，抓包 2026-09-22；仅网站级展示）
    private func loadIPGroups() async {
        do {
            let groups: [WAFIPGroupItem] = try await client.send(
                path: APIEndpoint.wafIPGroupSearch.path,
                body: WAFIPGroupSearchRequest(page: 1, pageSize: 100, type: "", name: "", all: true),
                as: [WAFIPGroupItem].self)
            ipGroups = groups
        } catch {
            // 候选拉取失败不阻断主流程，但打 DEBUG 日志定位「静默空列表」
            #if DEBUG
            Logger(subsystem: "com.xy.1PanelClient.debug", category: "waf")
                .warning("[WAF-DEBUG] 回源IP组候选拉取失败: \(error.localizedDescription, privacy: .public)")
            #endif
        }
    }

    /// CDN回源IP组 已选摘要（组名顿号连接 / 未选择）
    private var ipGroupSummary: String {
        originProtection.ipGroups.isEmpty
            ? L10n.t("未选择") : originProtection.ipGroups.joined(separator: "、")
    }

    /// 开关：全局走 config/global/state（vm.toggleRule 无成功回执、错误提示在
    /// 被覆盖的父页不可见，故自行请求：成功本地置位并轻刷 vm 配置，失败本页
    /// 提示回滚）；网站级走 config/website/state {scope:Cdn}
    private func toggleCDN(on: Bool) async {
        if websiteID == 0 {
            do {
                let _: EmptyResponse = try await client.send(
                    path: APIEndpoint.wafConfigGlobalState.path,
                    body: WAFGlobalStateRequest(scope: "Cdn", state: on ? "on" : "off"),
                    as: EmptyResponse.self)
                cdnOn = on
                // 作废在途的旧 /cdn 读取：其 state 是切换前的旧值
                cdnLoadToken += 1
                await vm.loadConfig()
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.wafWebsiteState.path,
                body: WAFWebsiteStateRequest(websiteID: websiteID, scope: "Cdn",
                                             state: on ? "on" : "off", mode: nil),
                as: EmptyResponse.self)
            cdnOn = on
            cdnLoadToken += 1
            onStateChanged?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let rules = (siteRules?.isEmpty == false) ? siteRules!
            : ((config?.rules?.isEmpty == false) ? config!.rules! : Self.defaultHeaders)
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
                // 轻量刷新全局配置：返回上级时 CDN 行的类型徽标显示新值
                await vm.loadConfig()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}


// MARK: - CDN 回源 IP 组多选（勾选即回写，关闭即确认）

private struct IPGroupMultiPickerView: View {
    /// 用 Binding 而非值传入：.sheet 内容闭包捕获的是旧 body 的值快照
    ///（实测 iOS 26：进入页面时 ipGroups 已拉到 2 组，弹层仍渲染空列表），
    /// Binding 在渲染时从活状态解引用，弹层恒读到最新候选
    @Binding var groups: [WAFIPGroupItem]
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
                                // plain 样式命中区只有文字部分，补全行矩形命中
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
                                .contentShape(Rectangle())
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
