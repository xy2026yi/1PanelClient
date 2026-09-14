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
