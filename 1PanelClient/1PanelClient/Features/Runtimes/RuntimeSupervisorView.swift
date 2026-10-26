//
//  RuntimeSupervisorView.swift
//  1PanelClient
//
//  PHP 进程守护（supervisor）：进程列表（含子进程状态展开）、
//  创建进程、重启/删除、进程源文读写。
//

import SwiftUI

struct RuntimeSupervisorView: View {
    let entry: RuntimeEntry
    let client: APIClient

    @State private var processes: [RuntimeSupervisorProcess] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var toast: String?
    /// 操作中的进程名
    @State private var busyNames: Set<String> = []
    @State private var showCreate = false
    @State private var editTarget: RuntimeSupervisorProcess?
    @State private var fileTarget: RuntimeSupervisorProcess?
    @State private var deleteTarget: RuntimeSupervisorProcess?
    @State private var restartTarget: RuntimeSupervisorProcess?
    /// 长按操作菜单目标（全站统一 ActionBottomSheet 半屏）
    @State private var actionProc: RuntimeSupervisorProcess?
    /// 收起子进程状态的进程名（默认全展开，点击行切换）
    @State private var collapsedNames: Set<String> = []

    var body: some View {
        List {
            if isLoading && processes.isEmpty {
                Section { LoadingStateView(compact: true).padding(.vertical, 20) }
            } else if let err = errorMessage, processes.isEmpty {
                Section {
                    Text(err).font(.footnote).foregroundStyle(.red)
                    Button(L10n.t("重试")) { Task { await load() } }
                }
            } else if processes.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无进程"),
                    systemImage: "gearshape.2",
                    description: Text(L10n.t("点击右上角 + 创建常驻进程"))
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(processes) { proc in
                        processCard(proc)
                    }
                }
            }
        }
        .navigationTitle(L10n.t("进程守护"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCreate = true } label: { Image(systemName: "plus") }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .toastOverlay(message: $toast)
        .sheet(item: $actionProc) { proc in
            ActionBottomSheet(
                title: proc.displayName,
                items: actionItems(proc),
                onDismiss: { actionProc = nil }
            )
        }
        .sheet(isPresented: $showCreate) {
            RuntimeSupervisorCreateSheet(client: client, runtimeID: entry.id, editing: nil) {
                Task { await load() }
            }
        }
        .sheet(item: $editTarget) { proc in
            RuntimeSupervisorCreateSheet(client: client, runtimeID: entry.id, editing: proc) {
                Task { await load() }
            }
        }
        .navigationDestination(item: $fileTarget) { proc in
            RuntimeSupervisorFileView(client: client, runtimeID: entry.id,
                                      processName: proc.displayName)
        }
        .alert(L10n.t("删除进程"), isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("删除"), role: .destructive) {
                // alert 关闭会把 deleteTarget 置 nil，异步闭包必须先捕获目标
                let target = deleteTarget
                Task { await operate("delete", target) }
            }
        } message: {
            Text(L10n.f("确认删除进程「%@」？", deleteTarget?.displayName ?? ""))
        }
        .alert(L10n.t("重启进程"), isPresented: Binding(
            get: { restartTarget != nil },
            set: { if !$0 { restartTarget = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("重启"), role: .destructive) {
                let target = restartTarget
                Task { await operate("restart", target) }
            }
        } message: {
            Text(L10n.f("确认重启进程「%@」？重启会中断正在执行的进程。", restartTarget?.displayName ?? ""))
        }
    }

    private func load() async {
        isLoading = processes.isEmpty
        errorMessage = nil
        defer { isLoading = false }
        do {
            let path = APIEndpoint.runtimesSupervisorList.path
                .replacingOccurrences(of: ":id", with: String(entry.id))
            let data: [RuntimeSupervisorProcess] = try await client.send(
                path: path, method: APIEndpoint.runtimesSupervisorList.method,
                as: [RuntimeSupervisorProcess].self
            )
            processes = data
        } catch {
            if !APIError.isCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    // MARK: 进程卡片

    private func processCard(_ proc: RuntimeSupervisorProcess) -> some View {
        // 全站统一行交互：点击收起/展开子进程状态，长按半屏操作菜单；
        // 内置 php-fpm 只读（删除会破坏 PHP 运行环境，面板对该行隐藏全部操作）
        cardBody(proc)
            .rowTapAndLongPress(
                onTap: {
                    if collapsedNames.contains(proc.displayName) {
                        collapsedNames.remove(proc.displayName)
                    } else {
                        collapsedNames.insert(proc.displayName)
                    }
                },
                onLongPress: {
                    if !proc.isBuiltinPHPFPM { actionProc = proc }
                }
            )
    }

    /// 长按菜单项（构建时捕获 proc：onDismiss 后回读 @State 会取到 nil）
    private func actionItems(_ proc: RuntimeSupervisorProcess) -> [ActionMenuItem] {
        [
            ActionMenuItem(title: L10n.t("编辑"), icon: "pencil") {
                editTarget = proc
            },
            ActionMenuItem(title: L10n.t("重启"),
                           icon: "arrow.triangle.2.circlepath") {
                restartTarget = proc
            },
            ActionMenuItem(title: L10n.t("源文"), icon: "doc.plaintext") {
                fileTarget = proc
            },
            ActionMenuItem(title: L10n.t("删除"), icon: "trash",
                           color: .red, role: .destructive) {
                deleteTarget = proc
            },
        ]
    }

    private func cardBody(_ proc: RuntimeSupervisorProcess) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(proc.displayName)
                        .font(.body.bold())
                    if busyNames.contains(proc.displayName) {
                        ProgressView().scaleEffect(0.7)
                    }
                    Spacer()
                    if let subs = proc.status, !subs.isEmpty {
                        Image(systemName: collapsedNames.contains(proc.displayName)
                              ? "chevron.down" : "chevron.up")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(proc.command ?? "—")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 12) {
                    if let user = proc.user, !user.isEmpty {
                        Label(user, systemImage: "person")
                    }
                    if let dir = proc.dir, !dir.isEmpty {
                        Label(dir, systemImage: "folder")
                    }
                    Label(L10n.f("×%@", proc.numprocs ?? "1"), systemImage: "square.stack")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)

                // 子进程状态（点击行收起/展开）
                if let subs = proc.status, !subs.isEmpty,
                   !collapsedNames.contains(proc.displayName) {
                    ForEach(Array(subs.enumerated()), id: \.offset) { _, sub in
                        HStack(spacing: 8) {
                            Image(systemName: sub.isRunning ? "circle.fill" : "circle.slash")
                                .font(.caption2)
                                .foregroundStyle(sub.isRunning ? Color.green : Color.secondary)
                            Text(sub.name ?? "—")
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            if let pid = sub.PID { Text("PID \(pid)").font(.caption2) }
                            if let up = sub.uptime, !up.isEmpty {
                                Text(up).font(.caption2)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func operate(_ op: String, _ proc: RuntimeSupervisorProcess?) async {
        guard let proc else { return }
        busyNames.insert(proc.displayName)
        defer { busyNames.remove(proc.displayName) }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.runtimesSupervisorOperate.path,
                body: RuntimeSupervisorOperateRequest(
                    operate: op, name: proc.displayName, id: entry.id
                ),
                as: EmptyResponse.self
            )
            if op == "delete" { deleteTarget = nil }
            toast = L10n.t("操作成功")
            await load()
        } catch {
            toast = L10n.f("操作失败：%@", error.localizedDescription)
        }
    }
}

// MARK: - 创建进程 Sheet

struct RuntimeSupervisorCreateSheet: View {
    let client: APIClient
    let runtimeID: Int
    /// nil = 创建；非 nil = 编辑（operate=update，名称锁定，字段回填）
    let editing: RuntimeSupervisorProcess?
    var onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var command = ""
    @State private var user = "www-data"
    @State private var dir = "/"
    @State private var numprocs = "1"
    @State private var autoStart = true
    @State private var autoRestart = true
    @State private var environment = ""
    @State private var isSaving = false
    @State private var toast: String?

    private var isEdit: Bool { editing != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    OutlinedTextField(label: L10n.t("名称"), text: $name)
                        .disabled(isEdit)
                    OutlinedMultiLineField(label: L10n.t("启动命令"), prompt: "php artisan queue:work",
                                           lines: 2, monospaced: true, text: $command)
                    OutlinedTextField(label: L10n.t("用户"), text: $user)
                    OutlinedTextField(label: L10n.t("运行目录"), text: $dir)
                    OutlinedTextField(label: L10n.t("进程数"), text: $numprocs,
                                      keyboardType: .numberPad)
                    OutlinedMultiLineField(label: L10n.t("环境变量"), prompt: "KEY=VALUE",
                                           lines: 2, monospaced: true, text: $environment)
                }
                Section {
                    Toggle(L10n.t("随容器启动"), isOn: $autoStart)
                    Toggle(L10n.t("异常自动重启"), isOn: $autoRestart)
                }
            }
            .navigationTitle(isEdit ? L10n.t("编辑进程") : L10n.t("创建进程"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(isEdit ? L10n.t("保存") : L10n.t("创建")) { Task { await save() } }
                            .disabled(name.isEmpty || command.isEmpty)
                    }
                }
            }
            .onAppear { prefill() }
            .toastOverlay(message: $toast)
        }
        .bottomSheetDetents([.medium, .large])
    }

    private func prefill() {
        guard let proc = editing else { return }
        name = proc.displayName
        command = proc.command ?? ""
        user = proc.user ?? "www-data"
        dir = proc.dir ?? "/"
        numprocs = proc.numprocs ?? "1"
        autoRestart = proc.autoRestartOn
        autoStart = proc.autoStartOn
        environment = proc.environment ?? ""
    }

    private func save() async {
        guard let n = Int(numprocs), n >= 1 else {
            toast = L10n.t("进程数需为正整数")
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.runtimesSupervisorOperate.path,
                body: RuntimeSupervisorCreateRequest(
                    operate: isEdit ? "update" : "create",
                    name: name, command: command, user: user, dir: dir,
                    numprocsNum: n, numprocs: String(n), id: runtimeID,
                    autoRestart: autoRestart ? "true" : "false",
                    autoStart: autoStart ? "true" : "false",
                    environment: environment
                ),
                as: EmptyResponse.self
            )
            onCreated()
            dismiss()
        } catch {
            toast = L10n.f(isEdit ? "保存失败：%@" : "创建失败：%@", error.localizedDescription)
        }
    }
}

// MARK: - 进程源文（get/update）

struct RuntimeSupervisorFileView: View {
    let client: APIClient
    let runtimeID: Int
    let processName: String

    @State private var content = ""
    @State private var original = ""
    @State private var isEditing = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var toast: String?
    @State private var isSaving = false

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView().padding(.top, 60)
            } else if let err = errorMessage {
                VStack(spacing: 12) {
                    Text(err).font(.footnote).foregroundStyle(.red)
                    Button(L10n.t("重试")) { Task { await load() } }
                }
            } else if isEditing {
                // 编辑：TextEditor 自滚动独占剩余空间（全 App 标准模式，
                // 避免「滚动容器包自滚动编辑器」的嵌套滚动/手势冲突）
                VStack(spacing: 12) {
                    CodeEditorArea(text: $content)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.small))
                }
                .padding(.vertical)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        CodeEditorArea(text: $content, readOnly: true)
                    }
                    .padding(.vertical)
                }
                .background(Color(.systemGroupedBackground))
            }
        }
        .navigationTitle(processName)
        .navigationBarTitleDisplayMode(.inline)
        .contentWidthLimit(860)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isEditing {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                    }
                    .disabled(isSaving || content == original)
                } else {
                    Button(L10n.t("编辑")) { isEditing = true }
                }
            }
        }
        .task { await load() }
        .toastOverlay(message: $toast)
        .onDisappear {
            if isEditing { content = original; isEditing = false }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            // 响应 data 即配置内容字符串
            let resp: APIResponse<String> = try await client.send(
                path: APIEndpoint.runtimesSupervisorFile.path,
                body: RuntimeSupervisorFileRequest(
                    name: processName, file: "config", operate: "get", content: "", id: runtimeID
                ),
                as: APIResponse<String>.self
            )
            content = resp.data ?? ""
            original = content
        } catch {
            if !APIError.isCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.runtimesSupervisorFile.path,
                body: RuntimeSupervisorFileRequest(
                    name: processName, file: "config", operate: "update",
                    content: content, id: runtimeID
                ),
                as: EmptyResponse.self
            )
            original = content
            isEditing = false
            toast = L10n.t("已保存")
        } catch {
            toast = L10n.f("保存失败：%@", error.localizedDescription)
        }
    }
}
