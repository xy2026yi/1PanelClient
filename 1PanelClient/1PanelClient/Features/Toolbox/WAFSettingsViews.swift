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

    private let client: APIClient

    init(server: ServerConfig, config: WAFCcRuleConfig?, scope: String, title: String) {
        self.server = server
        self.config = config
        self.scope = scope
        self.title = title
        self.client = APIClient(server: server)
    }

    var body: some View {
        Form {
            Section(L10n.t("模式")) {
                Picker(L10n.t("模式"), selection: $mode) {
                    Text(L10n.t("URL 模式")).tag("uri")
                    Text(L10n.t("全局模式")).tag("global")
                }
            }
            Section(L10n.t("参数")) {
                HStack {
                    Text(L10n.t("周期"))
                    Spacer()
                    TextField("", text: $duration)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text(L10n.t("秒")).foregroundStyle(.secondary)
                }
                HStack {
                    Text(L10n.t("频率"))
                    Spacer()
                    TextField("", text: $threshold)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text(L10n.t("次")).foregroundStyle(.secondary)
                }
                HStack {
                    Text(L10n.t("封禁时间"))
                    Spacer()
                    TextField("", text: $ipBlockTime)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text(L10n.t("秒")).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadConfig() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EllipsisMenuButton {
                    withAnimation(.easeOut(duration: 0.18)) { showMenu.toggle() }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if showMenu {
                EllipsisMenuPopup(entries: [
                    .action(title: L10n.t("保存默认")) { Task { await save(applyWebsite: nil) } },
                    .action(title: L10n.t("应用到网站")) { Task { await save(applyWebsite: true) } },
                ]) {
                    withAnimation(.easeIn(duration: 0.12)) { showMenu = false }
                }
            }
        }
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { successMessage != nil || errorMessage != nil },
            set: { _ in successMessage = nil; errorMessage = nil }
        )) {
            Button(L10n.t("好的")) { successMessage = nil; errorMessage = nil }
        } message: {
            Text(errorMessage ?? successMessage ?? "")
        }
    }

    private func loadConfig() {
        guard let c = config else { return }
        mode = c.mode ?? "global"
        duration = String(c.duration ?? 10)
        threshold = String(c.threshold ?? 100)
        ipBlockTime = String(c.ipBlockTime ?? 600)
    }

    private func save(applyWebsite: Bool?) async {
        isSaving = true
        let req = WAFCcRuleSaveRequest(
            state: config?.state ?? "off",
            code: config?.code ?? 0,
            action: config?.action ?? "deny",
            type: "cc",
            res: "",
            ipBlock: config?.ipBlock ?? "on",
            ipBlockTime: Int(ipBlockTime) ?? 600,
            threshold: Int(threshold) ?? 100,
            duration: Int(duration) ?? 10,
            mode: mode,
            scope: scope,
            applyWebsite: applyWebsite
        )
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafRuleCc.path, body: req, as: EmptyResponse.self)
            successMessage = applyWebsite == true ? L10n.t("已应用到网站") : L10n.t("已保存")
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
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

    private let client: APIClient
    private var ruleType: String { scope == "NotFoundCount" ? "notFoundCount" : "attackCount" }
    private var defaultCode: Int { scope == "NotFoundCount" ? 403 : 0 }

    init(server: ServerConfig, config: WAFCcRuleConfig?, scope: String, title: String) {
        self.server = server
        self.config = config
        self.scope = scope
        self.title = title
        self.client = APIClient(server: server)
    }

    var body: some View {
        Form {
            Section(L10n.t("参数")) {
                HStack {
                    Text(L10n.t("周期"))
                    Spacer()
                    TextField("", text: $duration)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text(L10n.t("秒")).foregroundStyle(.secondary)
                }
                HStack {
                    Text(L10n.t("频率"))
                    Spacer()
                    TextField("", text: $threshold)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text(L10n.t("次")).foregroundStyle(.secondary)
                }
                HStack {
                    Text(L10n.t("封禁时间"))
                    Spacer()
                    TextField("", text: $ipBlockTime)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text(L10n.t("秒")).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadConfig() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("保存")) { Task { await save() } }
                    .disabled(isSaving)
            }
        }
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { successMessage != nil || errorMessage != nil },
            set: { _ in successMessage = nil; errorMessage = nil }
        )) {
            Button(L10n.t("好的")) { successMessage = nil; errorMessage = nil }
        } message: {
            Text(errorMessage ?? successMessage ?? "")
        }
    }

    private func loadConfig() {
        guard let c = config else { return }
        duration = String(c.duration ?? 60)
        threshold = String(c.threshold ?? 10)
        ipBlockTime = String(c.ipBlockTime ?? 3000)
    }

    private func save() async {
        isSaving = true
        let req = WAFCcRuleSaveRequest(
            state: config?.state ?? "off",
            code: config?.code ?? defaultCode,
            action: config?.action ?? "deny",
            type: ruleType,
            res: "",
            ipBlock: config?.ipBlock ?? "on",
            ipBlockTime: Int(ipBlockTime) ?? 3000,
            threshold: Int(threshold) ?? 10,
            duration: Int(duration) ?? 60,
            mode: "",
            scope: scope,
            applyWebsite: nil
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
        self.client = APIClient(server: server)
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
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { successMessage != nil || errorMessage != nil },
            set: { _ in successMessage = nil; errorMessage = nil }
        )) {
            Button(L10n.t("好的")) { successMessage = nil; errorMessage = nil }
        } message: {
            Text(errorMessage ?? successMessage ?? "")
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

