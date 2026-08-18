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
            Section("模式") {
                Picker("模式", selection: $mode) {
                    Text("URL 模式").tag("uri")
                    Text("全局模式").tag("global")
                }
            }
            Section("参数") {
                HStack {
                    Text("周期")
                    Spacer()
                    TextField("", text: $duration)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text("秒").foregroundStyle(.secondary)
                }
                HStack {
                    Text("频率")
                    Spacer()
                    TextField("", text: $threshold)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text("次").foregroundStyle(.secondary)
                }
                HStack {
                    Text("封禁时间")
                    Spacer()
                    TextField("", text: $ipBlockTime)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text("秒").foregroundStyle(.secondary)
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
                    .action(title: "保存默认") { Task { await save(applyWebsite: nil) } },
                    .action(title: "应用到网站") { Task { await save(applyWebsite: true) } },
                ]) {
                    withAnimation(.easeIn(duration: 0.12)) { showMenu = false }
                }
            }
        }
        .alert("提示", isPresented: Binding(
            get: { successMessage != nil || errorMessage != nil },
            set: { _ in successMessage = nil; errorMessage = nil }
        )) {
            Button("好的") { successMessage = nil; errorMessage = nil }
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
            successMessage = applyWebsite == true ? "已应用到网站" : "已保存"
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
            Section("参数") {
                HStack {
                    Text("周期")
                    Spacer()
                    TextField("", text: $duration)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text("秒").foregroundStyle(.secondary)
                }
                HStack {
                    Text("频率")
                    Spacer()
                    TextField("", text: $threshold)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text("次").foregroundStyle(.secondary)
                }
                HStack {
                    Text("封禁时间")
                    Spacer()
                    TextField("", text: $ipBlockTime)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text("秒").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadConfig() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { Task { await save() } }
                    .disabled(isSaving)
            }
        }
        .alert("提示", isPresented: Binding(
            get: { successMessage != nil || errorMessage != nil },
            set: { _ in successMessage = nil; errorMessage = nil }
        )) {
            Button("好的") { successMessage = nil; errorMessage = nil }
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
            successMessage = "已保存"
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
                        Text("更新 IP 地址库")
                        Spacer()
                        if isUpdating { ProgressView() }
                    }
                }
            } header: {
                Text("IP 地址库")
            } footer: {
                Text("更新 GeoIP 数据库以支持基于地理位置的访问控制")
            }
        }
        .navigationTitle("IP 地址库")
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

    private func update(type: String) async {
        isUpdating = true
        let req = WAFLocationUpdateRequest(type: type)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafLocationUpdate.path, body: req, as: EmptyResponse.self)
            successMessage = "更新成功"
        } catch {
            errorMessage = error.localizedDescription
        }
        isUpdating = false
    }
}

