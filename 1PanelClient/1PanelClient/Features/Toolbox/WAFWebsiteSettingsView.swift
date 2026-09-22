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
    @ObservedObject var vm: WAFViewModel
    let server: ServerConfig

    @State private var websites: [WAFWebsiteItem] = []
    @State private var selectedID: Int?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var successMessage: String?
    /// 全局配置的 strict.state（"off" 时网站不可切严格模式）
    @State private var globalStrictOn = false
    /// 当前站的完整配置（config/website：按站规则开关 + CC 参数回填）
    @State private var siteConfig: WAFWebsiteConfig?
    /// 站配置回填竞态令牌：快速切换网站时丢弃过期响应
    @State private var ccLoadToken = 0

    // 确认弹窗：关闭 WAF / 切观察模式
    @State private var pendingCloseWAF = false
    @State private var pendingObservation = false
    @State private var isOperating = false

    private let client: APIClient

    init(vm: WAFViewModel, server: ServerConfig) {
        self.vm = vm
        self.server = server
        self.client = APIClient.shared(for: server)
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
                            systemImage: "globe",
                            description: Text(L10n.t("在面板创建网站后，可在此为其配置 WAF 防护。"))
                        )
                    }
                }
            } else {
                websiteSection
                protectionSection
                ccLinkSection
                defaultRulesSection
                customRulesSection
                otherSection
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
                Haptic.warning()
                Task { await setWebsiteState(scope: "Waf", state: "off") }
            }
        } message: {
            Text(L10n.t("关闭 WAF 会使网站失去防护，是否继续"))
        }
        // 切观察模式确认
        .alert(L10n.t("观察模式"), isPresented: $pendingObservation) {
            Button(L10n.t("取消"), role: .cancel) { pendingObservation = false }
            Button(L10n.t("确认"), role: .destructive) {
                Haptic.warning()
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
            OutlinedPicker(label: L10n.t("选择网站"),
                           options: websites.map { String($0.id) },
                           selection: websiteText,
                           optionLabels: Dictionary(uniqueKeysWithValues:
                               websites.map { (String($0.id), $0.primaryDomain ?? "#\($0.id)") }))
        }
    }

    /// 选中网站 Int? ↔ String（OutlinedPicker 用；选中即加载该站配置）
    private var websiteText: Binding<String> {
        Binding<String>(
            get: {
                if let id = selectedID, websites.contains(where: { $0.id == id }) {
                    return String(id)
                }
                return String(websites.first?.id ?? 0)
            },
            set: { newValue in
                selectedID = Int(newValue)
                Task { await loadWebsiteConfig() }
            }
        )
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

            OutlinedPicker(label: L10n.t("执行策略"),
                           options: ["protection", "observation"],
                           selection: Binding(
                               get: { selected?.wafMode == "observation" ? "observation" : "protection" },
                               set: { mode in
                                   if mode == "observation" {
                                       pendingObservation = true
                                   } else {
                                       Task { await setWebsiteState(scope: "Waf", state: "on", mode: "protection") }
                                   }
                               }),
                           optionLabels: ["protection": L10n.t("防护模式"),
                                          "observation": L10n.t("观察模式")])
                .disabled(isOperating || !wafOn)

            OutlinedPicker(label: L10n.t("检测强度"),
                           options: ["standard", "strict"],
                           selection: Binding(
                               get: { selected?.strictState == "on" ? "strict" : "standard" },
                               set: { newValue in
                                   let state = newValue == "strict" ? "on" : "off"
                                   Task { await setWebsiteState(scope: "Strict", state: state) }
                               }),
                           optionLabels: ["standard": L10n.t("标准模式"),
                                          "strict": L10n.t("严格模式")])
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

    /// 频率限制：跳转独立配置页（开关/模式/参数/保存）
    private var ccLinkSection: some View {
        Section {
            NavigationLink {
                if let site = selected {
                    WAFWebsiteCCPage(server: server, site: site) {
                        Task { await reloadKeepingSelection() }
                    }
                }
            } label: {
                HStack {
                    Text(L10n.t("频率限制"))
                    Spacer()
                    Text(selected?.ccState == "on" ? L10n.t("已启用") : L10n.t("未启用"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .disabled(selected == nil)
        } header: {
            Text(L10n.t("频率限制"))
        }
    }

    /// 默认规则（与全局配置同款六组，按站开关；点入查看规则集）
    private var defaultRulesSection: some View {
        Section {
            ruleToggleRow(title: L10n.t("参数规则"), item: siteConfig?.args, scope: "Args")
            ruleToggleRow(title: L10n.t("URL规则"), item: siteConfig?.defaultUrlBlack, scope: "DefaultUrlBlack")
            ruleToggleRow(title: L10n.t("HTTP规则"), item: siteConfig?.methodWhite, scope: "MethodWhite")
            ruleToggleRow(title: L10n.t("Cookie规则"), item: siteConfig?.cookie, scope: "Cookie")
            ruleToggleRow(title: L10n.t("Header规则"), item: siteConfig?.header, scope: "Header")
            ruleToggleRow(title: L10n.t("User-Agent规则"), item: siteConfig?.defaultUaBlack, scope: "DefaultUaBlack")
        } header: {
            SectionLabel(title: L10n.t("默认规则"), systemImage: "checkmark.shield")
        }
    }

    /// 自定义规则（与全局配置一致：文件上传限制 + CDN）
    private var customRulesSection: some View {
        Section {
            NavigationLink {
                WAFCommonRulesView(server: server, scope: "fileExt", title: L10n.t("文件上传限制"))
            } label: {
                ruleToggleRow(title: L10n.t("文件上传限制"), item: siteConfig?.fileExt, scope: "FileExt")
            }
            NavigationLink {
                WAFCdnSettingsView(vm: vm, server: server, config: vm.config?.cdn)
            } label: {
                HStack {
                    Text("CDN")
                    Spacer()
                    if vm.config?.cdn?.state == "on" {
                        Text(vm.config?.cdn?.type?.uppercased() ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            SectionLabel(title: L10n.t("自定义规则"), systemImage: "slider.horizontal.3")
        }
    }

    /// 其他（与全局配置一致，但无严格模式——网站级严格模式在「防护」分区）
    private var otherSection: some View {
        Section {
            ruleToggleRow(title: L10n.t("SQL注入防御"), item: siteConfig?.sql, scope: "Sql")
            ruleToggleRow(title: L10n.t("XSS防御"), item: siteConfig?.xss, scope: "Xss")
        } header: {
            SectionLabel(title: L10n.t("其他"), systemImage: "ellipsis.circle")
        }
    }

    /// 按站规则开关行（状态来自 config/website，切换走 website/state）
    private func ruleToggleRow(title: String, item: WAFRuleItem?, scope: String) -> some View {
        Toggle(isOn: Binding(
            get: { item?.isOn ?? false },
            set: { newVal in
                Task { await setWebsiteState(scope: scope, state: newVal ? "on" : "off") }
            }
        )) {
            Text(title)
        }
        .disabled(isOperating || !wafOn)
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

    /// 读取当前站的完整配置（按站规则开关；CC 参数由频率限制子页自行回填）。
    /// 失败静默保持现值；token 防快速切换网站的过期回填
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
            siteConfig = cfg
        } catch {
            // 无单独错误提示：开关维持现值，避免干扰主流程
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

// MARK: - 网站级频率限制配置页（跳转进入，右上角保存）

/// 开关 + 模式 + 周期/频率/封禁参数：进入时经 config/website 回填当前站真实值；
/// 开启 = state(Cc,on) + 附带 rule/cc 全量规则；关 = 仅 state(Cc,off)；保存参数 = rule/cc
struct WAFWebsiteCCPage: View {
    let server: ServerConfig
    let site: WAFWebsiteItem
    /// 开关/保存成功后回调（父页重拉列表与配置）
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var ccMode = "uri"
    @State private var ccDuration = "10"
    @State private var ccThreshold = "200"
    @State private var ccBlockTime = "600"
    @State private var isOn: Bool
    @State private var isOperating = false
    @State private var successMessage: String?
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig, site: WAFWebsiteItem, onChanged: @escaping () -> Void) {
        self.server = server
        self.site = site
        self.onChanged = onChanged
        self.client = APIClient.shared(for: server)
        _isOn = State(initialValue: site.ccState == "on")
    }

    var body: some View {
        Form {
            Section {
                Toggle(L10n.t("频率限制"), isOn: Binding(
                    get: { isOn },
                    set: { newVal in
                        isOn = newVal
                        Task { await toggleCC(on: newVal) }
                    }
                ))
                .disabled(isOperating)

                OutlinedPicker(label: L10n.t("模式"), options: ["uri", "global"],
                               selection: $ccMode,
                               optionLabels: ["uri": L10n.t("URL 模式"),
                                              "global": L10n.t("全局模式")])
                .disabled(!isOn)

                OutlinedUnitField(label: L10n.t("周期"), unit: L10n.t("秒"),
                                  text: $ccDuration)
                OutlinedUnitField(label: L10n.t("频率"), unit: L10n.t("次"),
                                  text: $ccThreshold)
                OutlinedUnitField(label: L10n.t("封禁时间"), unit: L10n.t("秒"),
                                  text: $ccBlockTime)
            } header: {
                Text(site.primaryDomain ?? L10n.t("频率限制"))
            } footer: {
                Text(L10n.t("保存后立即生效；周期内超过频率的访问将按封禁时间拦截"))
            }
        }
        .navigationTitle(L10n.t("频率限制"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await saveCC() }
                } label: {
                    if isOperating { ProgressView() } else { Text(L10n.t("保存")).bold() }
                }
                .disabled(isOperating || !isOn)
            }
        }
        .task { await loadParams() }
        .localToast(message: $successMessage)
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// 进入时回填当前站 CC 真实参数（失败静默保持默认）
    private func loadParams() async {
        guard let cfg: WAFWebsiteConfig = try? await client.send(
            path: APIEndpoint.wafConfigWebsite.path,
            body: WAFWebsiteConfigRequest(id: site.id),
            as: WAFWebsiteConfig.self
        ), let cc = cfg.cc else { return }
        ccMode = cc.mode ?? "uri"
        ccDuration = String(cc.duration ?? 10)
        ccThreshold = String(cc.threshold ?? 200)
        ccBlockTime = String(cc.ipBlockTime ?? 600)
    }

    /// 开频率限制 = state(Cc,on) + 附带一条 rule/cc 全量规则；关 = 仅 state(Cc,off)
    private func toggleCC(on: Bool) async {
        isOperating = true
        defer { isOperating = false }
        do {
            let stateReq = WAFWebsiteStateRequest(websiteID: site.id, scope: "Cc",
                                                  state: on ? "on" : "off", mode: nil)
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.wafWebsiteState.path, body: stateReq, as: EmptyResponse.self)
            if on {
                let _: EmptyResponse = try await client.send(
                    path: APIEndpoint.wafWebsiteRuleCC.path, body: ccRuleRequest(),
                    as: EmptyResponse.self)
            }
            onChanged()
        } catch {
            isOn = !on
            errorMessage = error.localizedDescription
            onChanged()
        }
    }

    /// 保存 CC 参数（rule/cc 全量规则）
    private func saveCC() async {
        isOperating = true
        defer { isOperating = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.wafWebsiteRuleCC.path, body: ccRuleRequest(),
                as: EmptyResponse.self)
            successMessage = L10n.t("已保存")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func ccRuleRequest() -> WAFWebsiteCCRuleRequest {
        WAFWebsiteCCRuleRequest(
            state: "on",
            code: 0,
            action: "deny",
            type: "cc",
            res: "",
            ipBlock: "on",
            ipBlockTime: Int(ccBlockTime) ?? 600,
            threshold: Int(ccThreshold) ?? 200,
            duration: Int(ccDuration) ?? 10,
            mode: ccMode,
            websites: [site.id]
        )
    }
}
