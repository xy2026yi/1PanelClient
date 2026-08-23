//
//  WAFWebsiteSettingsView.swift
//  1PanelClient
//
//  WAF 网站设置：按网站下发 WAF 开关 / 执行策略（防护·观察）/ 检测强度（标准·严格）/
//  频率限制（CC 模式与参数）。全站列表来自 waf/websites/search（含各开关当前值），
//  切换走 config/website/state，CC 规则走 website/rule/cc。
//  CC 参数经 config/website 读取当前站真实值回填表单（避免默认值覆盖服务器配置）。
//  严格模式依赖全局配置 strict.state=on，未开启时置灰。
//

import SwiftUI

struct WAFWebsiteSettingsView: View {
    let server: ServerConfig

    @State private var websites: [WAFWebsiteItem] = []
    @State private var selectedID: Int?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var successMessage: String?
    /// 全局配置的 strict.state（"off" 时网站不可切严格模式）
    @State private var globalStrictOn = false

    // CC 参数：默认与面板 Web 端一致起填，选中网站后经 config/website 回填真实值
    @State private var ccMode = "uri"
    @State private var ccDuration = "10"
    @State private var ccThreshold = "200"
    @State private var ccBlockTime = "600"
    /// CC 回填竞态令牌：快速切换网站时丢弃过期响应，避免旧值覆盖新选中站
    @State private var ccLoadToken = 0

    // 确认弹窗：关闭 WAF / 切观察模式
    @State private var pendingCloseWAF = false
    @State private var pendingObservation = false
    @State private var isOperating = false

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient(server: server)
    }

    private var selected: WAFWebsiteItem? {
        websites.first { $0.id == selectedID }
    }

    private var wafOn: Bool { selected?.wafState == "on" }

    var body: some View {
        Form {
            if isLoading {
                Section { LoadingStateView(compact: true).padding(.vertical, 20) }
            } else if websites.isEmpty {
                Section {
                    // 空列表 ≠ 加载失败：有错误才给重试，否则是面板确实没有网站
                    if let errorMessage {
                        ContentUnavailableView {
                            Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(errorMessage)
                        } actions: {
                            Button(L10n.t("重试")) { Task { await load() } }
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        ContentUnavailableView(
                            L10n.t("暂无网站"),
                            systemImage: "sitemap",
                            description: Text(L10n.t("在面板创建网站后，可在此为其配置 WAF 防护。"))
                        )
                    }
                }
            } else {
                websiteSection
                protectionSection
                ccSection
            }
        }
        .navigationTitle(L10n.t("网站设置"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .task { await load() }
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { successMessage != nil || errorMessage != nil },
            set: { _ in successMessage = nil; errorMessage = nil }
        )) {
            Button(L10n.t("好的"), role: .cancel) { successMessage = nil; errorMessage = nil }
        } message: {
            Text(errorMessage ?? successMessage ?? "")
        }
        // 关闭 WAF 确认
        .alert(L10n.t("关闭 WAF"), isPresented: $pendingCloseWAF) {
            Button(L10n.t("取消"), role: .cancel) { pendingCloseWAF = false }
            Button(L10n.t("确认"), role: .destructive) {
                Task { await setWebsiteState(scope: "Waf", state: "off") }
            }
        } message: {
            Text(L10n.t("关闭 WAF 会使网站失去防护，是否继续"))
        }
        // 切观察模式确认
        .alert(L10n.t("观察模式"), isPresented: $pendingObservation) {
            Button(L10n.t("取消"), role: .cancel) { pendingObservation = false }
            Button(L10n.t("确认"), role: .destructive) {
                Task { await setWebsiteState(scope: "Waf", state: "on", mode: "observation") }
            }
        } message: {
            Text(L10n.t("开启观察模式后，所有 WAF 命中都只记录日志，不会拦截请求，是否继续？"))
        }
    }

    // MARK: - 分区

    /// 网站下拉：选中后下方各开关带入该站当前值，CC 参数回填真实值
    private var websiteSection: some View {
        Section {
            Picker(L10n.t("选择网站"), selection: Binding(
                get: { selectedID },
                set: {
                    selectedID = $0
                    Task { await loadWebsiteConfig() }
                }
            )) {
                ForEach(websites) { site in
                    Text(site.primaryDomain ?? "#\(site.id)").tag(Optional(site.id))
                }
            }
        }
    }

    private var protectionSection: some View {
        Section {
            Toggle("WAF", isOn: Binding(
                get: { wafOn },
                set: { newVal in
                    if newVal {
                        Task { await setWebsiteState(scope: "Waf", state: "on") }
                    } else {
                        pendingCloseWAF = true
                    }
                }
            ))
            .disabled(isOperating)

            Picker(L10n.t("执行策略"), selection: Binding(
                get: { selected?.wafMode == "observation" ? "observation" : "protection" },
                set: { mode in
                    if mode == "observation" {
                        pendingObservation = true
                    } else {
                        Task { await setWebsiteState(scope: "Waf", state: "on", mode: "protection") }
                    }
                }
            )) {
                Text(L10n.t("防护模式")).tag("protection")
                Text(L10n.t("观察模式")).tag("observation")
            }
            .pickerStyle(.segmented)
            .segmentedPickerRow()
            .disabled(isOperating || !wafOn)

            Picker(L10n.t("检测强度"), selection: Binding(
                get: { selected?.strictState == "on" ? "strict" : "standard" },
                set: { newValue in
                    let state = newValue == "strict" ? "on" : "off"
                    Task { await setWebsiteState(scope: "Strict", state: state) }
                }
            )) {
                Text(L10n.t("标准模式")).tag("standard")
                Text(L10n.t("严格模式")).tag("strict")
            }
            .pickerStyle(.segmented)
            .segmentedPickerRow()
            // 全局 strict 未开启时严格模式不可选
            .disabled(isOperating || !wafOn || !globalStrictOn)
        } header: {
            Text(L10n.t("防护"))
        } footer: {
            if !globalStrictOn {
                Text(L10n.t("严格模式需在全局配置中开启"))
            }
        }
    }

    private var ccSection: some View {
        Section {
            Toggle(L10n.t("频率限制"), isOn: Binding(
                get: { selected?.ccState == "on" },
                set: { newVal in
                    Task { await toggleCC(on: newVal) }
                }
            ))
            .disabled(isOperating || !wafOn)

            Picker(L10n.t("模式"), selection: $ccMode) {
                Text(L10n.t("URL 模式")).tag("uri")
                Text(L10n.t("全局模式")).tag("global")
            }
            .disabled(selected?.ccState != "on")

            HStack {
                Text(L10n.t("周期"))
                Spacer()
                TextField("", text: $ccDuration)
                    .keyboardType(.numberPad)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                Text(L10n.t("秒")).foregroundStyle(.secondary)
            }
            HStack {
                Text(L10n.t("频率"))
                Spacer()
                TextField("", text: $ccThreshold)
                    .keyboardType(.numberPad)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                Text(L10n.t("次")).foregroundStyle(.secondary)
            }
            HStack {
                Text(L10n.t("封禁时间"))
                Spacer()
                TextField("", text: $ccBlockTime)
                    .keyboardType(.numberPad)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                Text(L10n.t("秒")).foregroundStyle(.secondary)
            }

            Button(L10n.t("保存")) {
                Task { await saveCC() }
            }
            .disabled(selected?.ccState != "on" || isOperating)
        } header: {
            Text(L10n.t("频率限制"))
        }
    }

    // MARK: - 数据与请求

    /// 分页拉全量网站。面板对 WebsiteConfigSearch.PageSize 有 max 校验
    ///（实测 200 报「Field validation for 'PageSize' on the 'max' tag」），
    /// 沿用 Web 端每页 20 的实证安全值翻页取全
    private func fetchAllWebsites() async throws -> [WAFWebsiteItem] {
        var result: [WAFWebsiteItem] = []
        var page = 1
        let pageSize = 20
        while page <= 50 {
            let resp: PageResponse<WAFWebsiteItem> = try await client.send(
                path: APIEndpoint.wafWebsitesSearch.path,
                body: WAFWebsiteSearchRequest(page: page, pageSize: pageSize, name: ""),
                as: PageResponse<WAFWebsiteItem>.self
            )
            let items = resp.items ?? []
            result += items
            let total = resp.total ?? 0
            if items.isEmpty || items.count < pageSize || result.count >= total { break }
            page += 1
        }
        return result
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        struct StrictOnly: Decodable {
            let strict: StrictState?
            struct StrictState: Decodable { let state: String? }
        }
        do {
            websites = try await fetchAllWebsites()
            if selectedID == nil { selectedID = websites.first?.id }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        // 全局 strict 开关（失败按未开启处理，严格模式置灰）
        if let g: StrictOnly = try? await client.send(
            path: APIEndpoint.wafConfigGlobal.path,
            method: APIEndpoint.wafConfigGlobal.method,
            as: StrictOnly.self
        ) {
            globalStrictOn = (g.strict?.state == "on")
        }
        await loadWebsiteConfig()
    }

    /// 读取当前站的网站配置，回填 CC 表单真实参数。
    /// 失败静默保持现值（表单仍可手动编辑提交）；token 防快速切换网站的过期回填
    private func loadWebsiteConfig() async {
        guard let id = selectedID else { return }
        ccLoadToken += 1
        let token = ccLoadToken
        do {
            let cfg: WAFWebsiteConfig = try await client.send(
                path: APIEndpoint.wafConfigWebsite.path,
                body: WAFWebsiteConfigRequest(id: id),
                as: WAFWebsiteConfig.self
            )
            guard token == ccLoadToken else { return }
            if let cc = cfg.cc {
                ccMode = cc.mode ?? "uri"
                ccDuration = String(cc.duration ?? 10)
                ccThreshold = String(cc.threshold ?? 200)
                ccBlockTime = String(cc.ipBlockTime ?? 600)
            }
        } catch {
            // 无单独错误提示：CC 表单维持默认值，避免干扰主流程
        }
    }

    /// 网站级开关/模式切换；成功后重拉列表保持选中
    private func setWebsiteState(scope: String, state: String, mode: String? = nil) async {
        guard let site = selected else { return }
        isOperating = true
        defer { isOperating = false }
        let req = WAFWebsiteStateRequest(websiteID: site.id, scope: scope, state: state, mode: mode)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.wafWebsiteState.path, body: req, as: EmptyResponse.self
            )
            await reloadKeepingSelection()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 开频率限制 = state(Cc,on) + 附带一条 rule/cc 全量规则；关 = 仅 state(Cc,off)
    private func toggleCC(on: Bool) async {
        guard let site = selected else { return }
        isOperating = true
        defer { isOperating = false }
        do {
            let stateReq = WAFWebsiteStateRequest(websiteID: site.id, scope: "Cc", state: on ? "on" : "off", mode: nil)
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.wafWebsiteState.path, body: stateReq, as: EmptyResponse.self
            )
            if on {
                let ccReq = ccRuleRequest(state: "on")
                let _: EmptyResponse = try await client.send(
                    path: APIEndpoint.wafWebsiteRuleCC.path, body: ccReq, as: EmptyResponse.self
                )
            }
            await reloadKeepingSelection()
        } catch {
            errorMessage = error.localizedDescription
            // 半途失败（state 已改而 rule 未提交）也要重载，保持 UI 与服务端一致
            await reloadKeepingSelection()
        }
    }

    /// 保存 CC 参数（rule/cc 全量规则）
    private func saveCC() async {
        isOperating = true
        defer { isOperating = false }
        do {
            let req = ccRuleRequest(state: "on")
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.wafWebsiteRuleCC.path, body: req, as: EmptyResponse.self
            )
            successMessage = L10n.t("已保存")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func ccRuleRequest(state: String) -> WAFWebsiteCCRuleRequest {
        WAFWebsiteCCRuleRequest(
            state: state,
            code: 0,
            action: "deny",
            type: "cc",
            res: "",
            ipBlock: "on",
            ipBlockTime: Int(ccBlockTime) ?? 600,
            threshold: Int(ccThreshold) ?? 200,
            duration: Int(ccDuration) ?? 10,
            mode: ccMode,
            websites: selected.map { [$0.id] } ?? []
        )
    }

    /// 状态切换后重拉网站列表（选中不变），并同步刷新 CC 表单回填值
    private func reloadKeepingSelection() async {
        let keep = selectedID
        if let all = try? await fetchAllWebsites() {
            websites = all
        }
        selectedID = websites.first { $0.id == keep }?.id ?? websites.first?.id
        await loadWebsiteConfig()
    }
}
