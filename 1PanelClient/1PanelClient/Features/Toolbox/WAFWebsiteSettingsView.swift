//
//  WAFWebsiteSettingsView.swift
//  1PanelClient
//
//  WAF 网站设置：按网站下发 WAF 开关 / 执行策略（防护·观察）/ 检测强度（标准·严格）/
//  频率限制（CC 模式与参数）。全站列表来自 waf/websites/search（含各开关当前值），
//  切换走 config/website/state，CC 规则走 website/rule/cc。
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

    // CC 参数（默认与面板 Web 端一致；服务端无单独读取接口，按默认值起填）
    @State private var ccMode = "uri"
    @State private var ccDuration = "10"
    @State private var ccThreshold = "200"
    @State private var ccBlockTime = "600"

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
                    ContentUnavailableView {
                        Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage ?? L10n.t("无数据"))
                    } actions: {
                        Button(L10n.t("重试")) { Task { await load() } }
                            .buttonStyle(.borderedProminent)
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

    /// 网站下拉：选中后下方各开关带入该站当前值
    private var websiteSection: some View {
        Section {
            Picker(L10n.t("选择网站"), selection: Binding(
                get: { selectedID },
                set: { selectedID = $0 }
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
            .disabled(isOperating || !wafOn)
            // 全局 strict 未开启时严格模式不可选
            .disabled(!globalStrictOn)
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

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        struct StrictOnly: Decodable {
            let strict: StrictState?
            struct StrictState: Decodable { let state: String? }
        }
        do {
            let resp: PageResponse<WAFWebsiteItem> = try await client.send(
                path: APIEndpoint.wafWebsitesSearch.path,
                body: WAFWebsiteSearchRequest(page: 1, pageSize: 200, name: ""),
                as: PageResponse<WAFWebsiteItem>.self
            )
            websites = resp.items ?? []
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

    /// 状态切换后重拉网站列表（选中不变）
    private func reloadKeepingSelection() async {
        let keep = selectedID
        if let resp: PageResponse<WAFWebsiteItem> = try? await client.send(
            path: APIEndpoint.wafWebsitesSearch.path,
            body: WAFWebsiteSearchRequest(page: 1, pageSize: 200, name: ""),
            as: PageResponse<WAFWebsiteItem>.self
        ) {
            websites = resp.items ?? []
        }
        selectedID = websites.first { $0.id == keep }?.id ?? websites.first?.id
    }
}
