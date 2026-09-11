//
//  SupervisorProcessFormView.swift
//  1PanelClient
//
//  守护进程创建/编辑表单 + 源文件（supervisor ini）编辑页
//

import SwiftUI

// MARK: - 创建 / 编辑表单

struct SupervisorProcessFormView: View {
    let server: ServerConfig
    /// 编辑模式传入已有进程；添加模式传 nil
    let editing: SupervisorProcessItem?
    @ObservedObject var vm: SupervisorViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var user = "root"
    @State private var dir = ""
    @State private var showDirPicker = false
    @State private var command = ""
    @State private var numprocs = 1
    @State private var environment = ""
    @State private var autoRestart = true
    @State private var autoStart = true

    @State private var isSaving = false
    @State private var didFill = false

    private var isEditing: Bool { editing != nil }

    private var canSubmit: Bool {
        !name.isEmpty && !command.isEmpty && !user.isEmpty && !isSaving
    }

    var body: some View {
        Form {
            Section {
                TextField(L10n.t("名称"), text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(isEditing)
                TextField(L10n.t("启动命令"), text: $command, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1...3)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                SectionLabel(title: L10n.t("基本信息"), systemImage: "info.circle")
            } footer: {
                if isEditing {
                    Text(L10n.t("名称不可修改"))
                }
            }

            Section {
                HStack {
                    TextField(L10n.t("运行目录"), text: $dir)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        showDirPicker = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.t("浏览目录"))
                }
                TextField(L10n.t("启动用户"), text: $user)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Stepper(value: $numprocs, in: 1...64) {
                    HStack {
                        Text(L10n.t("进程数量"))
                        Spacer()
                        Text("\(numprocs)").foregroundStyle(.secondary)
                    }
                }
            } header: {
                SectionLabel(title: L10n.t("运行设置"), systemImage: "gearshape.2")
            }

            Section {
                Toggle(L10n.t("自动重启"), isOn: $autoRestart)
                Toggle(L10n.t("自动启动"), isOn: $autoStart)
            } header: {
                SectionLabel(title: L10n.t("进程策略"), systemImage: "arrow.triangle.2.circlepath")
            } footer: {
                Text(L10n.t("自动重启在进程异常退出后拉起；自动启动随 Supervisor 服务启动"))
            }

            Section {
                TextField(L10n.t("环境变量（KEY=value，多个用逗号分隔）"), text: $environment, axis: .vertical)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(1...3)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                SectionLabel(title: L10n.t("环境变量"), systemImage: "curlybraces")
            }
        }
        .navigationTitle(isEditing ? L10n.t("编辑进程") : L10n.t("添加进程"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                }
                .disabled(!canSubmit)
            }
        }
        .task {
            guard !didFill else { return }
            didFill = true
            if let process = editing {
                name = process.name
                user = process.user ?? "root"
                dir = process.dir ?? ""
                command = process.command ?? ""
                numprocs = Int(process.numprocs ?? "") ?? 1
                environment = process.environment ?? ""
                autoRestart = process.isEnabled(process.autoRestart)
                autoStart = process.isEnabled(process.autoStart)
            }
        }
        .sheet(isPresented: $showDirPicker) {
            // 用宿主 VM 的 client：避免多机切换瞬间读到别的服务器的目录
            DirectoryPickerSheet(client: vm.client) { picked in
                dir = picked
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let req = SupervisorProcessRequest(
            operate: isEditing ? "update" : "create",
            name: name,
            command: command,
            user: user,
            dir: dir,
            numprocsNum: numprocs,
            numprocs: String(numprocs),
            autoRestart: autoRestart ? "true" : "false",
            autoStart: autoStart ? "true" : "false",
            environment: environment)

        let ok: Bool
        if isEditing {
            ok = await vm.updateProcess(req: req)
        } else {
            ok = await vm.createProcess(req: req)
        }
        if ok { dismiss() }
    }
}

// MARK: - 源文件编辑

/// 守护进程 supervisor ini 源文：GET file/get 加载，POST file {operate:update, file:"config"} 保存
struct SupervisorProcessFileView: View {
    let server: ServerConfig
    let processName: String

    @State private var content = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var successMessage: String?
    @State private var errorMessage: String?
    /// 加载失败文案：编辑器不落地（防止把加载失败的空内容保存上去覆盖配置）
    @State private var loadErrorMessage: String?

    private let client: APIClient

    init(server: ServerConfig, processName: String) {
        self.server = server
        self.processName = processName
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else if let loadError = loadErrorMessage {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(loadError)
                } actions: {
                    Button(L10n.t("重试")) {
                        Task { await loadConfig() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                TextEditor(text: $content)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }
        .navigationTitle(L10n.t("源文件"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("保存")) {
                    Task { await save() }
                }
                .disabled(isSaving || isLoading)
            }
        }
        .task { await loadConfig() }
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

    private func loadConfig() async {
        isLoading = true
        do {
            content = try await client.send(
                path: APIEndpoint.supervisorProcessFileGet.path,
                method: "GET",
                queryItems: [URLQueryItem(name: "name", value: processName)],
                as: String.self)
            loadErrorMessage = nil
        } catch {
            // 加载失败进错误态（带重试），不进编辑器：空文本一旦保存会清空配置
            loadErrorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        isSaving = true
        let req = SupervisorProcessFileRequest(
            name: processName, operate: "update", file: "config", content: content)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.supervisorProcessFile.path, body: req, as: EmptyResponse.self)
            successMessage = L10n.t("已保存")
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}
