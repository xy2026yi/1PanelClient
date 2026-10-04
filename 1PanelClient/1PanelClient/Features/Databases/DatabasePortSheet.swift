//
//  DatabasePortSheet.swift
//  1PanelClient
//
//  数据库端口修改半屏弹窗（MySQL/MariaDB/PostgreSQL/Redis，MongoDB 网页端无此入口）：
//  · 读 POST /databases/common/info {type,name} 预填当前端口
//  · 改 POST /apps/installed/port/change {key,name,port}（Redis 抓包额外携带 type，
//    见 AppPortChangeRequest.type 注释）
//  · 端口 + 「立即重启」双输入合并一屏；两者都合规才可保存（与网页端同款确认语义）
//

import SwiftUI

/// POST /api/v2/databases/common/info 响应
nonisolated struct DatabaseCommonInfo: Decodable {
    let name: String?
    let containerName: String?
    let port: Int?
}

/// POST /api/v2/apps/installed/port/change 请求
nonisolated struct AppPortChangeRequest: Encodable {
    let key: String
    let name: String
    let port: Int
    /// 抓包仅 Redis 请求携带（{"type":"redis","key":"redis",...}），其余库不传；
    /// nil 可选项编码时省略
    var type: String? = nil
}

struct DatabasePortSheet: View {
    let system: DatabaseSystem
    /// 保存成功回调（父页收 sheet 后展示 toast 并刷新连接信息）
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var portInput = ""
    @State private var restartInput = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showError = false

    private let client: APIClient

    init(system: DatabaseSystem, onSaved: @escaping () -> Void = {}) {
        self.system = system
        self.onSaved = onSaved
        self.client = APIClient.shared(for: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
    }

    /// 输入合法性：1-65535 整数且与当前端口不同
    private var editedPort: Int? {
        guard let p = Int(portInput), (1...65535).contains(p) else { return nil }
        guard let current = currentPort else { return p }
        return p == current ? nil : p
    }

    private var currentPort: Int? {
        info?.port
    }

    @State private var info: DatabaseCommonInfo?

    /// 保存条件：端口合规 + 已完整输入「立即重启」（与网页端同款确认语义）
    private var canSave: Bool {
        editedPort != nil
            && restartInput.trimmingCharacters(in: .whitespaces) == L10n.t("立即重启")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isLoading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .listRowBackground(Color.clear)
                    } else {
                        OutlinedTextField(label: L10n.t("端口"),
                                          text: $portInput,
                                          keyboardType: .numberPad)
                    }
                } header: {
                    Text(L10n.t("端口修改"))
                } footer: {
                    Text(L10n.t("端口号为 1-65535 的整数"))
                }

                Section {
                    TextField(L10n.t("请输入「立即重启」"), text: $restartInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(L10n.t("确认重启"))
                } footer: {
                    Text(L10n.t("修改配置后需要重启生效。如果确认操作，请手动输入 '立即重启'"))
                }
            }
            .navigationTitle(L10n.t("端口"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("保存")) {
                        guard canSave, !isSaving else { return }
                        Task { await save() }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .alert(L10n.t("提示"), isPresented: $showError) {
                Button(L10n.t("好的"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.medium])
        .task { await load() }
    }

    private func load() async {
        do {
            let resp: DatabaseCommonInfo = try await client.send(
                path: APIEndpoint.databasesCommonInfo.path,
                method: APIEndpoint.databasesCommonInfo.method,
                body: DatabaseStatusRequest(type: system.type, name: system.database),
                as: DatabaseCommonInfo.self)
            info = resp
            portInput = resp.port.map(String.init) ?? ""
        } catch {
            // 预填失败不阻断：留空输入，用户可手动填当前端口
            guard !APIError.isCancellation(error) else { return }
        }
        isLoading = false
    }

    private func save() async {
        guard let port = editedPort else { return }
        isSaving = true
        defer { isSaving = false }
        let req = AppPortChangeRequest(
            key: system.type,
            name: system.database,
            port: port,
            type: system.type.lowercased() == "redis" ? "redis" : nil)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.appsInstalledPortChange.path,
                method: APIEndpoint.appsInstalledPortChange.method,
                body: req,
                as: EmptyResponse.self)
            dismiss()
            onSaved()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
