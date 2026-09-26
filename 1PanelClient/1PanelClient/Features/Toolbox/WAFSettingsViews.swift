//
//  WAFSettingsViews.swift
//  1PanelClient
//

import SwiftUI

// MARK: - CC 访问频率限制设置

struct WAFCcSettingsView: View {
    let server: ServerConfig
    let config: WAFCcRuleConfig?
    let scope: String
    let title: String

    @State private var mode = "global"
    @State private var duration = "10"
    @State private var threshold = "100"
    @State private var ipBlockTime = "600"
    @State private var isSaving = false
    @State private var successMessage: String?
    @State private var errorMessage: String?
    @State private var showMenu = false
    /// 「应用到网站」多选弹层（与默认规则-参数规则的应用规则一致）
    @State private var showApply = false
    /// 进入时从服务端拉取的最新配置；父页快照在保存后不会刷新，回填与保存以此为准
    @State private var latestConfig: WAFCcRuleConfig?

    private let client: APIClient

    init(server: ServerConfig, config: WAFCcRuleConfig?, scope: String, title: String) {
        self.server = server
        self.config = config
        self.scope = scope
        self.title = title
        self.client = APIClient.shared(for: server)
        // 先用父页快照即时回填（不闪默认值），.task 再拉服务端最新覆盖
        if let c = config {
            _mode = State(initialValue: c.mode ?? "global")
            _duration = State(initialValue: String(c.duration ?? 10))
            _threshold = State(initialValue: String(c.threshold ?? 100))
            _ipBlockTime = State(initialValue: String(c.ipBlockTime ?? 600))
        }
    }

    var body: some View {
        Form {
            Section(L10n.t("模式")) {
                OutlinedPicker(label: L10n.t("模式"), options: ["uri", "global"],
                               selection: $mode,
                               optionLabels: ["uri": L10n.t("URL 模式"),
                                              "global": L10n.t("全局模式")])
            }
            Section(L10n.t("参数")) {
                OutlinedUnitField(label: L10n.t("周期"), unit: L10n.t("秒"),
                                  text: $duration)
                OutlinedUnitField(label: L10n.t("频率"), unit: L10n.t("次"),
                                  text: $threshold)
                OutlinedUnitField(label: L10n.t("封禁时间"), unit: L10n.t("秒"),
                                  text: $ipBlockTime)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshConfig() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EllipsisMenuButton(isLoading: isSaving) {
                    withAnimation(Motion.fast) { showMenu.toggle() }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if showMenu {
                EllipsisMenuPopup(entries: [
                    .action(title: L10n.t("保存默认"), isDisabled: isSaving) {
                        Task {
                            do {
                                try await save(applyWebsite: nil)
                                successMessage = L10n.t("已保存")
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    },
                    .action(title: L10n.t("应用到网站"), isDisabled: isSaving) { showApply = true },
                ]) {
                    withAnimation(Motion.fast) { showMenu = false }
                }
            }
        }
        .sheet(isPresented: $showApply) {
            WAFWebsiteApplySheet(server: server) {
                successMessage = L10n.t("已应用到网站")
            } apply: { ids in
                try await save(applyWebsite: true, websites: ids)
            }
        }
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

    /// 进入时拉取服务端最新配置回填（父页快照保存后不刷新，返回再进会是旧值）；
    /// 失败静默保持快照值
    private func refreshConfig() async {
        guard let cfg: WAFConfig = try? await client.send(
            path: APIEndpoint.wafConfigGlobal.path, method: "GET", as: WAFConfig.self
        ), let c = cfg.cc else { return }
        latestConfig = c
        mode = c.mode ?? "global"
        duration = String(c.duration ?? 10)
        threshold = String(c.threshold ?? 100)
        ipBlockTime = String(c.ipBlockTime ?? 600)
    }

    /// 保存 CC 规则；applyWebsite=true 时携带所选网站 ID（空省略 = 面板按全部
    /// 网站处理）。成功/失败提示由调用方呈现（菜单路径走 toast+alert，应用弹层
    /// 内部自行提示，避免弹层覆盖时重复弹窗）
    private func save(applyWebsite: Bool?, websites: [Int]? = nil) async throws {
        isSaving = true
        defer { isSaving = false }
        let base = latestConfig ?? config
        let req = WAFCcRuleSaveRequest(
            state: base?.state ?? "off",
            code: base?.code ?? 0,
            action: base?.action ?? "deny",
            type: "cc",
            res: "",
            ipBlock: base?.ipBlock ?? "on",
            ipBlockTime: Int(ipBlockTime) ?? 600,
            threshold: Int(threshold) ?? 100,
            duration: Int(duration) ?? 10,
            mode: mode,
            scope: scope,
            applyWebsite: applyWebsite,
            websites: websites
        )
        let _: EmptyResponse = try await client.send(path: APIEndpoint.wafRuleCc.path, body: req, as: EmptyResponse.self)
    }
}

// MARK: - 攻击频率 / 404 频率限制设置

struct WAFAttackCountSettingsView: View {
    let server: ServerConfig
    let config: WAFCcRuleConfig?
    let scope: String
    let title: String

    @State private var duration = "60"
    @State private var threshold = "10"
    @State private var ipBlockTime = "3000"
    @State private var isSaving = false
    @State private var successMessage: String?
    @State private var errorMessage: String?
    /// 进入时从服务端拉取的最新配置；父页快照在保存后不会刷新，回填与保存以此为准
    @State private var latestConfig: WAFCcRuleConfig?

    private let client: APIClient
    private var ruleType: String { scope == "NotFoundCount" ? "notFoundCount" : "attackCount" }
    private var defaultCode: Int { scope == "NotFoundCount" ? 403 : 0 }

    init(server: ServerConfig, config: WAFCcRuleConfig?, scope: String, title: String) {
        self.server = server
        self.config = config
        self.scope = scope
        self.title = title
        self.client = APIClient.shared(for: server)
        // 先用父页快照即时回填（不闪默认值），.task 再拉服务端最新覆盖
        if let c = config {
            _duration = State(initialValue: String(c.duration ?? 60))
            _threshold = State(initialValue: String(c.threshold ?? 10))
            _ipBlockTime = State(initialValue: String(c.ipBlockTime ?? 3000))
        }
    }

    var body: some View {
        Form {
            Section(L10n.t("参数")) {
                OutlinedUnitField(label: L10n.t("周期"), unit: L10n.t("秒"),
                                  text: $duration)
                OutlinedUnitField(label: L10n.t("频率"), unit: L10n.t("次"),
                                  text: $threshold)
                OutlinedUnitField(label: L10n.t("封禁时间"), unit: L10n.t("秒"),
                                  text: $ipBlockTime)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshConfig() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                }
                .disabled(isSaving)
            }
        }
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

    /// 进入时拉取服务端最新配置回填（父页快照保存后不刷新，返回再进会是旧值）；
    /// 失败静默保持快照值
    private func refreshConfig() async {
        guard let cfg: WAFConfig = try? await client.send(
            path: APIEndpoint.wafConfigGlobal.path, method: "GET", as: WAFConfig.self
        ), let c = scope == "NotFoundCount" ? cfg.notFoundCount : cfg.attackCount else { return }
        latestConfig = c
        duration = String(c.duration ?? 60)
        threshold = String(c.threshold ?? 10)
        ipBlockTime = String(c.ipBlockTime ?? 3000)
    }

    private func save() async {
        isSaving = true
        let base = latestConfig ?? config
        let req = WAFCcRuleSaveRequest(
            state: base?.state ?? "off",
            code: base?.code ?? defaultCode,
            action: base?.action ?? "deny",
            type: ruleType,
            res: "",
            ipBlock: base?.ipBlock ?? "on",
            ipBlockTime: Int(ipBlockTime) ?? 3000,
            threshold: Int(threshold) ?? 10,
            duration: Int(duration) ?? 60,
            mode: "",
            scope: scope,
            applyWebsite: nil,
            websites: nil
        )
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafRuleCc.path, body: req, as: EmptyResponse.self)
            successMessage = L10n.t("已保存")
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

// MARK: - IP 地址库更新

struct WAFLocationUpdateView: View {
    let server: ServerConfig

    @State private var isUpdating = false
    @State private var successMessage: String?
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await update(type: "geoIP") }
                } label: {
                    HStack {
                        Image(systemName: "globe.asia.australia")
                        Text(L10n.t("更新 IP 地址库"))
                        Spacer()
                        if isUpdating { ProgressView() }
                    }
                }
            } header: {
                Text(L10n.t("IP 地址库"))
            } footer: {
                Text(L10n.t("更新 GeoIP 数据库以支持基于地理位置的访问控制"))
            }
        }
        .navigationTitle(L10n.t("IP 地址库"))
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

    private func update(type: String) async {
        isUpdating = true
        let req = WAFLocationUpdateRequest(type: type)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafLocationUpdate.path, body: req, as: EmptyResponse.self)
            successMessage = L10n.t("更新成功")
        } catch {
            errorMessage = error.localizedDescription
        }
        isUpdating = false
    }
}

