//
//  DatabaseMySQLStatusView.swift
//  1PanelClient
//
//  MySQL/MariaDB 运行状态（logs/MySQL 状态抓包 2026-09-14）：
//  databases/status（基础参数 + 性能参数，命中率类客户端计算）。
//  系统变量（SHOW VARIABLES）独立成 DatabaseMySQLVariablesView（抽屉「参数」入口）
//

import SwiftUI

struct DatabaseMySQLStatusView: View {
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
            } else {
                statusSections
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("状态"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: 状态（基础 + 性能）

    @ViewBuilder private var statusSections: some View {
        if let status {
            Section {
                ForEach(Array(MySQLStatusMetrics.basicRows(status).enumerated()), id: \.offset) { _, row in
                    InfoRow(L10n.t(row.0), value: row.1, monospaced: row.0 != "启动时间")
                }
            } header: {
                SectionLabel(title: L10n.t("基础参数"), systemImage: "info.circle")
            }
            Section {
                ForEach(Array(MySQLStatusMetrics.performanceRows(status).enumerated()), id: \.offset) { _, row in
                    InfoRow(L10n.t(row.0), value: row.1)
                }
            } header: {
                SectionLabel(title: L10n.t("性能参数"), systemImage: "speedometer")
            }
        }
    }

    private func load() async {
        let req = DatabaseStatusRequest(type: system.type, name: system.database)
        do {
            let resp: [String: String] = try await client.send(
                path: APIEndpoint.databasesStatus.path, body: req, as: [String: String].self)
            status = resp
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
