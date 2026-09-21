//
//  DatabaseRedisStatusView.swift
//  1PanelClient
//
//  Redis 状态（logs/Redis 状态抓包 2026-09-14）：
//  databases/redis/status {type:"redis",name} → 基础/性能参数（内存换算 MB）
//

import SwiftUI

struct DatabaseRedisStatusView: View {
    let system: DatabaseSystem

    @State private var status: [String: String]?
    @State private var isLoading = true
    @State private var loadError: String?

    private let client: APIClient

    init(system: DatabaseSystem) {
        self.system = system
        self.client = APIClient.shared(for: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
    }

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); LoadingStateView(); Spacer() }
                    .listRowBackground(Color.clear)
            } else if let loadError {
                LoadErrorStateView(message: loadError) {
                    Task { await load() }
                }
                .listRowBackground(Color.clear)
            } else if let status {
                Section {
                    ForEach(Array(RedisStatusMetrics.basicRows(status).enumerated()), id: \.offset) { _, row in
                        InfoRow(L10n.t(row.0), value: row.1)
                    }
                } header: {
                    SectionLabel(title: L10n.t("基础参数"), systemImage: "info.circle")
                }
                Section {
                    ForEach(Array(RedisStatusMetrics.performanceRows(status).enumerated()), id: \.offset) { _, row in
                        InfoRow(L10n.t(row.0), value: row.1)
                    }
                } header: {
                    SectionLabel(title: L10n.t("性能参数"), systemImage: "speedometer")
                } footer: {
                    Text(L10n.t("内存碎片率过大表示内存碎片较多，可关注内存使用情况"))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("状态"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            let resp: [String: String] = try await client.send(
                path: APIEndpoint.databasesRedisStatus.path,
                body: DatabaseStatusRequest(type: "redis", name: system.database),
                as: [String: String].self)
            status = resp
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Redis 性能调整（timeout / maxclients / maxmemory）

struct DatabaseRedisPerformanceView: View {
    let system: DatabaseSystem

    @State private var timeoutText = ""
    @State private var maxclientsText = ""
    @State private var maxmemoryMBText = ""
    /// 最大内存单位（K/M/G，提交拼 "Xkb/mb/gb"）
    @State private var memoryUnit = "M"
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isSaving = false
    @State private var showSaveConfirm = false
    @State private var successToast: String?
    @State private var errorMessage: String?
    @State private var showError = false

    private let client: APIClient

    init(system: DatabaseSystem) {
        self.system = system
        self.client = APIClient.shared(for: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
    }

    var body: some View {
        Form {
            if isLoading {
                Section { HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 24) }
            } else if let loadError {
                Section {
                    ContentUnavailableView {
                        Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button(L10n.t("重试")) { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    OutlinedUnitField(label: L10n.t("超时时间"), unit: L10n.t("秒"),
                                      text: $timeoutText, range: 0...999999)
                    OutlinedUnitField(label: L10n.t("最大连接数"), unit: "", prompt: L10n.t("可选"),
                                      text: $maxclientsText, range: 0...999999)
                    OutlinedUnitField(label: L10n.t("最大内存使用"), unit: "",
                                      text: $maxmemoryMBText, range: 0...9_999_999)
                    OutlinedPicker(label: L10n.t("内存单位"), options: ["K", "M", "G"],
                                   selection: $memoryUnit,
                                   optionLabels: ["K": "KB", "M": "MB", "G": "GB"])
                } header: {
                    SectionLabel(title: L10n.t("性能调整"), systemImage: "speedometer")
                } footer: {
                    Text(L10n.t("超时时间为空闲连接超时时间，0 表示不断开；最大内存使用 0 表示不做限制。"))
                }
            }
        }
        .navigationTitle(L10n.t("性能调整"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSaving {
                    ProgressView()
                } else {
                    Button(L10n.t("保存")) {
                        showSaveConfirm = true
                    }
                    .disabled(isLoading || loadError != nil)
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .toastOverlay(message: $successToast)
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        // 保存需输入「立即重启」确认（保存后重启 Redis 生效，与网页端一致）
        .sheet(isPresented: $showSaveConfirm) {
            TextInputConfirmSheet(
                title: L10n.t("保存性能配置"),
                message: L10n.f("保存后需要重启 %@ 才能生效，期间连接将短暂中断。", system.displayName),
                expectedText: L10n.t("立即重启"),
                fieldLabel: L10n.t("确认重启"),
                fieldPlaceholder: L10n.t("请输入「立即重启」")
            ) {
                Task { await save() }
            }
        }
    }

    // MARK: 数据

    /// 读取：POST /databases/redis/conf {type,name}
    private func load() async {
        do {
            let resp: RedisConf = try await client.send(
                path: APIEndpoint.databasesRedisConf.path,
                body: DatabaseStatusRequest(type: system.type, name: system.database),
                as: RedisConf.self)
            timeoutText = resp.timeout ?? "0"
            maxclientsText = resp.maxclients ?? "10000"
            // 纯字节数字 → 数值+单位（整除且 ≥1GB 取 GB，否则 MB 四舍五入）；
            // 非数字值原样展示（保存时原样回传，不静默改值）
            if let bytes = Int(resp.maxmemory ?? ""), bytes > 0 {
                if bytes % (1024 * 1024 * 1024) == 0, bytes >= 1024 * 1024 * 1024 {
                    memoryUnit = "G"
                    maxmemoryMBText = String(bytes / 1024 / 1024 / 1024)
                } else {
                    memoryUnit = "M"
                    maxmemoryMBText = String(Int((Double(bytes) / 1024 / 1024).rounded()))
                }
            } else if let raw = resp.maxmemory, !raw.isEmpty {
                maxmemoryMBText = raw
            } else {
                maxmemoryMBText = "0"
            }
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    /// 保存：POST /databases/redis/conf/update {dbType,database,timeout,maxclients,maxmemory}
    /// （maxmemory 转为 "Xmb" 格式，抓包 2026-09-15；输入非数字时原样提交——
    /// 可能是 load 回显的服务器原始值，不能替用户清零）
    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let timeout = timeoutText.trimmingCharacters(in: .whitespaces)
        let maxclients = maxclientsText.trimmingCharacters(in: .whitespaces)
        let memoryInput = maxmemoryMBText.trimmingCharacters(in: .whitespaces)
        let maxmemory: String
        if let value = Int(memoryInput) {
            // 单位随菜单拼接（服务端 "Xkb/Xmb/Xgb" 格式，抓包确认）
            maxmemory = "\(value)\(memoryUnit.lowercased())"
        } else if !memoryInput.isEmpty {
            maxmemory = memoryInput
        } else {
            maxmemory = "0mb"
        }
        let req = RedisConfUpdateRequest(
            dbType: system.type,
            database: system.database,
            timeout: timeout.isEmpty ? "0" : timeout,
            maxclients: maxclients.isEmpty ? "10000" : maxclients,
            maxmemory: maxmemory)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.databasesRedisConfUpdate.path, body: req, as: EmptyResponse.self)
            successToast = L10n.t("已保存，重启后生效")
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
