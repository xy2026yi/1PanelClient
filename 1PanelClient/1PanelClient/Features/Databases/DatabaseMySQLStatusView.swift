//
//  DatabaseMySQLStatusView.swift
//  1PanelClient
//
//  MySQL/MariaDB 状态与参数（logs/MySQL 状态抓包 2026-09-14）：
//  databases/status（基础参数 + 性能参数，命中率类客户端计算）
//  · databases/variables（系统变量，字节类换算展示）
//

import SwiftUI

struct DatabaseMySQLStatusView: View {
    let system: DatabaseSystem

    @State private var segment = 0
    @State private var status: [String: String]?
    @State private var variables: [String: String]?
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
            } else if segment == 0 {
                statusSections
            } else {
                variablesSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("状态与参数"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("", selection: $segment) {
                    Text(L10n.t("状态")).tag(0)
                    Text(L10n.t("参数")).tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }
        }
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

    // MARK: 参数（SHOW VARIABLES）

    private var variablesSection: some View {
        Group {
            if let variables {
                Section {
                    ForEach(MySQLVariablesDisplay.displayKeys(variables), id: \.self) { key in
                        InfoRow(key, value: MySQLVariablesDisplay.value(key, variables[key]), monospaced: true)
                    }
                } header: {
                    SectionLabel(title: L10n.t("参数"), systemImage: "slider.horizontal.3")
                }
            }
        }
    }

    private func load() async {
        let req = DatabaseStatusRequest(type: system.type, name: system.database)
        do {
            if status == nil {
                let resp: [String: String] = try await client.send(
                    path: APIEndpoint.databasesStatus.path, body: req, as: [String: String].self)
                status = resp
            }
            if variables == nil {
                let resp: [String: String] = try await client.send(
                    path: APIEndpoint.databasesVariables.path, body: req, as: [String: String].self)
                variables = resp
            }
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
