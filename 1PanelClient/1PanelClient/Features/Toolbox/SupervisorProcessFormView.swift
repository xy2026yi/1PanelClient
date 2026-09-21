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
                OutlinedTextField(label: L10n.t("名称"), text: $name)
                    .disabled(isEditing)
                // 启动命令（形态 7.1，默认 1 行自动增高）
                OutlinedMultiLineField(label: L10n.t("启动命令"), prompt: "python app.py",
                                       lines: 1, text: $command)
            } header: {
                SectionLabel(title: L10n.t("基本信息"), systemImage: "info.circle")
            } footer: {
                if isEditing {
                    Text(L10n.t("名称不可修改"))
                }
            }

            Section {
                // 运行目录：目录浏览图标内嵌描边框右侧（可手输 + 浏览回填）
                FilePathBrowseRow(title: L10n.t("运行目录"), path: $dir, client: vm.client)
                OutlinedTextField(label: L10n.t("启动用户"), prompt: "root", text: $user)
                OutlinedUnitField(label: L10n.t("进程数量"), unit: L10n.t("个"),
                                  text: numprocsText, range: 1...64)
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
                // 环境变量（形态 7.1，每行一条 KEY=value）
                OutlinedMultiLineField(label: L10n.t("环境变量"), prompt: "KEY=value",
                                       lines: 1, text: $environment)
            } header: {
                SectionLabel(title: L10n.t("环境变量"), systemImage: "curlybraces")
            } footer: {
                Text(L10n.t("每行一条 KEY=value"))
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
                // 服务端逗号分隔 ↔ 表单按行编辑（值可带双引号且内含逗号，引号内逗号不拆）
                environment = Self.splitEnvironment(process.environment ?? "")
                    .joined(separator: "\n")
                autoRestart = process.isEnabled(process.autoRestart)
                autoStart = process.isEnabled(process.autoStart)
            }
        }
    }

    /// 进程数量 Int ↔ String（描边框用）
    private var numprocsText: Binding<String> {
        Binding<String>(get: { String(numprocs) },
                        set: { numprocs = Int($0) ?? numprocs })
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        // 环境变量：按行编辑，提交拼回服务端的逗号分隔格式
        //（值含逗号且未加引号时补引号，supervisor ini 语义要求，保证往返不拆断）
        let envValue = Self.joinEnvironment(
            environment
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
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
            environment: envValue)

        let ok: Bool
        if isEditing {
            ok = await vm.updateProcess(req: req)
        } else {
            ok = await vm.createProcess(req: req)
        }
        if ok { dismiss() }
    }

    // MARK: environment 串 ↔ 行（引号感知）

    /// 服务端 environment 串 "K=V,K2=V2"（值可带双引号且内含逗号）→ 行数组。
    /// 引号内的逗号不拆分；引号外空白去除（抓包确认网页端即此格式，
    /// 如 environment: "KEY=\"val\",KEY2=\"val2\""）
    private static func splitEnvironment(_ raw: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var inQuotes = false
        for ch in raw {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch == "," && !inQuotes {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { lines.append(trimmed) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { lines.append(trimmed) }
        return lines
    }

    /// 行数组 → 服务端逗号分隔串：值含逗号且整行未带引号时给值补双引号，
    /// 保证含逗号的值往返不拆断（无逗号行原样保留，含引号行视为用户自行处理）
    private static func joinEnvironment(_ lines: [String]) -> String {
        lines.map { line in
            guard line.contains(","), !line.contains("\""),
                  let eq = line.firstIndex(of: "=") else { return line }
            let key = String(line[line.startIndex..<eq])
            let value = String(line[line.index(after: eq)...])
            return "\(key)=\"\(value)\""
        }
        .joined(separator: ",")
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
                    .font(.dataMonospacedCaption)
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
                body: SupervisorFileGetRequest(name: processName, file: "config"),
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
