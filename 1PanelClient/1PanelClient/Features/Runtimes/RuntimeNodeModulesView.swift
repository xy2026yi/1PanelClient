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
    /// 操作中的模块名（该行/安装位转圈；install 用空串占位）
    @State private var busyName: String?

    /// 待确认操作（面板对安装/更新/卸载均二次确认）
    private struct PendingOp: Identifiable {
        let op: String        // install / update / uninstall
        let name: String
        var id: String { op + ":" + name }
    }
    @State private var pendingOp: PendingOp?
    /// 待确认的安装模块名（右上角安装入口）
    @State private var pendingInstall: String?

    /// 任一操作进行中：锁定其余操作（同一容器内并发跑 npm 会锁冲突）
    private var isOperating: Bool { busyName != nil }

    var body: some View {
        List {
            installSection
            if isLoading && modules.isEmpty {
                Section { LoadingStateView(compact: true).padding(.vertical, 20) }
            } else if let err = errorMessage, modules.isEmpty {
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
                            if busyName == mod.displayName {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Button(L10n.t("更新")) {
                                    pendingOp = PendingOp(op: "update", name: mod.displayName)
                                }
                                .font(.subheadline)
                                .buttonStyle(.bordered)
                                .disabled(isOperating)
                                Button(L10n.t("卸载"), role: .destructive) {
                                    pendingOp = PendingOp(op: "uninstall", name: mod.displayName)
                                }
                                .font(.subheadline)
                                .buttonStyle(.bordered)
                                .tint(.red)
                                .disabled(isOperating)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle(L10n.t("模块管理"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if busyName == "" {
                    ProgressView()
                } else {
                    Button(L10n.t("安装")) {
                        pendingInstall = newModule.trimmingCharacters(in: .whitespaces)
                    }
                    .disabled(newModule.trimmingCharacters(in: .whitespaces).isEmpty || isOperating)
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .toastOverlay(message: $toast)
        .alert(L10n.t("安装"), isPresented: Binding(
            get: { pendingInstall != nil },
            set: { if !$0 { pendingInstall = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("安装")) {
                let name = pendingInstall
                newModule = ""
                Task { if let name { await operate("install", name) } }
            }
        } message: {
            Text(L10n.f("是否安装 %@ 模块？操作可能导致运行环境异常，请确认后操作",
                        pendingInstall ?? ""))
        }
        .alert(pendingOp.map { alertTitle($0) } ?? "", isPresented: Binding(
            get: { pendingOp != nil },
            set: { if !$0 { pendingOp = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) {}
            // alert 关闭会把 pendingOp 置 nil，异步闭包必须先捕获目标
            Button(pendingOp.map { confirmTitle($0) } ?? "", role: .destructive) {
                let op = pendingOp
                Task { if let op { await operate(op.op, op.name) } }
            }
        } message: {
            Text(pendingOp.map { alertMessage($0) } ?? "")
        }
    }

    private func alertTitle(_ op: PendingOp) -> String {
        switch op.op {
        case "install": return L10n.t("安装模块")
        case "update": return L10n.t("更新模块")
        default: return L10n.t("卸载模块")
        }
    }

    private func confirmTitle(_ op: PendingOp) -> String {
        op.op == "uninstall" ? L10n.t("卸载") : L10n.t("确认")
    }

    private func alertMessage(_ op: PendingOp) -> String {
        switch op.op {
        case "install": return L10n.f("确认安装模块「%@」？", op.name)
        case "update": return L10n.f("确认更新模块「%@」？", op.name)
        default: return L10n.f("确认卸载模块「%@」？卸载后不可恢复。", op.name)
        }
    }

    private var installSection: some View {
        Section {
            OutlinedTextField(label: L10n.t("模块名"), prompt: "express",
                              text: $newModule)
        } header: {
            Text("\(entry.packageManager) install")
        } footer: {
            Text(L10n.t("输入模块名后点右上角安装；操作同步执行，大模块安装可能耗时较长"))
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
        guard !moduleName.isEmpty, busyName == nil else { return }
        busyName = op == "install" ? "" : moduleName
        defer { busyName = nil }
        do {
            // 同步阻塞接口：默认 15s 超时会在真实安装耗时下“假失败”（服务端仍在执行），
            // 按面板前端口径放宽到 10 分钟
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.runtimesNodeModulesOperate.path,
                body: RuntimeNodeModuleOperateRequest(
                    ID: entry.id, Operate: op, Module: moduleName,
                    PkgManager: entry.packageManager
                ),
                timeout: 600,
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
