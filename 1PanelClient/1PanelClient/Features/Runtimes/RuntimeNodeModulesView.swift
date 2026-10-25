//
//  RuntimeNodeModulesView.swift
//  1PanelClient
//
//  Node.js 模块管理：已装模块列表 + 输入模块名安装 + 行更新/卸载。
//  操作为同步等待（面板前端超时 10 分钟，无任务进度）。
//

import SwiftUI

struct RuntimeNodeModulesView: View {
    let entry: RuntimeEntry
    let client: APIClient

    @State private var modules: [RuntimeNodeModule] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var toast: String?
    @State private var newModule = ""
    @State private var busyNames: Set<String> = []
    @State private var isInstalling = false

    var body: some View {
        List {
            installSection
            if isLoading && modules.isEmpty {
                Section { LoadingStateView(compact: true).padding(.vertical, 20) }
            } else if let err = errorMessage {
                Section {
                    Text(err).font(.footnote).foregroundStyle(.red)
                    Button(L10n.t("重试")) { Task { await load() } }
                }
            } else if modules.isEmpty {
                Section {
                    Text(L10n.t("暂无已安装模块"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section(L10n.t("已安装模块")) {
                    ForEach(modules) { mod in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(mod.displayName)
                                        .font(.system(.body, design: .monospaced))
                                    if let v = mod.version, !v.isEmpty {
                                        Text("v\(v)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let license = mod.license, !license.isEmpty {
                                        Text(license)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                if let desc = mod.description, !desc.isEmpty {
                                    Text(desc)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            if busyNames.contains(mod.displayName) {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Button(L10n.t("更新")) {
                                    Task { await operate("update", mod.displayName) }
                                }
                                .font(.subheadline)
                                .buttonStyle(.bordered)
                                Button(L10n.t("卸载"), role: .destructive) {
                                    Task { await operate("uninstall", mod.displayName) }
                                }
                                .font(.subheadline)
                                .buttonStyle(.bordered)
                                .tint(.red)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle(L10n.t("模块管理"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .toastOverlay(message: $toast)
    }

    private var installSection: some View {
        Section {
            HStack {
                OutlinedTextField(label: L10n.t("模块名"), prompt: "express",
                                  text: $newModule)
                if isInstalling {
                    ProgressView().scaleEffect(0.9)
                } else {
                    Button(L10n.t("安装")) {
                        Task { await operate("install", newModule.trimmingCharacters(in: .whitespaces)) }
                    }
                    .disabled(newModule.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } header: {
            Text("\(entry.packageManager) install")
        } footer: {
            Text(L10n.t("操作同步执行，大模块安装可能耗时较长"))
        }
    }

    private func load() async {
        isLoading = modules.isEmpty
        errorMessage = nil
        defer { isLoading = false }
        do {
            // 抓包 data 可为 null（无已装模块），经空集合兜底为 []
            let resp: [RuntimeNodeModule] = try await client.send(
                path: APIEndpoint.runtimesNodeModules.path,
                body: RuntimeNodeModulesRequest(ID: entry.id),
                as: [RuntimeNodeModule].self
            )
            modules = resp
        } catch {
            if !APIError.isCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    private func operate(_ op: String, _ moduleName: String) async {
        guard !moduleName.isEmpty else { return }
        let busyKey = op == "install" ? "" : moduleName
        if op == "install" { isInstalling = true } else { busyNames.insert(busyKey) }
        defer {
            isInstalling = false
            if !busyKey.isEmpty { busyNames.remove(busyKey) }
        }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.runtimesNodeModulesOperate.path,
                body: RuntimeNodeModuleOperateRequest(
                    ID: entry.id, Operate: op, Module: moduleName,
                    PkgManager: entry.packageManager
                ),
                as: EmptyResponse.self
            )
            toast = L10n.f("%@ 完成", op == "install" ? L10n.t("安装") : (op == "update" ? L10n.t("更新") : L10n.t("卸载")))
            if op == "install" { newModule = "" }
            await load()
        } catch {
            toast = L10n.f("操作失败：%@", error.localizedDescription)
        }
    }
}
